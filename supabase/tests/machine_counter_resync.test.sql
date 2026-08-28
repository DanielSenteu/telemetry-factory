-- pgTAP: machine_dashboard_snapshot — counter re-sync guard (migration 59).
--
-- Replays the 2026-08-26 power-cut incident: controller drops shot_count to 0
-- (cycle_time 0, craft NULL), then restores the cumulative counter within one
-- polling gap. The restore jump must NOT count as production; real production
-- before and after must. A genuine operator counter reset (0 then climbing at
-- production speed) must still count.
--
-- Tests:
--   1. Power-cut day: today_shots counts only real production (restore rejected).
--   2. Power-cut day: today_parts_gross follows the guarded shots.
--   3. Scrap counter restore is rejected the same way.
--   4. Operator counter reset still counts the post-reset production.
--
-- Run: supabase start && supabase test db

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(4);

-- ── Fixture (as postgres — RLS bypassed) ──────────────────────────────────────

INSERT INTO organizations (id, name) VALUES (9910, 'Resync Org');

INSERT INTO machines (id, org_id, name, mac) VALUES
  (9911, 9910, 'Power-cut machine', 'aa:bb:cc:59:00:01'),
  (9912, 9910, 'Reset machine',     'aa:bb:cc:59:00:02');

-- Machine 9911: normal 13s-cycle production, a power cut, a counter restore.
-- Seed before the window: 998 shots / 100 scrap.
INSERT INTO machine_readings
  (machine_id, org_id, observed_at, craft_id, shot_count, inferior_count, cycle_time, mold_cavity)
VALUES
  (9911, 9910, now() - interval '3 hours',     'CAPS1', 998,  100, 13.1, 1),
  -- in-window production: +2 then +4, plausible at 13s cycle
  (9911, 9910, now() - interval '60 minutes',  'CAPS1', 1000, 100, 13.1, 1),
  (9911, 9910, now() - interval '59 minutes',  'CAPS1', 1004, 100, 13.1, 1),
  -- power cut: counter drops to 0, controller in boot state
  (9911, 9910, now() - interval '58 minutes',  NULL,    0,    0,   0,    0),
  (9911, 9910, now() - interval '57 minutes 30 seconds', NULL, 0, 0, 0,  0),
  -- restore: cumulative counter (and scrap) jump back within one 30s gap
  (9911, 9910, now() - interval '57 minutes',  NULL,    1004, 100, 0,    0),
  -- production resumes: +4 shots, +1 scrap
  (9911, 9910, now() - interval '56 minutes',  'CAPS1', 1008, 101, 13.1, 1);

-- Machine 9912: operator resets the counter mid-shift, then keeps producing.
INSERT INTO machine_readings
  (machine_id, org_id, observed_at, craft_id, shot_count, inferior_count, cycle_time, mold_cavity)
VALUES
  (9912, 9910, now() - interval '3 hours',    'CONT', 500, 0, 13.1, 1),
  (9912, 9910, now() - interval '50 minutes', 'CONT', 500, 0, 13.1, 1),
  (9912, 9910, now() - interval '49 minutes', 'CONT', 0,   0, 13.1, 1),
  (9912, 9910, now() - interval '48 minutes', 'CONT', 2,   0, 13.1, 1),
  (9912, 9910, now() - interval '47 minutes', 'CONT', 4,   0, 13.1, 1);

-- ── Assert ────────────────────────────────────────────────────────────────────

-- Real production: (1000-998) + (1004-1000) + (1008-1004) = 10.
-- The 0→1004 restore (30s gap, ceiling ~63 shots) contributes nothing.
SELECT is(
  (SELECT s.today_shots FROM machine_dashboard_snapshot(9910, now() - interval '2 hours', NULL) s
   WHERE s.machine_id = 9911),
  10::bigint,
  'power-cut day counts only real production, not the counter restore'
);

SELECT is(
  (SELECT s.today_parts_gross FROM machine_dashboard_snapshot(9910, now() - interval '2 hours', NULL) s
   WHERE s.machine_id = 9911),
  10::bigint,
  'parts gross follows guarded shots (restore rows contribute nothing)'
);

-- Scrap: the 0→100 restore is rejected; only the real 100→101 increment counts.
SELECT is(
  (SELECT s.today_scrap FROM machine_dashboard_snapshot(9910, now() - interval '2 hours', NULL) s
   WHERE s.machine_id = 9911),
  1::double precision,
  'scrap counter restore is rejected like the shot counter'
);

-- Operator reset: 500→500 (0) + reset-to-0 (counts 0) + 2 + 2 = 4.
SELECT is(
  (SELECT s.today_shots FROM machine_dashboard_snapshot(9910, now() - interval '2 hours', NULL) s
   WHERE s.machine_id = 9912),
  4::bigint,
  'operator counter reset still counts post-reset production'
);

SELECT * FROM finish();
ROLLBACK;
