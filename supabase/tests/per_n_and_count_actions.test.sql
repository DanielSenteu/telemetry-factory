-- pgTAP: per-N recipe lines, stages, and per-count actions (migrations 61 & 64).
--
-- Tests:
--   1. A per-500 moulding line consumes fractionally at confirm: 1000 good → 2 boxes.
--   2. A per-1 moulding line is untouched by the changes (grams × qty as before).
--   3. Fixed fallback action deducts qty_per_count × day counts, exactly once.
--   4. Posting twice leaves one receipt (run twice = run once).
--   5. Packaging-stage lines are NOT consumed at the moulder's confirm.
--   6. "What was wrapped today?" post consumes the product's packaging lines.
--   7. Org B admin cannot post org A's machine.
--
-- Run: supabase start && supabase test db

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(7);

-- ── Fixture ───────────────────────────────────────────────────────────────────

INSERT INTO organizations (id, name) VALUES (9930, 'PerN Org A'), (9931, 'PerN Org B');

INSERT INTO auth.users (id, email) VALUES
  ('a9300000-0000-0000-0000-000000000001', 'admin-a@perntest.local'),
  ('b9310000-0000-0000-0000-000000000002', 'admin-b@perntest.local');

INSERT INTO accounts (org_id, email, role, user_id) VALUES
  (9930, 'admin-a@perntest.local', 'admin', 'a9300000-0000-0000-0000-000000000001'),
  (9931, 'admin-b@perntest.local', 'admin', 'b9310000-0000-0000-0000-000000000002');

INSERT INTO machines (id, org_id, name, mac) VALUES
  (9931, 9930, 'Moulder A', 'aa:bb:cc:61:00:01'),
  (9932, 9930, 'Wrapper A', 'aa:bb:cc:61:00:02'),
  (9933, 9930, 'Wrapper A2', 'aa:bb:cc:61:00:03');

INSERT INTO products (id, org_id, name, unit_of_measure, kind) VALUES
  (9930, 9930, 'Cap',      'each', 'finished_good'),
  (9931, 9930, 'HDPE',     'g',    'raw_material'),
  (9932, 9930, 'Box',      'each', 'consumable'),
  (9933, 9930, 'Wrapper',  'each', 'consumable'),
  (9934, 9930, 'Film',     'm',    'consumable');

-- Recipe for caps: 2.7 g HDPE per cap + 1 box per 500 (both moulding),
-- and 0.2 m film per cap at PACKAGING.
SELECT set_config('request.jwt.claims',
  '{"sub":"a9300000-0000-0000-0000-000000000001","role":"authenticated"}', true);

SELECT upsert_bom_line(9930, 9930, 9931, 2.7, 'g');
SELECT upsert_bom_line(9930, 9930, 9932, 1, 'each', 500);
SELECT upsert_bom_line(9930, 9930, 9934, 0.2, 'm', 1, 'packaging');

-- Confirm a moulding run of 1000 good caps.
SELECT confirm_machine_output(9930, 9931, 9930, 1000, 0, '2026-08-20');

-- ── 1 & 2: moulding consumption honours per_units ────────────────────────────

SELECT is(
  (SELECT SUM(-quantity) FROM stock_movements
   WHERE org_id = 9930 AND product_id = 9932 AND movement_type = 'production_consume'),
  2::numeric,
  '1 box per 500 caps × 1000 good = 2 boxes consumed at confirm'
);

SELECT is(
  (SELECT SUM(-quantity) FROM stock_movements
   WHERE org_id = 9930 AND product_id = 9931 AND movement_type = 'production_consume'),
  2700::numeric,
  'per-1 gram line unchanged: 2.7 g × 1000 = 2700 g'
);

-- ── 3 & 4: fixed fallback action, idempotent ─────────────────────────────────

INSERT INTO machine_count_actions (machine_id, org_id, product_id, qty_per_count)
VALUES (9932, 9930, 9933, 1);

INSERT INTO machine_day_production (org_id, machine_id, day, shots, scrap, parts_gross)
VALUES (9930, 9932, '2026-08-20', 340, 0, 340);

SELECT post_count_action(9930, 9932, '2026-08-20');
SELECT post_count_action(9930, 9932, '2026-08-20');  -- run twice…

SELECT is(
  (SELECT SUM(-quantity) FROM stock_movements
   WHERE org_id = 9930 AND product_id = 9933 AND source_type = 'count_action'),
  340::numeric,
  'fixed action: 340 counts × 1 wrapper deducted, exactly once'
);

SELECT is(
  (SELECT COUNT(*) FROM count_action_posts WHERE machine_id = 9932),
  1::bigint,
  'posting twice leaves one receipt (run twice = run once)'
);

-- ── 5: packaging lines never bill at the moulder ─────────────────────────────

SELECT is(
  (SELECT COALESCE(SUM(-quantity), 0) FROM stock_movements
   WHERE org_id = 9930 AND product_id = 9934 AND source_type = 'production_run'),
  0::numeric,
  'the packaging film line is not consumed at moulding confirm'
);

-- ── 6: "what was wrapped today?" consumes packaging lines ────────────────────

INSERT INTO machine_day_production (org_id, machine_id, day, shots, scrap, parts_gross)
VALUES (9930, 9933, '2026-08-21', 1000, 0, 1000);

SELECT post_count_action(9930, 9933, '2026-08-21', NULL, 9930);

SELECT is(
  (SELECT SUM(-quantity) FROM stock_movements
   WHERE org_id = 9930 AND product_id = 9934 AND source_type = 'count_action'),
  200::numeric,
  'product post: 0.2 m film × 1000 wrapped = 200 m consumed'
);

-- ── 7: org isolation (rule 16) ───────────────────────────────────────────────

SELECT set_config('request.jwt.claims',
  '{"sub":"b9310000-0000-0000-0000-000000000002","role":"authenticated"}', true);

SELECT throws_ok(
  $$ SELECT post_count_action(9930, 9932, '2026-08-22') $$,
  'Only org admins can post count actions',
  'org B admin cannot post org A machine actions'
);

SELECT * FROM finish();
ROLLBACK;
