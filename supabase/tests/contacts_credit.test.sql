-- pgTAP: credit limits + contact stamping + alias learning + backfill
-- (the migration 0040 RPC deltas).
--
-- The behaviour under test, in plain terms:
--   * A credit sale (booked to AR '1100') that would push a linked customer
--     past their credit_limit_ksh RAISES — and the whole sale rolls back.
--   * Exactly AT the limit still passes (> not >=).
--   * Cash sales, customers with no limit, and sales with no contact id are
--     NEVER blocked (default-safe).
--   * confirm_invoice/record_sale stamp the contact id and learn the raw-text
--     alias; an id from the WRONG org is silently ignored.
--   * link_contact_alias backfills historic unlinked documents and reports
--     how many it touched; a worker calling it fails.
--
-- How to run (needs Docker Desktop running):
--   supabase start
--   supabase test db

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(18);

-- ── Fixture ───────────────────────────────────────────

INSERT INTO organizations (id, name) VALUES
  (9701, 'Credit Test Org'),
  (9702, 'Other Org');
DO $$ BEGIN PERFORM seed_default_gl_accounts(9701); END $$;

INSERT INTO contacts (id, org_id, name, kind, credit_limit_ksh) VALUES
  (9711, 9701, 'Limited Customer',   'customer', 100000),
  (9712, 9701, 'Unlimited Customer', 'customer', NULL),
  (9713, 9701, 'Backfill Supplier',  'supplier', NULL),
  (9714, 9701, 'Backfill Customer',  'customer', NULL),
  (9715, 9701, 'Stamped Supplier',   'supplier', NULL),
  (9721, 9702, 'Wrong Org Supplier', 'supplier', NULL);

-- Existing exposure: Limited Customer already owes 60k on account.
SELECT lives_ok(
  $$ SELECT record_sale(9701, current_date, 'Limited Customer', '1100',
       '[{"quantity":1,"unit_price":60000}]'::jsonb, 9711) $$,
  'Seed: 60k credit sale within the 100k limit posts fine');

-- ── The credit gate ───────────────────────────────────

SELECT throws_ok(
  $$ SELECT record_sale(9701, current_date, 'Limited Customer', '1100',
       '[{"quantity":1,"unit_price":40000.01}]'::jsonb, 9711) $$,
  'P0001', NULL,
  'Credit: 60k outstanding + 40,000.01 breaches the 100k limit and raises');

-- The rejected sale must leave NO trace (whole RPC rolled back).
SELECT is(
  (SELECT COUNT(*) FROM sales WHERE org_id = 9701 AND customer_id = 9711), 1::bigint,
  'Credit: the rejected sale rolled back entirely — only the seed sale exists');

SELECT lives_ok(
  $$ SELECT record_sale(9701, current_date, 'Limited Customer', '1100',
       '[{"quantity":1,"unit_price":40000}]'::jsonb, 9711) $$,
  'Credit: exactly AT the limit (60k + 40k = 100k) passes');

SELECT lives_ok(
  $$ SELECT record_sale(9701, current_date, 'Limited Customer', '1000',
       '[{"quantity":1,"unit_price":999999}]'::jsonb, 9711) $$,
  'Credit: CASH sales never check the limit (money in hand = no risk)');

SELECT lives_ok(
  $$ SELECT record_sale(9701, current_date, 'Unlimited Customer', '1100',
       '[{"quantity":1,"unit_price":500000}]'::jsonb, 9712) $$,
  'Credit: NULL limit = no limit set = never blocks');

SELECT lives_ok(
  $$ SELECT record_sale(9701, current_date, 'Anonymous Walk-in', '1100',
       '[{"quantity":1,"unit_price":500000}]'::jsonb) $$,
  'Credit: no contact id = zero new behaviour (default-safe)');

-- ── Stamping + alias learning ─────────────────────────

SELECT is(
  (SELECT customer_id FROM sales
    WHERE org_id = 9701 AND customer_name = 'Unlimited Customer' LIMIT 1),
  9712,
  'record_sale stamps customer_id on the sale row');

SELECT is(
  (SELECT contact_id FROM contact_aliases WHERE org_id = 9701 AND raw_text = 'Limited Customer'),
  9711,
  'record_sale learns the customer-text alias');

SELECT lives_ok(
  $$ SELECT confirm_invoice(9701, 'STAMPED SUPP LTD', 'ST-1', current_date, 1000,
       NULL, NULL, '[]'::jsonb, 0, 9715) $$,
  'confirm_invoice accepts p_supplier_id');

SELECT is(
  (SELECT supplier_id FROM invoices WHERE org_id = 9701 AND invoice_number = 'ST-1'),
  9715,
  'confirm_invoice stamps supplier_id on the invoice');

SELECT is(
  (SELECT contact_id FROM contact_aliases WHERE org_id = 9701 AND raw_text = 'STAMPED SUPP LTD'),
  9715,
  'confirm_invoice learns the vendor-text alias');

-- Wrong-org contact id: must not block the posting, must not link.
SELECT lives_ok(
  $$ SELECT confirm_invoice(9701, 'Cross Org Vendor', 'XO-1', current_date, 500,
       NULL, NULL, '[]'::jsonb, 0, 9721) $$,
  'A contact id from another org never blocks an invoice');
SELECT is(
  (SELECT supplier_id FROM invoices WHERE org_id = 9701 AND invoice_number = 'XO-1'),
  NULL,
  'A contact id from another org is silently ignored (stays NULL)');

-- ── link_contact_alias: the backfill assist ───────────

-- Two historic unlinked invoices with identical vendor text...
DO $$ BEGIN
  PERFORM confirm_invoice(9701, 'OLD VENDOR NAME', 'OV-1', current_date - 10, 100, NULL, NULL, '[]'::jsonb, 0);
  PERFORM confirm_invoice(9701, 'OLD VENDOR NAME', 'OV-2', current_date - 5,  200, NULL, NULL, '[]'::jsonb, 0);
END $$;

SELECT is(
  link_contact_alias(9701, 'supplier', 'OLD VENDOR NAME', 9713),
  2,
  'link_contact_alias backfills both historic invoices and returns the count');

SELECT is(
  (SELECT COUNT(*) FROM invoices
    WHERE org_id = 9701 AND vendor_name = 'OLD VENDOR NAME' AND supplier_id = 9713),
  2::bigint,
  'Backfilled invoices now carry the supplier link');

-- Sales mirror: the anonymous credit sale above gets claimed by name.
SELECT is(
  link_contact_alias(9701, 'customer', 'Anonymous Walk-in', 9714),
  1,
  'link_contact_alias backfills unlinked sales too');

-- ── A worker cannot use the backfill RPC ──────────────
-- Runs as invoker: the worker's contact lookup returns zero rows under RLS,
-- so the call fails before touching anything.

INSERT INTO auth.users (id, email) VALUES
  ('9d000000-0000-0000-0000-0000000000dd', 'worker-d@credittest.local');

SELECT set_config('request.jwt.claims',
  '{"sub":"9d000000-0000-0000-0000-0000000000dd","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$ SELECT link_contact_alias(9701, 'supplier', 'OLD VENDOR NAME', 9713) $$,
  'P0001', 'Contact not found for this organization',
  'Worker cannot link aliases (RLS hides all contacts)');

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
