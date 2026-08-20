-- Migration 53: repair post_manual_stock_adjustment.
--
-- TWO BUGS, one of which was silently corrupting inventory.
--
-- 1. IT NEVER RAN. stock_movements.movement_type has carried a CHECK constraint
--    since migration 14 allowing exactly: purchase, sale, wastage, adjustment,
--    production_consume, production_output. Migrations 49 and 50 both write
--    'manual_addition' / 'manual_deduction', which are on nobody's list and no
--    migration ever widened it. Every call to this function since 2026-08-13
--    has failed on the constraint — all three operator overrides.
--
-- 2. POWER-OUTAGE PRODUCTION CONSUMED NO RAW MATERIAL. Recording production
--    after an outage is the SAME EVENT as confirm_machine_output: finished goods
--    appear because raw material was used up. The old version added the finished
--    goods and touched no components, so every override overstated raw material
--    stock permanently — and added the finished goods at zero cost, dragging
--    down that product's weighted-average cost.
--
-- THE FIX IS NOT TO WIDEN THE CONSTRAINT. Every scenario already has a correct
-- movement type, and using the real ones matters beyond tidiness: had we added
-- 'manual_addition', power-outage output would have been invisible to any report
-- grouping by production_output, and waste invisible to anything counting
-- wastage. The totals would have looked healthy while quietly excluding these
-- events.
--
--   power_outage (qty > 0) → production_output + production_consume via BOM
--                            (+ runner regrind), and a production_runs row
--   waste        (qty < 0) → wastage
--   rejects      (qty < 0) → wastage (+ existing regrind routing, unchanged)
--
-- The signature is unchanged, so apps/web-admin/src/lib/bomService.js and the
-- override modal keep working untouched. Return value stays the primary
-- stock_movement id.

-- ── Shared production posting ─────────────────────────
--
-- confirm_machine_output (migration 50) carries equivalent logic inline. It is a
-- working critical path and is deliberately left alone here; this helper exists
-- so the repair does not copy it a third time, and is the natural place to
-- converge them later.

CREATE OR REPLACE FUNCTION post_production_for_run(
  p_org_id     INTEGER,
  p_run_id     INTEGER,
  p_product_id INTEGER,
  p_good_qty   NUMERIC,
  p_bom_id     INTEGER
) RETURNS INTEGER   -- the production_output movement id
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_output_id   INTEGER;
  v_rolled_cost NUMERIC := 0;
  v_avg_cost    NUMERIC;
  v_cavities    SMALLINT;
  v_runner_g    NUMERIC;
  v_runner_mat  INTEGER;
  v_shots       NUMERIC;
  v_line        RECORD;
BEGIN
  INSERT INTO stock_movements
    (org_id, product_id, quantity, movement_type, source_type, source_id, note)
  VALUES
    (p_org_id, p_product_id, p_good_qty, 'production_output',
     'production_run', p_run_id, 'Production posted for run ' || p_run_id::text)
  RETURNING id INTO v_output_id;

  IF p_bom_id IS NULL THEN
    RETURN v_output_id;      -- default-safe: no recipe ⇒ finished goods only
  END IF;

  SELECT cavities, runner_weight_g, runner_material_product_id
    INTO v_cavities, v_runner_g, v_runner_mat
    FROM boms WHERE id = p_bom_id;

  FOR v_line IN
    SELECT component_product_id, qty_per_unit, uom FROM bom_lines WHERE bom_id = p_bom_id
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
       'production_consume', v_avg_cost, 'production_run', p_run_id,
       v_line.qty_per_unit::text || ' ' || v_line.uom || ' × ' || p_good_qty::text || ' units consumed');

    v_rolled_cost := v_rolled_cost + (v_avg_cost * v_line.qty_per_unit);
  END LOOP;

  -- Finished goods are worth what went into them.
  UPDATE stock_movements SET unit_cost = v_rolled_cost WHERE id = v_output_id;

  -- Runner plastic is recovered, not lost.
  IF v_cavities IS NOT NULL AND v_cavities > 0
     AND v_runner_g IS NOT NULL AND v_runner_mat IS NOT NULL
  THEN
    v_shots := ROUND(p_good_qty::NUMERIC / v_cavities);
    INSERT INTO regrind_movements
      (org_id, material_product_id, qty_g, direction, source_type, source_id, note, created_by)
    VALUES
      (p_org_id, v_runner_mat, v_shots * v_runner_g, 'in', 'production_run', p_run_id,
       v_shots::text || ' shots × ' || v_runner_g::text || 'g runner', auth.uid());
  END IF;

  RETURN v_output_id;
END;
$$;

REVOKE ALL ON FUNCTION post_production_for_run(INTEGER, INTEGER, INTEGER, NUMERIC, INTEGER) FROM PUBLIC;

-- ── The repaired override ─────────────────────────────

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
  v_run_id      INTEGER;
  v_bom_id      INTEGER;
  v_reject_qty  NUMERIC;
  v_avg_cost    NUMERIC;
  v_line        RECORD;
BEGIN
  IF NOT is_org_admin(p_org_id) THEN
    RAISE EXCEPTION 'Only org admins can post manual stock adjustments';
  END IF;
  IF p_qty = 0 THEN
    RAISE EXCEPTION 'Quantity cannot be zero';
  END IF;

  SELECT id INTO v_bom_id
    FROM boms
   WHERE org_id = p_org_id AND product_id = p_product_id AND active = true
   LIMIT 1;

  IF p_qty > 0 THEN
    -- ── Production that happened but went untracked (power outage) ──
    -- Deliberately NOT deduplicated the way confirm_machine_output is: an
    -- operator may record two separate outages on the same day, and a run may
    -- already exist for that machine/product/date from the automatic path. This
    -- is additional output, not a repeat of it.
    INSERT INTO production_runs
      (org_id, machine_id, product_id, bom_id, run_date,
       good_qty, scrap_qty, status, confirmed_by, confirmed_at)
    VALUES
      (p_org_id, p_machine_id, p_product_id, v_bom_id, CURRENT_DATE,
       p_qty, 0, 'confirmed', auth.uid(), now())
    RETURNING id INTO v_run_id;

    v_movement_id := post_production_for_run(p_org_id, v_run_id, p_product_id, p_qty, v_bom_id);

    UPDATE stock_movements
       SET note = COALESCE(p_note, p_reason_type) || ' (untracked production recorded manually)'
     WHERE id = v_movement_id;

    RETURN v_movement_id;
  END IF;

  -- ── Stock that left without being sold (waste / rejects) ──
  -- Valued at weighted-average cost so inventory VALUE falls with the quantity;
  -- the old version wrote no cost at all.
  SELECT COALESCE(
    SUM(sm.quantity * sm.unit_cost) FILTER (WHERE sm.quantity > 0 AND sm.unit_cost IS NOT NULL)
    / NULLIF(SUM(sm.quantity) FILTER (WHERE sm.quantity > 0 AND sm.unit_cost IS NOT NULL), 0),
    0
  ) INTO v_avg_cost
  FROM stock_movements sm
  WHERE sm.product_id = p_product_id AND sm.org_id = p_org_id;

  INSERT INTO stock_movements
    (org_id, product_id, quantity, movement_type, unit_cost, source_type, note)
  VALUES (
    p_org_id, p_product_id, p_qty, 'wastage', v_avg_cost,
    p_reason_type, COALESCE(p_note, p_reason_type)
  )
  RETURNING id INTO v_movement_id;

  -- Broken parts are still usable plastic — unchanged from migration 50.
  IF p_route_to_regrind THEN
    v_reject_qty := ABS(p_qty);
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
          v_reject_qty::TEXT || ' rejected parts → ' ||
            (v_reject_qty * v_line.qty_per_unit)::TEXT || 'g to regrind',
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
