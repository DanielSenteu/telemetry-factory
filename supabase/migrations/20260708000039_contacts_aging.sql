-- Contacts — promoting "customer" and "vendor" from free-typed text to real
-- records. Until now every sale/invoice just carried a name string; that's fine
-- for a receipt, useless for questions like "how much does Mombasa Pharma owe
-- us, and how overdue is it?". A contact is the anchor those questions hang on:
-- per-contact statements, AR/AP aging, credit limits, supplier spend.
--
-- Everything here is ADDITIVE and default-safe:
--   * invoices/sales gain a NULLABLE contact FK — every existing row stays NULL
--     and every existing caller keeps working (text columns are untouched;
--     the contact id sits BESIDE the text, never replaces it).
--   * balance views only APPEND columns (Postgres forbids reordering in
--     CREATE OR REPLACE VIEW anyway — this is what keeps select("*") callers safe).
--   * No RPC changes in this migration (those come in 0040), so the schema can
--     ship alone with zero behaviour change.
--
-- Alias pattern deployment #7: same three-layer resolution as products
-- (raw text -> alias -> entity), pointed at contacts. "KENYA MED SUPP" learns
-- to mean Kenya Medical Supplies Ltd once, then auto-resolves forever.

-- ── 1. The contacts registry ──────────────────────────

CREATE TABLE contacts (
  id                 SERIAL PRIMARY KEY,
  org_id             INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name               TEXT    NOT NULL,
  kind               TEXT    NOT NULL CHECK (kind IN ('customer', 'supplier', 'both')),
  phone              TEXT,
  email              TEXT,
  kra_pin            TEXT,
  -- NULL = no limit set (credit checks skip entirely). 0 = "no credit at all".
  credit_limit_ksh   NUMERIC(14,2) CHECK (credit_limit_ksh >= 0),
  -- "Net N" terms: due date = document date + N days. 0 = due immediately.
  payment_terms_days INTEGER NOT NULL DEFAULT 0 CHECK (payment_terms_days >= 0),
  active             BOOLEAN NOT NULL DEFAULT true,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (org_id, name)
);

CREATE INDEX idx_contacts_org_id ON contacts(org_id);

-- ── 2. The alias memory (mirrors product/account aliases) ─
-- One org-wide mapping per exact raw string. Unlike account_aliases there is no
-- vendor_name dimension — the raw text IS the vendor/customer name itself.

CREATE TABLE contact_aliases (
  id         SERIAL PRIMARY KEY,
  org_id     INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  contact_id INTEGER NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  raw_text   TEXT    NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (org_id, raw_text)
);

CREATE INDEX idx_contact_aliases_org_id     ON contact_aliases(org_id);
CREATE INDEX idx_contact_aliases_contact_id ON contact_aliases(contact_id);

-- ── 3. RLS: ADMIN-ONLY, deliberately stricter than org-scoped ─
-- Contacts carry financial terms (credit limits). Workers get ZERO rows — they
-- can't read limits, and they can't insert sales anyway (no accounts row), so
-- the credit check in 0040 needs no SECURITY DEFINER escalation.

ALTER TABLE contacts        ENABLE ROW LEVEL SECURITY;
ALTER TABLE contact_aliases ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins manage contacts in their org" ON contacts
  FOR ALL TO authenticated
  USING (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

CREATE POLICY "Admins manage contact_aliases in their org" ON contact_aliases
  FOR ALL TO authenticated
  USING (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

-- Explicit table grants: RLS decides WHICH rows, GRANT decides IF the role may
-- touch the table at all. Older Supabase images granted CRUD to authenticated
-- by default; newer ones don't — so we stop relying on implicit defaults.
-- Workers still get zero rows (the policies above are the row gate).
GRANT SELECT, INSERT, UPDATE, DELETE ON contacts, contact_aliases TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE contacts_id_seq, contact_aliases_id_seq TO authenticated;

-- ── 4. Additive contact FKs on the source documents ───
-- The text columns (vendor_name / customer_name) remain the display truth on
-- the document; the id is the LINK. Old rows stay NULL ("Unassigned" in aging).

ALTER TABLE invoices ADD COLUMN IF NOT EXISTS supplier_id INTEGER REFERENCES contacts(id) ON DELETE SET NULL;
ALTER TABLE sales    ADD COLUMN IF NOT EXISTS customer_id INTEGER REFERENCES contacts(id) ON DELETE SET NULL;

CREATE INDEX idx_invoices_supplier_id ON invoices(supplier_id);
CREATE INDEX idx_sales_customer_id    ON sales(customer_id);

-- ── 5. Extend the balance views (APPEND-ONLY) ─────────
-- Same definitions as 0024 with the contact id appended as the LAST column.
-- CREATE OR REPLACE VIEW only permits appending — existing select("*") callers
-- see the same columns in the same positions.

CREATE OR REPLACE VIEW supplier_invoice_balances WITH (security_invoker = true) AS
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
       ELSE 'partial' END                   AS status,
  i.supplier_id
FROM invoices i
LEFT JOIN (
  SELECT invoice_id, SUM(amount) AS paid
  FROM payments WHERE kind = 'supplier'
  GROUP BY invoice_id
) p ON p.invoice_id = i.id;

CREATE OR REPLACE VIEW customer_receivables WITH (security_invoker = true) AS
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
       ELSE 'partial' END                   AS status,
  s.customer_id
FROM sales s
LEFT JOIN (
  SELECT sale_id, SUM(amount) AS paid
  FROM payments WHERE kind = 'customer'
  GROUP BY sale_id
) p ON p.sale_id = s.id
WHERE s.payment_account_code = '1100';

-- ── 6. Aging: "who to chase this week" ────────────────
-- One row per contact, outstanding split into how-overdue buckets. Age counts
-- from the DUE date (doc date + the contact's payment terms), not the doc date,
-- so "Net 14" invoices don't look overdue while still inside terms.
--
-- "Today" is pinned to Africa/Nairobi: a report run at 11pm EAT must not shift
-- documents between buckets because the server clock is UTC.
--
-- Buckets partition ALL outstanding docs (bucket_0_30 includes not-yet-due,
-- i.e. negative ages), so the four buckets always sum to total_outstanding —
-- and SUM(total_outstanding) reconciles to the AP/AR control account.

CREATE VIEW ap_aging WITH (security_invoker = true) AS
WITH docs AS (
  SELECT
    b.org_id,
    b.supplier_id AS contact_id,
    c.name        AS contact_name,
    b.outstanding,
    -- A NULL invoice_date can't age: treat as dated today (lands in 0-30).
    (now() AT TIME ZONE 'Africa/Nairobi')::date
      - (COALESCE(b.invoice_date, (now() AT TIME ZONE 'Africa/Nairobi')::date)
         + COALESCE(c.payment_terms_days, 0)) AS age_days
  FROM supplier_invoice_balances b
  LEFT JOIN contacts c ON c.id = b.supplier_id
  WHERE b.outstanding > 0
)
SELECT
  org_id,
  contact_id,
  COALESCE(contact_name, 'Unassigned')                              AS contact_name,
  COUNT(*)::int                                                     AS open_docs,
  SUM(outstanding)                                                  AS total_outstanding,
  COALESCE(SUM(outstanding) FILTER (WHERE age_days <= 30), 0)               AS bucket_0_30,
  COALESCE(SUM(outstanding) FILTER (WHERE age_days BETWEEN 31 AND 60), 0)   AS bucket_31_60,
  COALESCE(SUM(outstanding) FILTER (WHERE age_days BETWEEN 61 AND 90), 0)   AS bucket_61_90,
  COALESCE(SUM(outstanding) FILTER (WHERE age_days > 90), 0)                AS bucket_90_plus
FROM docs
GROUP BY org_id, contact_id, contact_name;

CREATE VIEW ar_aging WITH (security_invoker = true) AS
WITH docs AS (
  SELECT
    r.org_id,
    r.customer_id AS contact_id,
    c.name        AS contact_name,
    r.outstanding,
    (now() AT TIME ZONE 'Africa/Nairobi')::date
      - (r.sale_date + COALESCE(c.payment_terms_days, 0)) AS age_days
  FROM customer_receivables r
  LEFT JOIN contacts c ON c.id = r.customer_id
  WHERE r.outstanding > 0
)
SELECT
  org_id,
  contact_id,
  COALESCE(contact_name, 'Unassigned')                              AS contact_name,
  COUNT(*)::int                                                     AS open_docs,
  SUM(outstanding)                                                  AS total_outstanding,
  COALESCE(SUM(outstanding) FILTER (WHERE age_days <= 30), 0)               AS bucket_0_30,
  COALESCE(SUM(outstanding) FILTER (WHERE age_days BETWEEN 31 AND 60), 0)   AS bucket_31_60,
  COALESCE(SUM(outstanding) FILTER (WHERE age_days BETWEEN 61 AND 90), 0)   AS bucket_61_90,
  COALESCE(SUM(outstanding) FILTER (WHERE age_days > 90), 0)                AS bucket_90_plus
FROM docs
GROUP BY org_id, contact_id, contact_name;

-- ── 7. Suggestions: names waiting to become contacts ──
-- Every distinct vendor/customer string on documents that has no contact link
-- yet — the "Link names" backfill queue in the UI. security_invoker: the
-- underlying invoices/sales RLS scopes rows.

CREATE VIEW contact_suggestions WITH (security_invoker = true) AS
SELECT
  org_id,
  'supplier'          AS kind,
  vendor_name         AS raw_text,
  COUNT(*)::int       AS doc_count,
  MAX(invoice_date)   AS last_seen
FROM invoices
WHERE supplier_id IS NULL
  AND COALESCE(TRIM(vendor_name), '') <> ''
GROUP BY org_id, vendor_name
UNION ALL
SELECT
  org_id,
  'customer'          AS kind,
  customer_name       AS raw_text,
  COUNT(*)::int       AS doc_count,
  MAX(sale_date)      AS last_seen
FROM sales
WHERE customer_id IS NULL
  AND COALESCE(TRIM(customer_name), '') <> ''
GROUP BY org_id, customer_name;
