-- Create private "invoices" storage bucket

INSERT INTO storage.buckets (id, name, public)
VALUES ('invoices', 'invoices', false)
ON CONFLICT (id) DO NOTHING;

-- Allow anon uploads to the invoices bucket
CREATE POLICY "Allow anon upload to invoices" ON storage.objects
  FOR INSERT TO anon WITH CHECK (bucket_id = 'invoices');

-- Allow anon reads from the invoices bucket
CREATE POLICY "Allow anon read from invoices" ON storage.objects
  FOR SELECT TO anon USING (bucket_id = 'invoices');

-- Allow anon deletes from the invoices bucket
CREATE POLICY "Allow anon delete from invoices" ON storage.objects
  FOR DELETE TO anon USING (bucket_id = 'invoices');
