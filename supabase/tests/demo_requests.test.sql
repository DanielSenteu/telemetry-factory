-- pgTAP: demo_requests — the public demo-booking form (migration 66).
--
-- Tests:
--   1. An anonymous visitor can submit a request.
--   2. An anonymous visitor cannot read requests back (leads stay private).
--   3. Junk-length input is rejected by the CHECK bounds.
--
-- Run: supabase start && supabase test db

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(3);

SET LOCAL ROLE anon;

SELECT lives_ok(
  $$ INSERT INTO demo_requests (name, company, phone, manufactures)
     VALUES ('Jane Wanjiku', 'Nairobi Plastics', '+254700000000', 'caps and containers') $$,
  'an anonymous visitor can request a demo'
);

SELECT throws_like(
  $$ SELECT * FROM demo_requests $$,
  '%permission denied%',
  'anonymous visitors cannot read the leads back'
);

SELECT throws_like(
  $$ INSERT INTO demo_requests (name, phone) VALUES (repeat('x', 500), '+254700000000') $$,
  '%check constraint%',
  'over-length junk is rejected at the database'
);

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
