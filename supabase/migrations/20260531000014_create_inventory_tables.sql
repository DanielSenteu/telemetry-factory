-- Inventory: products catalog + supplier aliases + append-only stock ledger.
--
-- Three-layer entity resolution (see also the AI-matching phase, deferred):
--   line_items.description (raw, untrusted)
--     -> product_aliases    (the memory: "this vendor's text = our product")
--       -> products         (canonical catalog, the thing actually stocked)
--
-- Stock is NEVER stored as a mutable column. It is DERIVED from the
-- append-only stock_movements ledger (same principle as deriving worked hours
-- from clock events instead of an is_clocked_in flag). On-hand = SUM(quantity).

-- ── Layer 3: canonical product catalog ────────────────

CREATE TABLE products (
  id               SERIAL PRIMARY KEY,
  org_id           INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  sku              TEXT,
  name             TEXT NOT NULL,
  unit_of_measure  TEXT NOT NULL DEFAULT 'each',
  kind             TEXT NOT NULL DEFAULT 'finished_good'
                     CHECK (kind IN ('raw_material', 'finished_good', 'consumable')),
  barcode          TEXT,
  reorder_point    NUMERIC(12,3),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (org_id, sku),
  UNIQUE (org_id, barcode)
);

CREATE INDEX idx_products_org_id ON products(org_id);

-- ── Layer 2: supplier alias / link (the memory) ───────

CREATE TABLE product_aliases (
  id            SERIAL PRIMARY KEY,
  org_id        INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  product_id    INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  vendor_name   TEXT,
  raw_text      TEXT NOT NULL,
  supplier_code TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Seen once, auto-links forever: a vendor's exact line text maps to one product.
  UNIQUE (org_id, vendor_name, raw_text)
);

CREATE INDEX idx_product_aliases_org_id ON product_aliases(org_id);
CREATE INDEX idx_product_aliases_product_id ON product_aliases(product_id);

-- ── The append-only stock ledger (the heart) ──────────

CREATE TABLE stock_movements (
  id           SERIAL PRIMARY KEY,
  org_id       INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  product_id   INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  quantity     NUMERIC(12,3) NOT NULL,   -- SIGNED: +in (purchase), -out (sale/wastage)
  movement_type TEXT NOT NULL
                  CHECK (movement_type IN (
                    'purchase',            -- incoming invoice  (+)
                    'sale',                -- outgoing invoice  (-)
                    'wastage',             -- spillage/breakage/theft (-)
                    'adjustment',          -- manual stock-take correction (+/-)
                    'production_consume',  -- manufacturing: raw material used (-)  [future]
                    'production_output'    -- manufacturing: finished good made (+) [future]
                  )),
  unit_cost    NUMERIC(12,2),             -- captured from the invoice line -> valuation
  source_type  TEXT,                      -- 'invoice' | 'manual' | ...
  source_id    INTEGER,                   -- e.g. the line_items.id that caused it
  note         TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by   UUID DEFAULT auth.uid()
);

CREATE INDEX idx_stock_movements_org_id ON stock_movements(org_id);
CREATE INDEX idx_stock_movements_product_id ON stock_movements(product_id);

-- ── Convenience view: current on-hand, value, reorder ─
-- Everything derived from the ledger; no stored quantity to drift.

CREATE VIEW product_stock AS
SELECT
  base.product_id,
  base.org_id,
  base.sku,
  base.name,
  base.unit_of_measure,
  base.kind,
  base.reorder_point,
  base.on_hand,
  -- weighted-average cost of inflows (positive movements)
  CASE WHEN base.inflow_qty > 0
       THEN base.inflow_cost / base.inflow_qty ELSE 0 END        AS avg_unit_cost,
  base.on_hand * CASE WHEN base.inflow_qty > 0
       THEN base.inflow_cost / base.inflow_qty ELSE 0 END        AS stock_value,
  (base.reorder_point IS NOT NULL
     AND base.on_hand <= base.reorder_point)                     AS needs_reorder
FROM (
  SELECT
    p.id AS product_id, p.org_id, p.sku, p.name,
    p.unit_of_measure, p.kind, p.reorder_point,
    COALESCE(SUM(m.quantity), 0)                                                       AS on_hand,
    COALESCE(SUM(CASE WHEN m.quantity > 0 THEN m.unit_cost * m.quantity ELSE 0 END), 0) AS inflow_cost,
    COALESCE(SUM(CASE WHEN m.quantity > 0 THEN m.quantity ELSE 0 END), 0)               AS inflow_qty
  FROM products p
  LEFT JOIN stock_movements m ON m.product_id = p.id
  GROUP BY p.id
) base;

-- ── RLS (authenticated access, matching existing tables) ─

ALTER TABLE products        ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_aliases ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_movements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated access on products" ON products
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated access on product_aliases" ON product_aliases
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated access on stock_movements" ON stock_movements
  FOR ALL TO authenticated USING (true) WITH CHECK (true);
