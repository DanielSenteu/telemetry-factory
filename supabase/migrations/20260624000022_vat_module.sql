-- VAT (Value Added Tax) — the tax that passes THROUGH the business to KRA, never
-- income or expense. It splits in two, mirroring the two sides of the ledger:
--
--   OUTPUT VAT  collected on SALES     -> a LIABILITY (2100 VAT Payable, you owe KRA)
--   INPUT VAT   paid on PURCHASES      -> an ASSET     (1300 VAT Receivable, reclaimable)
--
-- Each is netted monthly; you remit only the difference (the VAT return). This
-- module is purely additive and GUARDED: VAT is a per-org switch (most small
-- traders below the KES 5M threshold aren't registered), and when it is off every
-- posting is byte-identical to before. When on, each posting simply gains balanced
-- VAT lines on the SAME post_journal_entry machinery — the immutable-ledger
-- discipline (balanced + append-only) is untouched.
--
-- Decisions baked in:
--   * Purchase VAT = one header amount per invoice (lines are NET, total is GROSS).
--   * Sale prices are VAT-INCLUSIVE (shelf price is what the customer pays); output
--     VAT is extracted out of the gross via rate/(100+rate).

-- ── 1. Per-org VAT settings ───────────────────────────
-- Read inside the RPCs by p_org_id. Defaults make every existing org non-VAT, so
-- behaviour is unchanged until a client is explicitly switched on.

ALTER TABLE organizations
  ADD COLUMN IF NOT EXISTS vat_enabled BOOLEAN     NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS vat_rate    NUMERIC(5,2) NOT NULL DEFAULT 16,
  ADD COLUMN IF NOT EXISTS vat_pin     TEXT;

-- ── 2. Header VAT columns on the source documents ─────
-- For tax-compliant records/receipts and the VAT return summary.

ALTER TABLE invoices ADD COLUMN IF NOT EXISTS vat_amount NUMERIC(12,2);
ALTER TABLE sales    ADD COLUMN IF NOT EXISTS vat_amount NUMERIC(14,2);

-- ── 3. Chart of accounts: add 1300 VAT Receivable ─────
-- 2100 VAT Payable (output) already seeded in 0017. Add the input side, then
-- backfill every existing org (idempotent via the function's ON CONFLICT).

CREATE OR REPLACE FUNCTION seed_default_gl_accounts(p_org_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO gl_accounts (org_id, code, name, type, normal_side, is_system)
  VALUES
    -- Assets (1000s) — what you have / are owed
    (p_org_id, '1000', 'Cash on Hand',          'asset',     'debit',  true),
    (p_org_id, '1010', 'M-Pesa',                 'asset',     'debit',  true),
    (p_org_id, '1020', 'Bank',                   'asset',     'debit',  true),
    (p_org_id, '1100', 'Accounts Receivable',    'asset',     'debit',  true),
    (p_org_id, '1200', 'Inventory',              'asset',     'debit',  true),
    (p_org_id, '1300', 'VAT Receivable',         'asset',     'debit',  true),
    -- Liabilities (2000s) — what you owe
    (p_org_id, '2000', 'Accounts Payable',       'liability', 'credit', true),
    (p_org_id, '2100', 'VAT Payable',            'liability', 'credit', true),
    -- Equity (3000s) — what's truly yours
    (p_org_id, '3000', 'Owner''s Equity',        'equity',    'credit', true),
    (p_org_id, '3900', 'Retained Earnings',      'equity',    'credit', true),
    -- Income (4000s) — money coming in
    (p_org_id, '4000', 'Sales',                  'income',    'credit', true),
    -- Expenses (5000s/6000s) — money going out
    (p_org_id, '5000', 'Cost of Goods Sold',     'expense',   'debit',  true),
    (p_org_id, '6000', 'Wages & Salaries',       'expense',   'debit',  true),
    (p_org_id, '6100', 'Electricity',            'expense',   'debit',  true),
    (p_org_id, '6200', 'Rent',                   'expense',   'debit',  true),
    (p_org_id, '6900', 'General Expenses',       'expense',   'debit',  true)
  ON CONFLICT (org_id, code) DO NOTHING;
END;
$$;

-- Backfill 1300 (and any other missing defaults) for every existing org.
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT id FROM organizations LOOP
    PERFORM seed_default_gl_accounts(r.id);
  END LOOP;
END $$;

-- ── 4. confirm_invoice: INPUT VAT on supplier invoices ─
-- Extends 0021. New p_vat_amount is the VAT shown on the supplier's tax invoice.
-- Lines remain NET; the entry now books:
--   Dr Inventory / Expense   (net line values, as before)
--   Dr VAT Receivable (1300) (the reclaimable input VAT)   <- NEW
--      Cr Accounts Payable (2000)  (net + VAT = gross owed)
-- VAT is ignored entirely when the org isn't VAT-registered or 1300 is absent, so
-- the AP credit never inflates without a matching debit (entry always balances).

-- Adding p_vat_amount changes the signature, so the prior 8-arg version (0021)
-- must be dropped explicitly — CREATE OR REPLACE would otherwise leave it behind
-- as a stale overload that still matches 8-arg calls.
DROP FUNCTION IF EXISTS confirm_invoice(INTEGER, TEXT, TEXT, DATE, NUMERIC, TEXT, TEXT, JSONB);

CREATE OR REPLACE FUNCTION confirm_invoice(
  p_org_id         INTEGER,
  p_vendor_name    TEXT,
  p_invoice_number TEXT,
  p_invoice_date   DATE,
  p_total_amount   NUMERIC(12,2),
  p_file_name      TEXT,
  p_storage_path   TEXT,
  p_line_items     JSONB,
  p_vat_amount     NUMERIC DEFAULT 0
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
  -- VAT
  v_vat_enabled     BOOLEAN := false;
  v_acct_vat_in     INTEGER;
  v_vat             NUMERIC := 0;
BEGIN
  SELECT id INTO v_acct_inventory FROM gl_accounts WHERE org_id = p_org_id AND code = '1200';
  SELECT id INTO v_acct_payable   FROM gl_accounts WHERE org_id = p_org_id AND code = '2000';
  SELECT id INTO v_acct_fallback  FROM gl_accounts WHERE org_id = p_org_id AND code = '6900';
  SELECT id INTO v_acct_vat_in    FROM gl_accounts WHERE org_id = p_org_id AND code = '1300';
  SELECT COALESCE(vat_enabled, false) INTO v_vat_enabled FROM organizations WHERE id = p_org_id;

  -- Effective input VAT: only when registered AND we have the account to book it to.
  IF v_vat_enabled AND v_acct_vat_in IS NOT NULL THEN
    v_vat := COALESCE(p_vat_amount, 0);
  END IF;

  INSERT INTO invoices (org_id, vendor_name, invoice_number, invoice_date, total_amount, file_name, storage_path, vat_amount)
  VALUES (p_org_id, p_vendor_name, p_invoice_number, p_invoice_date, p_total_amount, p_file_name, p_storage_path,
          CASE WHEN v_vat_enabled THEN COALESCE(p_vat_amount, 0) ELSE NULL END)
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
  -- With VAT registered, the line value is NET, so subtract VAT from the gross total.
  SELECT COALESCE(SUM(value::numeric), 0) INTO v_expense_sum FROM jsonb_each_text(v_expense_by_acct);
  IF v_inventory_total = 0 AND v_expense_sum = 0 AND COALESCE(p_total_amount, 0) - v_vat > 0
     AND v_acct_fallback IS NOT NULL THEN
    v_expense_by_acct := jsonb_build_object(v_acct_fallback::text, to_jsonb(p_total_amount - v_vat));
    v_expense_sum := p_total_amount - v_vat;
  END IF;

  v_owed := v_inventory_total + v_expense_sum;

  -- ── Post the AP journal entry (guarded) ───────────────
  IF v_acct_payable IS NOT NULL AND (v_owed + v_vat) > 0 THEN
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

    -- Reclaimable input VAT (only when registered & 1300 exists; else v_vat = 0).
    IF v_vat > 0 THEN
      INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
      VALUES (v_entry_id, p_org_id, v_acct_vat_in, v_vat, 0, 'Input VAT (reclaimable)');
    END IF;

    INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
    VALUES (v_entry_id, p_org_id, v_acct_payable, 0, v_owed + v_vat, 'Owed to supplier');
  END IF;

  RETURN v_invoice_id;
END;
$$;

-- ── 5. record_sale: OUTPUT VAT on sales ───────────────
-- Extends 0020. Prices are VAT-INCLUSIVE, so output VAT is extracted out of the
-- gross. The revenue pair becomes:
--   Dr Cash/M-Pesa   (gross — what the customer paid, unchanged)
--      Cr Sales (4000)        (net — true revenue)
--      Cr VAT Payable (2100)  (extracted output VAT)         <- NEW
-- When the org isn't registered (or 2100 is absent), Cr Sales = gross exactly as
-- before. The COGS pair is unchanged.

CREATE OR REPLACE FUNCTION record_sale(
  p_org_id               INTEGER,
  p_sale_date            DATE,
  p_customer_name        TEXT,
  p_payment_account_code TEXT,
  p_lines                JSONB
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_sale_id      INTEGER;
  v_line         JSONB;
  v_product_id   INTEGER;
  v_qty          NUMERIC;
  v_unit_price   NUMERIC;
  v_line_total   NUMERIC;
  v_unit_cost    NUMERIC;
  v_descr        TEXT;
  v_sale_total   NUMERIC := 0;
  v_cogs_total   NUMERIC := 0;
  -- accounts
  v_acct_pay     INTEGER;
  v_acct_sales   INTEGER;
  v_acct_cogs    INTEGER;
  v_acct_inv     INTEGER;
  v_entry_id     INTEGER;
  v_post_rev     BOOLEAN;
  v_post_cogs    BOOLEAN;
  -- VAT
  v_vat_enabled  BOOLEAN := false;
  v_vat_rate     NUMERIC := 0;
  v_acct_vat_out INTEGER;
  v_net          NUMERIC := 0;
  v_vat          NUMERIC := 0;
BEGIN
  INSERT INTO sales (org_id, sale_date, customer_name, payment_account_code, total_amount)
  VALUES (p_org_id, p_sale_date, p_customer_name, p_payment_account_code, 0)
  RETURNING id INTO v_sale_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_product_id := NULLIF(v_line->>'product_id', '')::INTEGER;
    v_qty        := COALESCE(NULLIF(v_line->>'quantity', '')::NUMERIC, 0);
    v_unit_price := COALESCE(NULLIF(v_line->>'unit_price', '')::NUMERIC, 0);
    v_line_total := v_qty * v_unit_price;
    v_descr      := v_line->>'description';

    -- Cost basis = current weighted-average cost from the inventory view.
    v_unit_cost := 0;
    IF v_product_id IS NOT NULL THEN
      SELECT COALESCE(avg_unit_cost, 0) INTO v_unit_cost
        FROM product_stock WHERE product_id = v_product_id;
      IF v_descr IS NULL THEN
        SELECT name INTO v_descr FROM products WHERE id = v_product_id;
      END IF;
    END IF;

    INSERT INTO sale_items (sale_id, org_id, product_id, description, quantity, unit_price, total_price, unit_cost)
    VALUES (v_sale_id, p_org_id, v_product_id, v_descr, v_qty, v_unit_price, v_line_total, v_unit_cost);

    -- Stock OUT: a negative 'sale' movement (only for tracked products).
    IF v_product_id IS NOT NULL AND v_qty <> 0 THEN
      INSERT INTO stock_movements
        (org_id, product_id, quantity, movement_type, unit_cost, source_type, source_id, note)
      VALUES
        (p_org_id, v_product_id, -v_qty, 'sale', v_unit_cost, 'sale', v_sale_id, p_customer_name);
    END IF;

    v_sale_total := v_sale_total + v_line_total;
    v_cogs_total := v_cogs_total + (v_qty * COALESCE(v_unit_cost, 0));
  END LOOP;

  -- ── Post the GL entry (guarded) ───────────────────────
  SELECT id INTO v_acct_pay     FROM gl_accounts WHERE org_id = p_org_id AND code = p_payment_account_code;
  SELECT id INTO v_acct_sales   FROM gl_accounts WHERE org_id = p_org_id AND code = '4000';
  SELECT id INTO v_acct_cogs    FROM gl_accounts WHERE org_id = p_org_id AND code = '5000';
  SELECT id INTO v_acct_inv     FROM gl_accounts WHERE org_id = p_org_id AND code = '1200';
  SELECT id INTO v_acct_vat_out FROM gl_accounts WHERE org_id = p_org_id AND code = '2100';
  SELECT COALESCE(vat_enabled, false), COALESCE(vat_rate, 0)
    INTO v_vat_enabled, v_vat_rate FROM organizations WHERE id = p_org_id;

  -- Extract output VAT out of the inclusive gross (only when registered, 2100
  -- exists, and a positive rate). Otherwise net = gross, vat = 0.
  IF v_vat_enabled AND v_acct_vat_out IS NOT NULL AND v_vat_rate > 0 AND v_sale_total > 0 THEN
    v_net := ROUND(v_sale_total * 100 / (100 + v_vat_rate), 2);
    v_vat := v_sale_total - v_net;
  ELSE
    v_net := v_sale_total;
    v_vat := 0;
  END IF;

  UPDATE sales
     SET total_amount = v_sale_total,
         vat_amount   = CASE WHEN v_vat_enabled THEN v_vat ELSE NULL END
   WHERE id = v_sale_id;

  -- Each pair balances on its own, so including/excluding a pair keeps the
  -- whole entry balanced.
  v_post_rev  := v_acct_pay  IS NOT NULL AND v_acct_sales IS NOT NULL AND v_sale_total > 0;
  v_post_cogs := v_acct_cogs IS NOT NULL AND v_acct_inv   IS NOT NULL AND v_cogs_total > 0;

  IF v_post_rev OR v_post_cogs THEN
    INSERT INTO journal_entries (org_id, entry_date, memo, source_type, source_id)
    VALUES (
      p_org_id,
      p_sale_date,
      'Sale' || CASE WHEN p_customer_name IS NOT NULL AND p_customer_name <> ''
                     THEN ' — ' || p_customer_name ELSE '' END,
      'sale',
      v_sale_id
    )
    RETURNING id INTO v_entry_id;

    IF v_post_rev THEN
      INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
      VALUES (v_entry_id, p_org_id, v_acct_pay,   v_sale_total, 0, 'Payment received');
      INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
      VALUES (v_entry_id, p_org_id, v_acct_sales, 0, v_net, 'Sales revenue');
      IF v_vat > 0 THEN
        INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
        VALUES (v_entry_id, p_org_id, v_acct_vat_out, 0, v_vat, 'Output VAT collected');
      END IF;
    END IF;

    IF v_post_cogs THEN
      INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
      VALUES (v_entry_id, p_org_id, v_acct_cogs, v_cogs_total, 0, 'Cost of goods sold');
      INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
      VALUES (v_entry_id, p_org_id, v_acct_inv,  0, v_cogs_total, 'Inventory reduction');
    END IF;
  END IF;

  RETURN v_sale_id;
END;
$$;

-- ── 6. vat_summary: the VAT return figures for a period ─
-- output_vat = net credits on 2100, input_vat = net debits on 1300, over the
-- entry-date range. net_due = output − input (positive = pay KRA, negative =
-- refund). Runs as the caller, so RLS scopes it to the user's org.
-- Settling a return reuses post_journal_entry (Dr 2100 / Cr 1300 / Cr Bank).

CREATE OR REPLACE FUNCTION vat_summary(p_org_id INTEGER, p_from DATE, p_to DATE)
RETURNS TABLE (output_vat NUMERIC, input_vat NUMERIC, net_due NUMERIC)
LANGUAGE sql
STABLE
AS $$
  WITH t AS (
    SELECT
      COALESCE(SUM(CASE WHEN a.code = '2100' THEN jl.credit - jl.debit ELSE 0 END), 0) AS out_vat,
      COALESCE(SUM(CASE WHEN a.code = '1300' THEN jl.debit - jl.credit ELSE 0 END), 0) AS in_vat
    FROM journal_lines jl
    JOIN journal_entries je ON je.id = jl.entry_id
    JOIN gl_accounts     a  ON a.id  = jl.account_id
    WHERE jl.org_id = p_org_id
      AND a.code IN ('2100', '1300')
      AND je.entry_date BETWEEN p_from AND p_to
  )
  SELECT out_vat, in_vat, out_vat - in_vat FROM t;
$$;
