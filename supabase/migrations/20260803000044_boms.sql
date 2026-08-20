-- Migration 44: Bill of Materials (BOM)
-- Recipe table: for each finished good, which raw materials go in and how much
-- per unit produced. Once entered, the confirm_machine_output RPC (migration 45)
-- uses the active BOM to auto-deduct components from stock.
--
-- Design: one active BOM per product at a time (version column allows future
-- versioning — editing creates v2, historical runs keep their v1 reference).

-- ── boms: one header row per product ─────────────────────────────────────────

CREATE TABLE boms (
  id         SERIAL PRIMARY KEY,
  org_id     INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  product_id INTEGER NOT NULL REFERENCES products(id)      ON DELETE RESTRICT,
  version    INTEGER NOT NULL DEFAULT 1,
  active     BOOLEAN NOT NULL DEFAULT true,
  created_by UUID    REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (org_id, product_id, version)
);

CREATE INDEX idx_boms_product ON boms (org_id, product_id);

ALTER TABLE boms ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org members view boms" ON boms
  FOR SELECT TO authenticated
  USING (org_id IN (SELECT user_org_ids()));

CREATE POLICY "Admins manage boms" ON boms
  FOR ALL TO authenticated
  USING  (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON boms TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE boms_id_seq TO authenticated;

-- ── bom_lines: one row per component ─────────────────────────────────────────

CREATE TABLE bom_lines (
  id                   SERIAL PRIMARY KEY,
  bom_id               INTEGER NOT NULL REFERENCES boms(id)     ON DELETE CASCADE,
  org_id               INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  component_product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
  qty_per_unit         NUMERIC(14,4) NOT NULL CHECK (qty_per_unit > 0),
  uom                  TEXT NOT NULL DEFAULT 'g',
  UNIQUE (bom_id, component_product_id)
);

CREATE INDEX idx_bom_lines_bom ON bom_lines (bom_id);

ALTER TABLE bom_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org members view bom_lines" ON bom_lines
  FOR SELECT TO authenticated
  USING (org_id IN (SELECT user_org_ids()));

CREATE POLICY "Admins manage bom_lines" ON bom_lines
  FOR ALL TO authenticated
  USING  (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON bom_lines TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE bom_lines_id_seq TO authenticated;

-- ── upsert_bom_line ───────────────────────────────────────────────────────────
-- Creates the BOM header if none exists for the product, then adds or updates
-- the given component line. Admins only.

CREATE OR REPLACE FUNCTION upsert_bom_line(
  p_org_id       INTEGER,
  p_product_id   INTEGER,   -- must be finished_good
  p_component_id INTEGER,   -- must be raw_material or consumable
  p_qty          NUMERIC,
  p_uom          TEXT
) RETURNS INTEGER            -- returns the bom_line id
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_bom_id  INTEGER;
  v_line_id INTEGER;
BEGIN
  IF NOT is_org_admin(p_org_id) THEN
    RAISE EXCEPTION 'Only org admins can manage BOMs';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM products
    WHERE id = p_product_id AND org_id = p_org_id AND kind = 'finished_good'
  ) THEN
    RAISE EXCEPTION 'Product not found or is not a finished good';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM products
    WHERE id = p_component_id AND org_id = p_org_id
      AND kind IN ('raw_material', 'consumable')
  ) THEN
    RAISE EXCEPTION 'Component not found or is not a raw material / consumable';
  END IF;

  -- Get or create the active BOM header for this product
  SELECT id INTO v_bom_id
  FROM boms
  WHERE org_id = p_org_id AND product_id = p_product_id AND active = true
  LIMIT 1;

  IF v_bom_id IS NULL THEN
    INSERT INTO boms (org_id, product_id, version, active, created_by)
    VALUES (p_org_id, p_product_id, 1, true, auth.uid())
    RETURNING id INTO v_bom_id;
  END IF;

  -- Add or update the ingredient line
  INSERT INTO bom_lines (bom_id, org_id, component_product_id, qty_per_unit, uom)
  VALUES (v_bom_id, p_org_id, p_component_id, p_qty, p_uom)
  ON CONFLICT (bom_id, component_product_id) DO UPDATE SET
    qty_per_unit = EXCLUDED.qty_per_unit,
    uom          = EXCLUDED.uom
  RETURNING id INTO v_line_id;

  RETURN v_line_id;
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_bom_line(INTEGER, INTEGER, INTEGER, NUMERIC, TEXT)
  TO authenticated;
