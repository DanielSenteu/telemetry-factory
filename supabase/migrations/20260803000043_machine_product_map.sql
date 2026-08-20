-- Machine integration Phase 2: product mapping.
-- Alias engine deployment #5: craft_id (raw OPC UA text) → product.
--
-- Once mapped, the dashboard shows "1,240 units of Part X" instead of
-- "1,240 shots", and the scrap % becomes meaningful per-product.
--
-- Three pieces:
--   1. machine_product_map table + RLS
--   2. map_machine_craft RPC (admin-only upsert)
--   3. unmapped_machine_crafts RPC (inbox query: crafts seen but not mapped)
--   4. machine_dashboard_snapshot extended with product_id + product_name

-- ── 1. machine_product_map ────────────────────────────────────────────────────
-- One row per (machine, craft_id): remembers the mapping forever.
-- cavity_override lets an admin correct a wrong live cavity count without
-- touching the OPC UA gateway (NULL = use the live mold_cavity value).

CREATE TABLE machine_product_map (
  id              SERIAL PRIMARY KEY,
  org_id          INTEGER NOT NULL REFERENCES organizations(id)  ON DELETE CASCADE,
  machine_id      INTEGER NOT NULL REFERENCES machines(id)       ON DELETE CASCADE,
  craft_id        TEXT    NOT NULL,
  product_id      INTEGER NOT NULL REFERENCES products(id)       ON DELETE RESTRICT,
  cavity_override SMALLINT,
  mapped_by       UUID    REFERENCES auth.users(id),
  mapped_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (org_id, machine_id, craft_id)
);

CREATE INDEX idx_machine_product_map_machine ON machine_product_map (machine_id);

ALTER TABLE machine_product_map ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org members view machine product map" ON machine_product_map
  FOR SELECT TO authenticated
  USING (org_id IN (SELECT user_org_ids()));

CREATE POLICY "Admins manage machine product map" ON machine_product_map
  FOR ALL TO authenticated
  USING  (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

-- RLS decides which rows; GRANT decides whether the role may touch the table.
GRANT SELECT, INSERT, UPDATE, DELETE ON machine_product_map TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE machine_product_map_id_seq TO authenticated;

-- ── 2. map_machine_craft ──────────────────────────────────────────────────────
-- Admin-only upsert. Calling with a different product_id for an existing
-- (machine, craft_id) remaps it — future readings attribute to the new product;
-- historic readings are untouched (append-only).

CREATE OR REPLACE FUNCTION map_machine_craft(
  p_org_id          INTEGER,
  p_machine_id      INTEGER,
  p_craft_id        TEXT,
  p_product_id      INTEGER,
  p_cavity_override SMALLINT DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT is_org_admin(p_org_id) THEN
    RAISE EXCEPTION 'Only org admins can map machine crafts';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM machines WHERE id = p_machine_id AND org_id = p_org_id
  ) THEN
    RAISE EXCEPTION 'Machine not found in this org';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM products WHERE id = p_product_id AND org_id = p_org_id
  ) THEN
    RAISE EXCEPTION 'Product not found in this org';
  END IF;

  INSERT INTO machine_product_map
    (org_id, machine_id, craft_id, product_id, cavity_override, mapped_by)
  VALUES
    (p_org_id, p_machine_id, p_craft_id, p_product_id, p_cavity_override, auth.uid())
  ON CONFLICT (org_id, machine_id, craft_id) DO UPDATE SET
    product_id      = EXCLUDED.product_id,
    cavity_override = EXCLUDED.cavity_override,
    mapped_by       = EXCLUDED.mapped_by,
    mapped_at       = now();
END;
$$;

GRANT EXECUTE ON FUNCTION map_machine_craft(INTEGER, INTEGER, TEXT, INTEGER, SMALLINT)
  TO authenticated;

-- ── 3. unmapped_machine_crafts ────────────────────────────────────────────────
-- Returns distinct (machine, craft_id) pairs seen in the last 24 h that have
-- no mapping yet. This drives the "unmapped crafts inbox" on the dashboard.
-- Runs as INVOKER — RLS on machine_readings + machines scopes it to the
-- caller's org automatically; p_org_id is an extra index hint, not the guard.

CREATE OR REPLACE FUNCTION unmapped_machine_crafts(p_org_id INTEGER)
RETURNS TABLE (
  machine_id   INTEGER,
  machine_name TEXT,
  craft_id     TEXT,
  last_seen_at TIMESTAMPTZ
)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT DISTINCT ON (m.id, r.craft_id)
    m.id          AS machine_id,
    m.name        AS machine_name,
    r.craft_id,
    r.observed_at AS last_seen_at
  FROM machine_readings r
  JOIN machines m ON m.id = r.machine_id
  WHERE m.org_id = p_org_id
    AND r.craft_id IS NOT NULL
    AND r.craft_id <> ''
    AND r.observed_at >= now() - interval '24 hours'
    AND NOT EXISTS (
      SELECT 1 FROM machine_product_map mp
      WHERE mp.org_id   = p_org_id
        AND mp.machine_id = r.machine_id
        AND mp.craft_id   = r.craft_id
    )
  ORDER BY m.id, r.craft_id, r.observed_at DESC;
$$;

GRANT EXECUTE ON FUNCTION unmapped_machine_crafts(INTEGER) TO authenticated;

-- ── 4. machine_dashboard_snapshot (extended) ──────────────────────────────────
-- Adds product_id + product_name by left-joining machine_product_map on the
-- current craft_id from the latest reading.
-- NULL product_name = this craft_id has not been mapped yet (show "Unmapped").

DROP FUNCTION IF EXISTS machine_dashboard_snapshot(INTEGER, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION machine_dashboard_snapshot(
  p_org_id INTEGER,
  p_since  TIMESTAMPTZ
) RETURNS TABLE (
  machine_id        INTEGER,
  name              TEXT,
  mac               TEXT,
  ip                TEXT,
  machine_type      TEXT,
  observed_at       TIMESTAMPTZ,
  online_state      SMALLINT,
  operate_mode      SMALLINT,
  motor_state       SMALLINT,
  heat_state        SMALLINT,
  cycle_time        DOUBLE PRECISION,
  craft_id          TEXT,
  material          TEXT,
  mold_cavity       SMALLINT,
  plan_count        BIGINT,
  power_kwh         DOUBLE PRECISION,
  alarms            JSONB,
  shot_count        BIGINT,
  today_shots       BIGINT,
  today_scrap       DOUBLE PRECISION,
  today_parts_gross BIGINT,
  recent_shots      BIGINT,
  product_id        INTEGER,
  product_name      TEXT
)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  WITH win AS (
    SELECT r.machine_id, r.observed_at, r.shot_count, r.inferior_count, r.mold_cavity
    FROM machine_readings r
    WHERE r.org_id = p_org_id AND r.observed_at >= p_since
    UNION ALL
    SELECT s.machine_id, s.observed_at, s.shot_count, s.inferior_count, s.mold_cavity
    FROM machines m
    CROSS JOIN LATERAL (
      SELECT r.machine_id, r.observed_at, r.shot_count, r.inferior_count, r.mold_cavity
      FROM machine_readings r
      WHERE r.machine_id = m.id AND r.observed_at < p_since
      ORDER BY r.observed_at DESC
      LIMIT 1
    ) s
    WHERE m.org_id = p_org_id
  ), d AS (
    SELECT w.*,
      lag(w.shot_count)     OVER (PARTITION BY w.machine_id ORDER BY w.observed_at) AS prev_shot,
      lag(w.inferior_count) OVER (PARTITION BY w.machine_id ORDER BY w.observed_at) AS prev_inf
    FROM win w
  ), deltas AS (
    SELECT d.machine_id, d.observed_at, d.mold_cavity,
      CASE WHEN d.shot_count IS NULL OR d.prev_shot IS NULL THEN NULL
           WHEN d.shot_count < d.prev_shot THEN d.shot_count
           ELSE d.shot_count - d.prev_shot END AS shots_delta,
      CASE WHEN d.inferior_count IS NULL OR d.prev_inf IS NULL THEN NULL
           WHEN d.inferior_count < d.prev_inf THEN d.inferior_count
           ELSE d.inferior_count - d.prev_inf END AS scrap_delta
    FROM d
    WHERE d.observed_at >= p_since
  ), today AS (
    SELECT dl.machine_id,
      COALESCE(SUM(dl.shots_delta), 0)::BIGINT                                          AS today_shots,
      COALESCE(SUM(dl.scrap_delta), 0)                                                  AS today_scrap,
      COALESCE(SUM(dl.shots_delta * COALESCE(dl.mold_cavity, 1)), 0)::BIGINT            AS today_parts_gross,
      COALESCE(SUM(dl.shots_delta) FILTER (
        WHERE dl.observed_at >= now() - interval '3 minutes'), 0)::BIGINT               AS recent_shots
    FROM deltas dl
    GROUP BY dl.machine_id
  )
  SELECT m.id, m.name, m.mac, m.ip, m.machine_type,
    lr.observed_at, lr.online_state, lr.operate_mode, lr.motor_state,
    lr.heat_state, lr.cycle_time, lr.craft_id, lr.material, lr.mold_cavity,
    lr.plan_count, lr.power_kwh, lr.alarms, lr.shot_count,
    COALESCE(t.today_shots, 0), COALESCE(t.today_scrap, 0),
    COALESCE(t.today_parts_gross, 0), COALESCE(t.recent_shots, 0),
    pm.product_id,
    p.name AS product_name
  FROM machines m
  LEFT JOIN LATERAL (
    SELECT r.*
    FROM machine_readings r
    WHERE r.machine_id = m.id
    ORDER BY r.observed_at DESC
    LIMIT 1
  ) lr ON true
  LEFT JOIN today t ON t.machine_id = m.id
  LEFT JOIN machine_product_map pm
    ON  pm.org_id     = p_org_id
    AND pm.machine_id = m.id
    AND pm.craft_id   = lr.craft_id
  LEFT JOIN products p ON p.id = pm.product_id
  WHERE m.org_id = p_org_id AND m.active
  ORDER BY m.id;
$$;

GRANT EXECUTE ON FUNCTION machine_dashboard_snapshot(INTEGER, TIMESTAMPTZ) TO authenticated;
