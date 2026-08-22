-- Migration 57: schedule the integration sync — no button, ever.
--
-- pg_cron wakes every 15 minutes and calls the sync edge function once, with
-- the shared cron secret. The function then loops every active connection
-- (incremental, or continuing a backfill) across all orgs. One factory or
-- fifty, one job.
--
-- The function URL and cron secret are read from Vault by NAME, so this
-- migration is portable — set the two secrets per environment (below) and the
-- same migration works on local, staging and prod without edits.

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- run_integration_sync: the body the schedule calls. Reads its coordinates from
-- Vault; if they are not set yet, it no-ops with a notice rather than erroring —
-- so the schedule can exist before the secrets do.
CREATE OR REPLACE FUNCTION run_integration_sync()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, vault, net
AS $$
DECLARE
  v_url    TEXT;
  v_secret TEXT;
BEGIN
  SELECT decrypted_secret INTO v_url    FROM vault.decrypted_secrets WHERE name = 'project_url';
  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'sync_cron_secret';

  IF v_url IS NULL OR v_secret IS NULL THEN
    RAISE NOTICE 'run_integration_sync: project_url / sync_cron_secret not set in Vault — skipping';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url     := v_url || '/functions/v1/sync-zoho-books',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', v_secret),
    body    := '{}'::jsonb   -- no target = all active connections, incremental
  );
END;
$$;

REVOKE ALL ON FUNCTION run_integration_sync() FROM PUBLIC;

-- Reschedule idempotently.
SELECT cron.unschedule('integration-sync') WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'integration-sync'
);
SELECT cron.schedule('integration-sync', '*/15 * * * *', 'SELECT run_integration_sync()');

-- ── Per-environment setup (run once, NOT in this migration) ──────────────────
-- In the Supabase SQL editor for each project:
--   SELECT vault.create_secret('https://<ref>.supabase.co', 'project_url');
--   SELECT vault.create_secret('<the SYNC_CRON_SECRET>',      'sync_cron_secret');
-- The same SYNC_CRON_SECRET must be set as an edge-function secret too.
