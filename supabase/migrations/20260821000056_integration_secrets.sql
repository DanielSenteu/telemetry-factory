-- Migration 56: integration secrets in Vault + connection columns for OAuth sync.
--
-- Refresh tokens are the permanent keys to a customer's outside system. They
-- must NEVER be readable by the app, an admin browsing the DB, or the anon
-- role — only by the sync job (service role). Supabase Vault gives us exactly
-- that: encrypted at rest, decrypted only on explicit read by a privileged role.
--
-- integration_connections keeps the NON-secret coordinates and a POINTER
-- (secret_id) to the Vault entry — never the token itself.

-- Columns the OAuth + cron flow needs on the existing connections table.
ALTER TABLE integration_connections
  ADD COLUMN IF NOT EXISTS secret_id     UUID,        -- → vault.secrets(id), the refresh token
  ADD COLUMN IF NOT EXISTS backfill_done BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS connected_by  UUID DEFAULT auth.uid(),
  ADD COLUMN IF NOT EXISTS connected_at  TIMESTAMPTZ;

-- ── store_integration_secret ──────────────────────────
-- Write-only from the app's perspective: an org admin can STORE a refresh
-- token (during connect), but the function returns only the secret's UUID —
-- never lets anything read the value back. SECURITY DEFINER so the admin needs
-- no direct Vault grants. Re-storing rotates in place (reconnect flow).
CREATE OR REPLACE FUNCTION store_integration_secret(
  p_connection_id INTEGER,
  p_token         TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, vault
AS $$
DECLARE
  v_org      INTEGER;
  v_existing UUID;
  v_name     TEXT;
BEGIN
  SELECT org_id, secret_id INTO v_org, v_existing
    FROM integration_connections WHERE id = p_connection_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'Connection % not found', p_connection_id;
  END IF;
  IF NOT is_org_admin(v_org) THEN
    RAISE EXCEPTION 'Only org admins can store integration secrets';
  END IF;

  v_name := 'integration_refresh_token_' || p_connection_id;

  IF v_existing IS NULL THEN
    v_existing := vault.create_secret(p_token, v_name, 'refresh token for connection ' || p_connection_id);
    UPDATE integration_connections SET secret_id = v_existing WHERE id = p_connection_id;
  ELSE
    PERFORM vault.update_secret(v_existing, p_token);  -- rotate in place
  END IF;

  RETURN v_existing;  -- the POINTER, never the token
END;
$$;

REVOKE ALL ON FUNCTION store_integration_secret(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION store_integration_secret(INTEGER, TEXT) TO authenticated;

-- ── read_integration_secret ───────────────────────────
-- The ONLY way to get a token back, and it is granted to service_role ONLY —
-- the sync edge function's identity, never a browser. authenticated cannot
-- execute this at all.
CREATE OR REPLACE FUNCTION read_integration_secret(p_connection_id INTEGER)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, vault
AS $$
DECLARE
  v_secret_id UUID;
  v_token     TEXT;
BEGIN
  SELECT secret_id INTO v_secret_id FROM integration_connections WHERE id = p_connection_id;
  IF v_secret_id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT decrypted_secret INTO v_token
    FROM vault.decrypted_secrets WHERE id = v_secret_id;
  RETURN v_token;
END;
$$;

REVOKE ALL ON FUNCTION read_integration_secret(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_integration_secret(INTEGER) TO service_role;

-- ── upsert_integration_connection ─────────────────────
-- Admin-only. Creates (or updates) the connection row during connect, before
-- the token is stored. Returns the connection id so the callback can then call
-- store_integration_secret. Cutover defaults to the connect day: history
-- imports records-only for demand; stock starts clean from today.
CREATE OR REPLACE FUNCTION upsert_integration_connection(
  p_org_id         INTEGER,
  p_provider       TEXT,
  p_external_org_id TEXT,
  p_config         JSONB DEFAULT '{}'::JSONB,
  p_cutover        DATE  DEFAULT NULL
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id INTEGER;
BEGIN
  IF NOT is_org_admin(p_org_id) THEN
    RAISE EXCEPTION 'Only org admins can connect integrations';
  END IF;

  INSERT INTO integration_connections
    (org_id, provider, external_org_id, config, stock_cutover_date, active, connected_by, connected_at)
  VALUES
    (p_org_id, p_provider, p_external_org_id, COALESCE(p_config, '{}'::JSONB),
     COALESCE(p_cutover, CURRENT_DATE), true, auth.uid(), now())
  ON CONFLICT (org_id, provider) DO UPDATE SET
    external_org_id = EXCLUDED.external_org_id,
    config          = integration_connections.config || EXCLUDED.config,
    active          = true,
    connected_by    = auth.uid(),
    connected_at    = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION upsert_integration_connection(INTEGER, TEXT, TEXT, JSONB, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_integration_connection(INTEGER, TEXT, TEXT, JSONB, DATE) TO authenticated;

-- Status view for the Sales tab — safe columns only, never the secret pointer.
CREATE OR REPLACE VIEW integration_status WITH (security_invoker = true) AS
SELECT
  c.id, c.org_id, c.provider, c.external_org_id, c.stock_cutover_date,
  c.active, c.backfill_done, c.last_sync_at, c.last_sync_status, c.last_sync_error,
  c.connected_at,
  (c.secret_id IS NOT NULL) AS has_token
FROM integration_connections c;

GRANT SELECT ON integration_status TO authenticated;
