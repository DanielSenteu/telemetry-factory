-- Payments — the "Step 2" that settles a debt. Until now the ledger only ever
-- created debts: a supplier invoice grows Accounts Payable (you owe), but there
-- was no way to record PAYING it, so AP grew forever. And sales were always
-- instant cash. This adds both missing halves, plus credit sales (Accounts
-- Receivable — money owed TO you).
--
-- A payment is just another money-event posting a balanced journal entry, on the
-- exact same spine as confirm_invoice / record_sale:
--   Supplier payment:  Dr Accounts Payable (2000)   Cr Cash/M-Pesa/Bank
--   Customer payment:  Dr Cash/M-Pesa/Bank          Cr Accounts Receivable (1100)
--
-- Credit sales need NO new posting code: record_sale already debits whatever
-- account code it's handed, so a sale "on account" simply passes '1100' (AR) as
-- the payment account → Dr AR / Cr Sales. This migration only adds the payments
-- and the who-owes-what views.
--
-- Installments are supported: many payments can point at one invoice/sale; the
-- outstanding balance is DERIVED (total − sum of payments), never stored — same
-- discipline as product_stock / account_balance.

-- ── The payments source document ──────────────────────

CREATE TABLE payments (
  id           SERIAL PRIMARY KEY,
  org_id       INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  kind         TEXT    NOT NULL CHECK (kind IN ('supplier', 'customer')),
  -- Exactly one of these is set, depending on kind.
  invoice_id   INTEGER REFERENCES invoices(id) ON DELETE CASCADE,  -- supplier
  sale_id      INTEGER REFERENCES sales(id)    ON DELETE CASCADE,  -- customer
  payment_date DATE    NOT NULL,
  amount       NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  account_code TEXT    NOT NULL,                 -- the cash/bank account that moved
  note         TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by   UUID DEFAULT auth.uid(),
  CHECK ((kind = 'supplier' AND invoice_id IS NOT NULL AND sale_id IS NULL)
      OR (kind = 'customer' AND sale_id    IS NOT NULL AND invoice_id IS NULL))
);

CREATE INDEX idx_payments_org_id     ON payments(org_id);
CREATE INDEX idx_payments_invoice_id ON payments(invoice_id);
CREATE INDEX idx_payments_sale_id    ON payments(sale_id);

-- ── record_payment: the one way to log a payment ──────
-- Writes the payment row AND posts the balanced journal entry atomically, guarded
-- exactly like the other RPCs (if the accounts aren't set up, the payment still
-- records and we skip the journal). Runs as the caller → RLS scopes every write.

CREATE OR REPLACE FUNCTION record_payment(
  p_org_id       INTEGER,
  p_kind         TEXT,
  p_target_id    INTEGER,        -- invoice_id (supplier) or sale_id (customer)
  p_payment_date DATE,
  p_amount       NUMERIC,
  p_account_code TEXT,
  p_note         TEXT DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_payment_id INTEGER;
  v_acct_cash  INTEGER;
  v_acct_ap    INTEGER;
  v_acct_ar    INTEGER;
  v_entry_id   INTEGER;
  v_label      TEXT;
BEGIN
  IF p_kind = 'supplier' THEN
    INSERT INTO payments (org_id, kind, invoice_id, payment_date, amount, account_code, note)
    VALUES (p_org_id, 'supplier', p_target_id, p_payment_date, p_amount, p_account_code, p_note)
    RETURNING id INTO v_payment_id;

    SELECT 'Payment for invoice ' || COALESCE(invoice_number, '') || ' — ' || COALESCE(vendor_name, '')
      INTO v_label FROM invoices WHERE id = p_target_id;
  ELSE
    INSERT INTO payments (org_id, kind, sale_id, payment_date, amount, account_code, note)
    VALUES (p_org_id, 'customer', p_target_id, p_payment_date, p_amount, p_account_code, p_note)
    RETURNING id INTO v_payment_id;

    SELECT 'Payment from ' || COALESCE(NULLIF(customer_name, ''), 'customer')
      INTO v_label FROM sales WHERE id = p_target_id;
  END IF;

  SELECT id INTO v_acct_cash FROM gl_accounts WHERE org_id = p_org_id AND code = p_account_code;
  SELECT id INTO v_acct_ap   FROM gl_accounts WHERE org_id = p_org_id AND code = '2000';
  SELECT id INTO v_acct_ar   FROM gl_accounts WHERE org_id = p_org_id AND code = '1100';

  IF p_kind = 'supplier' AND v_acct_cash IS NOT NULL AND v_acct_ap IS NOT NULL THEN
    INSERT INTO journal_entries (org_id, entry_date, memo, source_type, source_id)
    VALUES (p_org_id, p_payment_date, v_label, 'payment', v_payment_id)
    RETURNING id INTO v_entry_id;
    INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
    VALUES (v_entry_id, p_org_id, v_acct_ap,   p_amount, 0, 'Settle payable');
    INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
    VALUES (v_entry_id, p_org_id, v_acct_cash, 0, p_amount, 'Cash paid out');

  ELSIF p_kind = 'customer' AND v_acct_cash IS NOT NULL AND v_acct_ar IS NOT NULL THEN
    INSERT INTO journal_entries (org_id, entry_date, memo, source_type, source_id)
    VALUES (p_org_id, p_payment_date, v_label, 'payment', v_payment_id)
    RETURNING id INTO v_entry_id;
    INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
    VALUES (v_entry_id, p_org_id, v_acct_cash, p_amount, 0, 'Cash received');
    INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
    VALUES (v_entry_id, p_org_id, v_acct_ar,   0, p_amount, 'Settle receivable');
  END IF;

  RETURN v_payment_id;
END;
$$;

-- ── Who do I owe? — supplier invoice balances ─────────
-- total owed − payments = outstanding, with a friendly status. security_invoker
-- so the underlying invoices/payments RLS scopes rows to the user's org.

CREATE VIEW supplier_invoice_balances WITH (security_invoker = true) AS
SELECT
  i.id           AS invoice_id,
  i.org_id,
  i.vendor_name,
  i.invoice_number,
  i.invoice_date,
  i.total_amount,
  COALESCE(p.paid, 0)                       AS paid,
  i.total_amount - COALESCE(p.paid, 0)      AS outstanding,
  CASE WHEN COALESCE(p.paid, 0) <= 0                 THEN 'unpaid'
       WHEN COALESCE(p.paid, 0) >= i.total_amount    THEN 'paid'
       ELSE 'partial' END                   AS status
FROM invoices i
LEFT JOIN (
  SELECT invoice_id, SUM(amount) AS paid
  FROM payments WHERE kind = 'supplier'
  GROUP BY invoice_id
) p ON p.invoice_id = i.id;

-- ── Who owes me? — customer receivables ───────────────
-- Only CREDIT (on-account) sales appear: those whose money was booked to AR
-- (payment_account_code = '1100'). Cash sales are already settled.

CREATE VIEW customer_receivables WITH (security_invoker = true) AS
SELECT
  s.id           AS sale_id,
  s.org_id,
  s.customer_name,
  s.sale_date,
  s.total_amount,
  COALESCE(p.paid, 0)                       AS paid,
  s.total_amount - COALESCE(p.paid, 0)      AS outstanding,
  CASE WHEN COALESCE(p.paid, 0) <= 0              THEN 'unpaid'
       WHEN COALESCE(p.paid, 0) >= s.total_amount THEN 'paid'
       ELSE 'partial' END                   AS status
FROM sales s
LEFT JOIN (
  SELECT sale_id, SUM(amount) AS paid
  FROM payments WHERE kind = 'customer'
  GROUP BY sale_id
) p ON p.sale_id = s.id
WHERE s.payment_account_code = '1100';

-- ── RLS — org-scoped, mirroring every other data table ─

ALTER TABLE payments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org-scoped access on payments" ON payments
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));
