-- Migration 63: a panel cavity of 0 means "unset", never "multiply by zero"
--
-- Seen on prod (2026-08-31, Haijing-HJ168S-2): the panel reported
-- mold_cavity = 0 for most of a day — 8,108 shots counted as 416 parts,
-- because COALESCE takes 0 as a real value. Parts can never be fewer than
-- shots. 0 now falls through like NULL: override → NULLIF(panel, 0) → 1.
-- Same fix in the ingestion trigger and the rebuild; recount runs at the end.

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
        COALESCE(mpm.cavity_override, NULLIF(d.mold_cavity, 0), 1)), 0)::bigint
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
      COALESCE(mpm.cavity_override, NULLIF(d.mold_cavity, 0), 1)), 0)::bigint
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

SELECT rebuild_machine_day_production();
