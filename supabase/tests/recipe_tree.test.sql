-- pgTAP: process stages + recipe_tree (migration 68).
--
-- Tests:
--   1. recipe_tree returns the whole chain: root at depth 0, component at 1.
--   2. Each node carries its bought-in material lines as JSON.
--   3. The link row knows how much of the child one parent unit consumes.
--   4. Mould setup rides on the component's node.
--   5. Org B members see nothing of org A's tree (RLS through the walker).
--
-- Run: supabase start && supabase test db

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(5);

-- ── Fixture ───────────────────────────────────────────────────────────────────

INSERT INTO organizations (id, name) VALUES (9960, 'Tree Org A'), (9961, 'Tree Org B');

INSERT INTO auth.users (id, email) VALUES
  ('a9600000-0000-0000-0000-000000000001', 'admin-a@treetest.local'),
  ('b9610000-0000-0000-0000-000000000002', 'admin-b@treetest.local');
INSERT INTO accounts (org_id, email, role, user_id) VALUES
  (9960, 'admin-a@treetest.local', 'admin', 'a9600000-0000-0000-0000-000000000001'),
  (9961, 'admin-b@treetest.local', 'admin', 'b9610000-0000-0000-0000-000000000002');

INSERT INTO process_stages (id, org_id, name, sort_order) VALUES
  (9960, 9960, 'Moulding', 1),
  (9961, 9960, 'Sealing', 2);

INSERT INTO products (id, org_id, name, unit_of_measure, kind, made_at_stage_id) VALUES
  (9960, 9960, 'PP resin',            'g',    'raw_material', NULL),
  (9961, 9960, 'Container (moulded)', 'each', 'component',    9960),
  (9962, 9960, 'Container — sealed',  'each', 'finished_good', 9961),
  (9963, 9960, 'Film',                'm',    'consumable',   NULL);

SELECT set_config('request.jwt.claims',
  '{"sub":"a9600000-0000-0000-0000-000000000001","role":"authenticated"}', true);

SELECT upsert_bom_line(9960, 9961, 9960, 12, 'g');                      -- component: resin
SELECT update_bom_shot_params(9960, 9961, 16::smallint, 65::numeric, 9960);
SELECT upsert_bom_line(9960, 9962, 9961, 1, 'each', 1, 'packaging');    -- sealed: 1 component
SELECT upsert_bom_line(9960, 9962, 9963, 0.2, 'm', 1, 'packaging');     -- sealed: film

-- ── Assert ────────────────────────────────────────────────────────────────────

SELECT is(
  (SELECT array_agg(t.name ORDER BY t.depth) FROM recipe_tree(9960, 9962) t),
  ARRAY['Container — sealed', 'Container (moulded)'],
  'the walker returns the whole chain, root first'
);

SELECT is(
  (SELECT t.material_lines -> 0 ->> 'name' FROM recipe_tree(9960, 9962) t WHERE t.depth = 1),
  'PP resin',
  'a node carries its bought-in lines as JSON'
);

SELECT is(
  (SELECT ARRAY[t.link_qty, t.link_per_units] FROM recipe_tree(9960, 9962) t WHERE t.depth = 1),
  ARRAY[1, 1]::numeric[],
  'the link row says how much of the child one parent unit consumes'
);

SELECT is(
  (SELECT ARRAY[t.cavities::int, t.runner_weight_g::int] FROM recipe_tree(9960, 9962) t WHERE t.depth = 1),
  ARRAY[16, 65],
  'mould setup rides on the component node'
);

-- Org B sees nothing through the walker (RLS on the underlying tables).
SELECT set_config('request.jwt.claims',
  '{"sub":"b9610000-0000-0000-0000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT COUNT(*) FROM recipe_tree(9960, 9962)),
  0::bigint,
  'org B members see nothing of org A''s tree'
);

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
