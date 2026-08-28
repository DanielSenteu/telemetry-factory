-- Migration 60: machine_day_production — interpret each reading once, at write time
--
-- Migration 59 made the dashboard's delta math correct, but it still re-derives
-- history on every load: "yesterday" re-scans thousands of raw readings per
-- machine, per refresh, forever. This migration moves the interpretation to
-- ingestion: a trigger on machine_readings credits each reading's guarded
-- delta to a per-machine, per-Nairobi-day rollup, and the dashboard reads
-- finished numbers. Same cost at 3 machines or 3,000.
--
-- This table is a REBUILDABLE ROLLUP, not a ledger of record (rule 3 applies
-- to stock/financial ledgers): machine_readings stays the untouched source of
-- truth, and rebuild_machine_day_production() re-derives the rollup from it —
-- so an improved classification rule can be applied to all history at any time.
--
-- The physics guard (one shot per cycle_time seconds, 2x slack + 3-shot floor,
-- 1 s/shot backstop for boot readings) is identical to migration 59 — see that
-- migration for the 2026-08-26 power-cut incident that motivated it.
--
-- Day boundary is Africa/Nairobi — a decision, not a default (rule 6). EAT has
-- no DST, so the boundary is stable at 21:00 UTC.

-- ── The rollup table ──────────────────────────────────────────────────────────

CREATE TABLE machine_day_production (
  org_id      INTEGER NOT NULL REFERENCES organizations(id),
  machine_id  INTEGER NOT NULL REFERENCES machines(id),
  day         DATE    NOT NULL,          -- Nairobi day of the credited readings
  shots       BIGINT  NOT NULL DEFAULT 0,
  scrap       DOUBLE PRECISION NOT NULL DEFAULT 0,
  parts_gross BIGINT  NOT NULL DEFAULT 0,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (machine_id, day)
);

CREATE INDEX machine_day_production_org_day_idx ON machine_day_production (org_id, day);

ALTER TABLE machine_day_production ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org members view day production" ON machine_day_production
  FOR SELECT TO authenticated
  USING (org_id IN (SELECT user_org_ids()));

-- Writes happen only via the SECURITY DEFINER trigger/rebuild functions.
GRANT SELECT ON machine_day_production TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON machine_day_production TO service_role;

-- ── The physics guard, shared by trigger, rebuild and snapshot ────────────────

-- Counted delta between two counter readings, or 0 when the jump could not
-- physically be production (counter re-sync after a power cut). A decrease is
-- a counter reset: the new value is the production since the reset.
CREATE OR REPLACE FUNCTION machine_counted_delta(
  p_prev      DOUBLE PRECISION,
  p_new       DOUBLE PRECISION,
  p_elapsed_s DOUBLE PRECISION,
  p_cycle     DOUBLE PRECISION
) RETURNS DOUBLE PRECISION
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_prev IS NULL OR p_new IS NULL THEN 0
    WHEN raw.v > p_elapsed_s / GREATEST(COALESCE(NULLIF(p_cycle, 0), 1), 1) * 2 + 3 THEN 0
    ELSE raw.v
  END
  FROM (SELECT CASE WHEN p_new < p_prev THEN p_new ELSE p_new - p_prev END AS v) raw;
$$;

GRANT EXECUTE ON FUNCTION machine_counted_delta(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION)
  TO authenticated, service_role;

-- ── Ingestion trigger ─────────────────────────────────────────────────────────

-- Statement-level, not row-level: the collector batch-inserts readings, and a
-- row trigger already sees its own batch-mates in the table, which double-
-- credits deltas. Instead, each insert statement RECOMPUTES the touched
-- (machine, Nairobi-day) totals from raw readings — written as absolute
-- values, not increments. Single rows, batches, out-of-order arrivals and
-- replays all converge to the same rollup (rule 4: run twice = run once).
--
-- A day's first delta is computed against the last reading of the previous
-- day (the seed), so a reading that lands as another day's seed recomputes
-- that following day too when it already has readings.
CREATE OR REPLACE FUNCTION machine_readings_accrue() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  a RECORD;
  day_start TIMESTAMPTZ;
  day_end   TIMESTAMPTZ;
BEGIN
  FOR a IN
    SELECT DISTINCT nr.machine_id, nr.org_id,
      (nr.observed_at AT TIME ZONE 'Africa/Nairobi')::date AS day
    FROM newrows nr
    UNION
    -- The Nairobi day after each new reading, when it already has readings:
    -- the new reading may now be that day's seed.
    SELECT DISTINCT nr.machine_id, nr.org_id,
      (nr.observed_at AT TIME ZONE 'Africa/Nairobi')::date + 1 AS day
    FROM newrows nr
    WHERE EXISTS (
      SELECT 1 FROM machine_readings r
      WHERE r.machine_id = nr.machine_id
        AND r.observed_at >= ((nr.observed_at AT TIME ZONE 'Africa/Nairobi')::date + 1)::timestamp
                             AT TIME ZONE 'Africa/Nairobi'
        AND r.observed_at <  ((nr.observed_at AT TIME ZONE 'Africa/Nairobi')::date + 2)::timestamp
                             AT TIME ZONE 'Africa/Nairobi'
    )
  LOOP
    day_start := a.day::timestamp       AT TIME ZONE 'Africa/Nairobi';
    day_end   := (a.day + 1)::timestamp AT TIME ZONE 'Africa/Nairobi';

    INSERT INTO machine_day_production AS mdp (org_id, machine_id, day, shots, scrap, parts_gross)
    SELECT a.org_id, a.machine_id, a.day,
      COALESCE(SUM(d.shots_delta), 0)::bigint,
      COALESCE(SUM(d.scrap_delta), 0),
      COALESCE(SUM(d.shots_delta * COALESCE(d.mold_cavity, 1)), 0)::bigint
    FROM (
      SELECT w.observed_at, w.mold_cavity,
        machine_counted_delta(
          lag(w.shot_count) OVER mw, w.shot_count,
          extract(epoch FROM w.observed_at - lag(w.observed_at) OVER mw),
          w.cycle_time) AS shots_delta,
        machine_counted_delta(
          lag(w.inferior_count) OVER mw, w.inferior_count,
          extract(epoch FROM w.observed_at - lag(w.observed_at) OVER mw),
          w.cycle_time) AS scrap_delta
      FROM (
        SELECT r.observed_at, r.shot_count, r.inferior_count, r.mold_cavity, r.cycle_time
        FROM machine_readings r
        WHERE r.machine_id = a.machine_id
          AND r.observed_at >= day_start AND r.observed_at < day_end
        UNION ALL
        SELECT s.observed_at, s.shot_count, s.inferior_count, s.mold_cavity, s.cycle_time
        FROM (
          SELECT r.observed_at, r.shot_count, r.inferior_count, r.mold_cavity, r.cycle_time
          FROM machine_readings r
          WHERE r.machine_id = a.machine_id AND r.observed_at < day_start
          ORDER BY r.observed_at DESC LIMIT 1
        ) s
      ) w
      WINDOW mw AS (ORDER BY w.observed_at)
    ) d
    WHERE d.observed_at >= day_start
    ON CONFLICT (machine_id, day) DO UPDATE SET
      shots       = EXCLUDED.shots,
      scrap       = EXCLUDED.scrap,
      parts_gross = EXCLUDED.parts_gross,
      updated_at  = now();
  END LOOP;

  RETURN NULL;
END;
$$;

CREATE TRIGGER machine_readings_accrue_trg
  AFTER INSERT ON machine_readings
  REFERENCING NEW TABLE AS newrows
  FOR EACH STATEMENT EXECUTE FUNCTION machine_readings_accrue();

-- ── Rebuild from source of truth ──────────────────────────────────────────────

-- Re-derives the rollup from raw readings (one machine, or all when NULL).
-- The escape hatch: run after changing the classification rule, or on any
-- suspicion of drift. Run twice = run once (rule 4).
CREATE OR REPLACE FUNCTION rebuild_machine_day_production(p_machine_id INTEGER DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM machine_day_production
  WHERE p_machine_id IS NULL OR machine_id = p_machine_id;

  INSERT INTO machine_day_production (org_id, machine_id, day, shots, scrap, parts_gross)
  SELECT d.org_id, d.machine_id, d.day,
    COALESCE(SUM(d.shots_delta), 0)::bigint,
    COALESCE(SUM(d.scrap_delta), 0),
    COALESCE(SUM(d.shots_delta * COALESCE(d.mold_cavity, 1)), 0)::bigint
  FROM (
    SELECT r.org_id, r.machine_id,
      (r.observed_at AT TIME ZONE 'Africa/Nairobi')::date AS day,
      r.mold_cavity,
      machine_counted_delta(
        lag(r.shot_count) OVER mw, r.shot_count,
        extract(epoch FROM r.observed_at - lag(r.observed_at) OVER mw),
        r.cycle_time) AS shots_delta,
      machine_counted_delta(
        lag(r.inferior_count) OVER mw, r.inferior_count,
        extract(epoch FROM r.observed_at - lag(r.observed_at) OVER mw),
        r.cycle_time) AS scrap_delta
    FROM machine_readings r
    WHERE p_machine_id IS NULL OR r.machine_id = p_machine_id
    WINDOW mw AS (PARTITION BY r.machine_id ORDER BY r.observed_at)
  ) d
  GROUP BY d.org_id, d.machine_id, d.day;
END;
$$;

GRANT EXECUTE ON FUNCTION rebuild_machine_day_production(INTEGER) TO service_role;

-- Backfill all history now.
SELECT rebuild_machine_day_production();

-- ── Dashboard reads the rollup ────────────────────────────────────────────────

-- Same signature and columns; the period sums now come from the rollup instead
-- of re-deriving deltas over raw readings. The range is interpreted as whole
-- Nairobi days (the app only ever sends day-aligned ranges). recent_shots (the
-- "is it moving right now" signal) still reads the last few minutes of raw
-- readings — that window is tiny and inherently live.
CREATE OR REPLACE FUNCTION machine_dashboard_snapshot(
  p_org_id INTEGER,
  p_since  TIMESTAMPTZ,
  p_until  TIMESTAMPTZ DEFAULT NULL
) RETURNS TABLE (
  machine_id        INTEGER,
  name              TEXT,
  mac               TEXT,
  ip                TEXT,
  machine_type      TEXT,
  observed_at       TIMESTAMPTZ,
  online_state      SMALLINT,
  operate_mode      SMALLINT,
  motor_state       SMALLINT,
  heat_state        SMALLINT,
  cycle_time        DOUBLE PRECISION,
  craft_id          TEXT,
  material          TEXT,
  mold_cavity       SMALLINT,
  plan_count        BIGINT,
  power_kwh         DOUBLE PRECISION,
  alarms            JSONB,
  shot_count        BIGINT,
  today_shots       BIGINT,
  today_scrap       DOUBLE PRECISION,
  today_parts_gross BIGINT,
  recent_shots      BIGINT,
  product_id        INTEGER,
  product_name      TEXT
)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  WITH period AS (
    SELECT l.machine_id,
      SUM(l.shots)::bigint       AS today_shots,
      SUM(l.scrap)               AS today_scrap,
      SUM(l.parts_gross)::bigint AS today_parts_gross
    FROM machine_day_production l
    WHERE l.org_id = p_org_id
      AND l.day >= (p_since AT TIME ZONE 'Africa/Nairobi')::date
      AND (p_until IS NULL OR l.day < (p_until AT TIME ZONE 'Africa/Nairobi')::date)
    GROUP BY l.machine_id
  ), recent_deltas AS (
    SELECT w.machine_id, w.observed_at,
      machine_counted_delta(
        lag(w.shot_count) OVER mw, w.shot_count,
        extract(epoch FROM w.observed_at - lag(w.observed_at) OVER mw),
        w.cycle_time) AS delta
    FROM machine_readings w
    WHERE w.org_id = p_org_id
      AND w.observed_at >= now() - interval '5 minutes'
      AND (p_until IS NULL OR p_until > now())
    WINDOW mw AS (PARTITION BY w.machine_id ORDER BY w.observed_at)
  ), recent AS (
    SELECT rd.machine_id,
      COALESCE(SUM(rd.delta) FILTER (
        WHERE rd.observed_at >= now() - interval '3 minutes'), 0)::bigint AS recent_shots
    FROM recent_deltas rd
    GROUP BY rd.machine_id
  )
  SELECT m.id, m.name, m.mac, m.ip, m.machine_type,
    lr.observed_at, lr.online_state, lr.operate_mode, lr.motor_state,
    lr.heat_state, lr.cycle_time, lr.craft_id, lr.material, lr.mold_cavity,
    lr.plan_count, lr.power_kwh, lr.alarms, lr.shot_count,
    COALESCE(t.today_shots, 0), COALESCE(t.today_scrap, 0),
    COALESCE(t.today_parts_gross, 0), COALESCE(rc.recent_shots, 0),
    pm.product_id,
    p.name AS product_name
  FROM machines m
  -- Latest reading within the queried period (or ever, if no upper bound)
  LEFT JOIN LATERAL (
    SELECT r.*
    FROM machine_readings r
    WHERE r.machine_id = m.id
      AND (p_until IS NULL OR r.observed_at < p_until)
    ORDER BY r.observed_at DESC
    LIMIT 1
  ) lr ON true
  LEFT JOIN period t ON t.machine_id = m.id
  LEFT JOIN recent rc ON rc.machine_id = m.id
  LEFT JOIN machine_product_map pm
    ON  pm.org_id     = p_org_id
    AND pm.machine_id = m.id
    AND pm.craft_id   = lr.craft_id
  LEFT JOIN products p ON p.id = pm.product_id
  WHERE m.org_id = p_org_id AND m.active
  ORDER BY m.id;
$$;

GRANT EXECUTE ON FUNCTION machine_dashboard_snapshot(INTEGER, TIMESTAMPTZ, TIMESTAMPTZ)
  TO authenticated;
