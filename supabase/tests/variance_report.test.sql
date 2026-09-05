-- pgTAP: variance reports (migration 69).
--
-- Tests:
--   1. Agreeing with the shown number → error 0%, accuracy 100%.
--   2. Correcting it → error relative to the FLOOR's number.
--   3. An action-machine post with an override lands in the report too.
--   4. Old confirmations without a system number stay out of the report.
--
-- Run: supabase start && supabase test db

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(4);

-- ── Fixture ───────────────────────────────────────────────────────────────────

INSERT INTO organizations (id, name) VALUES (9970, 'Variance Org');
INSERT INTO auth.users (id, email) VALUES
  ('a9700000-0000-0000-0000-000000000001', 'admin-a@variancetest.local');
INSERT INTO accounts (org_id, email, role, user_id) VALUES
  (9970, 'admin-a@variancetest.local', 'admin', 'a9700000-0000-0000-0000-000000000001');

INSERT INTO machines (id, org_id, name, mac) VALUES
  (9971, 9970, 'Moulder V1', 'aa:bb:cc:69:00:01'),
  (9972, 9970, 'Moulder V2', 'aa:bb:cc:69:00:02'),
  (9973, 9970, 'Wrapper V',  'aa:bb:cc:69:00:03');

INSERT INTO products (id, org_id, name, unit_of_measure, kind) VALUES
  (9970, 9970, 'Vari Cap',     'each', 'finished_good'),
  (9971, 9970, 'Vari Box',     'each', 'finished_good'),
  (9972, 9970, 'Vari Wrapper', 'each', 'consumable');

SELECT set_config('request.jwt.claims',
  '{"sub":"a9700000-0000-0000-0000-000000000001","role":"authenticated"}', true);

-- 1. Operator agreed: floor = system = 10,000.
SELECT confirm_machine_output(9970, 9971, 9970, 10000, 0, '2026-09-01', 10000);
-- 2. Operator corrected: system said 10,000, floor counted 9,600.
SELECT confirm_machine_output(9970, 9972, 9971, 9600, 0, '2026-09-01', 10000);

SELECT is(
  (SELECT ARRAY[error_pct, accuracy_pct] FROM variance_report(9970, '2026-09-01', '2026-09-01')
   WHERE machine_id = 9971),
  ARRAY[0, 100]::numeric[],
  'agreeing with the shown number scores error 0, accuracy 100'
);

SELECT is(
  (SELECT ARRAY[diff, error_pct] FROM variance_report(9970, '2026-09-01', '2026-09-01')
   WHERE machine_id = 9972),
  ARRAY[-400, 4.17]::numeric[],
  'a correction scores against the floor''s number: |10000-9600|/9600 = 4.17%'
);

-- 3. Action machine: ledger says 340, floor overrides to 300.
INSERT INTO machine_count_actions (machine_id, org_id, product_id, qty_per_count)
VALUES (9973, 9970, 9972, 1);
INSERT INTO machine_day_production (org_id, machine_id, day, shots, scrap, parts_gross)
VALUES (9970, 9973, '2026-09-01', 340, 0, 340);
SELECT post_count_action(9970, 9973, '2026-09-01', 300);

SELECT is(
  (SELECT ARRAY[system_qty, floor_qty] FROM variance_report(9970, '2026-09-01', '2026-09-01')
   WHERE machine_id = 9973),
  ARRAY[340, 300]::numeric[],
  'action-machine posts carry the system/floor pair into the report'
);

-- 4. A legacy confirmation with no system number stays out.
SELECT confirm_machine_output(9970, 9971, 9971, 500, 0, '2026-09-02');
SELECT is(
  (SELECT COUNT(*) FROM variance_report(9970, '2026-09-02', '2026-09-02')),
  0::bigint,
  'confirmations without a recorded system number are not variance lines'
);

SELECT * FROM finish();
ROLLBACK;
