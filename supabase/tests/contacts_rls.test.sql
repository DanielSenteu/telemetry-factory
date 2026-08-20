-- pgTAP: RLS isolation for contacts + contact_aliases.
--
-- The security posture under test:
--   * contacts are ADMIN-ONLY (workers must never see credit limits/terms);
--   * strictly org-scoped — an admin of org A gets zero rows from org B;
--   * alias uniqueness is PER-ORG (same raw text can map differently per org);
--   * re-linking an alias (upsert) moves it to the new contact.
--
-- How to run (needs Docker Desktop running):
--   supabase start
--   supabase test db
--
-- Identity is simulated the way PostgREST does it: SET LOCAL ROLE authenticated
-- + a request.jwt.claims GUC carrying the user's sub. auth.uid() reads that
-- claim; is_org_admin() (SECURITY DEFINER) then checks the accounts table.

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(12);

-- ── Fixture (as postgres, RLS bypassed) ───────────────

INSERT INTO organizations (id, name) VALUES
  (9801, 'RLS Org A'),
  (9802, 'RLS Org B');

INSERT INTO auth.users (id, email) VALUES
  ('9a000000-0000-0000-0000-0000000000aa', 'admin-a@rlstest.local'),
  ('9b000000-0000-0000-0000-0000000000bb', 'admin-b@rlstest.local'),
  ('9c000000-0000-0000-0000-0000000000cc', 'worker-c@rlstest.local');

INSERT INTO accounts (org_id, email, role, user_id) VALUES
  (9801, 'admin-a@rlstest.local', 'admin', '9a000000-0000-0000-0000-0000000000aa'),
  (9802, 'admin-b@rlstest.local', 'admin', '9b000000-0000-0000-0000-0000000000bb');
-- worker-c deliberately has NO accounts row (mirrors real mobile workers).

INSERT INTO contacts (id, org_id, name, kind, credit_limit_ksh) VALUES
  (9811, 9801, 'Shared Name Ltd', 'supplier', 50000),
  (9812, 9801, 'Second A Contact', 'supplier', NULL),
  (9821, 9802, 'B Only Ltd',      'supplier', 75000);

-- ── Act as admin A ────────────────────────────────────
SELECT set_config('request.jwt.claims',
  '{"sub":"9a000000-0000-0000-0000-0000000000aa","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT is((SELECT COUNT(*) FROM contacts), 2::bigint,
  'Admin A sees exactly org A contacts');
SELECT is((SELECT COUNT(*) FROM contacts WHERE org_id = 9802), 0::bigint,
  'Admin A sees zero org B contacts');

SELECT throws_ok(
  $$ INSERT INTO contacts (org_id, name, kind) VALUES (9802, 'Sneaky', 'supplier') $$,
  '42501', NULL,
  'Admin A cannot insert a contact into org B');

-- (a data-modifying CTE can't sit in a subquery, so count via GET DIAGNOSTICS)
DO $$
DECLARE n INTEGER;
BEGIN
  UPDATE contacts SET phone = 'hacked' WHERE org_id = 9802;
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM set_config('test.cross_org_update_count', n::text, true);
END $$;
SELECT is(current_setting('test.cross_org_update_count')::int, 0,
  'Admin A''s cross-org UPDATE touches zero rows');

SELECT lives_ok(
  $$ INSERT INTO contact_aliases (org_id, contact_id, raw_text)
     VALUES (9801, 9811, 'SHARED NAME') $$,
  'Admin A can create an alias in org A');

-- Re-link: the upsert used by confirm_invoice/link_contact_alias moves the
-- alias to a new contact instead of erroring on the unique key.
SELECT lives_ok(
  $$ INSERT INTO contact_aliases (org_id, contact_id, raw_text)
     VALUES (9801, 9812, 'SHARED NAME')
     ON CONFLICT (org_id, raw_text) DO UPDATE SET contact_id = EXCLUDED.contact_id $$,
  'Re-linking the same raw text upserts instead of erroring');
SELECT is(
  (SELECT contact_id FROM contact_aliases WHERE org_id = 9801 AND raw_text = 'SHARED NAME'),
  9812,
  'Re-link points the alias at the new contact');

-- ── Act as admin B ────────────────────────────────────
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub":"9b000000-0000-0000-0000-0000000000bb","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT is((SELECT COUNT(*) FROM contact_aliases), 0::bigint,
  'Admin B sees zero org A aliases');

-- Same raw text, different org, different contact — per-org uniqueness.
SELECT lives_ok(
  $$ INSERT INTO contact_aliases (org_id, contact_id, raw_text)
     VALUES (9802, 9821, 'SHARED NAME') $$,
  'Same raw text maps independently in another org');

-- ── Act as worker C (authenticated, but no accounts row) ─
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub":"9c000000-0000-0000-0000-0000000000cc","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT is((SELECT COUNT(*) FROM contacts), 0::bigint,
  'Worker sees zero contact rows (credit limits stay private)');
SELECT is((SELECT COUNT(*) FROM contact_aliases), 0::bigint,
  'Worker sees zero alias rows');
SELECT throws_ok(
  $$ INSERT INTO contacts (org_id, name, kind) VALUES (9801, 'Worker Sneak', 'customer') $$,
  '42501', NULL,
  'Worker cannot create contacts');

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
