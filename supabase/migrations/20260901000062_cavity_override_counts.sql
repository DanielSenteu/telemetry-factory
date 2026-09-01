-- Migration 62: the cavity override actually drives the counted parts
--
-- Evidence (2026-08-31): the Haijing panels have NEVER reported a cavity
-- other than 0/1 in their entire history, while the real moulds are 8-16
-- cavities (validated Phase-2 spec). The panel value is human-typed and
-- unmaintained — so parts counting must be able to prefer OUR number.
--
-- machine_product_map.cavity_override existed but only fed the UI verdict;
-- the day ledger still multiplied by the reading's panel value. This makes
-- the override authoritative end-to-end:
--   parts = shots × COALESCE(override for (machine, craft), panel value, 1)
-- in both the ingestion trigger and the rebuild, and any change to an
-- override automatically recounts that machine's whole ledger from raw
-- readings — history heals itself the moment the truth is entered.

-- ── Ingestion trigger: override-aware parts ───────────────────────────────────

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
      COALESCE(SUM(d.shots_delta *
        COALESCE(mpm.cavity_override, d.mold_cavity, 1)), 0)::bigint
    FROM (
      SELECT w.observed_at, w.mold_cavity, w.craft_id,
        machine_counted_delta(
          lag(w.shot_count) OVER mw, w.shot_count,
          extract(epoch FROM w.observed_at - lag(w.observed_at) OVER mw),
          w.cycle_time) AS shots_delta,
        machine_counted_delta(
          lag(w.inferior_count) OVER mw, w.inferior_count,
          extract(epoch FROM w.observed_at - lag(w.observed_at) OVER mw),
          w.cycle_time) AS scrap_delta
      FROM (
        SELECT r.observed_at, r.shot_count, r.inferior_count, r.mold_cavity, r.cycle_time, r.craft_id
        FROM machine_readings r
        WHERE r.machine_id = a.machine_id
          AND r.observed_at >= day_start AND r.observed_at < day_end
        UNION ALL
        SELECT s.observed_at, s.shot_count, s.inferior_count, s.mold_cavity, s.cycle_time, s.craft_id
        FROM (
          SELECT r.observed_at, r.shot_count, r.inferior_count, r.mold_cavity, r.cycle_time, r.craft_id
          FROM machine_readings r
          WHERE r.machine_id = a.machine_id AND r.observed_at < day_start
          ORDER BY r.observed_at DESC LIMIT 1
        ) s
      ) w
      WINDOW mw AS (ORDER BY w.observed_at)
    ) d
    LEFT JOIN machine_product_map mpm
      ON  mpm.org_id     = a.org_id
      AND mpm.machine_id = a.machine_id
      AND mpm.craft_id   = d.craft_id
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

-- ── Rebuild: same override-aware parts ────────────────────────────────────────

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
    COALESCE(SUM(d.shots_delta *
      COALESCE(mpm.cavity_override, d.mold_cavity, 1)), 0)::bigint
  FROM (
    SELECT r.org_id, r.machine_id, r.craft_id,
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
  LEFT JOIN machine_product_map mpm
    ON  mpm.org_id     = d.org_id
    AND mpm.machine_id = d.machine_id
    AND mpm.craft_id   = d.craft_id
  GROUP BY d.org_id, d.machine_id, d.day;
END;
$$;

-- ── Changing an override recounts that machine's history automatically ────────

CREATE OR REPLACE FUNCTION machine_product_map_recount() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM rebuild_machine_day_production(NEW.machine_id);
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS machine_product_map_recount_trg ON machine_product_map;
CREATE TRIGGER machine_product_map_recount_trg
  AFTER INSERT OR UPDATE OF cavity_override, product_id ON machine_product_map
  FOR EACH ROW EXECUTE FUNCTION machine_product_map_recount();

-- Recount everything once so any overrides set before this migration count too.
SELECT rebuild_machine_day_production();
