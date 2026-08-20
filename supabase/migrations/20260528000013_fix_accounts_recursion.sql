-- Fix infinite recursion on accounts admin policies
-- The previous inline-subquery policies in migration 0010 triggered the
-- accounts SELECT policy, which Postgres flagged as recursive even though
-- user_org_ids() is SECURITY DEFINER. Swap to is_org_admin() (added in 0012),
-- which is SECURITY DEFINER and bypasses RLS cleanly.

DROP POLICY IF EXISTS "Admins can create accounts" ON accounts;
DROP POLICY IF EXISTS "Admins can delete accounts" ON accounts;

CREATE POLICY "Admins can create accounts" ON accounts
  FOR INSERT TO authenticated
  WITH CHECK (is_org_admin(org_id));

CREATE POLICY "Admins can delete accounts" ON accounts
  FOR DELETE TO authenticated
  USING (is_org_admin(org_id));
