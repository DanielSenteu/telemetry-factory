-- Migration 50: Repair / idempotent re-apply of 47-49
--
-- Migrations 47-49 were marked applied by the CLI but may have partially failed
-- because cavities already existed on boms from a prior manual change.
-- This migration applies everything safely using IF NOT EXISTS / CREATE OR REPLACE.

-- ── boms: shot params columns (ADD IF NOT EXISTS) ──────────────────────────────

ALTER TABLE boms
  ADD COLUMN IF NOT EXISTS cavities                   SMALLINT,
  ADD COLUMN IF NOT EXISTS runner_weight_g            NUMERIC(10,3),
  ADD COLUMN IF NOT EXISTS runner_material_product_id INTEGER REFERENCES products(id) ON DELETE SET NULL;

-- ── update_bom_shot_params ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION update_bom_shot_params(
  p_org_id                      INTEGER,
  p_product_id                  INTEGER,
  p_cavities                    SMALLINT,
  p_runner_weight_g             NUMERIC,
  p_runner_material_product_id  INTEGER
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_bom_id INTEGER;
BEGIN
  IF NOT is_org_admin(p_org_id) THEN
    RAISE EXCEPTION 'Only org admins can update BOM shot params';
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

  UPDATE boms SET
    cavities                   = p_cavities,
    runner_weight_g            = p_runner_weight_g,
    runner_material_product_id = p_runner_material_product_id
  WHERE id = v_bom_id;
END;
$$;

GRANT EXECUTE ON FUNCTION update_bom_shot_params(INTEGER, INTEGER, SMALLINT, NUMERIC, INTEGER)
  TO authenticated;

-- ── regrind_movements ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS regrind_movements (
  id                  SERIAL PRIMARY KEY,
  org_id              INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  material_product_id INTEGER NOT NULL REFERENCES products(id)      ON DELETE RESTRICT,
  qty_g               NUMERIC(14,3) NOT NULL CHECK (qty_g > 0),
  direction           TEXT NOT NULL CHECK (direction IN ('in', 'out')),
  source_type         TEXT,
  source_id           INTEGER,
  note                TEXT,
  created_by          UUID REFERENCES auth.users(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_regrind_movements_org') THEN
    CREATE INDEX idx_regrind_movements_org ON regrind_movements (org_id, created_at DESC);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_regrind_movements_mat') THEN
    CREATE INDEX idx_regrind_movements_mat ON regrind_movements (material_product_id);
  END IF;
END$$;

ALTER TABLE regrind_movements ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'regrind_movements' AND policyname = 'Org members view regrind'
  ) THEN
    CREATE POLICY "Org members view regrind" ON regrind_movements
      FOR SELECT TO authenticated
      USING (org_id IN (SELECT user_org_ids()));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'regrind_movements' AND policyname = 'Admins manage regrind'
  ) THEN
    CREATE POLICY "Admins manage regrind" ON regrind_movements
      FOR ALL TO authenticated
      USING  (is_org_admin(org_id))
      WITH CHECK (is_org_admin(org_id));
  END IF;
END$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON regrind_movements TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE regrind_movements_id_seq TO authenticated;

-- ── regrind_balances ──────────────────────────────────────────────────────────

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
             WHEN rm.direction = 'out' THEN -rm.qty_g END)        AS balance_g,
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

  INSERT INTO regrind_movements
    (org_id, material_product_id, qty_g, direction, source_type, note, created_by)
  VALUES
    (p_org_id, p_material_product_id, p_qty_g, 'out', 'manual',
     COALESCE(p_note, 'Regrind returned to machine'), auth.uid());

  INSERT INTO stock_movements
    (org_id, product_id, quantity, movement_type, source_type, note)
  VALUES
    (p_org_id, p_material_product_id, p_qty_g, 'regrind_return', 'manual',
     COALESCE(p_note, 'Regrind returned to raw material stock'));
END;
$$;

GRANT EXECUTE ON FUNCTION post_regrind_use(INTEGER, INTEGER, NUMERIC, TEXT)
  TO authenticated;

-- ── confirm_machine_output (with regrind) ─────────────────────────────────────

DROP FUNCTION IF EXISTS confirm_machine_output(INTEGER, INTEGER, INTEGER, NUMERIC, NUMERIC, DATE);

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
  WHERE org_id = p_org_id AND machine_id = p_machine_id AND product_id = p_product_id
    AND run_date = p_run_date AND status = 'confirmed';
  IF v_run_id IS NOT NULL THEN RETURN v_run_id; END IF;

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
     'production_run', v_run_id, 'Production confirmed ' || p_run_date::text);

  IF v_bom_id IS NOT NULL THEN
    FOR v_line IN
      SELECT component_product_id, qty_per_unit, uom FROM bom_lines WHERE bom_id = v_bom_id
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
        (p_org_id, v_line.component_product_id, -(v_line.qty_per_unit * p_good_qty),
         'production_consume', v_avg_cost, 'production_run', v_run_id,
         v_line.qty_per_unit::text || ' ' || v_line.uom || ' × ' || p_good_qty::text || ' units consumed');

      v_rolled_cost := v_rolled_cost + (v_avg_cost * v_line.qty_per_unit);
    END LOOP;

    UPDATE stock_movements SET unit_cost = v_rolled_cost
    WHERE source_type = 'production_run' AND source_id = v_run_id
      AND movement_type = 'production_output';

    IF v_cavities IS NOT NULL AND v_cavities > 0
      AND v_runner_g IS NOT NULL AND v_runner_mat IS NOT NULL
    THEN
      v_shots := ROUND(p_good_qty::numeric / v_cavities);
      INSERT INTO regrind_movements
        (org_id, material_product_id, qty_g, direction, source_type, source_id, note, created_by)
      VALUES
        (p_org_id, v_runner_mat, v_shots * v_runner_g, 'in', 'production_run', v_run_id,
         v_shots::text || ' shots × ' || v_runner_g::text || 'g runner', auth.uid());
    END IF;
  END IF;

  RETURN v_run_id;
END;
$$;

GRANT EXECUTE ON FUNCTION confirm_machine_output(INTEGER, INTEGER, INTEGER, NUMERIC, NUMERIC, DATE)
  TO authenticated;

-- ── post_manual_stock_adjustment ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION post_manual_stock_adjustment(
  p_org_id           INTEGER,
  p_product_id       INTEGER,
  p_qty              NUMERIC,
  p_reason_type      TEXT,
  p_route_to_regrind BOOLEAN  DEFAULT false,
  p_machine_id       INTEGER  DEFAULT NULL,
  p_note             TEXT     DEFAULT NULL
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_movement_id INTEGER;
  v_bom_id      INTEGER;
  v_reject_qty  NUMERIC;
  v_line        RECORD;
BEGIN
  IF NOT is_org_admin(p_org_id) THEN
    RAISE EXCEPTION 'Only org admins can post manual stock adjustments';
  END IF;
  IF p_qty = 0 THEN
    RAISE EXCEPTION 'Quantity cannot be zero';
  END IF;

  INSERT INTO stock_movements
    (org_id, product_id, quantity, movement_type, source_type, note)
  VALUES (
    p_org_id, p_product_id, p_qty,
    CASE WHEN p_qty > 0 THEN 'manual_addition' ELSE 'manual_deduction' END,
    p_reason_type, COALESCE(p_note, p_reason_type)
  )
  RETURNING id INTO v_movement_id;

  IF p_route_to_regrind AND p_qty < 0 THEN
    v_reject_qty := ABS(p_qty);
    SELECT id INTO v_bom_id
    FROM boms WHERE org_id = p_org_id AND product_id = p_product_id AND active = true LIMIT 1;

    IF v_bom_id IS NOT NULL THEN
      FOR v_line IN
        SELECT component_product_id, qty_per_unit FROM bom_lines WHERE bom_id = v_bom_id
      LOOP
        INSERT INTO regrind_movements
          (org_id, material_product_id, qty_g, direction, source_type, source_id, note, created_by)
        VALUES (
          p_org_id, v_line.component_product_id,
          v_reject_qty * v_line.qty_per_unit,
          'in', 'reject_override', v_movement_id,
          v_reject_qty::text || ' rejected parts → ' ||
            (v_reject_qty * v_line.qty_per_unit)::text || 'g to regrind',
          auth.uid()
        );
      END LOOP;
    END IF;
  END IF;

  RETURN v_movement_id;
END;
$$;

GRANT EXECUTE ON FUNCTION post_manual_stock_adjustment(INTEGER, INTEGER, NUMERIC, TEXT, BOOLEAN, INTEGER, TEXT)
  TO authenticated;
