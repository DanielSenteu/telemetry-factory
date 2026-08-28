-- pgTAP: machine_day_production — write-time production rollup (migration 60).
--
-- Tests:
--   1. Trigger accrues guarded deltas per Nairobi day as readings arrive.
--   2. Reboot counter restore contributes nothing (physics guard at ingestion).
--   3. Nairobi midnight boundary (21:00 UTC): the delta lands on the later
--      reading's Kenya day (rule 17: test the boundary).
--   4. Out-of-order arrival: inserting a middle reading late leaves the same
--      totals as chronological insertion (queued collector data).
--   5. rebuild_machine_day_production reproduces exactly what the trigger built.
--   6. machine_dashboard_snapshot serves period sums from the rollup.
--   7. Org A member cannot read org B rollup rows (rule 16).
--   8. Org A member can read their own rollup rows.
--
-- Run: supabase start && supabase test db

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(8);

-- ── Fixture (as postgres — RLS bypassed) ──────────────────────────────────────

INSERT INTO organizations (id, name) VALUES
  (9920, 'Rollup Org A'),
  (9921, 'Rollup Org B');

INSERT INTO auth.users (id, email) VALUES
  ('a9200000-0000-0000-0000-000000000001', 'admin-a@rolluptest.local');

INSERT INTO accounts (org_id, email, role, user_id) VALUES
  (9920, 'admin-a@rolluptest.local', 'admin', 'a9200000-0000-0000-0000-000000000001');

INSERT INTO machines (id, org_id, name, mac) VALUES
  (9921, 9920, 'Rollup machine',   'aa:bb:cc:60:00:01'),
  (9922, 9920, 'Boundary machine', 'aa:bb:cc:60:00:02'),
  (9923, 9920, 'Late machine',     'aa:bb:cc:60:00:03'),
  (9924, 9921, 'Org B machine',    'aa:bb:cc:60:00:04');

-- Machine 9921: production, a power cut, a restore — all on Kenya day 2026-08-20
-- (07:00–08:00 UTC = 10:00–11:00 EAT). 13s cycle, cavity 2.
INSERT INTO machine_readings
  (machine_id, org_id, observed_at, craft_id, shot_count, inferior_count, cycle_time, mold_cavity)
VALUES
  (9921, 9920, '2026-08-20T07:00:00Z', 'CAPS1', 1000, 100, 13.1, 2),
  (9921, 9920, '2026-08-20T07:01:00Z', 'CAPS1', 1004, 100, 13.1, 2),  -- +4 shots
  (9921, 9920, '2026-08-20T07:02:00Z', NULL,    0,    0,   0,    0),  -- power cut
  (9921, 9920, '2026-08-20T07:02:30Z', NULL,    1004, 100, 0,    0),  -- restore: rejected
  (9921, 9920, '2026-08-20T07:03:30Z', 'CAPS1', 1008, 101, 13.1, 2);  -- +4 shots, +1 scrap

-- Machine 9922: two readings straddling Nairobi midnight (21:00 UTC).
-- The +2 delta belongs to the LATER reading's Kenya day (2026-08-21).
INSERT INTO machine_readings
  (machine_id, org_id, observed_at, craft_id, shot_count, inferior_count, cycle_time, mold_cavity)
VALUES
  (9922, 9920, '2026-08-20T20:59:30Z', 'CONT', 500, 0, 13.1, 1),
  (9922, 9920, '2026-08-20T21:00:30Z', 'CONT', 502, 0, 13.1, 1);

-- Machine 9923: out-of-order arrival — the middle reading lands in a LATER
-- insert statement (queued collector data catching up). Chronological truth:
-- 100 → 104 → 108 (+8 total).
INSERT INTO machine_readings
  (machine_id, org_id, observed_at, craft_id, shot_count, inferior_count, cycle_time, mold_cavity)
VALUES
  (9923, 9920, '2026-08-20T09:00:00Z', 'CONT', 100, 0, 13.1, 1),
  (9923, 9920, '2026-08-20T09:02:00Z', 'CONT', 108, 0, 13.1, 1);
INSERT INTO machine_readings
  (machine_id, org_id, observed_at, craft_id, shot_count, inferior_count, cycle_time, mold_cavity)
VALUES
  (9923, 9920, '2026-08-20T09:01:00Z', 'CONT', 104, 0, 13.1, 1);

-- Org B: some production so isolation has something to hide.
INSERT INTO machine_readings
  (machine_id, org_id, observed_at, craft_id, shot_count, inferior_count, cycle_time, mold_cavity)
VALUES
  (9924, 9921, '2026-08-20T07:00:00Z', 'X', 10, 0, 13.1, 1),
  (9924, 9921, '2026-08-20T07:01:00Z', 'X', 14, 0, 13.1, 1);

-- ── Assert ────────────────────────────────────────────────────────────────────

-- 1. Power-cut day: 4 + 0 (drop) + 0 (restore rejected) + 4 = 8 shots, cavity 2 → 16 parts.
SELECT is(
  (SELECT ARRAY[shots, parts_gross] FROM machine_day_production
   WHERE machine_id = 9921 AND day = '2026-08-20'),
  ARRAY[8, 16]::bigint[],
  'trigger accrues guarded shot deltas per day (restore contributes nothing)'
);

-- 2. Scrap restore rejected the same way: only the real 100→101 increment.
SELECT is(
  (SELECT scrap FROM machine_day_production WHERE machine_id = 9921 AND day = '2026-08-20'),
  1::double precision,
  'scrap counter restore is rejected at ingestion'
);

-- 3. Midnight boundary: the +2 delta lands on 2026-08-21 (Kenya), not 08-20.
SELECT is(
  (SELECT ARRAY[
    COALESCE((SELECT shots FROM machine_day_production WHERE machine_id = 9922 AND day = '2026-08-20'), 0),
    COALESCE((SELECT shots FROM machine_day_production WHERE machine_id = 9922 AND day = '2026-08-21'), 0)]),
  ARRAY[0, 2]::bigint[],
  '21:00 UTC boundary: delta belongs to the later reading''s Nairobi day'
);

-- 4. Out-of-order arrival: same totals as chronological truth (+8).
SELECT is(
  (SELECT shots FROM machine_day_production WHERE machine_id = 9923 AND day = '2026-08-20'),
  8::bigint,
  'late-arriving middle reading leaves order-independent totals'
);

-- 5. Rebuild reproduces the trigger-built rollup exactly.
CREATE TEMP TABLE rollup_before AS
  SELECT machine_id, day, shots, scrap, parts_gross FROM machine_day_production
  WHERE org_id IN (9920, 9921);
SELECT rebuild_machine_day_production();
SELECT is(
  (SELECT COUNT(*) FROM (
    SELECT machine_id, day, shots, scrap, parts_gross FROM machine_day_production
    WHERE org_id IN (9920, 9921)
    EXCEPT SELECT * FROM rollup_before
    UNION ALL
    SELECT * FROM rollup_before
    EXCEPT SELECT machine_id, day, shots, scrap, parts_gross FROM machine_day_production
    WHERE org_id IN (9920, 9921)
  ) diff),
  0::bigint,
  'rebuild from raw readings reproduces the trigger-built rollup'
);

-- 6. Snapshot serves the period sums from the rollup (Kenya day 2026-08-20).
SELECT is(
  (SELECT s.today_shots FROM machine_dashboard_snapshot(
     9920, '2026-08-19T21:00:00Z', '2026-08-20T21:00:00Z') s
   WHERE s.machine_id = 9921),
  8::bigint,
  'dashboard snapshot reads period totals from the rollup'
);

-- ── RLS isolation (rule 16) ───────────────────────────────────────────────────

SELECT set_config('request.jwt.claims',
  '{"sub":"a9200000-0000-0000-0000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT is(
  (SELECT COUNT(*) FROM machine_day_production WHERE org_id = 9921),
  0::bigint,
  'org A member sees zero org B rollup rows'
);

SELECT cmp_ok(
  (SELECT COUNT(*) FROM machine_day_production WHERE org_id = 9920),
  '>=', 3::bigint,
  'org A member reads their own rollup rows'
);

SELECT * FROM finish();
ROLLBACK;
