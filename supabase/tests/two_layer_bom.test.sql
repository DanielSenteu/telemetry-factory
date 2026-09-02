-- pgTAP: two-layer BOM (migration 65).
--
-- Resin → [moulding] → moulded component → [sealing] → sealed finished good.
--
-- Tests:
--   1. Moulding confirm makes components: resin down, component stock up.
--   2. Sealing post is a transform: components consumed, film consumed,
--      SEALED stock produced.
--   3. The layer gap is visible: unsealed components remain in stock.
--   4. Sealed unit cost = component rolled cost + packaging cost.
--   5. Consume-only regression: a recipe with only bought-in packaging
--      still produces NO output (today's behaviour unchanged).
--   6. Recipe cycles are refused, however deep.
--
-- Run: supabase start && supabase test db

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(6);

-- ── Fixture ───────────────────────────────────────────────────────────────────

INSERT INTO organizations (id, name) VALUES (9950, 'TwoLayer Org');

INSERT INTO auth.users (id, email) VALUES
  ('a9500000-0000-0000-0000-000000000001', 'admin-a@twolayer.local');
INSERT INTO accounts (org_id, email, role, user_id) VALUES
  (9950, 'admin-a@twolayer.local', 'admin', 'a9500000-0000-0000-0000-000000000001');

INSERT INTO machines (id, org_id, name, mac) VALUES
  (9951, 9950, 'Moulder',  'aa:bb:cc:65:00:01'),
  (9952, 9950, 'Sealer',   'aa:bb:cc:65:00:02'),
  (9953, 9950, 'Wrapper2', 'aa:bb:cc:65:00:03');

INSERT INTO products (id, org_id, name, unit_of_measure, kind) VALUES
  (9950, 9950, 'PP resin',                 'g',    'raw_material'),
  (9951, 9950, '60ml Container (moulded)', 'each', 'component'),
  (9952, 9950, '60ml Container — sealed',  'each', 'finished_good'),
  (9953, 9950, 'Film',                     'm',    'consumable'),
  (9954, 9950, 'Loose Cap',                'each', 'finished_good');

SELECT set_config('request.jwt.claims',
  '{"sub":"a9500000-0000-0000-0000-000000000001","role":"authenticated"}', true);

-- Seed resin stock with a known cost: 100,000 g @ 0.2 (KES/g).
INSERT INTO stock_movements (org_id, product_id, quantity, movement_type, unit_cost, note)
VALUES (9950, 9950, 100000, 'purchase', 0.2, 'seed resin');
-- Film: 1,000 m @ 5.
INSERT INTO stock_movements (org_id, product_id, quantity, movement_type, unit_cost, note)
VALUES (9950, 9953, 1000, 'purchase', 5, 'seed film');

-- Component's recipe (moulding): 12 g resin per moulded container.
SELECT upsert_bom_line(9950, 9951, 9950, 12, 'g');

-- Finished good's recipe (packaging): 1 moulded container + 0.1 m film per unit.
SELECT upsert_bom_line(9950, 9952, 9951, 1, 'each', 1, 'packaging');
SELECT upsert_bom_line(9950, 9952, 9953, 0.1, 'm', 1, 'packaging');

-- ── 1. Moulding makes components ──────────────────────────────────────────────

SELECT confirm_machine_output(9950, 9951, 9951, 1000, 0, '2026-08-20');

SELECT is(
  (SELECT ARRAY[
    (SELECT SUM(quantity) FROM stock_movements WHERE org_id = 9950 AND product_id = 9951),
    (SELECT SUM(-quantity) FROM stock_movements
     WHERE org_id = 9950 AND product_id = 9950 AND movement_type = 'production_consume')
  ]),
  ARRAY[1000, 12000]::numeric[],
  'moulding confirm: +1000 moulded components, 12,000 g resin consumed'
);

-- ── 2 & 3. Sealing transforms 800 of them ─────────────────────────────────────

INSERT INTO machine_day_production (org_id, machine_id, day, shots, scrap, parts_gross)
VALUES (9950, 9952, '2026-08-21', 800, 0, 800);

SELECT post_count_action(9950, 9952, '2026-08-21', NULL, 9952);

SELECT is(
  (SELECT ARRAY[
    (SELECT SUM(quantity) FROM stock_movements
     WHERE org_id = 9950 AND product_id = 9952 AND movement_type = 'production_output'),
    (SELECT SUM(-quantity) FROM stock_movements
     WHERE org_id = 9950 AND product_id = 9951 AND source_type = 'count_action'),
    (SELECT SUM(-quantity) FROM stock_movements
     WHERE org_id = 9950 AND product_id = 9953 AND source_type = 'count_action')
  ]),
  ARRAY[800, 800, 80]::numeric[],
  'transform: +800 sealed produced, 800 components and 80 m film consumed'
);

SELECT is(
  (SELECT SUM(quantity) FROM stock_movements WHERE org_id = 9950 AND product_id = 9951),
  200::numeric,
  'the layer gap is visible: 200 moulded-but-unsealed components remain'
);

-- ── 4. Cost chains through the layers ─────────────────────────────────────────

-- Component rolled cost = 12 g × 0.2 = 2.4; sealed = 2.4 + 0.1 m × 5 = 2.9.
SELECT is(
  (SELECT unit_cost FROM stock_movements
   WHERE org_id = 9950 AND product_id = 9952 AND movement_type = 'production_output'),
  2.9::numeric,
  'sealed unit cost = component rolled cost (2.4) + packaging (0.5)'
);

-- ── 5. Consume-only regression (no in-house ingredient → no output) ──────────

SELECT upsert_bom_line(9950, 9954, 9953, 0.05, 'm', 1, 'packaging');

INSERT INTO machine_day_production (org_id, machine_id, day, shots, scrap, parts_gross)
VALUES (9950, 9953, '2026-08-21', 500, 0, 500);

SELECT post_count_action(9950, 9953, '2026-08-21', NULL, 9954);

SELECT is(
  (SELECT COALESCE(SUM(quantity), 0) FROM stock_movements
   WHERE org_id = 9950 AND product_id = 9954 AND movement_type = 'production_output'),
  0::numeric,
  'bought-in-only packaging stays consume-only: no output produced'
);

-- ── 6. Cycles are refused ─────────────────────────────────────────────────────

-- sealed already eats moulded; making moulded eat sealed must fail.
SELECT throws_ok(
  $$ SELECT upsert_bom_line(9950, 9951, 9952, 1, 'each', 1, 'packaging') $$,
  'This would make the product an ingredient of itself (recipe cycle)',
  'recipe cycles are refused'
);

SELECT * FROM finish();
ROLLBACK;
