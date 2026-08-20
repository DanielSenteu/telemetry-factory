-- pgTAP: machine_product_map — Phase 2 product mapping.
--
-- Tests:
--   1. Unmapped crafts inbox shows unseen craft before any mapping.
--   2. Admin A sees zero org B mappings (RLS isolation).
--   3. Admin A can create a mapping (lives_ok).
--   4. After mapping, inbox clears for that craft.
--   5. Mapping row has the correct product_id.
--   6. Remapping the same craft upserts (no duplicate row).
--   7. Remap produces exactly one row (not two).
--   8. Remap updated product_id to the new product.
--   9. Snapshot returns product_name for a mapped craft.
--  10. Admin A blocked from mapping into org B.
--  11. Admin B sees zero org A mappings.
--  12. Admin B unmapped inbox shows only org B crafts.
--
-- Run: supabase start && supabase test db

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(12);

-- ── Fixture (as postgres — RLS bypassed) ──────────────────────────────────────

INSERT INTO organizations (id, name) VALUES
  (9901, 'Map Org A'),
  (9902, 'Map Org B');

INSERT INTO auth.users (id, email) VALUES
  ('a1000000-0000-0000-0000-000000000001', 'admin-a@maptest.local'),
  ('b2000000-0000-0000-0000-000000000002', 'admin-b@maptest.local');

INSERT INTO accounts (org_id, email, role, user_id) VALUES
  (9901, 'admin-a@maptest.local', 'admin', 'a1000000-0000-0000-0000-000000000001'),
  (9902, 'admin-b@maptest.local', 'admin', 'b2000000-0000-0000-0000-000000000002');

INSERT INTO machines (id, org_id, name, mac) VALUES
  (9901, 9901, 'Machine A1', 'aa:bb:cc:01:01:01'),
  (9902, 9902, 'Machine B1', 'aa:bb:cc:02:02:02');

INSERT INTO products (id, org_id, name, unit_of_measure, kind) VALUES
  (9901, 9901, 'Syringe Barrel',  'each', 'finished_good'),
  (9902, 9902, 'Cap Red',         'each', 'finished_good'),
  (9903, 9901, 'Syringe Plunger', 'each', 'finished_good');

-- Readings with craft_ids in the last hour so unmapped_machine_crafts picks them up.
INSERT INTO machine_readings (machine_id, org_id, observed_at, craft_id, shot_count, inferior_count)
VALUES
  (9901, 9901, now() - interval '30 minutes', 'CRAFT-A1', 100, 2),
  (9901, 9901, now() - interval '10 minutes', 'CRAFT-A1', 150, 3),
  (9902, 9902, now() - interval '20 minutes', 'CRAFT-B1', 200, 5);

-- ── Act as admin A ─────────────────────────────────────────────────────────────

SELECT set_config('request.jwt.claims',
  '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

-- 1. Inbox shows CRAFT-A1 before any mapping
SELECT is(
  (SELECT COUNT(*) FROM unmapped_machine_crafts(9901) WHERE craft_id = 'CRAFT-A1'),
  1::bigint,
  'Unmapped crafts inbox shows CRAFT-A1 for org A before mapping');

-- 2. RLS: admin A sees zero org B mappings
SELECT is(
  (SELECT COUNT(*) FROM machine_product_map WHERE org_id = 9902),
  0::bigint,
  'Admin A sees zero org B mappings');

-- 3. Admin A can create a mapping
SELECT lives_ok(
  $$ SELECT map_machine_craft(9901, 9901, 'CRAFT-A1', 9901, NULL::SMALLINT) $$,
  'Admin A can map CRAFT-A1 to Syringe Barrel');

-- 4. After mapping, inbox is empty
SELECT is(
  (SELECT COUNT(*) FROM unmapped_machine_crafts(9901)),
  0::bigint,
  'Unmapped crafts inbox clears after mapping');

-- 5. Mapping row has correct product
SELECT is(
  (SELECT product_id
   FROM machine_product_map
   WHERE org_id = 9901 AND machine_id = 9901 AND craft_id = 'CRAFT-A1'),
  9901,
  'Mapping row points at Syringe Barrel (product 9901)');

-- 6. Remap to a different product in same org — must not error
SELECT lives_ok(
  $$ SELECT map_machine_craft(9901, 9901, 'CRAFT-A1', 9903, NULL::SMALLINT) $$,
  'Remapping the same craft upserts without error');

-- 7. Remap produced exactly one row (no duplicate)
SELECT is(
  (SELECT COUNT(*)
   FROM machine_product_map
   WHERE org_id = 9901 AND machine_id = 9901 AND craft_id = 'CRAFT-A1'),
  1::bigint,
  'Remap leaves exactly one mapping row (no duplicate)');

-- 8. Remap updated product_id
SELECT is(
  (SELECT product_id
   FROM machine_product_map
   WHERE org_id = 9901 AND machine_id = 9901 AND craft_id = 'CRAFT-A1'),
  9903,
  'Remap updated product_id to Syringe Plunger (9903)');

-- 9. Snapshot enriches with product_name for mapped craft
SELECT is(
  (SELECT product_name
   FROM machine_dashboard_snapshot(9901, now() - interval '1 hour')
   WHERE machine_id = 9901),
  'Syringe Plunger',
  'Snapshot returns product_name for a mapped craft');

-- 10. Admin A blocked from mapping into org B
SELECT throws_ok(
  $$ SELECT map_machine_craft(9902, 9902, 'CRAFT-B1', 9902, NULL::SMALLINT) $$,
  'P0001', NULL,
  'Admin A cannot map a craft into org B');

-- ── Act as admin B ─────────────────────────────────────────────────────────────

RESET ROLE;
SELECT set_config('request.jwt.claims',
  '{"sub":"b2000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

-- 11. Admin B sees zero org A mappings
SELECT is(
  (SELECT COUNT(*) FROM machine_product_map),
  0::bigint,
  'Admin B sees zero org A mappings');

-- 12. Admin B unmapped inbox shows only CRAFT-B1
SELECT is(
  (SELECT COUNT(*) FROM unmapped_machine_crafts(9902) WHERE craft_id = 'CRAFT-B1'),
  1::bigint,
  'Admin B unmapped inbox shows only org B crafts');

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
