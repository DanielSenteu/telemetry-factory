-- Migration 54: restore table privileges the schema has been silently assuming.
--
-- FOUND BY: running `supabase test db` on a freshly built database for the first
-- time. Three separate pgTAP suites failed with "permission denied for table
-- products / stock_movements / machine_readings" — including machine_product_map,
-- which predates today's work.
--
-- THE CAUSE: 26 of the original tables have NO table-level privileges for the
-- `authenticated` role on a fresh database. They never granted any, because when
-- they were written Supabase's images granted CRUD to `authenticated` by default.
-- Newer images do not. Migration 39 spotted this and started granting explicitly
-- ("Older Supabase images granted CRUD to authenticated by default; newer ones
-- don't — so we stop relying on implicit defaults"), and every table since has
-- carried its own GRANT. Everything OLDER was left behind.
--
-- WHY IT MATTERS BEYOND THE TESTS: production works only because it was created
-- back when the implicit default still applied. Any database built from these
-- migrations today — staging, a new client's project, or a disaster-recovery
-- restore following docs/operations.md — comes up with invoicing, inventory, POS,
-- payroll, attendance, accounting and the machine dashboard all failing with
-- permission errors. The runbook's restore procedure would not have worked.
--
-- WHY THIS IS SAFE: verified on the local database before writing this — every
-- table in `public` has RLS ENABLED and at least one policy. GRANT decides
-- whether a role may touch a table at all; RLS decides which rows. Restoring the
-- grants therefore restores the access the app has always had in production
-- without widening any row-level rule by a single row.
--
-- Idempotent, and a no-op on production where these grants already exist.

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- ── service_role: worse, and caught the same way ──────
--
-- ALL 37 tables lack privileges for `service_role` on a fresh database — found
-- when the Zoho sync function returned "permission denied for table
-- integration_connections" against a locally-served edge function.
--
-- This breaks every edge function, not just the new one: ingest-machine-readings
-- (the factory agent's cloud endpoint, which upserts machines and inserts
-- readings) and process-invoice both run as the service role. On a fresh
-- database the factory collector would ship readings into a 500 forever.
--
-- service_role is the trusted backend identity — it is never exposed to a
-- browser, only ever used from an edge function holding the secret key, and
-- Supabase grants it full access to `public` by default. Restoring that is
-- returning to the intended configuration, not loosening anything.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO service_role;

-- `anon` is deliberately excluded: it is the pre-login public key, no policy
-- grants it rows, and it needs no table privileges to sign in.

-- Deliberately NOT setting ALTER DEFAULT PRIVILEGES: new tables should keep
-- granting explicitly, as every migration since 39 has done. Blanket defaults
-- would hide the next omission instead of surfacing it.
