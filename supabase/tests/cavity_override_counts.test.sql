-- pgTAP: cavity override drives counted parts (migration 62).
--
-- Tests:
--   1. With an override in place, incoming readings count parts with it
--      (panel says 1, override says 16 → parts = shots × 16).
--   2. Setting an override AFTER readings exist recounts history automatically.
--   3. Clearing back to panel value follows the same path (update → recount).
--
-- Run: supabase start && supabase test db

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(4);

-- ── Fixture ───────────────────────────────────────────────────────────────────

INSERT INTO organizations (id, name) VALUES (9940, 'Override Org');

INSERT INTO machines (id, org_id, name, mac) VALUES
  (9941, 9940, 'Panel-liar A', 'aa:bb:cc:62:00:01'),
  (9942, 9940, 'Panel-liar B', 'aa:bb:cc:62:00:02');

INSERT INTO products (id, org_id, name, unit_of_measure, kind) VALUES
  (9940, 9940, '60ml Container', 'each', 'finished_good');

-- Machine A: override exists BEFORE readings arrive.
INSERT INTO machine_product_map (org_id, machine_id, craft_id, product_id, cavity_override)
VALUES (9940, 9941, 'CONT', 9940, 16);

-- Panel claims 1 cavity; 10 real shots at a 13s cycle.
INSERT INTO machine_readings
  (machine_id, org_id, observed_at, craft_id, shot_count, inferior_count, cycle_time, mold_cavity)
VALUES
  (9941, 9940, '2026-08-20T07:00:00Z', 'CONT', 100, 0, 13.1, 1),
  (9941, 9940, '2026-08-20T07:01:00Z', 'CONT', 104, 0, 13.1, 1),
  (9941, 9940, '2026-08-20T07:02:00Z', 'CONT', 110, 0, 13.1, 1);

SELECT is(
  (SELECT ARRAY[shots, parts_gross] FROM machine_day_production
   WHERE machine_id = 9941 AND day = '2026-08-20'),
  ARRAY[10, 160]::bigint[],
  'override wins over the panel at ingestion: 10 shots × 16 = 160 parts'
);

-- Machine B: readings arrive FIRST (counted at panel value 1)…
INSERT INTO machine_readings
  (machine_id, org_id, observed_at, craft_id, shot_count, inferior_count, cycle_time, mold_cavity)
VALUES
  (9942, 9940, '2026-08-20T07:00:00Z', 'CONT', 200, 0, 13.1, 1),
  (9942, 9940, '2026-08-20T07:01:00Z', 'CONT', 205, 0, 13.1, 1);

-- …then the truth is entered: mapping with override 16 → history recounts itself.
INSERT INTO machine_product_map (org_id, machine_id, craft_id, product_id, cavity_override)
VALUES (9940, 9942, 'CONT', 9940, 16);

SELECT is(
  (SELECT parts_gross FROM machine_day_production
   WHERE machine_id = 9942 AND day = '2026-08-20'),
  80::bigint,
  'setting an override after the fact recounts history: 5 shots × 16'
);

-- Clearing the override goes back to the panel value, history recounted again.
UPDATE machine_product_map SET cavity_override = NULL
WHERE machine_id = 9942 AND craft_id = 'CONT';

SELECT is(
  (SELECT parts_gross FROM machine_day_production
   WHERE machine_id = 9942 AND day = '2026-08-20'),
  5::bigint,
  'clearing the override returns counting to the panel value'
);

-- A panel cavity of 0 means unset: parts fall back to ×1, never ×0.
INSERT INTO machines (id, org_id, name, mac) VALUES
  (9943, 9940, 'Panel-zero', 'aa:bb:cc:62:00:03');
INSERT INTO machine_readings
  (machine_id, org_id, observed_at, craft_id, shot_count, inferior_count, cycle_time, mold_cavity)
VALUES
  (9943, 9940, '2026-08-20T07:00:00Z', 'X1', 50, 0, 13.1, 0),
  (9943, 9940, '2026-08-20T07:01:00Z', 'X1', 54, 0, 13.1, 0);

SELECT is(
  (SELECT parts_gross FROM machine_day_production
   WHERE machine_id = 9943 AND day = '2026-08-20'),
  4::bigint,
  'panel cavity 0 counts as unset (×1), never multiplies parts to zero'
);

SELECT * FROM finish();
ROLLBACK;
