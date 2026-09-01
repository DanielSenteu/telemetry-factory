-- Migration 64: recipe stages + "what was wrapped today?" posting
--
-- The formula for wrapping a product belongs to the PRODUCT (its recipe);
-- which product a machine wrapped today belongs to the MACHINE-DAY (chosen
-- at post time). So:
--
-- 1. bom_lines.stage — 'moulding' (default; every existing line unchanged)
--    or 'packaging'. confirm_machine_output consumes ONLY moulding lines;
--    the wrapper's post consumes ONLY packaging lines. One recipe, whole
--    product story, each machine bills its own stage.
--
-- 2. post_count_action gains p_product_id: pick the wrapped product and the
--    day's counts flow through that product's packaging lines. The receipt
--    records which product was posted. Without a product it falls back to
--    the machine's fixed action ("each count uses 1 wrapper").
--
-- 3. REMOVED: the 'bom' kind on machine_count_actions (and its bom_id).
--    Pointing at a formula from the machine was the duplication we decided
--    against — the product picker at post time replaces it. The table is now
--    just the fixed fallback: product + qty per count.

-- ── 1. Stage on recipe lines ──────────────────────────────────────────────────

ALTER TABLE bom_lines
  ADD COLUMN stage TEXT NOT NULL DEFAULT 'moulding'
  CHECK (stage IN ('moulding', 'packaging'));

COMMENT ON COLUMN bom_lines.stage IS
  'When this line is consumed: at the moulder''s confirm (moulding) or at the wrapper/sealer''s post (packaging).';

DROP FUNCTION IF EXISTS upsert_bom_line(INTEGER, INTEGER, INTEGER, NUMERIC, TEXT, NUMERIC);

CREATE OR REPLACE FUNCTION upsert_bom_line(
  p_org_id       INTEGER,
  p_product_id   INTEGER,
  p_component_id INTEGER,
  p_qty          NUMERIC,
  p_uom          TEXT,
  p_per_units    NUMERIC DEFAULT 1,
  p_stage        TEXT DEFAULT 'moulding'
) RETURNS INTEGER
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

  IF p_stage NOT IN ('moulding', 'packaging') THEN
    RAISE EXCEPTION 'stage must be moulding or packaging';
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

  INSERT INTO bom_lines (bom_id, org_id, component_product_id, qty_per_unit, uom, per_units, stage)
  VALUES (v_bom_id, p_org_id, p_component_id, p_qty, p_uom, p_per_units, p_stage)
  ON CONFLICT (bom_id, component_product_id) DO UPDATE SET
    qty_per_unit = EXCLUDED.qty_per_unit,
    uom          = EXCLUDED.uom,
    per_units    = EXCLUDED.per_units,
    stage        = EXCLUDED.stage
  RETURNING id INTO v_line_id;

  RETURN v_line_id;
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_bom_line(INTEGER, INTEGER, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT)
  TO authenticated;

-- confirm_machine_output: consume MOULDING lines only.
CREATE OR REPLACE FUNCTION confirm_machine_output(
  p_org_id     INTEGER,
  p_machine_id INTEGER,
  p_product_id INTEGER,
  p_good_qty   NUMERIC,
  p_scrap_qty  NUMERIC,
  p_run_date   DATE DEFAULT CURRENT_DATE
) RETURNS INTEGER
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
      FROM bom_lines WHERE bom_id = v_bom_id AND stage = 'moulding'
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

-- ── 2 & 3. Simplify the fixed action; product-aware posting ───────────────────

DELETE FROM machine_count_actions WHERE kind = 'bom';
ALTER TABLE machine_count_actions DROP CONSTRAINT machine_count_actions_check;
ALTER TABLE machine_count_actions DROP COLUMN bom_id;
ALTER TABLE machine_count_actions DROP COLUMN kind;
ALTER TABLE machine_count_actions
  ALTER COLUMN product_id SET NOT NULL,
  ALTER COLUMN qty_per_count SET NOT NULL;

COMMENT ON TABLE machine_count_actions IS
  'Fixed per-count fallback for action machines: each count consumes qty_per_count of product_id. Product-specific packaging is posted via post_count_action(p_product_id) instead.';

-- The receipt now records which product was posted (NULL = fixed action).
ALTER TABLE count_action_posts
  ADD COLUMN product_id INTEGER REFERENCES products(id);

DROP FUNCTION IF EXISTS post_count_action(INTEGER, INTEGER, DATE, NUMERIC);

CREATE OR REPLACE FUNCTION post_count_action(
  p_org_id          INTEGER,
  p_machine_id      INTEGER,
  p_day             DATE DEFAULT NULL,
  p_counts_override NUMERIC DEFAULT NULL,
  p_product_id      INTEGER DEFAULT NULL   -- the product wrapped that day
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_day      DATE;
  v_action   RECORD;
  v_counts   NUMERIC;
  v_post_id  INTEGER;
  v_bom_id   INTEGER;
  v_avg_cost NUMERIC;
  v_line     RECORD;
  v_lines    INTEGER := 0;
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

  SELECT shots INTO v_counts
  FROM machine_day_production
  WHERE machine_id = p_machine_id AND day = v_day;
  v_counts := COALESCE(p_counts_override, v_counts, 0);

  IF v_counts <= 0 THEN
    RAISE EXCEPTION 'No counts recorded for % on %', p_machine_id, v_day;
  END IF;

  IF p_product_id IS NOT NULL THEN
    -- "What was wrapped today?" → consume the product's PACKAGING lines.
    IF NOT EXISTS (
      SELECT 1 FROM products
      WHERE id = p_product_id AND org_id = p_org_id AND kind = 'finished_good'
    ) THEN
      RAISE EXCEPTION 'Product not found or is not a finished good';
    END IF;

    SELECT id INTO v_bom_id
    FROM boms
    WHERE org_id = p_org_id AND product_id = p_product_id AND active = true
    LIMIT 1;

    IF v_bom_id IS NULL THEN
      RAISE EXCEPTION 'Product has no recipe — add its packaging lines first';
    END IF;

    INSERT INTO count_action_posts (org_id, machine_id, day, counts, product_id, posted_by)
    VALUES (p_org_id, p_machine_id, v_day, v_counts, p_product_id, auth.uid())
    RETURNING id INTO v_post_id;

    FOR v_line IN
      SELECT component_product_id, qty_per_unit, uom, per_units
      FROM bom_lines WHERE bom_id = v_bom_id AND stage = 'packaging'
    LOOP
      v_lines := v_lines + 1;
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
         v_counts::text || ' wrapped: ' || v_line.qty_per_unit::text || ' ' || v_line.uom ||
         CASE WHEN v_line.per_units = 1 THEN '' ELSE ' per ' || v_line.per_units::text END ||
         ' on ' || v_day::text);
    END LOOP;

    IF v_lines = 0 THEN
      RAISE EXCEPTION 'Product has no packaging lines in its recipe';
    END IF;

    RETURN v_post_id;
  END IF;

  -- No product chosen → the machine's fixed fallback action.
  SELECT * INTO v_action
  FROM machine_count_actions
  WHERE machine_id = p_machine_id AND org_id = p_org_id;
  IF v_action IS NULL THEN
    RAISE EXCEPTION 'No per-count action configured for this machine';
  END IF;

  INSERT INTO count_action_posts (org_id, machine_id, day, counts, posted_by)
  VALUES (p_org_id, p_machine_id, v_day, v_counts, auth.uid())
  RETURNING id INTO v_post_id;

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

  RETURN v_post_id;
END;
$$;

GRANT EXECUTE ON FUNCTION post_count_action(INTEGER, INTEGER, DATE, NUMERIC, INTEGER)
  TO authenticated;
