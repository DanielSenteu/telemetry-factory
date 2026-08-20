-- Migration 48: Regrind inventory
--
-- Tracks the lifecycle of runner plastic:
--   'in'  — runners generated from a confirmed production run (auto-posted)
--   'out' — regrind returned to the machine by the operator (manual)
--
-- When the operator grinds runners and loads them back, post_regrind_use posts
-- an 'out' row here AND a positive stock_movement on the raw material so the
-- recycled plastic re-enters the inventory balance.
--
-- confirm_machine_output is re-created here (extending migration 45) to add the
-- automatic regrind_in posting when shot params are configured on the BOM.

-- ── regrind_movements ─────────────────────────────────────────────────────────

CREATE TABLE regrind_movements (
  id                  SERIAL PRIMARY KEY,
  org_id              INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  material_product_id INTEGER NOT NULL REFERENCES products(id)      ON DELETE RESTRICT,
  qty_g               NUMERIC(14,3) NOT NULL CHECK (qty_g > 0),
  direction           TEXT NOT NULL CHECK (direction IN ('in', 'out')),
  source_type         TEXT,    -- 'production_run', 'reject_override', 'manual'
  source_id           INTEGER, -- e.g. production_run.id when source_type = 'production_run'
  note                TEXT,
  created_by          UUID REFERENCES auth.users(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_regrind_movements_org  ON regrind_movements (org_id, created_at DESC);
CREATE INDEX idx_regrind_movements_mat  ON regrind_movements (material_product_id);

ALTER TABLE regrind_movements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org members view regrind" ON regrind_movements
  FOR SELECT TO authenticated
  USING (org_id IN (SELECT user_org_ids()));

CREATE POLICY "Admins manage regrind" ON regrind_movements
  FOR ALL TO authenticated
  USING  (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON regrind_movements TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE regrind_movements_id_seq TO authenticated;

-- ── regrind_balances ──────────────────────────────────────────────────────────
-- Returns current regrind pool balance per raw material, plus lifetime totals.

CREATE OR REPLACE FUNCTION regrind_balances(p_org_id INTEGER)
RETURNS TABLE (
  material_product_id INTEGER,
  material_name       TEXT,
  balance_g           NUMERIC,
  total_in_g          NUMERIC,
  total_out_g         NUMERIC
)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT
    rm.material_product_id,
    p.name AS material_name,
    SUM(CASE WHEN rm.direction = 'in'  THEN  rm.qty_g
             WHEN rm.direction = 'out' THEN -rm.qty_g END)   AS balance_g,
    SUM(CASE WHEN rm.direction = 'in'  THEN  rm.qty_g ELSE 0 END) AS total_in_g,
    SUM(CASE WHEN rm.direction = 'out' THEN  rm.qty_g ELSE 0 END) AS total_out_g
  FROM regrind_movements rm
  JOIN products p ON p.id = rm.material_product_id
  WHERE rm.org_id = p_org_id
  GROUP BY rm.material_product_id, p.name
  ORDER BY p.name;
$$;

GRANT EXECUTE ON FUNCTION regrind_balances(INTEGER) TO authenticated;

-- ── post_regrind_use ──────────────────────────────────────────────────────────
-- Called when the operator grinds runners and loads them back into the machine.
-- Posts regrind 'out' + a positive stock_movement so the plastic re-enters stock.

CREATE OR REPLACE FUNCTION post_regrind_use(
  p_org_id              INTEGER,
  p_material_product_id INTEGER,
  p_qty_g               NUMERIC,
  p_note                TEXT DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT is_org_admin(p_org_id) THEN
    RAISE EXCEPTION 'Only org admins can post regrind use';
  END IF;

  IF p_qty_g <= 0 THEN
    RAISE EXCEPTION 'Quantity must be positive';
  END IF;

  -- Record regrind leaving the pool
  INSERT INTO regrind_movements
    (org_id, material_product_id, qty_g, direction, source_type, note, created_by)
  VALUES
    (p_org_id, p_material_product_id, p_qty_g, 'out', 'manual',
     COALESCE(p_note, 'Regrind returned to machine'), auth.uid());

  -- Return the weight to raw material stock
  INSERT INTO stock_movements
    (org_id, product_id, quantity, movement_type, source_type, note)
  VALUES
    (p_org_id, p_material_product_id, p_qty_g, 'regrind_return', 'manual',
     COALESCE(p_note, 'Regrind returned to raw material stock'));
END;
$$;

GRANT EXECUTE ON FUNCTION post_regrind_use(INTEGER, INTEGER, NUMERIC, TEXT)
  TO authenticated;

-- ── confirm_machine_output (extended) ─────────────────────────────────────────
-- Re-creates the RPC from migration 45 adding automatic regrind_in posting
-- when the BOM has shot params configured (cavities + runner_weight_g +
-- runner_material_product_id all non-null).

DROP FUNCTION IF EXISTS confirm_machine_output(INTEGER, INTEGER, INTEGER, NUMERIC, NUMERIC, DATE);

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

  -- Idempotency: return existing confirmed run for the same machine/product/date
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

  -- Look up the active BOM (including shot params)
  SELECT id, cavities, runner_weight_g, runner_material_product_id
  INTO v_bom_id, v_cavities, v_runner_g, v_runner_mat
  FROM boms
  WHERE org_id = p_org_id AND product_id = p_product_id AND active = true
  LIMIT 1;

  -- Create the run record
  INSERT INTO production_runs
    (org_id, machine_id, product_id, bom_id, run_date,
     good_qty, scrap_qty, status, confirmed_by, confirmed_at)
  VALUES
    (p_org_id, p_machine_id, p_product_id, v_bom_id, p_run_date,
     p_good_qty, p_scrap_qty, 'confirmed', auth.uid(), now())
  RETURNING id INTO v_run_id;

  -- Post finished good stock increase
  INSERT INTO stock_movements
    (org_id, product_id, quantity, movement_type, source_type, source_id, note)
  VALUES
    (p_org_id, p_product_id, p_good_qty, 'production_output',
     'production_run', v_run_id,
     'Production confirmed ' || p_run_date::text);

  -- If a BOM exists, deduct each raw material component
  IF v_bom_id IS NOT NULL THEN
    FOR v_line IN
      SELECT component_product_id, qty_per_unit, uom
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
         -(v_line.qty_per_unit * p_good_qty),
         'production_consume', v_avg_cost,
         'production_run', v_run_id,
         v_line.qty_per_unit::text || ' ' || v_line.uom ||
         ' × ' || p_good_qty::text || ' units consumed');

      v_rolled_cost := v_rolled_cost + (v_avg_cost * v_line.qty_per_unit);
    END LOOP;

    -- Back-fill unit cost on the finished good movement
    UPDATE stock_movements
    SET unit_cost = v_rolled_cost
    WHERE source_type   = 'production_run'
      AND source_id     = v_run_id
      AND movement_type = 'production_output';

    -- Regrind: park runner weight if shot params are fully configured
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
