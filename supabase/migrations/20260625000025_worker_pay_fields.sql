-- Payroll foundation (Phase 3a): how much each worker is paid. Until now the
-- workers table had no pay info, so payslips were impossible. This adds the pay
-- setup; the payroll RUN (computing hours/days, absence docking, payslips, GL
-- posting) comes next in Phase 3b.
--
-- Two pay types:
--   * hourly  — pay = hours worked (to the minute, from clock-in→out) × pay_rate
--   * monthly — pay = pay_rate (a fixed salary); attendance counts DAYS present,
--               and monthly_expected_days is the denominator for a day's pay
--               (salary ÷ expected days) when an absent day is docked at payroll.
--
-- pay_rate carries the hourly rate OR the monthly salary depending on pay_type.
-- Minute-level time needs NO change: timesheet_entries.clock_in/clock_out are
-- already TIMESTAMPTZ, so exact durations are present in the data already.

ALTER TABLE workers
  ADD COLUMN IF NOT EXISTS pay_type TEXT NOT NULL DEFAULT 'hourly'
    CHECK (pay_type IN ('hourly', 'monthly')),
  ADD COLUMN IF NOT EXISTS pay_rate NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS monthly_expected_days INTEGER;
