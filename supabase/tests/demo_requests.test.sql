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

SELECT plan(6);

SET LOCAL ROLE anon;

SELECT lives_ok(
  $$ INSERT INTO demo_requests (name, company, phone, manufactures, email)
     VALUES ('Jane Wanjiku', 'Nairobi Plastics', '+254 745-435 732', 'caps and containers', '  Jane@Example.COM ') $$,
  'an anonymous visitor can request a demo'
);

RESET ROLE;

SELECT is(
  (SELECT ARRAY[phone, email] FROM demo_requests WHERE name = 'Jane Wanjiku'),
  ARRAY['+254745435732', 'jane@example.com'],
  'phone and email are normalized on the way in'
);

SET LOCAL ROLE anon;

SELECT throws_like(
  $$ INSERT INTO demo_requests (name, phone, email)
     VALUES ('Bad Email', '+254700000002', 'not-an-email') $$,
  '%check constraint%',
  'a malformed email is rejected'
);

SELECT throws_like(
  $$ INSERT INTO demo_requests (name, phone) VALUES ('Bad Phone', 'call me maybe') $$,
  '%check constraint%',
  'a phone with no digits is rejected'
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
