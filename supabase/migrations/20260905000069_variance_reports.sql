-- Migration 69: variance reports — the floor grades the system's counting
--
-- Every confirmation now records BOTH numbers: what the system counted
-- (shown to the operator) and what the floor said actually happened. The
-- operator's number always wins in stock — reality is the authority — and
-- the pair becomes a daily accuracy record per (machine, product):
--   error % = |system − floor| ÷ floor × 100   (reality is the denominator)
--   accuracy % = 100 − error
-- Agreeing with the shown number is a 100%-accuracy line; correcting it
-- measures exactly how wrong the counting chain was, which points at wrong
-- cavities, scrap leaks, or theft. variance_report() serves the daily lines.

ALTER TABLE production_runs   ADD COLUMN system_qty    NUMERIC;
ALTER TABLE count_action_posts ADD COLUMN system_counts NUMERIC;

-- confirm_machine_output gains p_system_qty (the number we showed).
DROP FUNCTION IF EXISTS confirm_machine_output(INTEGER, INTEGER, INTEGER, NUMERIC, NUMERIC, DATE);

CREATE OR REPLACE FUNCTION confirm_machine_output(
  p_org_id     INTEGER,
  p_machine_id INTEGER,
  p_product_id INTEGER,
  p_good_qty   NUMERIC,
  p_scrap_qty  NUMERIC,
  p_run_date   DATE DEFAULT CURRENT_DATE,
  p_system_qty NUMERIC DEFAULT NULL
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
     good_qty, scrap_qty, system_qty, status, confirmed_by, confirmed_at)
  VALUES
    (p_org_id, p_machine_id, p_product_id, v_bom_id, p_run_date,
     p_good_qty, p_scrap_qty, p_system_qty, 'confirmed', auth.uid(), now())
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

GRANT EXECUTE ON FUNCTION confirm_machine_output(INTEGER, INTEGER, INTEGER, NUMERIC, NUMERIC, DATE, NUMERIC)
  TO authenticated;

-- post_count_action stores the system's number beside the posted one.
CREATE OR REPLACE FUNCTION post_count_action(
  p_org_id          INTEGER,
  p_machine_id      INTEGER,
  p_day             DATE DEFAULT NULL,
  p_counts_override NUMERIC DEFAULT NULL,
  p_product_id      INTEGER DEFAULT NULL
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_day          DATE;
  v_action       RECORD;
  v_system       NUMERIC;
  v_counts       NUMERIC;
  v_post_id      INTEGER;
  v_bom_id       INTEGER;
  v_avg_cost     NUMERIC;
  v_line         RECORD;
  v_lines        INTEGER := 0;
  v_is_transform BOOLEAN := false;
  v_rolled_cost  NUMERIC := 0;
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

  SELECT shots INTO v_system
  FROM machine_day_production
  WHERE machine_id = p_machine_id AND day = v_day;
  v_counts := COALESCE(p_counts_override, v_system, 0);

  IF v_counts <= 0 THEN
    RAISE EXCEPTION 'No counts recorded for % on %', p_machine_id, v_day;
  END IF;

  IF p_product_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM products
      WHERE id = p_product_id AND org_id = p_org_id
        AND kind IN ('finished_good', 'component')
    ) THEN
      RAISE EXCEPTION 'Product not found or cannot be posted';
    END IF;

    SELECT id INTO v_bom_id
    FROM boms
    WHERE org_id = p_org_id AND product_id = p_product_id AND active = true
    LIMIT 1;

    IF v_bom_id IS NULL THEN
      RAISE EXCEPTION 'Product has no recipe — add its packaging lines first';
    END IF;

    SELECT EXISTS (
      SELECT 1 FROM bom_lines bl
      JOIN products p ON p.id = bl.component_product_id
      WHERE bl.bom_id = v_bom_id AND bl.stage = 'packaging'
        AND p.kind IN ('component', 'finished_good')
    ) INTO v_is_transform;

    INSERT INTO count_action_posts (org_id, machine_id, day, counts, system_counts, product_id, posted_by)
    VALUES (p_org_id, p_machine_id, v_day, v_counts, v_system, p_product_id, auth.uid())
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
         v_counts::text || ' processed: ' || v_line.qty_per_unit::text || ' ' || v_line.uom ||
         CASE WHEN v_line.per_units = 1 THEN '' ELSE ' per ' || v_line.per_units::text END ||
         ' on ' || v_day::text);

      v_rolled_cost := v_rolled_cost + (v_avg_cost * v_line.qty_per_unit / v_line.per_units);
    END LOOP;

    IF v_lines = 0 THEN
      RAISE EXCEPTION 'Product has no packaging lines in its recipe';
    END IF;

    IF v_is_transform THEN
      INSERT INTO stock_movements
        (org_id, product_id, quantity, movement_type, unit_cost, source_type, source_id, note)
      VALUES
        (p_org_id, p_product_id, v_counts, 'production_output', v_rolled_cost,
         'count_action', v_post_id,
         v_counts::text || ' assembled on ' || v_day::text);
    END IF;

    RETURN v_post_id;
  END IF;

  SELECT * INTO v_action
  FROM machine_count_actions
  WHERE machine_id = p_machine_id AND org_id = p_org_id;
  IF v_action IS NULL THEN
    RAISE EXCEPTION 'No per-count action configured for this machine';
  END IF;

  INSERT INTO count_action_posts (org_id, machine_id, day, counts, system_counts, posted_by)
  VALUES (p_org_id, p_machine_id, v_day, v_counts, v_system, auth.uid())
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

-- ── The report ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION variance_report(p_org_id INTEGER, p_from DATE, p_to DATE)
RETURNS TABLE (
  day          DATE,
  machine_id   INTEGER,
  machine_name TEXT,
  product_id   INTEGER,
  product_name TEXT,
  source       TEXT,      -- 'confirm' (moulder) or 'post' (action machine)
  system_qty   NUMERIC,
  floor_qty    NUMERIC,
  diff         NUMERIC,
  error_pct    NUMERIC,
  accuracy_pct NUMERIC
)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  WITH lines AS (
    SELECT pr.run_date AS day, pr.machine_id, pr.product_id,
           'confirm'::text AS source, pr.system_qty, pr.good_qty AS floor_qty
    FROM production_runs pr
    WHERE pr.org_id = p_org_id AND pr.status = 'confirmed'
      AND pr.system_qty IS NOT NULL
      AND pr.run_date BETWEEN p_from AND p_to
    UNION ALL
    SELECT cap.day, cap.machine_id, cap.product_id,
           'post', cap.system_counts, cap.counts
    FROM count_action_posts cap
    WHERE cap.org_id = p_org_id AND cap.system_counts IS NOT NULL
      AND cap.day BETWEEN p_from AND p_to
  ), scored AS (
    SELECT l.*,
      CASE WHEN l.floor_qty = 0 THEN CASE WHEN l.system_qty = 0 THEN 0 ELSE 100 END
           ELSE ROUND(ABS(l.system_qty - l.floor_qty) / l.floor_qty * 100, 2)
      END AS err
    FROM lines l
  )
  SELECT s.day, s.machine_id, m.name, s.product_id, COALESCE(p.name, '—'),
    s.source, s.system_qty, s.floor_qty,
    s.floor_qty - s.system_qty AS diff,
    s.err AS error_pct,
    GREATEST(0, 100 - s.err) AS accuracy_pct
  FROM scored s
  JOIN machines m ON m.id = s.machine_id
  LEFT JOIN products p ON p.id = s.product_id
  ORDER BY s.day DESC, m.name, p.name;
$$;

GRANT EXECUTE ON FUNCTION variance_report(INTEGER, DATE, DATE) TO authenticated;
