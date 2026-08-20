-- RPC to atomically create an org, link the calling user as admin, and enable default modules
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
  VALUES (v_org_id, 'invoicing', true), (v_org_id, 'attendance', true);

  RETURN v_org_id;
END;
$$;
