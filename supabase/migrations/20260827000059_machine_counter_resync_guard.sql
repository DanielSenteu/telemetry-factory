-- Migration 59: reject counter re-sync jumps in machine_dashboard_snapshot
--
-- Incident (2026-08-26, Haijing-HJ168S): after a factory power cut the
-- controller briefly reports shot_count=0 (cycle_time=0, craft NULL), then
-- restores its cumulative counter — 0 → 130,943 within one ~16s polling gap.
-- The delta logic handled the drop (reset branch contributes ~0) but read the
-- restore as real production, so one day showed 265,205 shots against a true
-- ~2,765. Every power cut re-added the machine's entire lifetime count.
--
-- Fix: a physical-plausibility ceiling derived from the machine's OWN
-- telemetry — it cannot mold faster than one shot per cycle_time seconds.
-- A delta larger than elapsed/cycle_time (with 2x slack + 3-shot floor for
-- polling jitter) is a counter re-sync, not production, and contributes
-- nothing. Nothing is configured per machine: every reading carries the
-- machine's reported cycle_time. When the controller reports cycle_time 0/NULL
-- (boot state) a 1 s/shot backstop applies — still generous, no real machine
-- cycles under a second, and observed re-sync jumps overshoot the ceiling by
-- four orders of magnitude.
--
-- Genuine cases stay counted: an operator counter reset climbs at production
-- speed (passes), and queued collector data keeps its original observed_at so
-- its deltas are spread over real elapsed time (passes).

DROP FUNCTION IF EXISTS machine_dashboard_snapshot(INTEGER, TIMESTAMPTZ, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION machine_dashboard_snapshot(
  p_org_id INTEGER,
  p_since  TIMESTAMPTZ,
  p_until  TIMESTAMPTZ DEFAULT NULL
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
    -- Period readings
    SELECT r.machine_id, r.observed_at, r.shot_count, r.inferior_count, r.mold_cavity, r.cycle_time
    FROM machine_readings r
    WHERE r.org_id = p_org_id
      AND r.observed_at >= p_since
      AND (p_until IS NULL OR r.observed_at < p_until)
    UNION ALL
    -- One seed row per machine from just before p_since so the first delta
    -- of the period is correct (without it the first reading looks like 0 delta).
    SELECT s.machine_id, s.observed_at, s.shot_count, s.inferior_count, s.mold_cavity, s.cycle_time
    FROM machines m
    CROSS JOIN LATERAL (
      SELECT r.machine_id, r.observed_at, r.shot_count, r.inferior_count, r.mold_cavity, r.cycle_time
      FROM machine_readings r
      WHERE r.machine_id = m.id AND r.observed_at < p_since
      ORDER BY r.observed_at DESC
      LIMIT 1
    ) s
    WHERE m.org_id = p_org_id
  ), d AS (
    SELECT w.*,
      lag(w.shot_count)     OVER mw AS prev_shot,
      lag(w.inferior_count) OVER mw AS prev_inf,
      lag(w.observed_at)    OVER mw AS prev_at
    FROM win w
    WINDOW mw AS (PARTITION BY w.machine_id ORDER BY w.observed_at)
  ), raw AS (
    SELECT d.machine_id, d.observed_at, d.mold_cavity,
      CASE WHEN d.shot_count IS NULL OR d.prev_shot IS NULL THEN NULL
           WHEN d.shot_count < d.prev_shot THEN d.shot_count
           ELSE d.shot_count - d.prev_shot END AS shots_raw,
      CASE WHEN d.inferior_count IS NULL OR d.prev_inf IS NULL THEN NULL
           WHEN d.inferior_count < d.prev_inf THEN d.inferior_count
           ELSE d.inferior_count - d.prev_inf END AS scrap_raw,
      -- Most shots this machine could physically mold in the gap, from its own
      -- reported cycle. 2x slack + 3-shot floor absorb polling jitter; scrap
      -- parts are parts, so the same ceiling bounds scrap_raw.
      extract(epoch FROM (d.observed_at - d.prev_at))
        / GREATEST(COALESCE(NULLIF(d.cycle_time, 0), 1), 1) * 2 + 3 AS max_plausible
    FROM d
  ), deltas AS (
    SELECT r.machine_id, r.observed_at, r.mold_cavity,
      CASE WHEN r.shots_raw > r.max_plausible THEN NULL ELSE r.shots_raw END AS shots_delta,
      CASE WHEN r.scrap_raw > r.max_plausible THEN NULL ELSE r.scrap_raw END AS scrap_delta
    FROM raw r
    WHERE r.observed_at >= p_since
      AND (p_until IS NULL OR r.observed_at < p_until)
  ), today AS (
    SELECT dl.machine_id,
      COALESCE(SUM(dl.shots_delta), 0)::BIGINT                                        AS today_shots,
      COALESCE(SUM(dl.scrap_delta), 0)                                                AS today_scrap,
      COALESCE(SUM(dl.shots_delta * COALESCE(dl.mold_cavity, 1)), 0)::BIGINT          AS today_parts_gross,
      COALESCE(SUM(dl.shots_delta) FILTER (
        WHERE dl.observed_at >= now() - interval '3 minutes'), 0)::BIGINT             AS recent_shots
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
  -- Latest reading within the queried period (or ever, if no upper bound)
  LEFT JOIN LATERAL (
    SELECT r.*
    FROM machine_readings r
    WHERE r.machine_id = m.id
      AND (p_until IS NULL OR r.observed_at < p_until)
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

GRANT EXECUTE ON FUNCTION machine_dashboard_snapshot(INTEGER, TIMESTAMPTZ, TIMESTAMPTZ)
  TO authenticated;
