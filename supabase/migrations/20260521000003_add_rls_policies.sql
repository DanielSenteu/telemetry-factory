-- Enable RLS on all tables with permissive policies
-- (single-user admin app — tighten these when auth is added)

ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE line_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE workplaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE workers ENABLE ROW LEVEL SECURITY;
ALTER TABLE timesheet_entries ENABLE ROW LEVEL SECURITY;

-- Invoices: allow all operations
CREATE POLICY "Allow all on invoices" ON invoices
  FOR ALL USING (true) WITH CHECK (true);

-- Line items: allow all operations
CREATE POLICY "Allow all on line_items" ON line_items
  FOR ALL USING (true) WITH CHECK (true);

-- Workplaces: allow all operations
CREATE POLICY "Allow all on workplaces" ON workplaces
  FOR ALL USING (true) WITH CHECK (true);

-- Workers: allow all operations
CREATE POLICY "Allow all on workers" ON workers
  FOR ALL USING (true) WITH CHECK (true);

-- Timesheet entries: allow all operations
CREATE POLICY "Allow all on timesheet_entries" ON timesheet_entries
  FOR ALL USING (true) WITH CHECK (true);
