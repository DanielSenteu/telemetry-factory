-- Extend confirm_invoice so that, when a line item is linked to a product,
-- confirming the invoice also:
--   1. writes a 'purchase' stock movement (+qty) into the ledger, and
--   2. remembers the alias (this vendor's line text -> this product) so the
--      same text auto-links next time.
--
-- Lines with no product_id behave exactly as before (invoice + line_item only).

CREATE OR REPLACE FUNCTION confirm_invoice(
  p_org_id         INTEGER,
  p_vendor_name    TEXT,
  p_invoice_number TEXT,
  p_invoice_date   DATE,
  p_total_amount   NUMERIC(12,2),
  p_file_name      TEXT,
  p_storage_path   TEXT,
  p_line_items     JSONB
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_invoice_id INTEGER;
  v_item       JSONB;
  v_line_id    INTEGER;
  v_product_id INTEGER;
  v_qty        NUMERIC;
  v_unit_price NUMERIC;
BEGIN
  INSERT INTO invoices (org_id, vendor_name, invoice_number, invoice_date, total_amount, file_name, storage_path)
  VALUES (p_org_id, p_vendor_name, p_invoice_number, p_invoice_date, p_total_amount, p_file_name, p_storage_path)
  RETURNING id INTO v_invoice_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_line_items)
  LOOP
    v_qty        := NULLIF(v_item->>'quantity', '')::NUMERIC;
    v_unit_price := NULLIF(v_item->>'unit_price', '')::NUMERIC;

    INSERT INTO line_items (invoice_id, description, quantity, unit_price, total_price)
    VALUES (
      v_invoice_id,
      v_item->>'description',
      v_qty,
      v_unit_price,
      NULLIF(v_item->>'total_price', '')::NUMERIC
    )
    RETURNING id INTO v_line_id;

    v_product_id := NULLIF(v_item->>'product_id', '')::INTEGER;

    IF v_product_id IS NOT NULL THEN
      -- Remember the mapping so this vendor's text auto-links next time.
      INSERT INTO product_aliases (org_id, product_id, vendor_name, raw_text)
      VALUES (p_org_id, v_product_id, p_vendor_name, v_item->>'description')
      ON CONFLICT (org_id, vendor_name, raw_text)
        DO UPDATE SET product_id = EXCLUDED.product_id;

      -- Incoming stock: a positive 'purchase' movement (skip zero-qty lines).
      IF COALESCE(v_qty, 0) <> 0 THEN
        INSERT INTO stock_movements
          (org_id, product_id, quantity, movement_type, unit_cost, source_type, source_id, note)
        VALUES
          (p_org_id, v_product_id, v_qty, 'purchase', v_unit_price, 'invoice', v_line_id, p_invoice_number);
      END IF;
    END IF;
  END LOOP;

  RETURN v_invoice_id;
END;
$$;
