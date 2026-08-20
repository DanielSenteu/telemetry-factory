-- Tighten RLS: scope all data access to the user's org(s)

-- ── Helper function ────────────────────────────────────
CREATE OR REPLACE FUNCTION user_org_ids()
RETURNS SETOF INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT org_id FROM accounts WHERE user_id = auth.uid();
$$;

-- ── Organizations ──────────────────────────────────────
DROP POLICY "Authenticated access on organizations" ON organizations;

CREATE POLICY "Users can view their orgs" ON organizations
  FOR SELECT TO authenticated
  USING (id IN (SELECT user_org_ids()));

CREATE POLICY "Users can update their orgs" ON organizations
  FOR UPDATE TO authenticated
  USING (id IN (SELECT user_org_ids()))
  WITH CHECK (id IN (SELECT user_org_ids()));

CREATE POLICY "Authenticated can insert orgs" ON organizations
  FOR INSERT TO authenticated
  WITH CHECK (true);

CREATE POLICY "Admins can delete their orgs" ON organizations
  FOR DELETE TO authenticated
  USING (
    id IN (
      SELECT org_id FROM accounts
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  );

-- ── Accounts ───────────────────────────────────────────
DROP POLICY "Authenticated access on accounts" ON accounts;

CREATE POLICY "Users can view accounts in their org" ON accounts
  FOR SELECT TO authenticated
  USING (org_id IN (SELECT user_org_ids()));

CREATE POLICY "Admins can create accounts" ON accounts
  FOR INSERT TO authenticated
  WITH CHECK (
    org_id IN (
      SELECT org_id FROM accounts
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  );

CREATE POLICY "Admins can delete accounts" ON accounts
  FOR DELETE TO authenticated
  USING (
    org_id IN (
      SELECT org_id FROM accounts
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  );

CREATE POLICY "Users can update own account" ON accounts
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid() OR user_id IS NULL)
  WITH CHECK (true);

-- Keep existing anon SELECT policy from migration 0009

-- ── Invoices ───────────────────────────────────────────
DROP POLICY "Authenticated access on invoices" ON invoices;

CREATE POLICY "Org-scoped access on invoices" ON invoices
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));

-- ── Line items ─────────────────────────────────────────
DROP POLICY "Authenticated access on line_items" ON line_items;

CREATE POLICY "Org-scoped access on line_items" ON line_items
  FOR ALL TO authenticated
  USING (
    invoice_id IN (
      SELECT id FROM invoices WHERE org_id IN (SELECT user_org_ids())
    )
  )
  WITH CHECK (
    invoice_id IN (
      SELECT id FROM invoices WHERE org_id IN (SELECT user_org_ids())
    )
  );

-- ── Workplaces ─────────────────────────────────────────
DROP POLICY "Authenticated access on workplaces" ON workplaces;

CREATE POLICY "Org-scoped access on workplaces" ON workplaces
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));

-- ── Workers ────────────────────────────────────────────
DROP POLICY "Authenticated access on workers" ON workers;

CREATE POLICY "Org-scoped access on workers" ON workers
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));

-- ── Timesheet entries ──────────────────────────────────
DROP POLICY "Authenticated access on timesheet_entries" ON timesheet_entries;

CREATE POLICY "Org-scoped access on timesheet_entries" ON timesheet_entries
  FOR ALL TO authenticated
  USING (
    worker_id IN (
      SELECT id FROM workers WHERE org_id IN (SELECT user_org_ids())
    )
  )
  WITH CHECK (
    worker_id IN (
      SELECT id FROM workers WHERE org_id IN (SELECT user_org_ids())
    )
  );

-- ── Org modules ────────────────────────────────────────
DROP POLICY "Authenticated access on org_modules" ON org_modules;

CREATE POLICY "Org-scoped access on org_modules" ON org_modules
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));
