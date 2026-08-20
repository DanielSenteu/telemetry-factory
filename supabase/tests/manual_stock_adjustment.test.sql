-- pgTAP: post_manual_stock_adjustment — the operator overrides (migration 53).
--
-- This function shipped on 2026-08-13 and had never run successfully: it wrote
-- movement_type 'manual_addition'/'manual_deduction', which the CHECK constraint
-- from migration 14 has always rejected. It also added finished goods from a
-- power outage WITHOUT consuming any raw material, permanently overstating
-- component stock. Both are fixed in 53; these tests are what should have
-- existed to catch them.
--
-- Tests:
--   1. Power-outage override runs at all (the constraint bug).
--   2. It posts production_output, not an invented movement type.
--   3. It CONSUMES raw material via the BOM — the bug that corrupted stock.
--   4. Finished goods are valued at rolled-up component cost, not zero.
--   5. It records a production_runs row so the output appears in reporting.
--   6. Runner plastic is recovered into the regrind pool.
--   7. Waste posts as 'wastage'.
--   8. Waste is valued, so inventory value falls with the quantity.
--   9. Rejects routed to regrind park the plastic weight.
--  10. Zero quantity is refused.
--  11. Non-admins cannot post overrides.
--
-- Run: supabase start && supabase test db

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(11);

-- ── Fixture ───────────────────────────────────────────────────────────────────

INSERT INTO organizations (id, name) VALUES (9601, 'Override Org');

INSERT INTO auth.users (id, email) VALUES
  ('e1000000-0000-0000-0000-000000000001', 'admin@ovtest.local'),
  ('e2000000-0000-0000-0000-000000000002', 'worker@ovtest.local');

INSERT INTO accounts (org_id, email, role, user_id) VALUES
  (9601, 'admin@ovtest.local',  'admin',  'e1000000-0000-0000-0000-000000000001'),
  (9601, 'worker@ovtest.local', 'worker', 'e2000000-0000-0000-0000-000000000002');

INSERT INTO products (id, org_id, name, unit_of_measure, kind) VALUES
  (9601, 9601, 'Urine Container 45ml', 'each', 'finished_good'),
  (9602, 9601, 'Polypropylene',        'g',    'raw_material');

-- Raw material bought in at a known cost so the rollup is checkable:
-- 10,000 g at 0.50/g.
INSERT INTO stock_movements (org_id, product_id, quantity, movement_type, unit_cost, source_type)
VALUES (9601, 9602, 10000, 'purchase', 0.50, 'fixture');

-- Recipe: 4 g per container, 4-cavity mould, 2 g of runner per shot.
INSERT INTO boms (id, org_id, product_id, version, active, cavities, runner_weight_g, runner_material_product_id)
VALUES (9601, 9601, 9601, 1, true, 4, 2.0, 9602);

INSERT INTO bom_lines (bom_id, org_id, component_product_id, qty_per_unit, uom)
VALUES (9601, 9601, 9602, 4.0, 'g');

SELECT set_config('request.jwt.claims',
  '{"sub":"e1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

-- ── Power outage: 100 containers made while the collector was down ────────────

-- 1. It runs. Before migration 53 this raised on the movement_type constraint.
SELECT lives_ok(
  $$ SELECT post_manual_stock_adjustment(9601, 9601, 100, 'power_outage', false, NULL,
                                         'outage 14:00-16:00') $$,
  'Power-outage override runs (movement_type constraint no longer violated)');

-- 2. Correct movement type — so production reports actually include it
SELECT is(
  (SELECT COUNT(*) FROM stock_movements
    WHERE org_id = 9601 AND product_id = 9601 AND movement_type = 'production_output'),
  1::bigint,
  'Untracked production posts as production_output');

-- 3. THE BUG: raw material must fall by 4 g × 100 units = 400 g
SELECT is(
  (SELECT COALESCE(SUM(quantity), 0) FROM stock_movements
    WHERE org_id = 9601 AND product_id = 9602 AND movement_type = 'production_consume'),
  -400::numeric,
  'Power-outage production consumes raw material through the BOM');

-- 4. Finished goods carry the rolled-up cost (4 g × 0.50 = 2.00), not zero
SELECT is(
  (SELECT unit_cost FROM stock_movements
    WHERE org_id = 9601 AND product_id = 9601 AND movement_type = 'production_output'),
  2.00::numeric,
  'Finished goods are valued at rolled-up component cost, not zero');

-- 5. Visible to production reporting, not only to the stock ledger
SELECT is(
  (SELECT COUNT(*) FROM production_runs
    WHERE org_id = 9601 AND product_id = 9601 AND good_qty = 100 AND status = 'confirmed'),
  1::bigint,
  'A confirmed production_runs row records the recovered output');

-- 6. 100 units ÷ 4 cavities = 25 shots × 2 g = 50 g of runner recovered
SELECT is(
  (SELECT COALESCE(SUM(qty_g), 0) FROM regrind_movements
    WHERE org_id = 9601 AND direction = 'in' AND source_type = 'production_run'),
  50::numeric,
  'Runner plastic is recovered into the regrind pool');

-- ── End-of-day waste ──────────────────────────────────────────────────────────

SELECT post_manual_stock_adjustment(9601, 9601, -10, 'waste', false, NULL, 'sealing waste');

-- 7. Correct type — so wastage reporting includes it
SELECT is(
  (SELECT COALESCE(SUM(quantity), 0) FROM stock_movements
    WHERE org_id = 9601 AND product_id = 9601 AND movement_type = 'wastage'),
  -10::numeric,
  'Waste posts as wastage');

-- 8. Valued, so inventory VALUE falls with it (the old version wrote no cost)
SELECT ok(
  (SELECT unit_cost FROM stock_movements
    WHERE org_id = 9601 AND product_id = 9601 AND movement_type = 'wastage'
    LIMIT 1) > 0,
  'Waste is valued at weighted-average cost, so stock value falls too');

-- ── Rejects routed to regrind ─────────────────────────────────────────────────

SELECT post_manual_stock_adjustment(9601, 9601, -5, 'rejects', true, NULL, 'rejected parts');

-- 9. 5 rejects × 4 g = 20 g of plastic parked in the pool
SELECT is(
  (SELECT COALESCE(SUM(qty_g), 0) FROM regrind_movements
    WHERE org_id = 9601 AND direction = 'in' AND source_type = 'reject_override'),
  20::numeric,
  'Rejects routed to regrind park the plastic weight of the broken parts');

-- ── Guards ────────────────────────────────────────────────────────────────────

-- 10.
SELECT throws_ok(
  $$ SELECT post_manual_stock_adjustment(9601, 9601, 0, 'waste', false, NULL, NULL) $$,
  'P0001', 'Quantity cannot be zero',
  'Zero quantity is refused');

-- 11. Workers cannot silently adjust stock
RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub":"e2000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$ SELECT post_manual_stock_adjustment(9601, 9601, -1, 'waste', false, NULL, NULL) $$,
  'P0001', 'Only org admins can post manual stock adjustments',
  'Workers cannot post manual stock adjustments');

SELECT * FROM finish();
ROLLBACK;
