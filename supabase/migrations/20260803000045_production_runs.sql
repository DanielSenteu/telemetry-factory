-- Migration 45: production_runs + confirm_machine_output RPC
--
-- A production run is the daily record of what a machine made.
-- Confirming one posts two kinds of stock movements atomically:
--   production_output  (+finished good stock, unit_cost = BOM rollup)
--   production_consume (-raw material stock per BOM line)
--
-- Idempotent: if a confirmed run already exists for (machine, product, date)
-- the RPC returns that run's id without double-posting.
-- Default-safe: if no BOM is set for the product, only the +finished good
-- movement posts; nothing crashes and the run is still confirmed.

CREATE TABLE production_runs (
  id           SERIAL PRIMARY KEY,
  org_id       INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  machine_id   INTEGER          REFERENCES machines(id)      ON DELETE SET NULL,
  product_id   INTEGER NOT NULL REFERENCES products(id)      ON DELETE RESTRICT,
  bom_id       INTEGER          REFERENCES boms(id)          ON DELETE RESTRICT,
  run_date     DATE NOT NULL DEFAULT CURRENT_DATE,
  good_qty     NUMERIC(14,3) NOT NULL CHECK (good_qty >= 0),
  scrap_qty    NUMERIC(14,3) NOT NULL DEFAULT 0 CHECK (scrap_qty >= 0),
  status       TEXT NOT NULL DEFAULT 'confirmed'
               CHECK (status IN ('draft', 'confirmed')),
  confirmed_by UUID REFERENCES auth.users(id),
  confirmed_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_production_runs_org_date ON production_runs (org_id, run_date DESC);
CREATE INDEX idx_production_runs_machine  ON production_runs (machine_id, run_date DESC);

ALTER TABLE production_runs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org members view production runs" ON production_runs
  FOR SELECT TO authenticated
  USING (org_id IN (SELECT user_org_ids()));

CREATE POLICY "Admins manage production runs" ON production_runs
  FOR ALL TO authenticated
  USING  (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON production_runs TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE production_runs_id_seq TO authenticated;

-- ── confirm_machine_output ────────────────────────────────────────────────────
-- Called from the "Confirm today's output" button on the Live floor dashboard.
-- Creates a production_run record and posts movements in one atomic transaction.

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
  v_rolled_cost NUMERIC := 0;
  v_avg_cost    NUMERIC;
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

  -- Look up the active BOM for this product (NULL is allowed — default-safe)
  SELECT id INTO v_bom_id
  FROM boms
  WHERE org_id = p_org_id AND product_id = p_product_id AND active = true
  LIMIT 1;

  -- Create the run record (status = confirmed from the start)
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
      FROM bom_lines
      WHERE bom_id = v_bom_id
    LOOP
      -- Weighted-average cost of the component at time of confirmation
      SELECT COALESCE(
        SUM(sm.quantity * sm.unit_cost) FILTER (WHERE sm.quantity > 0 AND sm.unit_cost IS NOT NULL)
        / NULLIF(SUM(sm.quantity) FILTER (WHERE sm.quantity > 0 AND sm.unit_cost IS NOT NULL), 0),
        0
      ) INTO v_avg_cost
      FROM stock_movements sm
      WHERE sm.product_id = v_line.component_product_id
        AND sm.org_id = p_org_id;

      INSERT INTO stock_movements
        (org_id, product_id, quantity, movement_type, unit_cost,
         source_type, source_id, note)
      VALUES
        (p_org_id, v_line.component_product_id,
         -(v_line.qty_per_unit * p_good_qty),
         'production_consume',
         v_avg_cost,
         'production_run', v_run_id,
         v_line.qty_per_unit::text || ' ' || v_line.uom ||
         ' × ' || p_good_qty::text || ' units consumed');

      v_rolled_cost := v_rolled_cost + (v_avg_cost * v_line.qty_per_unit);
    END LOOP;

    -- Back-fill the unit_cost on the finished good movement with the BOM rollup
    UPDATE stock_movements
    SET unit_cost = v_rolled_cost
    WHERE source_type   = 'production_run'
      AND source_id     = v_run_id
      AND movement_type = 'production_output';
  END IF;

  RETURN v_run_id;
END;
$$;

GRANT EXECUTE ON FUNCTION confirm_machine_output(INTEGER, INTEGER, INTEGER, NUMERIC, NUMERIC, DATE)
  TO authenticated;
