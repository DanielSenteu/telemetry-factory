-- Worker auth: link workers to auth.users; scope RLS per role (admin vs worker)

-- ── Add user_id to workers ──────────────────────────
ALTER TABLE workers ADD COLUMN user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;
CREATE INDEX idx_workers_user_id ON workers(user_id);

-- ── Helper: is the calling user an admin of the given org? ──
CREATE OR REPLACE FUNCTION is_org_admin(p_org_id INTEGER)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM accounts
    WHERE user_id = auth.uid()
      AND org_id = p_org_id
      AND role = 'admin'
  );
$$;

-- ── Workers RLS ─────────────────────────────────────
DROP POLICY IF EXISTS "Org-scoped access on workers" ON workers;

CREATE POLICY "Workers visible to admins and self" ON workers
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR is_org_admin(org_id));

CREATE POLICY "Admins insert workers" ON workers
  FOR INSERT TO authenticated
  WITH CHECK (is_org_admin(org_id));

CREATE POLICY "Admins update workers, workers link self" ON workers
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid() OR is_org_admin(org_id))
  WITH CHECK (user_id = auth.uid() OR is_org_admin(org_id));

CREATE POLICY "Admins delete workers" ON workers
  FOR DELETE TO authenticated
  USING (is_org_admin(org_id));

-- ── Timesheet entries RLS ───────────────────────────
DROP POLICY IF EXISTS "Org-scoped access on timesheet_entries" ON timesheet_entries;

CREATE POLICY "Timesheet entries visible to admins and owning worker" ON timesheet_entries
  FOR SELECT TO authenticated
  USING (
    worker_id IN (
      SELECT id FROM workers
      WHERE user_id = auth.uid() OR is_org_admin(org_id)
    )
  );

CREATE POLICY "Workers insert own entries, admins insert any" ON timesheet_entries
  FOR INSERT TO authenticated
  WITH CHECK (
    worker_id IN (
      SELECT id FROM workers
      WHERE user_id = auth.uid() OR is_org_admin(org_id)
    )
  );

CREATE POLICY "Workers update own entries, admins update any" ON timesheet_entries
  FOR UPDATE TO authenticated
  USING (
    worker_id IN (
      SELECT id FROM workers
      WHERE user_id = auth.uid() OR is_org_admin(org_id)
    )
  )
  WITH CHECK (
    worker_id IN (
      SELECT id FROM workers
      WHERE user_id = auth.uid() OR is_org_admin(org_id)
    )
  );

CREATE POLICY "Admins delete entries" ON timesheet_entries
  FOR DELETE TO authenticated
  USING (
    worker_id IN (SELECT id FROM workers WHERE is_org_admin(org_id))
  );

-- ── Workplaces RLS ──────────────────────────────────
DROP POLICY IF EXISTS "Org-scoped access on workplaces" ON workplaces;

CREATE POLICY "Workplaces visible to admins and assigned workers" ON workplaces
  FOR SELECT TO authenticated
  USING (
    is_org_admin(org_id)
    OR id IN (SELECT workplace_id FROM workers WHERE user_id = auth.uid())
  );

CREATE POLICY "Admins insert workplaces" ON workplaces
  FOR INSERT TO authenticated WITH CHECK (is_org_admin(org_id));

CREATE POLICY "Admins update workplaces" ON workplaces
  FOR UPDATE TO authenticated
  USING (is_org_admin(org_id)) WITH CHECK (is_org_admin(org_id));

CREATE POLICY "Admins delete workplaces" ON workplaces
  FOR DELETE TO authenticated USING (is_org_admin(org_id));

-- ── Worker sign-up RPC ──────────────────────────────
-- Mobile flow: worker calls supabase.auth.signUp(email, password); then calls
-- this RPC which finds the pre-created worker row matching their auth email
-- and links it. Email comes from auth.users — never trusted from the client.
CREATE OR REPLACE FUNCTION link_worker_user()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_worker_id INTEGER;
  v_email TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Must be authenticated';
  END IF;

  IF EXISTS (SELECT 1 FROM workers WHERE user_id = auth.uid()) THEN
    RAISE EXCEPTION 'User is already linked to a worker';
  END IF;

  SELECT email INTO v_email FROM auth.users WHERE id = auth.uid();

  UPDATE workers
  SET user_id = auth.uid()
  WHERE email = v_email AND user_id IS NULL
  RETURNING id INTO v_worker_id;

  IF v_worker_id IS NULL THEN
    RAISE EXCEPTION 'No unlinked worker found for your email';
  END IF;

  RETURN v_worker_id;
END;
$$;
