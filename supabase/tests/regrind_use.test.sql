-- pgTAP: regrind USE — the path that was never tested and therefore never worked.
--
-- Tests:
--   1. Runner accumulation on confirm (the half that always worked).
--   2. post_regrind_use runs at all (the constraint bug, migration 55).
--   3. The pool balance falls by the grams used.
--   4. The grams land back in raw material stock as 'regrind_return'.
--   5. The material's total on-hand reflects the return.
--   6. Using more than makes sense is still allowed (physical reality wins),
--      but zero/negative grams are refused.
--   7. Workers cannot log regrind use.
--
-- Run: supabase start && supabase test db

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(7);

INSERT INTO organizations (id, name) VALUES (9501, 'Regrind Org');
INSERT INTO auth.users (id, email) VALUES
  ('f5000000-0000-0000-0000-000000000001', 'admin@rgtest.local'),
  ('f5000000-0000-0000-0000-000000000002', 'worker@rgtest.local');
INSERT INTO accounts (org_id, email, role, user_id) VALUES
  (9501, 'admin@rgtest.local',  'admin',  'f5000000-0000-0000-0000-000000000001'),
  (9501, 'worker@rgtest.local', 'worker', 'f5000000-0000-0000-0000-000000000002');
INSERT INTO products (id, org_id, name, unit_of_measure, kind) VALUES
  (9501, 9501, 'Container', 'each', 'finished_good'),
  (9502, 9501, 'Polypropylene', 'g', 'raw_material');
INSERT INTO stock_movements (org_id, product_id, quantity, movement_type, unit_cost, source_type)
VALUES (9501, 9502, 10000, 'purchase', 0.50, 'fixture');
INSERT INTO machines (id, org_id, name, mac) VALUES (9501, 9501, 'IMM-T', 'aa:bb:cc:95:01:01');
INSERT INTO boms (id, org_id, product_id, version, active, cavities, runner_weight_g, runner_material_product_id)
VALUES (9501, 9501, 9501, 1, true, 4, 2.0, 9502);
INSERT INTO bom_lines (bom_id, org_id, component_product_id, qty_per_unit, uom)
VALUES (9501, 9501, 9502, 4.0, 'g');

SELECT set_config('request.jwt.claims',
  '{"sub":"f5000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

-- 1. Accumulate: 1,000 parts / 4 cavities = 250 shots x 2 g = 500 g in
SELECT confirm_machine_output(9501, 9501, 9501, 1000, 0, CURRENT_DATE);
SELECT is(
  (SELECT balance_g FROM regrind_balances(9501) WHERE material_product_id = 9502),
  500::numeric,
  'Confirming output accumulates runner weight into the pool');

-- 2. THE BUG: this call failed on the movement_type constraint before 55
SELECT lives_ok(
  $$ SELECT post_regrind_use(9501, 9502, 300, 'ground and loaded') $$,
  'Logging regrind use runs (regrind_return now an allowed movement type)');

-- 3. Pool fell
SELECT is(
  (SELECT balance_g FROM regrind_balances(9501) WHERE material_product_id = 9502),
  200::numeric,
  'Pool balance falls by the grams used');

-- 4. Stock gained a regrind_return
SELECT is(
  (SELECT COALESCE(SUM(quantity), 0) FROM stock_movements
    WHERE org_id = 9501 AND product_id = 9502 AND movement_type = 'regrind_return'),
  300::numeric,
  'The grams land back in raw material stock as regrind_return');

-- 5. On-hand math: 10,000 bought − 4,000 consumed + 300 returned = 6,300
SELECT is(
  (SELECT on_hand FROM product_stock WHERE product_id = 9502),
  6300::numeric,
  'Material on-hand reflects purchase − production + regrind return');

-- 6. Zero grams refused
SELECT throws_ok(
  $$ SELECT post_regrind_use(9501, 9502, 0, NULL) $$,
  'P0001', 'Quantity must be positive',
  'Zero grams is refused');

-- 7. Workers cannot log regrind use
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub":"f5000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$ SELECT post_regrind_use(9501, 9502, 10, NULL) $$,
  'P0001', 'Only org admins can post regrind use',
  'Workers cannot log regrind use');

SELECT * FROM finish();
ROLLBACK;
