-- The expense mapper: the SAME three-layer entity-resolution pattern as
-- inventory, pointed at GL accounts instead of products.
--
--   INVENTORY:  invoice line -> product_alias -> Product   -> Dr Inventory
--   EXPENSES:   invoice line -> account_alias -> GL Account -> Dr (right expense)
--
-- "KPLC" learns to mean Electricity, "Zoho" learns to mean Subscriptions —
-- confirmed once by a human, then remembered forever. Each invoice line now
-- routes to EITHER a product (goods -> Inventory) OR a chosen expense account;
-- anything left uncategorised still falls back to General Expenses (6900), so
-- behaviour degrades gracefully and nothing breaks.

-- ── The alias memory (mirrors product_aliases) ────────

CREATE TABLE account_aliases (
  id          SERIAL PRIMARY KEY,
  org_id      INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  account_id  INTEGER NOT NULL REFERENCES gl_accounts(id) ON DELETE CASCADE,
  vendor_name TEXT,
  raw_text    TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Seen once, auto-links forever: a vendor's exact line text -> one account.
  UNIQUE (org_id, vendor_name, raw_text)
);

CREATE INDEX idx_account_aliases_org_id     ON account_aliases(org_id);
CREATE INDEX idx_account_aliases_account_id ON account_aliases(account_id);

ALTER TABLE account_aliases ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org-scoped access on account_aliases" ON account_aliases
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));

-- ── confirm_invoice, now with expense routing ─────────
-- Per line the caller may pass product_id OR account_id:
--   product_id  -> goods into stock (Dr Inventory) + product alias + movement
--   account_id  -> a specific expense (Dr that account) + account alias
--   neither     -> General Expenses (6900) fallback
-- All non-inventory debits are aggregated per account so the journal shows one
-- clean line per expense account, with a single Accounts Payable credit.

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
  v_invoice_id      INTEGER;
  v_item            JSONB;
  v_line_id         INTEGER;
  v_product_id      INTEGER;
  v_account_id      INTEGER;
  v_qty             NUMERIC;
  v_unit_price      NUMERIC;
  v_line_total      NUMERIC;
  -- GL accumulation
  v_inventory_total NUMERIC := 0;
  v_expense_by_acct JSONB   := '{}'::jsonb;   -- { "<account_id>": amount, ... }
  v_expense_sum     NUMERIC := 0;
  v_owed            NUMERIC := 0;
  v_acct_inventory  INTEGER;
  v_acct_payable    INTEGER;
  v_acct_fallback   INTEGER;
  v_target          INTEGER;
  v_key             TEXT;
  v_val             TEXT;
  v_entry_id        INTEGER;
BEGIN
  SELECT id INTO v_acct_inventory FROM gl_accounts WHERE org_id = p_org_id AND code = '1200';
  SELECT id INTO v_acct_payable   FROM gl_accounts WHERE org_id = p_org_id AND code = '2000';
  SELECT id INTO v_acct_fallback  FROM gl_accounts WHERE org_id = p_org_id AND code = '6900';

  INSERT INTO invoices (org_id, vendor_name, invoice_number, invoice_date, total_amount, file_name, storage_path)
  VALUES (p_org_id, p_vendor_name, p_invoice_number, p_invoice_date, p_total_amount, p_file_name, p_storage_path)
  RETURNING id INTO v_invoice_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_line_items)
  LOOP
    v_qty        := NULLIF(v_item->>'quantity', '')::NUMERIC;
    v_unit_price := NULLIF(v_item->>'unit_price', '')::NUMERIC;
    v_line_total := NULLIF(v_item->>'total_price', '')::NUMERIC;
    IF v_line_total IS NULL THEN
      v_line_total := COALESCE(v_qty, 0) * COALESCE(v_unit_price, 0);
    END IF;

    INSERT INTO line_items (invoice_id, description, quantity, unit_price, total_price)
    VALUES (v_invoice_id, v_item->>'description', v_qty, v_unit_price, v_line_total)
    RETURNING id INTO v_line_id;

    v_product_id := NULLIF(v_item->>'product_id', '')::INTEGER;
    v_account_id := NULLIF(v_item->>'account_id', '')::INTEGER;
    -- Validate the account belongs to this org; otherwise ignore it.
    IF v_account_id IS NOT NULL THEN
      SELECT id INTO v_account_id FROM gl_accounts WHERE id = v_account_id AND org_id = p_org_id;
    END IF;

    -- v_target = the expense account this line's value should be debited to.
    -- NULL means "already booked to Inventory" (a product line with an
    -- inventory account). Reset every iteration so nothing carries over.
    v_target := NULL;

    IF v_product_id IS NOT NULL THEN
      -- Goods into stock.
      INSERT INTO product_aliases (org_id, product_id, vendor_name, raw_text)
      VALUES (p_org_id, v_product_id, p_vendor_name, v_item->>'description')
      ON CONFLICT (org_id, vendor_name, raw_text)
        DO UPDATE SET product_id = EXCLUDED.product_id;

      IF COALESCE(v_qty, 0) <> 0 THEN
        INSERT INTO stock_movements
          (org_id, product_id, quantity, movement_type, unit_cost, source_type, source_id, note)
        VALUES
          (p_org_id, v_product_id, v_qty, 'purchase', v_unit_price, 'invoice', v_line_id, p_invoice_number);
      END IF;

      IF v_acct_inventory IS NOT NULL THEN
        v_inventory_total := v_inventory_total + COALESCE(v_line_total, 0);
      ELSE
        v_target := v_acct_fallback;   -- no inventory account -> treat as expense
      END IF;
    ELSE
      -- An expense/service line: route to the chosen account, else fallback.
      IF v_account_id IS NOT NULL THEN
        INSERT INTO account_aliases (org_id, account_id, vendor_name, raw_text)
        VALUES (p_org_id, v_account_id, p_vendor_name, v_item->>'description')
        ON CONFLICT (org_id, vendor_name, raw_text)
          DO UPDATE SET account_id = EXCLUDED.account_id;
        v_target := v_account_id;
      ELSE
        v_target := v_acct_fallback;
      END IF;
    END IF;

    -- Accumulate any expense debit (skip when booked to inventory, or when no
    -- fallback account exists to receive it).
    IF v_target IS NOT NULL AND COALESCE(v_line_total, 0) <> 0 THEN
      v_key := v_target::text;
      v_expense_by_acct := jsonb_set(
        v_expense_by_acct, ARRAY[v_key],
        to_jsonb(COALESCE((v_expense_by_acct->>v_key)::numeric, 0) + v_line_total)
      );
    END IF;
  END LOOP;

  -- If lines carried no value but the invoice has a total, book it to fallback.
  SELECT COALESCE(SUM(value::numeric), 0) INTO v_expense_sum FROM jsonb_each_text(v_expense_by_acct);
  IF v_inventory_total = 0 AND v_expense_sum = 0 AND COALESCE(p_total_amount, 0) > 0
     AND v_acct_fallback IS NOT NULL THEN
    v_expense_by_acct := jsonb_build_object(v_acct_fallback::text, to_jsonb(p_total_amount));
    v_expense_sum := p_total_amount;
  END IF;

  v_owed := v_inventory_total + v_expense_sum;

  -- ── Post the AP journal entry (guarded) ───────────────
  IF v_acct_payable IS NOT NULL AND v_owed > 0 THEN
    INSERT INTO journal_entries (org_id, entry_date, memo, source_type, source_id)
    VALUES (
      p_org_id, p_invoice_date,
      'Supplier invoice ' || COALESCE(p_invoice_number, '') || ' — ' || COALESCE(p_vendor_name, ''),
      'invoice', v_invoice_id
    )
    RETURNING id INTO v_entry_id;

    IF v_inventory_total > 0 THEN
      INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
      VALUES (v_entry_id, p_org_id, v_acct_inventory, v_inventory_total, 0, 'Goods received into stock');
    END IF;

    FOR v_key, v_val IN SELECT key, value FROM jsonb_each_text(v_expense_by_acct)
    LOOP
      INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
      VALUES (v_entry_id, p_org_id, v_key::integer, v_val::numeric, 0, 'Expense');
    END LOOP;

    INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
    VALUES (v_entry_id, p_org_id, v_acct_payable, 0, v_owed, 'Owed to supplier');
  END IF;

  RETURN v_invoice_id;
END;
$$;
