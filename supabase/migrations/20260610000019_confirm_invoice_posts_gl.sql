-- Extend confirm_invoice once more: a confirmed SUPPLIER invoice is a purchase
-- on credit, so it now also posts a balanced journal entry into the GL (0017):
--
--   Dr Inventory (1200)         <- value of lines linked to a stocked product
--   Dr General Expenses (6900)  <- value of lines NOT linked to a product (services etc.)
--      Cr Accounts Payable (2000)  <- the total we now owe the supplier
--
-- This is purely additive: invoice + line_items + stock movements + aliases all
-- behave exactly as in 0015. The journal posting is GUARDED — if the org has no
-- GL accounts yet (accounting never set up), confirming an invoice must never
-- fail, so we simply skip the posting.
--
-- Note on totals: debits are summed from the line values, so the entry always
-- balances against the AP credit. When line values don't reconcile to the
-- invoice grand total (most often because of 16% VAT), that gap is handled by
-- the VAT module (next) — for now the ledger reflects the lines we captured.

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
  v_invoice_id     INTEGER;
  v_item           JSONB;
  v_line_id        INTEGER;
  v_product_id     INTEGER;
  v_qty            NUMERIC;
  v_unit_price     NUMERIC;
  v_line_total     NUMERIC;
  -- GL accumulation
  v_inventory_total NUMERIC := 0;
  v_expense_total   NUMERIC := 0;
  v_owed            NUMERIC := 0;
  v_acct_inventory  INTEGER;
  v_acct_expense    INTEGER;
  v_acct_payable    INTEGER;
  v_entry_id        INTEGER;
BEGIN
  INSERT INTO invoices (org_id, vendor_name, invoice_number, invoice_date, total_amount, file_name, storage_path)
  VALUES (p_org_id, p_vendor_name, p_invoice_number, p_invoice_date, p_total_amount, p_file_name, p_storage_path)
  RETURNING id INTO v_invoice_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_line_items)
  LOOP
    v_qty        := NULLIF(v_item->>'quantity', '')::NUMERIC;
    v_unit_price := NULLIF(v_item->>'unit_price', '')::NUMERIC;
    v_line_total := NULLIF(v_item->>'total_price', '')::NUMERIC;
    -- Fall back to qty * unit_price when the line total wasn't extracted.
    IF v_line_total IS NULL THEN
      v_line_total := COALESCE(v_qty, 0) * COALESCE(v_unit_price, 0);
    END IF;

    INSERT INTO line_items (invoice_id, description, quantity, unit_price, total_price)
    VALUES (
      v_invoice_id,
      v_item->>'description',
      v_qty,
      v_unit_price,
      v_line_total
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

      -- Goods into stock → debit Inventory.
      v_inventory_total := v_inventory_total + COALESCE(v_line_total, 0);
    ELSE
      -- No product link → treat as an expense/service.
      v_expense_total := v_expense_total + COALESCE(v_line_total, 0);
    END IF;
  END LOOP;

  -- ── Auto-post the AP journal entry (guarded) ──────────────────────────
  SELECT id INTO v_acct_payable   FROM gl_accounts WHERE org_id = p_org_id AND code = '2000';
  SELECT id INTO v_acct_inventory FROM gl_accounts WHERE org_id = p_org_id AND code = '1200';
  SELECT id INTO v_acct_expense   FROM gl_accounts WHERE org_id = p_org_id AND code = '6900';

  -- If lines carried no value but the invoice has a total, book it as expense
  -- so the liability is still captured.
  IF v_inventory_total = 0 AND v_expense_total = 0 AND COALESCE(p_total_amount, 0) > 0 THEN
    v_expense_total := p_total_amount;
  END IF;

  -- Total we now owe the supplier (the credit) — fixed before we decide which
  -- debit accounts to use, so folding between debit buckets never changes it.
  v_owed := v_inventory_total + v_expense_total;

  -- Fold a bucket into the other if its account is missing, so the debit side
  -- still sums to v_owed.
  IF v_acct_inventory IS NULL THEN
    v_expense_total := v_expense_total + v_inventory_total;
    v_inventory_total := 0;
  END IF;
  IF v_acct_expense IS NULL THEN
    v_inventory_total := v_inventory_total + v_expense_total;
    v_expense_total := 0;
  END IF;

  -- Post only if we owe something, AP exists, and we have at least one debit
  -- account to balance against (otherwise leave the invoice un-journaled rather
  -- than abort confirmation with an unbalanced entry).
  IF v_acct_payable IS NOT NULL
     AND v_owed > 0
     AND (v_acct_inventory IS NOT NULL OR v_acct_expense IS NOT NULL) THEN

    INSERT INTO journal_entries (org_id, entry_date, memo, source_type, source_id)
    VALUES (
      p_org_id,
      p_invoice_date,
      'Supplier invoice ' || COALESCE(p_invoice_number, '') || ' — ' || COALESCE(p_vendor_name, ''),
      'invoice',
      v_invoice_id
    )
    RETURNING id INTO v_entry_id;

    IF v_inventory_total > 0 THEN
      INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
      VALUES (v_entry_id, p_org_id, v_acct_inventory, v_inventory_total, 0, 'Goods received into stock');
    END IF;

    IF v_expense_total > 0 THEN
      INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
      VALUES (v_entry_id, p_org_id, v_acct_expense, v_expense_total, 0, 'Expense / services');
    END IF;

    -- Credit side: the total we now owe the supplier.
    INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
    VALUES (v_entry_id, p_org_id, v_acct_payable, 0, v_owed, 'Owed to supplier');
  END IF;

  RETURN v_invoice_id;
END;
$$;
