-- Financial reports (P&L + Balance Sheet) need DATE-AWARE balances. The
-- account_balance view (0017) sums ALL posted history with no period, which is
-- right for the chart-of-accounts screen but wrong for statements:
--   * Income Statement (P&L) measures a PERIOD          -> activity from..to
--   * Balance Sheet is a SNAPSHOT at a point in time    -> inception..as_of
--
-- account_activity returns per-account debit/credit/balance over an optional
-- range (p_from NULL = since inception). Only POSTED entries count, mirroring
-- account_balance. The statements themselves are shaped in the app from these
-- rows (Revenue→Gross→Net for P&L; Assets = Liabilities + Equity for the BS,
-- with current-period earnings computed as income − expenses — no closing entry
-- required). Runs as the caller, so RLS scopes every read to the user's org.

CREATE OR REPLACE FUNCTION account_activity(
  p_org_id INTEGER,
  p_from   DATE,
  p_to     DATE
)
RETURNS TABLE (
  account_id   INTEGER,
  code         TEXT,
  name         TEXT,
  type         TEXT,
  normal_side  TEXT,
  total_debit  NUMERIC,
  total_credit NUMERIC,
  balance      NUMERIC
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    a.id,
    a.code,
    a.name,
    a.type,
    a.normal_side,
    COALESCE(t.total_debit, 0)  AS total_debit,
    COALESCE(t.total_credit, 0) AS total_credit,
    -- Balance expressed on the account's normal side (positive = "normal").
    CASE WHEN a.normal_side = 'debit'
         THEN COALESCE(t.total_debit - t.total_credit, 0)
         ELSE COALESCE(t.total_credit - t.total_debit, 0)
    END AS balance
  FROM gl_accounts a
  -- Aggregate matching lines in a subquery so that lines OUTSIDE the date range
  -- (or in unposted entries) contribute nothing — a LEFT JOIN with the filters
  -- in the ON clause would still let those lines' amounts leak into the SUM.
  LEFT JOIN (
    SELECT jl.account_id,
           SUM(jl.debit)  AS total_debit,
           SUM(jl.credit) AS total_credit
    FROM journal_lines jl
    JOIN journal_entries je ON je.id = jl.entry_id
    WHERE jl.org_id = p_org_id
      AND je.posted
      AND (p_from IS NULL OR je.entry_date >= p_from)
      AND je.entry_date <= p_to
    GROUP BY jl.account_id
  ) t ON t.account_id = a.id
  WHERE a.org_id = p_org_id
  ORDER BY a.code;
$$;
