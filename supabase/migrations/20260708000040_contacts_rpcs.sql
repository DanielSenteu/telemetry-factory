-- Contacts wiring into the posting RPCs (extends 0022's bodies byte-for-byte,
-- with three additive deltas):
--
--   1. confirm_invoice gains p_supplier_id  — stamps the contact link + learns
--      the vendor-text alias.
--   2. record_sale gains p_customer_id      — stamps + learns, PLUS the credit
--      check: a credit sale (booked to AR '1100') that would push a customer
--      past their credit_limit_ksh raises and rolls the whole sale back.
--   3. link_contact_alias                   — the backfill assist for the
--      "Link names" UI: upserts the alias and stamps every historic unlinked
--      document bearing that exact text.
--
-- Default-safe: both new params default NULL. No id (or an id from another
-- org — silently ignored), no limit, or a cash payment code ⇒ ZERO new
-- behaviour; the posting logic is untouched. Existing callers keep working.
--
-- RACE-SAFETY of the credit check: two cashiers ringing up credit sales for
-- the same customer at once could both read "outstanding 60k, limit 100k" and
-- both approve 40k. SELECT ... FOR UPDATE on the contact row serializes them:
-- the second waits for the first to commit, then (READ COMMITTED gives each
-- statement a fresh snapshot) re-reads the NEW outstanding and correctly
-- rejects. The lock auto-releases at commit/rollback and only ever blocks
-- credit sales for that one customer.
--
-- All three run as INVOKER: contacts/aliases are admin-only via RLS, workers
-- can't insert sales anyway (no accounts row), so no SECURITY DEFINER needed.

-- ── 1. confirm_invoice + p_supplier_id ────────────────
-- Adding a param changes the signature: the 9-arg version from 0022 must be
-- dropped explicitly or it survives as a stale overload (see 0022 lines 88-91).

DROP FUNCTION IF EXISTS confirm_invoice(INTEGER, TEXT, TEXT, DATE, NUMERIC, TEXT, TEXT, JSONB, NUMERIC);

CREATE OR REPLACE FUNCTION confirm_invoice(
  p_org_id         INTEGER,
  p_vendor_name    TEXT,
  p_invoice_number TEXT,
  p_invoice_date   DATE,
  p_total_amount   NUMERIC(12,2),
  p_file_name      TEXT,
  p_storage_path   TEXT,
  p_line_items     JSONB,
  p_vat_amount     NUMERIC DEFAULT 0,
  p_supplier_id    INTEGER DEFAULT NULL
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
  -- Contacts
  v_supplier_id     INTEGER;
BEGIN
  SELECT id INTO v_acct_inventory FROM gl_accounts WHERE org_id = p_org_id AND code = '1200';
  SELECT id INTO v_acct_payable   FROM gl_accounts WHERE org_id = p_org_id AND code = '2000';
  SELECT id INTO v_acct_fallback  FROM gl_accounts WHERE org_id = p_org_id AND code = '6900';
  SELECT id INTO v_acct_vat_in    FROM gl_accounts WHERE org_id = p_org_id AND code = '1300';
  SELECT COALESCE(vat_enabled, false) INTO v_vat_enabled FROM organizations WHERE id = p_org_id;

  -- Validate the supplier belongs to this org; anything else ⇒ silently NULL
  -- (default-safe: a bad id must never block an invoice from posting).
  IF p_supplier_id IS NOT NULL THEN
    SELECT id INTO v_supplier_id FROM contacts WHERE id = p_supplier_id AND org_id = p_org_id;
  END IF;

  -- Effective input VAT: only when registered AND we have the account to book it to.
  IF v_vat_enabled AND v_acct_vat_in IS NOT NULL THEN
    v_vat := COALESCE(p_vat_amount, 0);
  END IF;

  INSERT INTO invoices (org_id, vendor_name, invoice_number, invoice_date, total_amount, file_name, storage_path, vat_amount, supplier_id)
  VALUES (p_org_id, p_vendor_name, p_invoice_number, p_invoice_date, p_total_amount, p_file_name, p_storage_path,
          CASE WHEN v_vat_enabled THEN COALESCE(p_vat_amount, 0) ELSE NULL END,
          v_supplier_id)
  RETURNING id INTO v_invoice_id;

  -- Alias-learn: this vendor text now means this contact (upsert re-links).
  IF v_supplier_id IS NOT NULL AND COALESCE(TRIM(p_vendor_name), '') <> '' THEN
    INSERT INTO contact_aliases (org_id, contact_id, raw_text)
    VALUES (p_org_id, v_supplier_id, p_vendor_name)
    ON CONFLICT (org_id, raw_text) DO UPDATE SET contact_id = EXCLUDED.contact_id;
  END IF;

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

-- ── 2. record_sale + p_customer_id + credit check ─────
-- Same stale-overload discipline: drop the 5-arg version from 0022.

DROP FUNCTION IF EXISTS record_sale(INTEGER, DATE, TEXT, TEXT, JSONB);

CREATE OR REPLACE FUNCTION record_sale(
  p_org_id               INTEGER,
  p_sale_date            DATE,
  p_customer_name        TEXT,
  p_payment_account_code TEXT,
  p_lines                JSONB,
  p_customer_id          INTEGER DEFAULT NULL
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
  -- Contacts / credit
  v_customer_id  INTEGER;
  v_cust_name    TEXT;
  v_limit        NUMERIC;
  v_outstanding  NUMERIC;
BEGIN
  -- Validate the customer belongs to this org; anything else ⇒ silently NULL.
  IF p_customer_id IS NOT NULL THEN
    SELECT id INTO v_customer_id FROM contacts WHERE id = p_customer_id AND org_id = p_org_id;
  END IF;

  INSERT INTO sales (org_id, sale_date, customer_name, payment_account_code, total_amount, customer_id)
  VALUES (p_org_id, p_sale_date, p_customer_name, p_payment_account_code, 0, v_customer_id)
  RETURNING id INTO v_sale_id;

  -- Alias-learn: this customer text now means this contact (upsert re-links).
  IF v_customer_id IS NOT NULL AND COALESCE(TRIM(p_customer_name), '') <> '' THEN
    INSERT INTO contact_aliases (org_id, contact_id, raw_text)
    VALUES (p_org_id, v_customer_id, p_customer_name)
    ON CONFLICT (org_id, raw_text) DO UPDATE SET contact_id = EXCLUDED.contact_id;
  END IF;

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

  -- ── Credit check (only for linked customers buying ON ACCOUNT) ─
  -- FOR UPDATE locks the contact row so concurrent credit sales for the SAME
  -- customer run one at a time — the second re-reads outstanding AFTER the
  -- first commits. NULL limit = no limit set = never blocks. Raising here
  -- rolls back the ENTIRE sale (rows, stock movements, alias) atomically.
  IF v_customer_id IS NOT NULL AND p_payment_account_code = '1100' THEN
    SELECT name, credit_limit_ksh INTO v_cust_name, v_limit
      FROM contacts WHERE id = v_customer_id AND org_id = p_org_id
       FOR UPDATE;

    IF v_limit IS NOT NULL THEN
      SELECT COALESCE(SUM(outstanding), 0) INTO v_outstanding
        FROM customer_receivables
       WHERE org_id = p_org_id AND customer_id = v_customer_id
         AND sale_id <> v_sale_id;   -- exclude our own in-flight row

      IF v_outstanding + v_sale_total > v_limit THEN
        RAISE EXCEPTION 'Credit limit exceeded for %: outstanding % + this sale % > limit %',
          v_cust_name, v_outstanding, v_sale_total, v_limit;
      END IF;
    END IF;
  END IF;

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

-- ── 3. link_contact_alias: the backfill assist ────────
-- "This raw name = this contact, and stamp all the old documents too."
-- Upserts the alias, then links every historic doc with that EXACT text that
-- has no contact yet. Returns how many documents were backfilled. Runs as
-- invoker — RLS (admin-only on contacts/aliases) is the gate; a worker's
-- contact lookup returns nothing and the call fails before touching anything.

CREATE OR REPLACE FUNCTION link_contact_alias(
  p_org_id     INTEGER,
  p_kind       TEXT,
  p_raw_text   TEXT,
  p_contact_id INTEGER
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_contact_id INTEGER;
  v_count      INTEGER := 0;
BEGIN
  IF p_kind NOT IN ('supplier', 'customer') THEN
    RAISE EXCEPTION 'Invalid kind: %', p_kind;
  END IF;
  IF COALESCE(TRIM(p_raw_text), '') = '' THEN
    RAISE EXCEPTION 'Raw text is required';
  END IF;

  SELECT id INTO v_contact_id FROM contacts WHERE id = p_contact_id AND org_id = p_org_id;
  IF v_contact_id IS NULL THEN
    RAISE EXCEPTION 'Contact not found for this organization';
  END IF;

  INSERT INTO contact_aliases (org_id, contact_id, raw_text)
  VALUES (p_org_id, v_contact_id, p_raw_text)
  ON CONFLICT (org_id, raw_text) DO UPDATE SET contact_id = EXCLUDED.contact_id;

  IF p_kind = 'supplier' THEN
    UPDATE invoices SET supplier_id = v_contact_id
     WHERE org_id = p_org_id AND supplier_id IS NULL AND vendor_name = p_raw_text;
  ELSE
    UPDATE sales SET customer_id = v_contact_id
     WHERE org_id = p_org_id AND customer_id IS NULL AND customer_name = p_raw_text;
  END IF;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN v_count;
END;
$$;
