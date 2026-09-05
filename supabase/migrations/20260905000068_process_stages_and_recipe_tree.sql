-- Migration 68: per-factory process stages + the recipe tree walker
--
-- A stage is a NAME that connects products to machines — nothing more.
-- Each factory writes its own list (Alpha: Moulding, Packaging; company 3
-- might add Printing, Filling). Each made-here product states which stage
-- makes it; each processing machine states which stage it performs. The
-- mechanics (recipes deduct, posts produce, idempotent per day) stay in
-- code and are never configurable — only the vocabulary is. Stages must
-- never grow ordering logic or workflow states.
--
-- recipe_tree() walks the existing recipe links (they ARE the tree; nothing
-- new is stored) and returns every level under a product in one call: the
-- made-here chain as parent/child rows, each carrying its bought-in material
-- lines as JSON, its mould setup, and its stage name. The UI draws this as
-- the full production story with gap badges.

-- ── Stage vocabulary ──────────────────────────────────────────────────────────

CREATE TABLE process_stages (
  id         SERIAL PRIMARY KEY,
  org_id     INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name       TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 60),
  sort_order INTEGER NOT NULL DEFAULT 0,
  UNIQUE (org_id, name)
);

ALTER TABLE process_stages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org members view stages" ON process_stages
  FOR SELECT TO authenticated
  USING (org_id IN (SELECT user_org_ids()));

CREATE POLICY "Admins manage stages" ON process_stages
  FOR ALL TO authenticated
  USING (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON process_stages TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE process_stages_id_seq TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON process_stages TO service_role;
GRANT USAGE, SELECT ON SEQUENCE process_stages_id_seq TO service_role;

ALTER TABLE products
  ADD COLUMN made_at_stage_id INTEGER REFERENCES process_stages(id) ON DELETE SET NULL;

ALTER TABLE machines
  ADD COLUMN performs_stage_id INTEGER REFERENCES process_stages(id) ON DELETE SET NULL;

-- Seed every existing org with the two names today's data speaks, and map
-- what exists: components are made at Moulding; a finished good whose recipe
-- consumes a made-here product is made at Packaging; other recipe-carrying
-- finished goods at Moulding.
INSERT INTO process_stages (org_id, name, sort_order)
SELECT o.id, s.name, s.sort_order
FROM organizations o
CROSS JOIN (VALUES ('Moulding', 1), ('Packaging', 2)) AS s(name, sort_order);

UPDATE products p SET made_at_stage_id = ps.id
FROM process_stages ps
WHERE ps.org_id = p.org_id AND ps.name = 'Moulding'
  AND p.kind = 'component';

UPDATE products p SET made_at_stage_id = ps.id
FROM process_stages ps
WHERE ps.org_id = p.org_id AND ps.name = 'Packaging'
  AND p.kind = 'finished_good'
  AND EXISTS (
    SELECT 1 FROM boms b
    JOIN bom_lines bl ON bl.bom_id = b.id
    JOIN products cp ON cp.id = bl.component_product_id
    WHERE b.product_id = p.id AND b.active
      AND cp.kind IN ('component', 'finished_good')
  );

UPDATE products p SET made_at_stage_id = ps.id
FROM process_stages ps
WHERE ps.org_id = p.org_id AND ps.name = 'Moulding'
  AND p.kind = 'finished_good' AND p.made_at_stage_id IS NULL
  AND EXISTS (SELECT 1 FROM boms b WHERE b.product_id = p.id AND b.active);

-- ── The tree walker ───────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION recipe_tree(p_org_id INTEGER, p_product_id INTEGER)
RETURNS TABLE (
  product_id        INTEGER,
  parent_product_id INTEGER,
  depth             INTEGER,
  link_qty          NUMERIC,   -- how many of this node one parent unit consumes
  link_per_units    NUMERIC,
  link_uom          TEXT,
  name              TEXT,
  kind              TEXT,
  unit_of_measure   TEXT,
  stage_name        TEXT,
  cavities          SMALLINT,
  runner_weight_g   NUMERIC,
  runner_material   TEXT,
  has_recipe        BOOLEAN,
  material_lines    JSONB      -- bought-in lines: [{name, qty, per_units, uom, stage}]
)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  WITH RECURSIVE nodes AS (
    SELECT p.id AS product_id, NULL::integer AS parent_product_id, 0 AS depth,
           NULL::numeric AS link_qty, NULL::numeric AS link_per_units, NULL::text AS link_uom
    FROM products p
    WHERE p.id = p_product_id AND p.org_id = p_org_id
    UNION ALL
    SELECT bl.component_product_id, n.product_id, n.depth + 1,
           bl.qty_per_unit, bl.per_units, bl.uom
    FROM nodes n
    JOIN boms b   ON b.product_id = n.product_id AND b.active AND b.org_id = p_org_id
    JOIN bom_lines bl ON bl.bom_id = b.id
    JOIN products cp ON cp.id = bl.component_product_id
    WHERE cp.kind IN ('component', 'finished_good')
      AND n.depth < 10
  )
  SELECT n.product_id, n.parent_product_id, n.depth,
    n.link_qty, n.link_per_units, n.link_uom,
    p.name, p.kind, p.unit_of_measure,
    ps.name AS stage_name,
    b.cavities, b.runner_weight_g, rm.name AS runner_material,
    (b.id IS NOT NULL) AS has_recipe,
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'name', mp.name, 'qty', bl2.qty_per_unit,
        'per_units', bl2.per_units, 'uom', bl2.uom, 'stage', bl2.stage
      ) ORDER BY bl2.id)
      FROM bom_lines bl2
      JOIN products mp ON mp.id = bl2.component_product_id
      WHERE bl2.bom_id = b.id AND mp.kind IN ('raw_material', 'consumable')
    ), '[]'::jsonb) AS material_lines
  FROM nodes n
  JOIN products p ON p.id = n.product_id
  LEFT JOIN boms b ON b.product_id = n.product_id AND b.active AND b.org_id = p_org_id
  LEFT JOIN process_stages ps ON ps.id = p.made_at_stage_id
  LEFT JOIN products rm ON rm.id = b.runner_material_product_id
  ORDER BY n.depth, n.product_id;
$$;

GRANT EXECUTE ON FUNCTION recipe_tree(INTEGER, INTEGER) TO authenticated;
