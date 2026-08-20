-- Payroll run (Phase 3b): turn pay rates (3a) + actual hours + auto-absences
-- (scheduling 2) into payslips, and post the wages to the GL. Closes the
-- workforce → money loop.
--
--   Hourly  pay = actual hours worked (to the minute) × pay_rate   (flat rate, v1)
--   Monthly pay = salary − (docked absent days × salary/expected_days)
--
-- Finalizing posts ONE balanced entry: Dr Wages & Salaries (6000) / Cr the cash
-- account it was paid from. Guarded like every other posting.

-- ── Tables ────────────────────────────────────────────

CREATE TABLE payroll_runs (
  id               SERIAL PRIMARY KEY,
  org_id           INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  period_from      DATE NOT NULL,
  period_to        DATE NOT NULL,             -- exclusive end (first day after the period)
  paid_account_code TEXT,
  total_amount     NUMERIC(14,2) NOT NULL DEFAULT 0,
  journal_entry_id INTEGER REFERENCES journal_entries(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by       UUID DEFAULT auth.uid()
);
CREATE INDEX idx_payroll_runs_org_id ON payroll_runs(org_id);

CREATE TABLE payslips (
  id           SERIAL PRIMARY KEY,
  run_id       INTEGER NOT NULL REFERENCES payroll_runs(id) ON DELETE CASCADE,
  org_id       INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  worker_id    INTEGER REFERENCES workers(id),
  pay_type     TEXT,
  hours        NUMERIC(12,2),
  days_present INTEGER,
  absent_days  INTEGER,
  docked_days  INTEGER,
  gross_pay    NUMERIC(14,2) NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_payslips_run_id ON payslips(run_id);
CREATE INDEX idx_payslips_org_id ON payslips(org_id);

-- ── payroll_preview: hours worked + pay setup per active worker ─
-- Hours = sum of completed clock-ins whose clock_in falls in [from, to).
-- Returns the pay fields too so the app can compute gross (and apply per-day
-- docking interactively). security invoker → RLS scopes to the user's org.

CREATE OR REPLACE FUNCTION payroll_preview(p_org_id INTEGER, p_from DATE, p_to DATE)
RETURNS TABLE (
  worker_id             INTEGER,
  name                  TEXT,
  pay_type              TEXT,
  pay_rate              NUMERIC,
  monthly_expected_days INTEGER,
  hours_worked          NUMERIC
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    w.id, w.name, w.pay_type, w.pay_rate, w.monthly_expected_days,
    COALESCE((
      SELECT SUM(EXTRACT(EPOCH FROM (t.clock_out - t.clock_in)) / 3600.0)
      FROM timesheet_entries t
      WHERE t.worker_id = w.id
        AND t.clock_out IS NOT NULL
        AND t.clock_in >= p_from::timestamptz
        AND t.clock_in <  p_to::timestamptz
    ), 0)::numeric(12,2) AS hours_worked
  FROM workers w
  WHERE w.org_id = p_org_id AND w.is_active = true
  ORDER BY w.name;
$$;

-- ── finalize_payroll: persist payslips + post the wages entry ──
-- p_payslips = [{ worker_id, pay_type, hours, days_present, absent_days,
--                 docked_days, gross_pay }, ...]

CREATE OR REPLACE FUNCTION finalize_payroll(
  p_org_id           INTEGER,
  p_from             DATE,
  p_to               DATE,
  p_paid_account_code TEXT,
  p_payslips         JSONB
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_run_id      INTEGER;
  v_item        JSONB;
  v_total       NUMERIC := 0;
  v_gross       NUMERIC;
  v_acct_wages  INTEGER;
  v_acct_cash   INTEGER;
  v_entry_id    INTEGER;
BEGIN
  INSERT INTO payroll_runs (org_id, period_from, period_to, paid_account_code)
  VALUES (p_org_id, p_from, p_to, p_paid_account_code)
  RETURNING id INTO v_run_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_payslips)
  LOOP
    v_gross := COALESCE((v_item->>'gross_pay')::numeric, 0);
    INSERT INTO payslips (run_id, org_id, worker_id, pay_type, hours, days_present, absent_days, docked_days, gross_pay)
    VALUES (
      v_run_id, p_org_id,
      NULLIF(v_item->>'worker_id', '')::integer,
      v_item->>'pay_type',
      NULLIF(v_item->>'hours', '')::numeric,
      NULLIF(v_item->>'days_present', '')::integer,
      NULLIF(v_item->>'absent_days', '')::integer,
      NULLIF(v_item->>'docked_days', '')::integer,
      v_gross
    );
    v_total := v_total + v_gross;
  END LOOP;

  UPDATE payroll_runs SET total_amount = v_total WHERE id = v_run_id;

  -- Post the wages entry (guarded).
  SELECT id INTO v_acct_wages FROM gl_accounts WHERE org_id = p_org_id AND code = '6000';
  SELECT id INTO v_acct_cash  FROM gl_accounts WHERE org_id = p_org_id AND code = p_paid_account_code;
  IF v_acct_wages IS NOT NULL AND v_acct_cash IS NOT NULL AND v_total > 0 THEN
    INSERT INTO journal_entries (org_id, entry_date, memo, source_type, source_id)
    VALUES (p_org_id, p_to, 'Payroll ' || p_from || ' to ' || p_to, 'payroll', v_run_id)
    RETURNING id INTO v_entry_id;
    INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
    VALUES (v_entry_id, p_org_id, v_acct_wages, v_total, 0, 'Wages & salaries');
    INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
    VALUES (v_entry_id, p_org_id, v_acct_cash, 0, v_total, 'Net pay disbursed');
    UPDATE payroll_runs SET journal_entry_id = v_entry_id WHERE id = v_run_id;
  END IF;

  RETURN v_run_id;
END;
$$;

-- ── RLS — org-scoped ──────────────────────────────────

ALTER TABLE payroll_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE payslips     ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org-scoped access on payroll_runs" ON payroll_runs
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));

CREATE POLICY "Org-scoped access on payslips" ON payslips
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));
