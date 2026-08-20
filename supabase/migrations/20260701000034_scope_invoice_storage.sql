-- Security: org-scope the invoice file storage (closes the last gap from the RLS
-- audit). Since migration 6 the `invoices` bucket policies were `bucket_id =
-- 'invoices'` for ANY authenticated user — so a logged-in user from org B could
-- read/DELETE org A's invoice PDFs if they knew the path. Files are now uploaded
-- to `<org_id>/<file>`, and these policies require the first path folder to be one
-- of the caller's own orgs.
--
-- No user-facing impact: the app never serves these files to users — only the
-- `process-invoice` Edge Function reads them, via the service role, which bypasses
-- RLS. Legacy folderless files (uploaded before this) simply become
-- service-role-only, which is safe.

DROP POLICY IF EXISTS "Allow authenticated upload to invoices" ON storage.objects;
DROP POLICY IF EXISTS "Allow authenticated read from invoices"   ON storage.objects;
DROP POLICY IF EXISTS "Allow authenticated delete from invoices" ON storage.objects;

CREATE POLICY "Invoices: upload to own org folder" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'invoices'
    AND (storage.foldername(name))[1] IN (SELECT o::text FROM user_org_ids() AS o)
  );

CREATE POLICY "Invoices: read own org files" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'invoices'
    AND (storage.foldername(name))[1] IN (SELECT o::text FROM user_org_ids() AS o)
  );

CREATE POLICY "Invoices: delete own org files" ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'invoices'
    AND (storage.foldername(name))[1] IN (SELECT o::text FROM user_org_ids() AS o)
  );
