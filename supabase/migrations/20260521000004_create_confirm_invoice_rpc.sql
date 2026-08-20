-- RPC function to confirm an invoice (insert invoice + line items in a transaction)
-- Called via supabase.rpc("confirm_invoice", { ... }) from the frontend

CREATE OR REPLACE FUNCTION confirm_invoice(
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
  v_item JSONB;
BEGIN
  INSERT INTO invoices (vendor_name, invoice_number, invoice_date, total_amount, file_name, storage_path)
  VALUES (p_vendor_name, p_invoice_number, p_invoice_date, p_total_amount, p_file_name, p_storage_path)
  RETURNING id INTO v_invoice_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_line_items)
  LOOP
    INSERT INTO line_items (invoice_id, description, quantity, unit_price, total_price)
    VALUES (
      v_invoice_id,
      v_item->>'description',
      (v_item->>'quantity')::NUMERIC,
      (v_item->>'unit_price')::NUMERIC,
      (v_item->>'total_price')::NUMERIC
    );
  END LOOP;

  RETURN v_invoice_id;
END;
$$;
