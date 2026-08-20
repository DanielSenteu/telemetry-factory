-- Scheduling #3 — leave ↔ attendance/payroll tie-in.
--
-- Two pieces:
-- 1. shift_attendance view learns about approved leave: a published shift falling
--    on an approved-leave day shows as 'leave' instead of 'absent'/'scheduled'.
--    (In practice approving leave releases the shift to the open pool, so the
--    worker usually has no shift that day — this covers any that remain, and keeps
--    the manager's Attendance view honest.)
-- 2. worker_leave_days(): expands approved leave into per-day rows (with paid flag)
--    for a period, so payroll can EXCUSE paid leave and DOCK unpaid leave — the
--    case the shift-release alone can't handle (no shift left to mark absent).

-- ── 1. Recreate the attendance view with a 'leave' status ─
CREATE OR REPLACE VIEW shift_attendance WITH (security_invoker = true) AS
WITH matched AS (
  SELECT
    s.id AS shift_id, s.org_id, s.worker_id, s.workplace_id,
    s.start_at, s.end_at,
    t.id AS timesheet_id, t.clock_in, t.clock_out
  FROM shifts s
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
    -- Excused: approved leave covering this shift's day (and they didn't clock in).
    WHEN m.timesheet_id IS NULL AND EXISTS (
      SELECT 1 FROM leave_requests lr
      WHERE lr.worker_id = m.worker_id
        AND lr.status = 'approved'
        AND m.start_at::date BETWEEN lr.start_date AND lr.end_date
    ) THEN 'leave'
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

-- ── 2. Approved leave expanded to per-day rows for a pay period ─
-- Returns one row per worker per leave day in [p_from, p_to), with the paid flag.
-- Payroll uses this to auto-dock unpaid leave and excuse paid leave. SECURITY
-- INVOKER (default) so RLS on leave_requests scopes it to the caller's org.
CREATE OR REPLACE FUNCTION worker_leave_days(p_org_id INTEGER, p_from DATE, p_to DATE)
RETURNS TABLE (
  worker_id  INTEGER,
  leave_date DATE,
  paid       BOOLEAN
)
LANGUAGE sql
STABLE
AS $$
  SELECT lr.worker_id, gs::date AS leave_date, lr.paid
  FROM leave_requests lr
  CROSS JOIN generate_series(lr.start_date::timestamp, lr.end_date::timestamp, interval '1 day') gs
  WHERE lr.org_id = p_org_id
    AND lr.status = 'approved'
    AND gs::date >= p_from
    AND gs::date <  p_to
  ORDER BY lr.worker_id, leave_date;
$$;
