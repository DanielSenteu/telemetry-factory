-- Invoice tables (migrated from schema.sql + storage_path column)

CREATE TABLE IF NOT EXISTS invoices (
  id             SERIAL PRIMARY KEY,
  vendor_name    TEXT,
  invoice_number TEXT,
  invoice_date   DATE,
  total_amount   NUMERIC(12,2),
  file_name      TEXT,
  storage_path   TEXT,
  created_at     TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS line_items (
  id            SERIAL PRIMARY KEY,
  invoice_id    INTEGER REFERENCES invoices(id) ON DELETE CASCADE,
  description   TEXT NOT NULL,
  quantity      NUMERIC(10,3),
  unit_price    NUMERIC(12,2),
  total_price   NUMERIC(12,2)
);
