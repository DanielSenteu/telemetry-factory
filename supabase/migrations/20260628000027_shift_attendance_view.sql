-- Scheduling module 2: schedule vs actual. Compares each PUBLISHED shift (the
-- plan) against the worker's clock-ins (the actual, timesheet_entries) and labels
-- the result. This is the automation payoff: late/absent/overtime fall out of the
-- data, and it feeds payroll — a published past shift with no clock-in (and no
-- approved leave, later) is exactly the absent day to consider docking.
--
-- timesheet_entries has no org_id (scoped via worker FK), so org_id is taken from
-- shifts (matched/absent rows) or workers (unplanned rows). security_invoker so
-- the underlying RLS scopes every row to the user's org.
--
-- Status rules (5-min lateness grace, baked in for v1; configurable later):
--   present    clocked in on time (≤5 min late)
--   late       clocked in >5 min after shift start
--   absent     a PAST published shift with no overlapping clock-in
--   scheduled  an upcoming published shift, not yet started/clocked
--   unplanned  a clock-in with no matching published shift
-- Plus late_minutes and overtime_minutes (clock-out beyond shift end).

CREATE VIEW shift_attendance WITH (security_invoker = true) AS
WITH matched AS (
  SELECT
    s.id AS shift_id, s.org_id, s.worker_id, s.workplace_id,
    s.start_at, s.end_at,
    t.id AS timesheet_id, t.clock_in, t.clock_out
  FROM shifts s
  -- Best-matching clock-in: same worker, actual worked interval overlaps the
  -- shift. (COALESCE(clock_out, now()) treats a still-open shift as ongoing.)
  LEFT JOIN LATERAL (
    SELECT te.*
    FROM timesheet_entries te
    WHERE te.worker_id = s.worker_id
      AND te.clock_in < s.end_at
      AND COALESCE(te.clock_out, now()) > s.start_at
    ORDER BY te.clock_in
    LIMIT 1
  ) t ON true
  WHERE s.status = 'published' AND s.worker_id IS NOT NULL
)
SELECT
  m.org_id,
  m.worker_id,
  m.workplace_id,
  m.shift_id,
  m.timesheet_id,
  m.start_at,
  m.end_at,
  m.clock_in,
  m.clock_out,
  m.start_at::date AS event_date,
  CASE
    WHEN m.timesheet_id IS NULL AND m.end_at < now() THEN 'absent'
    WHEN m.timesheet_id IS NULL                       THEN 'scheduled'
    WHEN m.clock_in > m.start_at + interval '5 minutes' THEN 'late'
    ELSE 'present'
  END AS status,
  CASE WHEN m.timesheet_id IS NOT NULL
       THEN GREATEST(0, (EXTRACT(EPOCH FROM (m.clock_in - m.start_at)) / 60))::int
       ELSE 0 END AS late_minutes,
  CASE WHEN m.clock_out IS NOT NULL AND m.clock_out > m.end_at
       THEN (EXTRACT(EPOCH FROM (m.clock_out - m.end_at)) / 60)::int
       ELSE 0 END AS overtime_minutes
FROM matched m

UNION ALL

-- Clock-ins with no matching published shift = unplanned work.
SELECT
  w.org_id,
  t.worker_id,
  t.workplace_id,
  NULL::integer AS shift_id,
  t.id AS timesheet_id,
  NULL::timestamptz AS start_at,
  NULL::timestamptz AS end_at,
  t.clock_in,
  t.clock_out,
  t.clock_in::date AS event_date,
  'unplanned' AS status,
  0 AS late_minutes,
  0 AS overtime_minutes
FROM timesheet_entries t
JOIN workers w ON w.id = t.worker_id
WHERE NOT EXISTS (
  SELECT 1 FROM shifts s
  WHERE s.status = 'published'
    AND s.worker_id = t.worker_id
    AND t.clock_in < s.end_at
    AND COALESCE(t.clock_out, now()) > s.start_at
);
