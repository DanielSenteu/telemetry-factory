-- Accounting: the double-entry General Ledger (GL) — the financial twin of the
-- inventory ledger added in 0014. Same discipline, applied to money instead of
-- stock:
--
--   gl_accounts    (chart of accounts)  ~ products      (the catalog of buckets)
--   journal_lines  (signed debit/credit) ~ stock_movements (the append-only heart)
--   account_balance VIEW = SUM(debit-credit) ~ product_stock VIEW = SUM(quantity)
--   journal_entries (header, source_type/id) ~ invoices  (what caused the movement)
--
-- Two invariants are enforced in the DATABASE, not the app:
--   1. Every journal entry BALANCES — SUM(debit) = SUM(credit). An unbalanced
--      entry cannot be committed (deferred constraint trigger).
--   2. Posted entries are IMMUTABLE — you never edit/delete a posted line.
--      Corrections are made with a reversing entry. This is what makes the
--      ledger audit-grade and safe to mirror to QuickBooks/Zoho later.
--
-- RLS is org-scoped from line one (user_org_ids(), as in 0010/0016). A financial
-- ledger must NEVER use the permissive USING(true) pattern — cross-org reads of
-- another business's books would be a dealbreaker.

-- ── Layer: chart of accounts (the list of money-buckets) ──────────────

CREATE TABLE gl_accounts (
  id          SERIAL PRIMARY KEY,
  org_id      INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  code        TEXT    NOT NULL,                 -- e.g. '1010' M-Pesa, '4000' Sales
  name        TEXT    NOT NULL,
  type        TEXT    NOT NULL
                CHECK (type IN ('asset','liability','equity','income','expense')),
  -- The side on which this account's balance NORMALLY sits. Assets & expenses
  -- are debit-normal; liabilities, equity & income are credit-normal. Stored
  -- (not computed) so the rare contra-account can override it.
  normal_side TEXT    NOT NULL CHECK (normal_side IN ('debit','credit')),
  -- System accounts are seeded defaults the auto-posting rules rely on
  -- (by code); they cannot be deleted, only deactivated.
  is_system   BOOLEAN NOT NULL DEFAULT false,
  is_active   BOOLEAN NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (org_id, code)
);

CREATE INDEX idx_gl_accounts_org_id ON gl_accounts(org_id);

-- ── The journal: one row per money-event (the header) ─────────────────

CREATE TABLE journal_entries (
  id           SERIAL PRIMARY KEY,
  org_id       INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  entry_date   DATE    NOT NULL,
  memo         TEXT,
  -- What real-world event produced this entry. Mirrors stock_movements'
  -- source_type/source_id so a journal line traces back to its origin.
  source_type  TEXT,                            -- 'invoice' | 'sale' | 'payroll' | 'manual' | ...
  source_id    INTEGER,
  posted       BOOLEAN NOT NULL DEFAULT true,   -- false = draft; true = locked & counted
  -- Links a reversing entry back to the entry it cancels (audit trail).
  reverses_id  INTEGER REFERENCES journal_entries(id),
  -- Connector seam (deferred): once an entry is mirrored to an external system
  -- (QuickBooks/Zoho/Oracle), its id there lands here so we never double-post.
  external_ref TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by   UUID DEFAULT auth.uid()
);

CREATE INDEX idx_journal_entries_org_id      ON journal_entries(org_id);
CREATE INDEX idx_journal_entries_source      ON journal_entries(source_type, source_id);
CREATE INDEX idx_journal_entries_entry_date  ON journal_entries(entry_date);

-- ── The heart: signed debit/credit lines ──────────────────────────────

CREATE TABLE journal_lines (
  id         SERIAL PRIMARY KEY,
  entry_id   INTEGER NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
  -- org_id denormalised from the parent entry so RLS & indexing stay simple
  -- and fast (same choice stock_movements made).
  org_id     INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  account_id INTEGER NOT NULL REFERENCES gl_accounts(id),
  debit      NUMERIC(14,2) NOT NULL DEFAULT 0,
  credit     NUMERIC(14,2) NOT NULL DEFAULT 0,
  line_memo  TEXT,
  -- A line is EITHER a debit OR a credit, never both, never negative.
  CONSTRAINT one_sided_positive
    CHECK (debit >= 0 AND credit >= 0 AND (debit = 0) <> (credit = 0))
);

CREATE INDEX idx_journal_lines_entry_id   ON journal_lines(entry_id);
CREATE INDEX idx_journal_lines_account_id ON journal_lines(account_id);
CREATE INDEX idx_journal_lines_org_id     ON journal_lines(org_id);

-- ── Invariant 1: every entry must balance (deferred to commit) ────────
-- Checked at COMMIT, not per-INSERT, so the RPC can insert the entry's lines
-- one at a time and only the finished, balanced entry is allowed to land.

CREATE OR REPLACE FUNCTION assert_entry_balanced()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_entry  INTEGER := COALESCE(NEW.entry_id, OLD.entry_id);
  v_debit  NUMERIC;
  v_credit NUMERIC;
BEGIN
  SELECT COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0)
    INTO v_debit, v_credit
    FROM journal_lines
   WHERE entry_id = v_entry;

  -- An entry with no lines (e.g. fully deleted) trivially balances at 0 = 0.
  IF v_debit <> v_credit THEN
    RAISE EXCEPTION
      'Journal entry % is unbalanced: debit % <> credit %',
      v_entry, v_debit, v_credit;
  END IF;
  RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_journal_lines_balanced
  AFTER INSERT OR UPDATE OR DELETE ON journal_lines
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION assert_entry_balanced();

-- ── Invariant 2: posted entries are immutable ─────────────────────────
-- Once posted, a line cannot be changed or removed, and the entry's financial
-- fields are frozen (only the connector's external_ref may be filled in later).

CREATE OR REPLACE FUNCTION guard_posted_lines()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_posted BOOLEAN;
BEGIN
  SELECT posted INTO v_posted
    FROM journal_entries
   WHERE id = COALESCE(OLD.entry_id, NEW.entry_id);

  IF v_posted THEN
    RAISE EXCEPTION
      'Posted journal lines are immutable (entry %). Reverse the entry instead.',
      COALESCE(OLD.entry_id, NEW.entry_id);
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_journal_lines_immutable
  BEFORE UPDATE OR DELETE ON journal_lines
  FOR EACH ROW EXECUTE FUNCTION guard_posted_lines();

CREATE OR REPLACE FUNCTION guard_posted_entries()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.posted THEN
      RAISE EXCEPTION 'Posted journal entries cannot be deleted (entry %). Reverse it instead.', OLD.id;
    END IF;
    RETURN OLD;
  END IF;

  -- UPDATE: once posted, freeze the financial fields. Allow only external_ref
  -- (connector mirroring) and reverses_id to be set afterwards.
  IF OLD.posted THEN
    IF NEW.entry_date  IS DISTINCT FROM OLD.entry_date
       OR NEW.memo        IS DISTINCT FROM OLD.memo
       OR NEW.source_type IS DISTINCT FROM OLD.source_type
       OR NEW.source_id   IS DISTINCT FROM OLD.source_id
       OR NEW.org_id      IS DISTINCT FROM OLD.org_id
       OR NEW.posted = false THEN
      RAISE EXCEPTION 'Posted journal entry % is immutable; reverse it instead of editing.', OLD.id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_journal_entries_immutable
  BEFORE UPDATE OR DELETE ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION guard_posted_entries();

-- ── Derived balances: the trial balance, never a stored number ────────
-- Only POSTED entries count. Balance is expressed on the account's normal
-- side, so a positive number always means "normal" (cash up, sales up, etc.).

CREATE VIEW account_balance AS
SELECT
  a.id        AS account_id,
  a.org_id,
  a.code,
  a.name,
  a.type,
  a.normal_side,
  a.is_active,
  COALESCE(SUM(l.debit)  FILTER (WHERE e.posted), 0) AS total_debit,
  COALESCE(SUM(l.credit) FILTER (WHERE e.posted), 0) AS total_credit,
  CASE WHEN a.normal_side = 'debit'
       THEN COALESCE(SUM(l.debit  - l.credit) FILTER (WHERE e.posted), 0)
       ELSE COALESCE(SUM(l.credit - l.debit) FILTER (WHERE e.posted), 0)
  END AS balance
FROM gl_accounts a
LEFT JOIN journal_lines   l ON l.account_id = a.id
LEFT JOIN journal_entries e ON e.id = l.entry_id
GROUP BY a.id;

-- Honour the caller's RLS (don't leak other orgs' books through the view).
ALTER VIEW account_balance SET (security_invoker = true);

-- ── post_journal_entry: the one way to write to the ledger ────────────
-- Runs as the caller, so RLS scopes every insert to the user's org. Accepts a
-- balanced set of lines and writes the entry atomically. Each line references
-- its account by id OR by code (code is what the auto-posting rules use):
--   p_lines = [{ "account_code": "1010", "debit": 50, "credit": 0, "memo": "" }, ...]

CREATE OR REPLACE FUNCTION post_journal_entry(
  p_org_id      INTEGER,
  p_entry_date  DATE,
  p_memo        TEXT,
  p_source_type TEXT,
  p_source_id   INTEGER,
  p_lines       JSONB
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_entry_id   INTEGER;
  v_line       JSONB;
  v_account_id INTEGER;
  v_code       TEXT;
  v_debit      NUMERIC;
  v_credit     NUMERIC;
  v_sum_debit  NUMERIC := 0;
  v_sum_credit NUMERIC := 0;
BEGIN
  IF jsonb_array_length(p_lines) < 2 THEN
    RAISE EXCEPTION 'A journal entry needs at least two lines (a debit and a credit).';
  END IF;

  INSERT INTO journal_entries (org_id, entry_date, memo, source_type, source_id)
  VALUES (p_org_id, p_entry_date, p_memo, p_source_type, p_source_id)
  RETURNING id INTO v_entry_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_debit  := COALESCE(NULLIF(v_line->>'debit',  '')::NUMERIC, 0);
    v_credit := COALESCE(NULLIF(v_line->>'credit', '')::NUMERIC, 0);

    -- Resolve account by explicit id, else by code within this org.
    v_account_id := NULLIF(v_line->>'account_id', '')::INTEGER;
    IF v_account_id IS NULL THEN
      v_code := v_line->>'account_code';
      SELECT id INTO v_account_id
        FROM gl_accounts
       WHERE org_id = p_org_id AND code = v_code;
      IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'No GL account with code % in org %', v_code, p_org_id;
      END IF;
    END IF;

    INSERT INTO journal_lines (entry_id, org_id, account_id, debit, credit, line_memo)
    VALUES (v_entry_id, p_org_id, v_account_id, v_debit, v_credit, v_line->>'memo');

    v_sum_debit  := v_sum_debit  + v_debit;
    v_sum_credit := v_sum_credit + v_credit;
  END LOOP;

  -- Friendly error before the deferred trigger fires at COMMIT.
  IF v_sum_debit <> v_sum_credit THEN
    RAISE EXCEPTION 'Entry does not balance: debit % <> credit %', v_sum_debit, v_sum_credit;
  END IF;

  RETURN v_entry_id;
END;
$$;

-- ── seed_default_gl_accounts: a sensible Kenya-SMB chart of accounts ───
-- Idempotent: safe to call again; existing codes are left untouched. Call this
-- when a new org is created (and below, once, for the existing Default Company).

CREATE OR REPLACE FUNCTION seed_default_gl_accounts(p_org_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO gl_accounts (org_id, code, name, type, normal_side, is_system)
  VALUES
    -- Assets (1000s) — what you have / are owed
    (p_org_id, '1000', 'Cash on Hand',          'asset',     'debit',  true),
    (p_org_id, '1010', 'M-Pesa',                 'asset',     'debit',  true),
    (p_org_id, '1020', 'Bank',                   'asset',     'debit',  true),
    (p_org_id, '1100', 'Accounts Receivable',    'asset',     'debit',  true),
    (p_org_id, '1200', 'Inventory',              'asset',     'debit',  true),
    -- Liabilities (2000s) — what you owe
    (p_org_id, '2000', 'Accounts Payable',       'liability', 'credit', true),
    (p_org_id, '2100', 'VAT Payable',            'liability', 'credit', true),
    -- Equity (3000s) — what's truly yours
    (p_org_id, '3000', 'Owner''s Equity',        'equity',    'credit', true),
    (p_org_id, '3900', 'Retained Earnings',      'equity',    'credit', true),
    -- Income (4000s) — money coming in
    (p_org_id, '4000', 'Sales',                  'income',    'credit', true),
    -- Expenses (5000s/6000s) — money going out
    (p_org_id, '5000', 'Cost of Goods Sold',     'expense',   'debit',  true),
    (p_org_id, '6000', 'Wages & Salaries',       'expense',   'debit',  true),
    (p_org_id, '6100', 'Electricity',            'expense',   'debit',  true),
    (p_org_id, '6200', 'Rent',                   'expense',   'debit',  true),
    (p_org_id, '6900', 'General Expenses',       'expense',   'debit',  true)
  ON CONFLICT (org_id, code) DO NOTHING;
END;
$$;

-- Seed the existing Default Company (org 1, created in 0006).
SELECT seed_default_gl_accounts(1);

-- ── RLS — org-scoped, mirroring 0010/0016 exactly ─────────────────────

ALTER TABLE gl_accounts      ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_entries  ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_lines    ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org-scoped access on gl_accounts" ON gl_accounts
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));

CREATE POLICY "Org-scoped access on journal_entries" ON journal_entries
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));

CREATE POLICY "Org-scoped access on journal_lines" ON journal_lines
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));
