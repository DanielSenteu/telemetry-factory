-- Migration 49: Manual stock adjustments
--
-- post_manual_stock_adjustment covers three operator override scenarios:
--   'power_outage'  — positive qty: production happened but wasn't tracked (CV350 outage)
--   'waste'         — negative qty: broken/waste units at end of day (CV350 sealing waste)
--   'rejects'       — negative qty: rejected units at end of day (Haijing machines)
--                     optionally route_to_regrind=true to park the plastic weight in the
--                     regrind pool (broken parts are still usable plastic)
--
-- All adjustments post to stock_movements with movement_type = 'manual_addition'
-- or 'manual_deduction' and source_type = the reason_type for auditability.

CREATE OR REPLACE FUNCTION post_manual_stock_adjustment(
  p_org_id          INTEGER,
  p_product_id      INTEGER,
  p_qty             NUMERIC,      -- positive = add stock, negative = deduct stock
  p_reason_type     TEXT,         -- 'power_outage', 'waste', 'rejects'
  p_route_to_regrind BOOLEAN      DEFAULT false,
  p_machine_id      INTEGER       DEFAULT NULL,
  p_note            TEXT          DEFAULT NULL
) RETURNS INTEGER   -- the stock_movement id
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

  -- Post the stock movement
  INSERT INTO stock_movements
    (org_id, product_id, quantity, movement_type, source_type, note)
  VALUES (
    p_org_id,
    p_product_id,
    p_qty,
    CASE WHEN p_qty > 0 THEN 'manual_addition' ELSE 'manual_deduction' END,
    p_reason_type,
    COALESCE(p_note, p_reason_type)
  )
  RETURNING id INTO v_movement_id;

  -- Regrind routing: only for negative adjustments when explicitly opted in
  IF p_route_to_regrind AND p_qty < 0 THEN
    v_reject_qty := ABS(p_qty);

    SELECT id INTO v_bom_id
    FROM boms
    WHERE org_id = p_org_id AND product_id = p_product_id AND active = true
    LIMIT 1;

    -- For each raw material in the BOM, add that material's share to the regrind pool
    IF v_bom_id IS NOT NULL THEN
      FOR v_line IN
        SELECT component_product_id, qty_per_unit
        FROM bom_lines WHERE bom_id = v_bom_id
      LOOP
        INSERT INTO regrind_movements
          (org_id, material_product_id, qty_g, direction, source_type, source_id, note, created_by)
        VALUES (
          p_org_id,
          v_line.component_product_id,
          v_reject_qty * v_line.qty_per_unit,
          'in',
          'reject_override',
          v_movement_id,
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
