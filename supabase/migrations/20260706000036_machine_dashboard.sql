-- Live machines dashboard (Phase 1 shadow mode): realtime feed + one-shot
-- snapshot RPC for the web-admin "Live floor" page.
--
-- (a) Add machine_readings to the realtime publication so the dashboard can
--     react to inserts (RLS still governs what each user receives). Guarded
--     no-op pattern copied from 20260628000030_realtime_shifts.sql.
-- (b) machine_dashboard_snapshot: one row per active machine — latest reading
--     + today's reset-aware production totals. SECURITY INVOKER on purpose:
--     RLS on machines/machine_readings applies, so non-members get zero rows.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (
       SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
         AND tablename = 'machine_readings'
     )
  THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE machine_readings;
  END IF;
END $$;

-- Why not query the machine_deltas view with `observed_at >= p_since`?
-- Its lag() window is over each machine's FULL history — the time predicate
-- cannot be pushed below the window, so every refresh would re-window
-- everything ever recorded. Here the filter is applied *before* the window,
-- seeded with one pre-p_since row per machine so the first delta of the day
-- still counts. Delta semantics match machine_deltas / agent deltas.ts:
-- counter went down ⇒ reset ⇒ the new value IS the production since reset.
CREATE OR REPLACE FUNCTION machine_dashboard_snapshot(
  p_org_id INTEGER,
  p_since  TIMESTAMPTZ
) RETURNS TABLE (
  machine_id        INTEGER,
  name              TEXT,
  mac               TEXT,
  ip                TEXT,
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
  recent_shots      BIGINT
)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  WITH win AS (
    -- today's readings + one seed row per machine from before p_since,
    -- so the first delta of the day is counted and the window stays bounded
    SELECT r.machine_id, r.observed_at, r.shot_count, r.inferior_count, r.mold_cavity
    FROM machine_readings r
    WHERE r.org_id = p_org_id AND r.observed_at >= p_since
    UNION ALL
    SELECT s.machine_id, s.observed_at, s.shot_count, s.inferior_count, s.mold_cavity
    FROM machines m
    CROSS JOIN LATERAL (
      SELECT r.machine_id, r.observed_at, r.shot_count, r.inferior_count, r.mold_cavity
      FROM machine_readings r
      WHERE r.machine_id = m.id AND r.observed_at < p_since
      ORDER BY r.observed_at DESC
      LIMIT 1
    ) s
    WHERE m.org_id = p_org_id
  ), d AS (
    SELECT w.*,
      lag(w.shot_count)     OVER (PARTITION BY w.machine_id ORDER BY w.observed_at) AS prev_shot,
      lag(w.inferior_count) OVER (PARTITION BY w.machine_id ORDER BY w.observed_at) AS prev_inf
    FROM win w
  ), deltas AS (
    SELECT d.machine_id, d.observed_at, d.mold_cavity,
      CASE WHEN d.shot_count IS NULL OR d.prev_shot IS NULL THEN NULL
           WHEN d.shot_count < d.prev_shot THEN d.shot_count            -- counter reset
           ELSE d.shot_count - d.prev_shot END AS shots_delta,
      CASE WHEN d.inferior_count IS NULL OR d.prev_inf IS NULL THEN NULL
           WHEN d.inferior_count < d.prev_inf THEN d.inferior_count
           ELSE d.inferior_count - d.prev_inf END AS scrap_delta
    FROM d
    WHERE d.observed_at >= p_since                                      -- drop the seed row itself
  ), today AS (
    SELECT dl.machine_id,
      COALESCE(SUM(dl.shots_delta), 0)::BIGINT                              AS today_shots,
      COALESCE(SUM(dl.scrap_delta), 0)                                      AS today_scrap,
      COALESCE(SUM(dl.shots_delta * COALESCE(dl.mold_cavity, 1)), 0)::BIGINT AS today_parts_gross,
      COALESCE(SUM(dl.shots_delta) FILTER (
        WHERE dl.observed_at >= now() - interval '3 minutes'), 0)::BIGINT   AS recent_shots
    FROM deltas dl
    GROUP BY dl.machine_id
  )
  SELECT m.id, m.name, m.mac, m.ip,
    lr.observed_at, lr.online_state, lr.operate_mode, lr.motor_state,
    lr.heat_state, lr.cycle_time, lr.craft_id, lr.material, lr.mold_cavity,
    lr.plan_count, lr.power_kwh, lr.alarms, lr.shot_count,
    COALESCE(t.today_shots, 0), COALESCE(t.today_scrap, 0),
    COALESCE(t.today_parts_gross, 0), COALESCE(t.recent_shots, 0)
  FROM machines m
  LEFT JOIN LATERAL (
    SELECT r.*
    FROM machine_readings r
    WHERE r.machine_id = m.id
    ORDER BY r.observed_at DESC
    LIMIT 1
  ) lr ON true
  LEFT JOIN today t ON t.machine_id = m.id
  WHERE m.org_id = p_org_id AND m.active
  ORDER BY m.name;
$$;
