-- Machine integration Phase 1 (shadow mode): factory agents, machines, raw
-- readings feed, and the delta view. Design: docs/erp-roadmap-2026-07.md §1.
--
-- Data path: on-prem agent (apps/factory-agent) → edge function
-- `ingest-machine-readings` (service role, dedupes) → machine_readings.
-- No client ever writes these tables directly; org members read them.
-- Zero ledger writes in this phase.

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ── factory_agents: one row per on-prem collector box ──────────────────────
-- The agent authenticates with a bearer token; we store only its SHA-256 hash.
-- token→org binding is what makes multi-org safe: an agent can only ever
-- write machines/readings into its own org.

CREATE TABLE factory_agents (
  id           SERIAL PRIMARY KEY,
  org_id       INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  token_hash   TEXT NOT NULL UNIQUE,
  last_seen_at TIMESTAMPTZ,
  active       BOOLEAN NOT NULL DEFAULT true,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE factory_agents ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org members view factory agents" ON factory_agents
  FOR SELECT TO authenticated
  USING (org_id IN (SELECT user_org_ids()));

CREATE POLICY "Admins manage factory agents" ON factory_agents
  FOR ALL TO authenticated
  USING (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

-- Mint a token for a new agent. Returns the PLAINTEXT token exactly once —
-- it is never stored or shown again (only the hash is kept).
CREATE OR REPLACE FUNCTION create_factory_agent(p_org_id INTEGER, p_name TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_token TEXT;
BEGIN
  IF NOT is_org_admin(p_org_id) THEN
    RAISE EXCEPTION 'Only org admins can create factory agents';
  END IF;

  v_token := 'fa_' || encode(extensions.gen_random_bytes(32), 'hex');

  INSERT INTO factory_agents (org_id, name, token_hash)
  VALUES (p_org_id, p_name, encode(extensions.digest(v_token, 'sha256'), 'hex'));

  RETURN v_token;
END;
$$;

-- ── machines: registry, keyed by controller MAC within an org ──────────────
-- (Roadmap says "mac UNIQUE"; scoped per-org here so a resold/moved machine
-- can exist in two orgs' histories without a collision.)

CREATE TABLE machines (
  id                SERIAL PRIMARY KEY,
  org_id            INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name              TEXT NOT NULL,
  mac               TEXT NOT NULL,
  ip                TEXT,
  controller_series TEXT,
  active            BOOLEAN NOT NULL DEFAULT true,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (org_id, mac)
);

ALTER TABLE machines ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org members view machines" ON machines
  FOR SELECT TO authenticated
  USING (org_id IN (SELECT user_org_ids()));

-- rename / deactivate / link to workplace later; ingestion inserts via service role
CREATE POLICY "Admins update machines" ON machines
  FOR UPDATE TO authenticated
  USING (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

-- ── machine_readings: append-only raw feed ─────────────────────────────────
-- observed_at = agent clock (NTP), received_at = server clock. Sentinels are
-- already NULLed by the agent. UNIQUE(machine_id, observed_at) is the
-- idempotency key that makes at-least-once delivery safe.

CREATE TABLE machine_readings (
  id             BIGSERIAL PRIMARY KEY,
  org_id         INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  machine_id     INTEGER NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
  observed_at    TIMESTAMPTZ NOT NULL,
  received_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  online_state   SMALLINT,
  shot_count     BIGINT,
  inferior_count DOUBLE PRECISION,
  operate_mode   SMALLINT,
  motor_state    SMALLINT,
  heat_state     SMALLINT,
  cycle_time     DOUBLE PRECISION,
  craft_id       TEXT,
  material       TEXT,
  mold_cavity    SMALLINT,
  plan_count     BIGINT,
  power_kwh      DOUBLE PRECISION,
  alarms         JSONB,
  UNIQUE (machine_id, observed_at)
);

-- dashboard reads: latest N per machine, org-wide "today" windows
CREATE INDEX idx_machine_readings_machine_time
  ON machine_readings (machine_id, observed_at DESC);
CREATE INDEX idx_machine_readings_org_time
  ON machine_readings (org_id, observed_at DESC);

ALTER TABLE machine_readings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org members view machine readings" ON machine_readings
  FOR SELECT TO authenticated
  USING (org_id IN (SELECT user_org_ids()));

-- No INSERT/UPDATE/DELETE policies on purpose: only the ingestion edge
-- function (service role, bypasses RLS) writes; the feed is append-only.

-- ── machine_deltas: reset-aware production deltas per reading ──────────────
-- Counters are cumulative and reset on reboot/job change. delta < 0 ⇒ reset:
-- the new value IS the production since reset (matches agent-side deltas.ts).
-- Good parts ≈ shots_delta × mold_cavity − scrap_delta (rolled up in Phase 2).

CREATE VIEW machine_deltas WITH (security_invoker = true) AS
SELECT
  r.*,
  CASE
    WHEN r.shot_count IS NULL OR r.prev_shot IS NULL THEN NULL
    WHEN r.shot_count < r.prev_shot THEN r.shot_count
    ELSE r.shot_count - r.prev_shot
  END AS shots_delta,
  CASE
    WHEN r.inferior_count IS NULL OR r.prev_inferior IS NULL THEN NULL
    WHEN r.inferior_count < r.prev_inferior THEN r.inferior_count
    ELSE r.inferior_count - r.prev_inferior
  END AS scrap_delta,
  (r.shot_count IS NOT NULL AND r.prev_shot IS NOT NULL
    AND r.shot_count < r.prev_shot) AS counter_reset
FROM (
  SELECT
    mr.*,
    lag(mr.shot_count)     OVER w AS prev_shot,
    lag(mr.inferior_count) OVER w AS prev_inferior
  FROM machine_readings mr
  WINDOW w AS (PARTITION BY mr.machine_id ORDER BY mr.observed_at)
) r;
