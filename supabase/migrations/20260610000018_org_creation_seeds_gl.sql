-- When a new organization is created, give it the default chart of accounts
-- (seed_default_gl_accounts, added in 0017) and turn the 'accounting' module on
-- alongside the existing 'invoicing' and 'attendance' defaults. Existing orgs
-- were seeded directly in 0017.

CREATE OR REPLACE FUNCTION create_org_with_account(p_name TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org_id INTEGER;
BEGIN
  INSERT INTO organizations (name) VALUES (p_name) RETURNING id INTO v_org_id;

  INSERT INTO accounts (org_id, email, role, user_id)
  VALUES (
    v_org_id,
    (SELECT email FROM auth.users WHERE id = auth.uid()),
    'admin',
    auth.uid()
  );

  INSERT INTO org_modules (org_id, module_key, enabled)
  VALUES (v_org_id, 'invoicing', true),
         (v_org_id, 'attendance', true),
         (v_org_id, 'accounting', true);

  -- Every new org starts with a usable Kenya-SMB chart of accounts.
  PERFORM seed_default_gl_accounts(v_org_id);

  RETURN v_org_id;
END;
$$;

-- Make sure the existing Default Company (org 1) also has the module flag.
INSERT INTO org_modules (org_id, module_key, enabled)
VALUES (1, 'accounting', true)
ON CONFLICT (org_id, module_key) DO NOTHING;
