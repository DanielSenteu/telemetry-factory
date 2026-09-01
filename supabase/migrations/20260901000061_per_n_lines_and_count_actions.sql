-- Migration 61: per-N recipe lines + per-count actions for action machines
--
-- 1. bom_lines.per_units — a line now says "N units consume X of Y"
--    (500 caps → 1 box). Default 1 keeps every existing recipe meaning
--    exactly what it meant. Posting stays FRACTIONAL in the ledger (exact,
--    conserves material); displays round to whole units; physical counts
--    true it up. No separate rules engine — meaning lives in the recipe
--    (CONVENTIONS rule 8).
--
-- 2. machine_count_actions — an action machine (CV-350: each count = one
--    finished unit) gets a configured "per count, do this": apply a recipe,
--    or a simple stock movement ("each count uses 1 wrapper"). Counts accrue
--    through machine_day_production; posting happens ONCE per day as a single
--    aggregated movement via post_count_action — never per-count rows.
--    Idempotent: one post per machine per day (rule 4). The machine's own
--    product is NOT produced/consumed here — the moulder already counted it
--    (no double-counting); transform mode can be added later without a new
--    table.

-- ── 1. Per-N recipe lines ─────────────────────────────────────────────────────

ALTER TABLE bom_lines
  ADD COLUMN per_units NUMERIC(12,3) NOT NULL DEFAULT 1 CHECK (per_units > 0);

COMMENT ON COLUMN bom_lines.per_units IS
  'The line consumes qty_per_unit of the component per THIS MANY units of the product (default 1).';

DROP FUNCTION IF EXISTS upsert_bom_line(INTEGER, INTEGER, INTEGER, NUMERIC, TEXT);

CREATE OR REPLACE FUNCTION upsert_bom_line(
  p_org_id       INTEGER,
  p_product_id   INTEGER,   -- must be finished_good
  p_component_id INTEGER,   -- must be raw_material or consumable
  p_qty          NUMERIC,
  p_uom          TEXT,
  p_per_units    NUMERIC DEFAULT 1
) RETURNS INTEGER            -- returns the bom_line id
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_bom_id  INTEGER;
  v_line_id INTEGER;
BEGIN
  IF NOT is_org_admin(p_org_id) THEN
    RAISE EXCEPTION 'Only org admins can manage BOMs';
  END IF;

  IF p_per_units IS NULL OR p_per_units <= 0 THEN
    RAISE EXCEPTION 'per_units must be a positive number';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM products
    WHERE id = p_product_id AND org_id = p_org_id AND kind = 'finished_good'
  ) THEN
    RAISE EXCEPTION 'Product not found or is not a finished good';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM products
    WHERE id = p_component_id AND org_id = p_org_id
      AND kind IN ('raw_material', 'consumable')
  ) THEN
    RAISE EXCEPTION 'Component not found or is not a raw material / consumable';
  END IF;

  SELECT id INTO v_bom_id
  FROM boms
  WHERE org_id = p_org_id AND product_id = p_product_id AND active = true
  LIMIT 1;

  IF v_bom_id IS NULL THEN
    INSERT INTO boms (org_id, product_id, version, active, created_by)
    VALUES (p_org_id, p_product_id, 1, true, auth.uid())
    RETURNING id INTO v_bom_id;
  END IF;

  INSERT INTO bom_lines (bom_id, org_id, component_product_id, qty_per_unit, uom, per_units)
  VALUES (v_bom_id, p_org_id, p_component_id, p_qty, p_uom, p_per_units)
  ON CONFLICT (bom_id, component_product_id) DO UPDATE SET
    qty_per_unit = EXCLUDED.qty_per_unit,
    uom          = EXCLUDED.uom,
    per_units    = EXCLUDED.per_units
  RETURNING id INTO v_line_id;

  RETURN v_line_id;
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_bom_line(INTEGER, INTEGER, INTEGER, NUMERIC, TEXT, NUMERIC)
  TO authenticated;

-- confirm_machine_output: consumption honours per_units.
-- (Same function as migration 48/53 otherwise; consumption divides by the
-- line's per_units, and so does the rolled unit cost.)
CREATE OR REPLACE FUNCTION confirm_machine_output(
  p_org_id     INTEGER,
  p_machine_id INTEGER,
  p_product_id INTEGER,
  p_good_qty   NUMERIC,
  p_scrap_qty  NUMERIC,
  p_run_date   DATE DEFAULT CURRENT_DATE
) RETURNS INTEGER   -- the production_run id
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_run_id      INTEGER;
  v_bom_id      INTEGER;
  v_cavities    SMALLINT;
  v_runner_g    NUMERIC;
  v_runner_mat  INTEGER;
  v_rolled_cost NUMERIC := 0;
  v_avg_cost    NUMERIC;
  v_shots       NUMERIC;
  v_line        RECORD;
BEGIN
  IF NOT is_org_admin(p_org_id) THEN
    RAISE EXCEPTION 'Only org admins can confirm production runs';
  END IF;

  SELECT id INTO v_run_id
  FROM production_runs
  WHERE org_id     = p_org_id
    AND machine_id = p_machine_id
    AND product_id = p_product_id
    AND run_date   = p_run_date
    AND status     = 'confirmed';

  IF v_run_id IS NOT NULL THEN
    RETURN v_run_id;
  END IF;

  SELECT id, cavities, runner_weight_g, runner_material_product_id
  INTO v_bom_id, v_cavities, v_runner_g, v_runner_mat
  FROM boms
  WHERE org_id = p_org_id AND product_id = p_product_id AND active = true
  LIMIT 1;

  INSERT INTO production_runs
    (org_id, machine_id, product_id, bom_id, run_date,
     good_qty, scrap_qty, status, confirmed_by, confirmed_at)
  VALUES
    (p_org_id, p_machine_id, p_product_id, v_bom_id, p_run_date,
     p_good_qty, p_scrap_qty, 'confirmed', auth.uid(), now())
  RETURNING id INTO v_run_id;

  INSERT INTO stock_movements
    (org_id, product_id, quantity, movement_type, source_type, source_id, note)
  VALUES
    (p_org_id, p_product_id, p_good_qty, 'production_output',
     'production_run', v_run_id,
     'Production confirmed ' || p_run_date::text);

  IF v_bom_id IS NOT NULL THEN
    FOR v_line IN
      SELECT component_product_id, qty_per_unit, uom, per_units
      FROM bom_lines WHERE bom_id = v_bom_id
    LOOP
      SELECT COALESCE(
        SUM(sm.quantity * sm.unit_cost) FILTER (WHERE sm.quantity > 0 AND sm.unit_cost IS NOT NULL)
        / NULLIF(SUM(sm.quantity) FILTER (WHERE sm.quantity > 0 AND sm.unit_cost IS NOT NULL), 0),
        0
      ) INTO v_avg_cost
      FROM stock_movements sm
      WHERE sm.product_id = v_line.component_product_id AND sm.org_id = p_org_id;

      INSERT INTO stock_movements
        (org_id, product_id, quantity, movement_type, unit_cost,
         source_type, source_id, note)
      VALUES
        (p_org_id, v_line.component_product_id,
         -(v_line.qty_per_unit * p_good_qty / v_line.per_units),
         'production_consume', v_avg_cost,
         'production_run', v_run_id,
         v_line.qty_per_unit::text || ' ' || v_line.uom ||
         CASE WHEN v_line.per_units = 1 THEN '' ELSE ' per ' || v_line.per_units::text END ||
         ' × ' || p_good_qty::text || ' units consumed');

      v_rolled_cost := v_rolled_cost + (v_avg_cost * v_line.qty_per_unit / v_line.per_units);
    END LOOP;

    UPDATE stock_movements
    SET unit_cost = v_rolled_cost
    WHERE source_type   = 'production_run'
      AND source_id     = v_run_id
      AND movement_type = 'production_output';

    IF v_cavities IS NOT NULL AND v_cavities > 0
      AND v_runner_g IS NOT NULL
      AND v_runner_mat IS NOT NULL
    THEN
      v_shots := ROUND(p_good_qty::numeric / v_cavities);
      INSERT INTO regrind_movements
        (org_id, material_product_id, qty_g, direction, source_type, source_id, note, created_by)
      VALUES
        (p_org_id, v_runner_mat,
         v_shots * v_runner_g,
         'in', 'production_run', v_run_id,
         v_shots::text || ' shots × ' || v_runner_g::text || 'g runner',
         auth.uid());
    END IF;
  END IF;

  RETURN v_run_id;
END;
$$;

GRANT EXECUTE ON FUNCTION confirm_machine_output(INTEGER, INTEGER, INTEGER, NUMERIC, NUMERIC, DATE)
  TO authenticated;

-- ── 2. Per-count actions ──────────────────────────────────────────────────────

CREATE TABLE machine_count_actions (
  machine_id INTEGER PRIMARY KEY REFERENCES machines(id) ON DELETE CASCADE,
  org_id     INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  kind       TEXT NOT NULL CHECK (kind IN ('movement', 'bom')),
  -- kind = 'movement': each count moves qty_per_count of product_id (consume)
  product_id    INTEGER REFERENCES products(id) ON DELETE RESTRICT,
  qty_per_count NUMERIC(14,4) CHECK (qty_per_count IS NULL OR qty_per_count > 0),
  -- kind = 'bom': each count applies this recipe's lines (per_units honoured)
  bom_id     INTEGER REFERENCES boms(id) ON DELETE RESTRICT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (
    (kind = 'movement' AND product_id IS NOT NULL AND qty_per_count IS NOT NULL AND bom_id IS NULL) OR
    (kind = 'bom'      AND bom_id IS NOT NULL AND product_id IS NULL AND qty_per_count IS NULL)
  )
);

ALTER TABLE machine_count_actions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org members view count actions" ON machine_count_actions
  FOR SELECT TO authenticated
  USING (org_id IN (SELECT user_org_ids()));

CREATE POLICY "Admins manage count actions" ON machine_count_actions
  FOR ALL TO authenticated
  USING (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON machine_count_actions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON machine_count_actions TO service_role;

-- One post per machine per day — the idempotency spine (rule 4).
CREATE TABLE count_action_posts (
  id         SERIAL PRIMARY KEY,
  org_id     INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  machine_id INTEGER NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
  day        DATE NOT NULL,          -- Nairobi day, same bucketing as the ledger
  counts     NUMERIC(14,3) NOT NULL,
  posted_by  UUID,
  posted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (machine_id, day)
);

ALTER TABLE count_action_posts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org members view count action posts" ON count_action_posts
  FOR SELECT TO authenticated
  USING (org_id IN (SELECT user_org_ids()));

GRANT SELECT ON count_action_posts TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON count_action_posts TO service_role;
GRANT USAGE, SELECT ON SEQUENCE count_action_posts_id_seq TO authenticated, service_role;

-- Post one day's accumulated counts through the machine's configured action.
-- Counts come from machine_day_production (guarded at ingestion); the operator
-- can override when the physical count disagrees. Run twice = run once.
CREATE OR REPLACE FUNCTION post_count_action(
  p_org_id          INTEGER,
  p_machine_id      INTEGER,
  p_day             DATE DEFAULT NULL,   -- Nairobi day; default today (EAT)
  p_counts_override NUMERIC DEFAULT NULL
) RETURNS INTEGER   -- the count_action_posts id
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_day      DATE;
  v_action   RECORD;
  v_counts   NUMERIC;
  v_post_id  INTEGER;
  v_avg_cost NUMERIC;
  v_line     RECORD;
BEGIN
  IF NOT is_org_admin(p_org_id) THEN
    RAISE EXCEPTION 'Only org admins can post count actions';
  END IF;

  v_day := COALESCE(p_day, (now() AT TIME ZONE 'Africa/Nairobi')::date);

  SELECT id INTO v_post_id
  FROM count_action_posts
  WHERE machine_id = p_machine_id AND day = v_day;
  IF v_post_id IS NOT NULL THEN
    RETURN v_post_id;   -- already posted; run twice = run once
  END IF;

  SELECT * INTO v_action
  FROM machine_count_actions
  WHERE machine_id = p_machine_id AND org_id = p_org_id;
  IF v_action IS NULL THEN
    RAISE EXCEPTION 'No per-count action configured for this machine';
  END IF;

  SELECT shots INTO v_counts
  FROM machine_day_production
  WHERE machine_id = p_machine_id AND day = v_day;
  v_counts := COALESCE(p_counts_override, v_counts, 0);

  IF v_counts <= 0 THEN
    RAISE EXCEPTION 'No counts recorded for % on %', p_machine_id, v_day;
  END IF;

  INSERT INTO count_action_posts (org_id, machine_id, day, counts, posted_by)
  VALUES (p_org_id, p_machine_id, v_day, v_counts, auth.uid())
  RETURNING id INTO v_post_id;

  IF v_action.kind = 'movement' THEN
    SELECT COALESCE(
      SUM(sm.quantity * sm.unit_cost) FILTER (WHERE sm.quantity > 0 AND sm.unit_cost IS NOT NULL)
      / NULLIF(SUM(sm.quantity) FILTER (WHERE sm.quantity > 0 AND sm.unit_cost IS NOT NULL), 0),
      0
    ) INTO v_avg_cost
    FROM stock_movements sm
    WHERE sm.product_id = v_action.product_id AND sm.org_id = p_org_id;

    INSERT INTO stock_movements
      (org_id, product_id, quantity, movement_type, unit_cost, source_type, source_id, note)
    VALUES
      (p_org_id, v_action.product_id,
       -(v_action.qty_per_count * v_counts),
       'production_consume', v_avg_cost,
       'count_action', v_post_id,
       v_counts::text || ' counts × ' || v_action.qty_per_count::text || ' on ' || v_day::text);
  ELSE
    FOR v_line IN
      SELECT component_product_id, qty_per_unit, uom, per_units
      FROM bom_lines WHERE bom_id = v_action.bom_id
    LOOP
      SELECT COALESCE(
        SUM(sm.quantity * sm.unit_cost) FILTER (WHERE sm.quantity > 0 AND sm.unit_cost IS NOT NULL)
        / NULLIF(SUM(sm.quantity) FILTER (WHERE sm.quantity > 0 AND sm.unit_cost IS NOT NULL), 0),
        0
      ) INTO v_avg_cost
      FROM stock_movements sm
      WHERE sm.product_id = v_line.component_product_id AND sm.org_id = p_org_id;

      INSERT INTO stock_movements
        (org_id, product_id, quantity, movement_type, unit_cost, source_type, source_id, note)
      VALUES
        (p_org_id, v_line.component_product_id,
         -(v_line.qty_per_unit * v_counts / v_line.per_units),
         'production_consume', v_avg_cost,
         'count_action', v_post_id,
         v_counts::text || ' counts: ' || v_line.qty_per_unit::text || ' ' || v_line.uom ||
         CASE WHEN v_line.per_units = 1 THEN '' ELSE ' per ' || v_line.per_units::text END ||
         ' on ' || v_day::text);
    END LOOP;
  END IF;

  RETURN v_post_id;
END;
$$;

GRANT EXECUTE ON FUNCTION post_count_action(INTEGER, INTEGER, DATE, NUMERIC)
  TO authenticated;
