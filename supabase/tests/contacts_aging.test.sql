-- pgTAP: AP/AR aging buckets, payment-terms shift, partial payments,
-- Unassigned rows, and GL control-account reconciliation.
--
-- This is the repo's first DATABASE test suite. Vitest covers the JS; nothing
-- covered the SQL itself — and migrations go straight to prod (no staging), so
-- pgTAP is the safety net. Everything runs inside one transaction and rolls
-- back: the local database is left untouched.
--
-- How to run (needs Docker Desktop running):
--   supabase start        # first time: boots the local stack, applies all migrations
--   supabase test db      # runs every supabase/tests/*.sql with pg_prove
--
-- NOTE ON DATES: now() is frozen for the whole transaction, so "EAT today"
-- (now() AT TIME ZONE 'Africa/Nairobi')::date is one constant value everywhere
-- below — seeded ages are exact even if the suite runs across midnight.
--
-- NOTE ON FIXTURES: documents are created through the REAL RPCs
-- (confirm_invoice / record_sale / record_payment) so the GL entries exist and
-- the reconciliation assertions are meaningful. Contact ids are stamped with a
-- direct UPDATE because this suite ships alongside migration 0039 (schema),
-- before 0040 teaches the RPCs to stamp ids themselves.

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(20);

-- ── Fixture ───────────────────────────────────────────

INSERT INTO organizations (id, name) VALUES (9901, 'Aging Test Org');
DO $$ BEGIN PERFORM seed_default_gl_accounts(9901); END $$;

INSERT INTO contacts (id, org_id, name, kind, payment_terms_days) VALUES
  (9911, 9901, 'Acme Supplies',       'supplier', 0),
  (9912, 9901, 'Net14 Supplies',      'supplier', 14),
  (9913, 9901, 'PartialPay Supplies', 'supplier', 0),
  (9921, 9901, 'Credit Customer',     'customer', 0),
  (9922, 9901, 'Partial Customer',    'customer', 0);

DO $$
DECLARE
  v_today DATE := (now() AT TIME ZONE 'Africa/Nairobi')::date;
  v_id    INTEGER;
BEGIN
  -- Acme (terms 0): one invoice at each bucket boundary. Distinct power-of-ten
  -- amounts so a mis-bucketed doc changes two buckets detectably.
  --   age 30 -> 0-30 | 31,60 -> 31-60 | 61,90 -> 61-90 | 91 -> 90+
  v_id := confirm_invoice(9901, 'Acme Supplies', 'AC-30', v_today - 30, 100,  NULL, NULL, '[]'::jsonb, 0);
  UPDATE invoices SET supplier_id = 9911 WHERE id = v_id;
  v_id := confirm_invoice(9901, 'Acme Supplies', 'AC-31', v_today - 31, 200,  NULL, NULL, '[]'::jsonb, 0);
  UPDATE invoices SET supplier_id = 9911 WHERE id = v_id;
  v_id := confirm_invoice(9901, 'Acme Supplies', 'AC-60', v_today - 60, 400,  NULL, NULL, '[]'::jsonb, 0);
  UPDATE invoices SET supplier_id = 9911 WHERE id = v_id;
  v_id := confirm_invoice(9901, 'Acme Supplies', 'AC-61', v_today - 61, 800,  NULL, NULL, '[]'::jsonb, 0);
  UPDATE invoices SET supplier_id = 9911 WHERE id = v_id;
  v_id := confirm_invoice(9901, 'Acme Supplies', 'AC-90', v_today - 90, 1600, NULL, NULL, '[]'::jsonb, 0);
  UPDATE invoices SET supplier_id = 9911 WHERE id = v_id;
  v_id := confirm_invoice(9901, 'Acme Supplies', 'AC-91', v_today - 91, 3200, NULL, NULL, '[]'::jsonb, 0);
  UPDATE invoices SET supplier_id = 9911 WHERE id = v_id;

  -- Net14 (terms 14): dated 44/45 days ago -> EFFECTIVE ages 30/31. Proves the
  -- aging clock starts at the due date, not the document date.
  v_id := confirm_invoice(9901, 'Net14 Supplies', 'N14-A', v_today - 44, 10, NULL, NULL, '[]'::jsonb, 0);
  UPDATE invoices SET supplier_id = 9912 WHERE id = v_id;
  v_id := confirm_invoice(9901, 'Net14 Supplies', 'N14-B', v_today - 45, 20, NULL, NULL, '[]'::jsonb, 0);
  UPDATE invoices SET supplier_id = 9912 WHERE id = v_id;

  -- Partial payment: 100k invoice, 60k paid -> 40k remains in its bucket.
  v_id := confirm_invoice(9901, 'PartialPay Supplies', 'PP-1', v_today - 10, 100000, NULL, NULL, '[]'::jsonb, 0);
  UPDATE invoices SET supplier_id = 9913 WHERE id = v_id;
  PERFORM record_payment(9901, 'supplier', v_id, v_today, 60000, '1000', 'partial');

  -- Unassigned: no contact link at all.
  v_id := confirm_invoice(9901, 'Mystery Vendor', 'MYS-1', v_today - 100, 500, NULL, NULL, '[]'::jsonb, 0);

  -- ── AR side ──
  -- Credit sales (booked to 1100) age; cash sales never appear.
  v_id := record_sale(9901, v_today - 30, 'Credit Customer', '1100',
                      '[{"quantity":1,"unit_price":50}]'::jsonb);
  UPDATE sales SET customer_id = 9921 WHERE id = v_id;
  v_id := record_sale(9901, v_today - 91, 'Credit Customer', '1100',
                      '[{"quantity":1,"unit_price":70}]'::jsonb);
  UPDATE sales SET customer_id = 9921 WHERE id = v_id;

  -- Partially-paid credit sale: 1000 - 400 = 600 outstanding.
  v_id := record_sale(9901, v_today - 5, 'Partial Customer', '1100',
                      '[{"quantity":1,"unit_price":1000}]'::jsonb);
  UPDATE sales SET customer_id = 9922 WHERE id = v_id;
  PERFORM record_payment(9901, 'customer', v_id, v_today, 400, '1000', 'partial');

  -- Cash sale: settled instantly, must NOT show up in AR aging.
  v_id := record_sale(9901, v_today - 200, 'Walk-in Joe', '1000',
                      '[{"quantity":1,"unit_price":999}]'::jsonb);
END $$;

-- ── AP aging: bucket boundaries (terms 0) ─────────────

SELECT is((SELECT bucket_0_30    FROM ap_aging WHERE org_id = 9901 AND contact_id = 9911), 100::numeric,
  'AP: age 30 lands in 0-30');
SELECT is((SELECT bucket_31_60   FROM ap_aging WHERE org_id = 9901 AND contact_id = 9911), 600::numeric,
  'AP: ages 31 and 60 land in 31-60');
SELECT is((SELECT bucket_61_90   FROM ap_aging WHERE org_id = 9901 AND contact_id = 9911), 2400::numeric,
  'AP: ages 61 and 90 land in 61-90');
SELECT is((SELECT bucket_90_plus FROM ap_aging WHERE org_id = 9901 AND contact_id = 9911), 3200::numeric,
  'AP: age 91 lands in 90+');
SELECT is((SELECT total_outstanding FROM ap_aging WHERE org_id = 9901 AND contact_id = 9911), 6300::numeric,
  'AP: buckets sum to total_outstanding');
SELECT is((SELECT open_docs FROM ap_aging WHERE org_id = 9901 AND contact_id = 9911), 6,
  'AP: open_docs counts every unpaid doc');

-- ── Payment terms shift the clock ─────────────────────

SELECT is((SELECT bucket_0_30  FROM ap_aging WHERE org_id = 9901 AND contact_id = 9912), 10::numeric,
  'AP: Net-14 doc dated 44 days ago is only 30 days OVERDUE (0-30)');
SELECT is((SELECT bucket_31_60 FROM ap_aging WHERE org_id = 9901 AND contact_id = 9912), 20::numeric,
  'AP: Net-14 doc dated 45 days ago is 31 days overdue (31-60)');

-- ── Partial payment: remainder stays in its bucket ────

SELECT is((SELECT total_outstanding FROM ap_aging WHERE org_id = 9901 AND contact_id = 9913), 40000::numeric,
  'AP: 100k - 60k paid leaves 40k outstanding');
SELECT is((SELECT bucket_0_30 FROM ap_aging WHERE org_id = 9901 AND contact_id = 9913), 40000::numeric,
  'AP: the 40k remainder sits in the original bucket');

-- ── Unassigned (no contact link) ──────────────────────

SELECT is((SELECT contact_name FROM ap_aging WHERE org_id = 9901 AND contact_id IS NULL), 'Unassigned',
  'AP: unlinked docs group under Unassigned');
SELECT is((SELECT bucket_90_plus FROM ap_aging WHERE org_id = 9901 AND contact_id IS NULL), 500::numeric,
  'AP: Unassigned docs still age correctly');

-- ── AP reconciliation: aging total == AP control (2000) ─

SELECT is(
  (SELECT SUM(total_outstanding) FROM ap_aging WHERE org_id = 9901),
  (SELECT SUM(jl.credit - jl.debit)
     FROM journal_lines jl
     JOIN gl_accounts a ON a.id = jl.account_id
    WHERE jl.org_id = 9901 AND a.code = '2000'),
  'AP: SUM(aging outstanding) reconciles to the AP control account');

-- ── AR aging ──────────────────────────────────────────

SELECT is((SELECT bucket_0_30 FROM ar_aging WHERE org_id = 9901 AND contact_id = 9921), 50::numeric,
  'AR: age 30 credit sale lands in 0-30');
SELECT is((SELECT bucket_90_plus FROM ar_aging WHERE org_id = 9901 AND contact_id = 9921), 70::numeric,
  'AR: age 91 credit sale lands in 90+');
SELECT is((SELECT total_outstanding FROM ar_aging WHERE org_id = 9901 AND contact_id = 9922), 600::numeric,
  'AR: partially-paid credit sale shows the remainder');
SELECT is((SELECT COUNT(*) FROM ar_aging WHERE org_id = 9901 AND contact_id IS NULL), 0::bigint,
  'AR: cash sales never appear in receivables aging');

-- ── AR reconciliation: aging total == AR control (1100) ─

SELECT is(
  (SELECT SUM(total_outstanding) FROM ar_aging WHERE org_id = 9901),
  (SELECT SUM(jl.debit - jl.credit)
     FROM journal_lines jl
     JOIN gl_accounts a ON a.id = jl.account_id
    WHERE jl.org_id = 9901 AND a.code = '1100'),
  'AR: SUM(aging outstanding) reconciles to the AR control account');

-- ── contact_suggestions: the backfill queue ───────────

SELECT is((SELECT doc_count FROM contact_suggestions
            WHERE org_id = 9901 AND kind = 'supplier' AND raw_text = 'Mystery Vendor'), 1,
  'Suggestions: unlinked vendor text is offered');
SELECT is((SELECT COUNT(*) FROM contact_suggestions
            WHERE org_id = 9901 AND raw_text = 'Acme Supplies'), 0::bigint,
  'Suggestions: linked docs are not re-offered');

SELECT * FROM finish();
ROLLBACK;
