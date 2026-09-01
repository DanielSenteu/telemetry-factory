-- pgTAP: per-N recipe lines + per-count actions (migration 61).
--
-- Tests:
--   1. A per-500 line consumes fractionally: 1 box per 500 caps × 1000 good = 2 boxes.
--   2. A per-1 line is untouched by the change (grams × qty as before).
--   3. post_count_action (movement kind) deducts qty_per_count × day counts.
--   4. post_count_action is idempotent — second call posts nothing new.
--   5. post_count_action (bom kind) honours per_units in its lines.
--   6. Org B admin cannot post org A's machine action.
--
-- Run: supabase start && supabase test db

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(6);

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
  (9933, 9930, 'Wrapper',  'each', 'consumable');

-- Recipe: 2.7 g HDPE per cap + 1 box per 500 caps.
SELECT set_config('request.jwt.claims',
  '{"sub":"a9300000-0000-0000-0000-000000000001","role":"authenticated"}', true);

SELECT upsert_bom_line(9930, 9930, 9931, 2.7, 'g');
SELECT upsert_bom_line(9930, 9930, 9932, 1, 'each', 500);

-- Confirm a run of 1000 good caps.
SELECT confirm_machine_output(9930, 9931, 9930, 1000, 0, '2026-08-20');

-- ── 1 & 2: consumption honours per_units ─────────────────────────────────────

SELECT is(
  (SELECT SUM(-quantity) FROM stock_movements
   WHERE org_id = 9930 AND product_id = 9932 AND movement_type = 'production_consume'),
  2::numeric,
  '1 box per 500 caps × 1000 good = 2 boxes consumed'
);

SELECT is(
  (SELECT SUM(-quantity) FROM stock_movements
   WHERE org_id = 9930 AND product_id = 9931 AND movement_type = 'production_consume'),
  2700::numeric,
  'per-1 gram line unchanged: 2.7 g × 1000 = 2700 g'
);

-- ── 3 & 4: movement-kind count action, idempotent ────────────────────────────

INSERT INTO machine_count_actions (machine_id, org_id, kind, product_id, qty_per_count)
VALUES (9932, 9930, 'movement', 9933, 1);

-- The wrapper counted 340 units on 2026-08-20 (ledger row seeded directly).
INSERT INTO machine_day_production (org_id, machine_id, day, shots, scrap, parts_gross)
VALUES (9930, 9932, '2026-08-20', 340, 0, 340);

SELECT post_count_action(9930, 9932, '2026-08-20');
SELECT post_count_action(9930, 9932, '2026-08-20');  -- run twice…

SELECT is(
  (SELECT SUM(-quantity) FROM stock_movements
   WHERE org_id = 9930 AND product_id = 9933 AND source_type = 'count_action'),
  340::numeric,
  'movement action: 340 counts × 1 wrapper deducted, exactly once'
);

SELECT is(
  (SELECT COUNT(*) FROM count_action_posts WHERE machine_id = 9932),
  1::bigint,
  'posting twice leaves one post (run twice = run once)'
);

-- ── 5: bom-kind action honours per_units ─────────────────────────────────────

INSERT INTO machine_count_actions (machine_id, org_id, kind, bom_id)
VALUES (9933, 9930,'bom', (SELECT id FROM boms WHERE org_id = 9930 AND product_id = 9930));

INSERT INTO machine_day_production (org_id, machine_id, day, shots, scrap, parts_gross)
VALUES (9930, 9933, '2026-08-21', 1000, 0, 1000);

SELECT post_count_action(9930, 9933, '2026-08-21');

SELECT is(
  (SELECT SUM(-quantity) FROM stock_movements
   WHERE org_id = 9930 AND product_id = 9932 AND source_type = 'count_action'),
  2::numeric,
  'bom action: per-500 box line consumed fractionally over 1000 counts'
);

-- ── 6: org isolation (rule 16) ───────────────────────────────────────────────

SELECT set_config('request.jwt.claims',
  '{"sub":"b9310000-0000-0000-0000-000000000002","role":"authenticated"}', true);

SELECT throws_ok(
  $$ SELECT post_count_action(9930, 9932, '2026-08-22') $$,
  'Only org admins can post count actions',
  'org B admin cannot post org A machine actions'
);

SELECT * FROM finish();
ROLLBACK;
