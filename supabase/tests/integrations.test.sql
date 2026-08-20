-- pgTAP: integrations spine — ingestion, cutover, mapping, stock, void reversal.
--
-- Tests:
--   1. Ingest lands every document.
--   2. Re-ingesting an unchanged document is a no-op (idempotent backfill).
--   3. Pre-cutover document is records_only.
--   4. Pre-cutover document moved no stock.
--   5. Post-cutover document with an unmapped item waits in needs_mapping.
--   6. A voided document never moves stock, whatever its date.
--   7. A partially-mapped document waits rather than half-deducting.
--   8. The unmapped inbox surfaces the item with its full sold quantity.
--   9. RLS: admin A sees zero org B documents.
--  10. Admin A cannot map an external id onto org B's product.
--  11. Admin A can map within their own org.
--  12. Mapping retroactively unblocks the post-cutover document.
--  13. Mapping deducted exactly the invoiced quantity.
--  14. A document with one unmapped line STAYS blocked (no partial posting).
--  15. Reprocessing a stocked document does not double-deduct.
--  16. Voiding an already-stocked document reverses it to a net of zero.
--  17. Demand history counts documents regardless of cutover or mapping.
--
-- Run: supabase start && supabase test db

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(17);

-- ── Fixture (as postgres — RLS bypassed) ──────────────────────────────────────

INSERT INTO organizations (id, name) VALUES
  (9801, 'Integr Org A'),
  (9802, 'Integr Org B');

INSERT INTO auth.users (id, email) VALUES
  ('c1000000-0000-0000-0000-000000000001', 'admin-a@integrtest.local'),
  ('d2000000-0000-0000-0000-000000000002', 'admin-b@integrtest.local');

INSERT INTO accounts (org_id, email, role, user_id) VALUES
  (9801, 'admin-a@integrtest.local', 'admin', 'c1000000-0000-0000-0000-000000000001'),
  (9802, 'admin-b@integrtest.local', 'admin', 'd2000000-0000-0000-0000-000000000002');

INSERT INTO products (id, org_id, name, unit_of_measure, kind) VALUES
  (9801, 9801, 'Urine Container 45ml', 'each', 'finished_good'),
  (9802, 9801, 'Stool Container 45ml', 'each', 'finished_good'),
  (9803, 9802, 'Org B Widget',         'each', 'finished_good');

-- Cutover on 2026-09-01: anything earlier is history, anything later moves stock.
INSERT INTO integration_connections (id, org_id, provider, external_org_id, stock_cutover_date) VALUES
  (9801, 9801, 'zoho_books', '823632753', '2026-09-01'),
  (9802, 9802, 'zoho_books', '999999999', '2026-09-01');

-- Z-1 pre-cutover · Z-2 post-cutover · Z-3 post-cutover but VOID · Z-4 two lines
SELECT ingest_external_document(9801, 9801, 'zoho_books',
  '{"external_id":"Z-1","external_number":"INV001","doc_date":"2026-08-01",
    "external_modified_at":"2026-08-01T10:00:00+03:00","customer_external_id":"C-1",
    "total":75,"balance":0,"external_status":"paid","payload":{}}'::JSONB,
  '[{"line_index":0,"external_item_id":"ZI-1","description":"45ml Urine Container",
     "quantity":10,"unit_price":7.5,"line_total":75}]'::JSONB);

SELECT ingest_external_document(9801, 9801, 'zoho_books',
  '{"external_id":"Z-2","external_number":"INV002","doc_date":"2026-09-05",
    "external_modified_at":"2026-09-05T10:00:00+03:00","customer_external_id":"C-1",
    "total":37.5,"balance":37.5,"external_status":"sent","payload":{}}'::JSONB,
  '[{"line_index":0,"external_item_id":"ZI-1","description":"45ml Urine Container",
     "quantity":5,"unit_price":7.5,"line_total":37.5}]'::JSONB);

SELECT ingest_external_document(9801, 9801, 'zoho_books',
  '{"external_id":"Z-3","external_number":"INV003","doc_date":"2026-09-06",
    "external_modified_at":"2026-09-06T10:00:00+03:00","customer_external_id":"C-1",
    "total":22.5,"balance":0,"external_status":"void","payload":{}}'::JSONB,
  '[{"line_index":0,"external_item_id":"ZI-1","description":"45ml Urine Container",
     "quantity":3,"unit_price":7.5,"line_total":22.5}]'::JSONB);

SELECT ingest_external_document(9801, 9801, 'zoho_books',
  '{"external_id":"Z-4","external_number":"INV004","doc_date":"2026-09-07",
    "external_modified_at":"2026-09-07T10:00:00+03:00","customer_external_id":"C-1",
    "total":30,"balance":30,"external_status":"sent","payload":{}}'::JSONB,
  '[{"line_index":0,"external_item_id":"ZI-1","description":"45ml Urine Container",
     "quantity":2,"unit_price":7.5,"line_total":15},
    {"line_index":1,"external_item_id":"ZI-2","description":"Polypot",
     "quantity":1,"unit_price":15,"line_total":15}]'::JSONB);

-- Org B's own document, for the isolation test.
SELECT ingest_external_document(9802, 9802, 'zoho_books',
  '{"external_id":"ZB-1","external_number":"BINV001","doc_date":"2026-09-05",
    "external_modified_at":"2026-09-05T10:00:00+03:00","customer_external_id":"BC-1",
    "total":10,"balance":10,"external_status":"sent","payload":{}}'::JSONB,
  '[{"line_index":0,"external_item_id":"ZBI-1","description":"Org B thing",
     "quantity":1,"unit_price":10,"line_total":10}]'::JSONB);

-- 1. Everything landed
SELECT is(
  (SELECT COUNT(*) FROM external_documents WHERE org_id = 9801),
  4::bigint,
  'Four documents landed for org A');

-- 2. Re-ingesting Z-1 with the SAME external_modified_at must not duplicate or churn
SELECT ingest_external_document(9801, 9801, 'zoho_books',
  '{"external_id":"Z-1","external_number":"INV001","doc_date":"2026-08-01",
    "external_modified_at":"2026-08-01T10:00:00+03:00","customer_external_id":"C-1",
    "total":75,"balance":0,"external_status":"paid","payload":{}}'::JSONB,
  '[{"line_index":0,"external_item_id":"ZI-1","description":"45ml Urine Container",
     "quantity":10,"unit_price":7.5,"line_total":75}]'::JSONB);

SELECT is(
  (SELECT COUNT(*) FROM external_documents WHERE org_id = 9801),
  4::bigint,
  'Re-ingesting an unchanged document creates no duplicate (backfill is safe to re-run)');

-- 3. Pre-cutover ⇒ history only
SELECT is(
  (SELECT import_state FROM external_documents WHERE org_id = 9801 AND external_id = 'Z-1'),
  'records_only',
  'Pre-cutover document is records_only');

-- 4. ...and moved no stock
SELECT is(
  (SELECT COUNT(*) FROM stock_movements WHERE org_id = 9801 AND source_type = 'external_document'),
  0::bigint,
  'No stock moved while every item is still unmapped');

-- 5. Post-cutover, unmapped ⇒ waiting
SELECT is(
  (SELECT import_state FROM external_documents WHERE org_id = 9801 AND external_id = 'Z-2'),
  'needs_mapping',
  'Post-cutover document with an unmapped item waits in needs_mapping');

-- 6. Void is never stocked, regardless of date
SELECT is(
  (SELECT import_state FROM external_documents WHERE org_id = 9801 AND external_id = 'Z-3'),
  'records_only',
  'Voided document is records_only even though it is post-cutover');

-- 7. Two lines, neither mapped yet
SELECT is(
  (SELECT import_state FROM external_documents WHERE org_id = 9801 AND external_id = 'Z-4'),
  'needs_mapping',
  'Multi-line document with unmapped items waits');

-- 8. The inbox sees the item across every document that used it (10+5+3+2)
SELECT is(
  (SELECT total_quantity FROM external_unmapped_items
    WHERE org_id = 9801 AND external_item_id = 'ZI-1'),
  20::numeric,
  'Unmapped inbox totals the quantity sold across all documents');

-- ── Act as admin A ─────────────────────────────────────────────────────────────

SELECT set_config('request.jwt.claims',
  '{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

-- 9. RLS isolation
SELECT is(
  (SELECT COUNT(*) FROM external_documents WHERE org_id = 9802),
  0::bigint,
  'Admin A sees zero org B documents');

-- 10. Cross-org mapping is refused — a mis-scoped mapping would leak another
--     org's product into our stock ledger.
SELECT throws_ok(
  $$ SELECT map_external_entity(9801, 'zoho_books', 'product', 'ZI-9', 'x', NULL, 9803) $$,
  'P0001', NULL,
  'Admin A cannot map an external id onto org B''s product');

-- 11/12/13. Map, then check it worked retroactively
SELECT lives_ok(
  $$ SELECT map_external_entity(9801, 'zoho_books', 'product', 'ZI-1',
                                '45ml Urine Container', NULL, 9801) $$,
  'Admin A can map ZI-1 to their own product');

SELECT is(
  (SELECT import_state FROM external_documents WHERE org_id = 9801 AND external_id = 'Z-2'),
  'stocked',
  'Mapping retroactively unblocks the post-cutover document');

SELECT is(
  (SELECT COALESCE(SUM(quantity), 0) FROM stock_movements
    WHERE org_id = 9801 AND product_id = 9801 AND source_type = 'external_document'),
  -5::numeric,
  'Exactly the invoiced quantity was deducted — pre-cutover and void documents excluded');

-- 14. The half-mapped document must NOT post: half-deducting looks like success.
SELECT is(
  (SELECT import_state FROM external_documents WHERE org_id = 9801 AND external_id = 'Z-4'),
  'needs_mapping',
  'Document with one still-unmapped line stays blocked (no partial posting)');

-- 15. Idempotent reprocessing
SELECT reprocess_external_document(9801,
  (SELECT id FROM external_documents WHERE org_id = 9801 AND external_id = 'Z-2'));

SELECT is(
  (SELECT COUNT(*) FROM stock_movements
    WHERE org_id = 9801 AND source_type = 'external_document'),
  1::bigint,
  'Reprocessing a stocked document does not deduct twice');

-- 16. Voided AFTER stocking ⇒ reversed, not deleted (the ledger stays append-only)
UPDATE external_documents SET external_status = 'void'
 WHERE org_id = 9801 AND external_id = 'Z-2';

SELECT reprocess_external_document(9801,
  (SELECT id FROM external_documents WHERE org_id = 9801 AND external_id = 'Z-2'));

SELECT is(
  (SELECT COALESCE(SUM(quantity), 0) FROM stock_movements
    WHERE org_id = 9801 AND product_id = 9801),
  0::numeric,
  'Voiding an already-stocked document reverses it to a net of zero');

-- 17. Demand history is independent of cutover and mapping — it is the whole
--     point of importing three years nobody will ever post.
SELECT is(
  (SELECT SUM(quantity_sold) FROM external_demand_monthly
    WHERE org_id = 9801 AND external_item_id = 'ZI-1'),
  20::numeric,
  'Demand history counts every document, mapped or not, cutover or not');

SELECT * FROM finish();
ROLLBACK;
