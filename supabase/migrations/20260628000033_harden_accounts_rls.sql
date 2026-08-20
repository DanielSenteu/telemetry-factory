-- Security hardening: lock down the `accounts` table (multi-tenant staff/admin
-- membership). Two real gaps closed here, found in an RLS audit:
--
--  1. ANON COULD READ EVERY ACCOUNT. Migration 9 left `FOR SELECT TO anon
--     USING (true)` on accounts so signup could look up an email pre-login. But
--     the public anon key ships in the web app, so anyone could dump every org's
--     staff emails, roles and user ids. Removed — signup now claims via an RPC.
--
--  2. ACCOUNT-CLAIM / ROLE-CHANGE WAS TOO OPEN. The UPDATE policy
--     `USING (user_id = auth.uid() OR user_id IS NULL) WITH CHECK (true)` let ANY
--     authenticated user (workers authenticate too) claim ANY unclaimed
--     account — including an admin row in another org — and the
--     WITH CHECK (true) let a user rewrite their own role/org. Replaced with an
--     admin-only UPDATE, and a SECURITY DEFINER claim_account() that only ever
--     links an account whose email matches the caller's own verified email
--     (mirrors link_worker_user() for the mobile side).

-- 1. Remove the blanket anon read.
DROP POLICY IF EXISTS "Anon read access on accounts" ON accounts;

-- 2. Replace the permissive self-update with admin-only updates.
DROP POLICY IF EXISTS "Users can update own account" ON accounts;

CREATE POLICY "Admins manage accounts in their org" ON accounts
  FOR UPDATE TO authenticated
  USING (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

-- 3. Safe account claiming. Runs AFTER signup (authenticated). Links every
-- unclaimed account whose email equals the caller's verified auth email — no
-- client-supplied id, no cross-email/cross-org claiming possible. Returns how
-- many accounts were linked (0 is fine if already linked from a prior run).
CREATE OR REPLACE FUNCTION claim_account()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email TEXT;
  v_count INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Must be authenticated';
  END IF;

  SELECT email INTO v_email FROM auth.users WHERE id = auth.uid();

  UPDATE accounts
  SET user_id = auth.uid()
  WHERE lower(email) = lower(v_email)
    AND user_id IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  IF v_count = 0 AND NOT EXISTS (SELECT 1 FROM accounts WHERE user_id = auth.uid()) THEN
    RAISE EXCEPTION 'No account found for your email. Contact your administrator.';
  END IF;

  RETURN v_count;
END;
$$;
