-- Live schedule: let the mobile app react the instant a shift changes (e.g. a
-- manager publishes the roster) by adding `shifts` to Supabase's realtime
-- publication. The app subscribes to postgres_changes and refetches; RLS still
-- governs what each worker actually receives. Guarded so it's a no-op if the
-- publication is missing or the table is already a member.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (
       SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'shifts'
     )
  THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE shifts;
  END IF;
END $$;
