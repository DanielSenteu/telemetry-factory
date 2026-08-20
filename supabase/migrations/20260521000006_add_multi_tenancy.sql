-- Multi-tenancy: organizations, org_modules, org_id scoping, RLS tightening

-- ── New tables ────────────────────────────────────────

CREATE TABLE organizations (
  id         SERIAL PRIMARY KEY,
  name       TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE org_modules (
  id         SERIAL PRIMARY KEY,
  org_id     INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  module_key TEXT NOT NULL,
  enabled    BOOLEAN NOT NULL DEFAULT true,
  UNIQUE(org_id, module_key)
);

ALTER TABLE org_modules ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;

-- ── Add org_id to existing tables ─────────────────────

-- Seed default company first so we can backfill
INSERT INTO organizations (id, name) VALUES (1, 'Default Company');
SELECT setval('organizations_id_seq', 1, true);

-- invoices
ALTER TABLE invoices ADD COLUMN org_id INTEGER;
UPDATE invoices SET org_id = 1;
ALTER TABLE invoices ALTER COLUMN org_id SET NOT NULL;
ALTER TABLE invoices ADD CONSTRAINT invoices_org_id_fkey
  FOREIGN KEY (org_id) REFERENCES organizations(id);
CREATE INDEX idx_invoices_org_id ON invoices(org_id);

-- workplaces
ALTER TABLE workplaces ADD COLUMN org_id INTEGER;
UPDATE workplaces SET org_id = 1;
ALTER TABLE workplaces ALTER COLUMN org_id SET NOT NULL;
ALTER TABLE workplaces ADD CONSTRAINT workplaces_org_id_fkey
  FOREIGN KEY (org_id) REFERENCES organizations(id);
CREATE INDEX idx_workplaces_org_id ON workplaces(org_id);

-- workers
ALTER TABLE workers ADD COLUMN org_id INTEGER;
UPDATE workers SET org_id = 1;
ALTER TABLE workers ALTER COLUMN org_id SET NOT NULL;
ALTER TABLE workers ADD CONSTRAINT workers_org_id_fkey
  FOREIGN KEY (org_id) REFERENCES organizations(id);
CREATE INDEX idx_workers_org_id ON workers(org_id);

-- timesheet_entries does NOT get org_id — scoped through worker/workplace FKs

-- ── Drop old permissive anon policies ─────────────────

DROP POLICY "Allow all on invoices" ON invoices;
DROP POLICY "Allow all on line_items" ON line_items;
DROP POLICY "Allow all on workplaces" ON workplaces;
DROP POLICY "Allow all on workers" ON workers;
DROP POLICY "Allow all on timesheet_entries" ON timesheet_entries;

-- ── Create authenticated-only policies ────────────────

CREATE POLICY "Authenticated access on invoices" ON invoices
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated access on line_items" ON line_items
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated access on workplaces" ON workplaces
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated access on workers" ON workers
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated access on timesheet_entries" ON timesheet_entries
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated access on organizations" ON organizations
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated access on org_modules" ON org_modules
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ── Update storage policies from anon → authenticated ─

DROP POLICY "Allow anon upload to invoices" ON storage.objects;
DROP POLICY "Allow anon read from invoices" ON storage.objects;
DROP POLICY "Allow anon delete from invoices" ON storage.objects;

CREATE POLICY "Allow authenticated upload to invoices" ON storage.objects
  FOR INSERT TO authenticated WITH CHECK (bucket_id = 'invoices');

CREATE POLICY "Allow authenticated read from invoices" ON storage.objects
  FOR SELECT TO authenticated USING (bucket_id = 'invoices');

CREATE POLICY "Allow authenticated delete from invoices" ON storage.objects
  FOR DELETE TO authenticated USING (bucket_id = 'invoices');

-- ── Update confirm_invoice RPC to accept org_id ───────

CREATE OR REPLACE FUNCTION confirm_invoice(
  p_org_id         INTEGER,
  p_vendor_name    TEXT,
  p_invoice_number TEXT,
  p_invoice_date   DATE,
  p_total_amount   NUMERIC(12,2),
  p_file_name      TEXT,
  p_storage_path   TEXT,
  p_line_items     JSONB
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_invoice_id INTEGER;
  v_item JSONB;
BEGIN
  INSERT INTO invoices (org_id, vendor_name, invoice_number, invoice_date, total_amount, file_name, storage_path)
  VALUES (p_org_id, p_vendor_name, p_invoice_number, p_invoice_date, p_total_amount, p_file_name, p_storage_path)
  RETURNING id INTO v_invoice_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_line_items)
  LOOP
    INSERT INTO line_items (invoice_id, description, quantity, unit_price, total_price)
    VALUES (
      v_invoice_id,
      v_item->>'description',
      (v_item->>'quantity')::NUMERIC,
      (v_item->>'unit_price')::NUMERIC,
      (v_item->>'total_price')::NUMERIC
    );
  END LOOP;

  RETURN v_invoice_id;
END;
$$;
