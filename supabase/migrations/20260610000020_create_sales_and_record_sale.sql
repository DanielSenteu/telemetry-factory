-- Point of Sale: the outgoing-side source document, mirroring invoices (the
-- incoming side). A sale is ONE event that fans out to three places at once,
-- atomically — the whole point of the event-ledger spine:
--
--   1. sales + sale_items     — the receipt / source document
--   2. stock_movements        — stock OUT (-qty, 'sale'), capturing the cost basis
--   3. journal_entries/lines  — the money:
--        Dr Cash/M-Pesa   Cr Sales      (what the customer paid)
--        Dr COGS          Cr Inventory  (what those goods actually cost us)
--
-- That second journal pair is what finally answers the CEO's #1 pain — TRUE
-- UNIT COST / gross profit — using the weighted-average cost we already derive
-- in the product_stock view. No separate costing system; it falls out of the
-- ledger we already keep.

-- Products gain a sale price (what we charge). Cost is still DERIVED from the
-- stock ledger (product_stock.avg_unit_cost); this is the other half — the
-- price — so the POS can auto-fill and we can show margin = price − cost.
ALTER TABLE products ADD COLUMN sale_price NUMERIC(14,2);

-- ── Sales (the receipt header) ────────────────────────

CREATE TABLE sales (
  id                   SERIAL PRIMARY KEY,
  org_id               INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  sale_date            DATE NOT NULL,
  customer_name        TEXT,
  payment_account_code TEXT,                       -- which asset got the money: '1010' M-Pesa, '1000' Cash, '1020' Bank
  total_amount         NUMERIC(14,2) NOT NULL DEFAULT 0,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by           UUID DEFAULT auth.uid()
);

CREATE INDEX idx_sales_org_id ON sales(org_id);

-- ── Sale items (the lines) ────────────────────────────

CREATE TABLE sale_items (
  id          SERIAL PRIMARY KEY,
  sale_id     INTEGER NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
  org_id      INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  product_id  INTEGER REFERENCES products(id),     -- nullable: an ad-hoc/service line sells without stock
  description TEXT,
  quantity    NUMERIC(12,3) NOT NULL,
  unit_price  NUMERIC(14,2) NOT NULL,              -- what we charged
  total_price NUMERIC(14,2) NOT NULL,
  unit_cost   NUMERIC(14,2),                       -- captured cost basis at sale time (for COGS / margin)
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_sale_items_sale_id    ON sale_items(sale_id);
CREATE INDEX idx_sale_items_org_id     ON sale_items(org_id);
CREATE INDEX idx_sale_items_product_id ON sale_items(product_id);

-- ── record_sale: the one way to ring up a sale ────────
-- Runs as the caller, so RLS scopes every write to the user's org. The GL
-- posting is GUARDED exactly like confirm_invoice: if the accounts aren't set
-- up, the sale + stock still record and we simply skip the journal.
--   p_lines = [{ "product_id": 5, "quantity": 3, "unit_price": 50 }, ...]

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
    -- (The sale's own negative movement doesn't affect it — only inflows do.)
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

  UPDATE sales SET total_amount = v_sale_total WHERE id = v_sale_id;

  -- ── Post the GL entry (guarded) ───────────────────────
  SELECT id INTO v_acct_pay   FROM gl_accounts WHERE org_id = p_org_id AND code = p_payment_account_code;
  SELECT id INTO v_acct_sales FROM gl_accounts WHERE org_id = p_org_id AND code = '4000';
  SELECT id INTO v_acct_cogs  FROM gl_accounts WHERE org_id = p_org_id AND code = '5000';
  SELECT id INTO v_acct_inv   FROM gl_accounts WHERE org_id = p_org_id AND code = '1200';

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
      VALUES (v_entry_id, p_org_id, v_acct_sales, 0, v_sale_total, 'Sales revenue');
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

-- ── RLS — org-scoped, mirroring every other data table ─

ALTER TABLE sales      ENABLE ROW LEVEL SECURITY;
ALTER TABLE sale_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org-scoped access on sales" ON sales
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));

CREATE POLICY "Org-scoped access on sale_items" ON sale_items
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));
