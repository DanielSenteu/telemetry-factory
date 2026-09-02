-- Migration 65: two-layer BOM — components, in-house ingredients, transform
--
-- A moulded container is an ingredient to the sealing stage exactly the way
-- resin is an ingredient to moulding: one level's output is the next level's
-- input. Model:
--
--   PP resin (raw_material)
--      ↓ component's recipe (moulding lines)
--   60ml Container — moulded   (kind 'component': stocked, costed, NOT sold)
--      ↓ finished good's recipe (packaging lines: 1× component + labels + film)
--   60ml Container — sealed    (finished_good: what sales deduct)
--
-- Changes:
--   1. products.kind gains 'component' (in-house, never shown in sales/demand).
--   2. Recipe lines may consume our own products (components AND finished
--      goods — a sellable cap can still go inside a kit), guarded against
--      cycles by a recursive ancestor check.
--   3. post_count_action becomes a TRANSFORM when the posted product's
--      packaging lines consume an in-house product: it additionally produces
--      the posted product into stock with rolled cost (component cost +
--      packaging cost — same formula as the moulder's confirm). Recipes with
--      only bought-in packaging keep today's consume-only behaviour exactly.
--      The recipe's own shape selects the physics; nothing is configured.

-- ── 1. The component kind ─────────────────────────────────────────────────────

ALTER TABLE products DROP CONSTRAINT products_kind_check;
ALTER TABLE products ADD CONSTRAINT products_kind_check
  CHECK (kind IN ('raw_material', 'finished_good', 'consumable', 'component'));

-- ── 2. Recipes may consume in-house products, cycles forbidden ────────────────

DROP FUNCTION IF EXISTS upsert_bom_line(INTEGER, INTEGER, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT);

CREATE OR REPLACE FUNCTION upsert_bom_line(
  p_org_id       INTEGER,
  p_product_id   INTEGER,
  p_component_id INTEGER,
  p_qty          NUMERIC,
  p_uom          TEXT,
  p_per_units    NUMERIC DEFAULT 1,
  p_stage        TEXT DEFAULT 'moulding'
) RETURNS INTEGER
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

  IF p_per_units IS NULL OR p_per_units <= 0 THEN
    RAISE EXCEPTION 'per_units must be a positive number';
  END IF;

  IF p_stage NOT IN ('moulding', 'packaging') THEN
    RAISE EXCEPTION 'stage must be moulding or packaging';
  END IF;

  IF p_product_id = p_component_id THEN
    RAISE EXCEPTION 'A product cannot be an ingredient of itself';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM products
    WHERE id = p_product_id AND org_id = p_org_id
      AND kind IN ('finished_good', 'component')
  ) THEN
    RAISE EXCEPTION 'Product not found or cannot carry a recipe';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM products
    WHERE id = p_component_id AND org_id = p_org_id
      AND kind IN ('raw_material', 'consumable', 'component', 'finished_good')
  ) THEN
    RAISE EXCEPTION 'Ingredient not found';
  END IF;

  -- Cycle guard: refuse if p_product_id appears anywhere in the ingredient's
  -- own recipe tree (A eats B, B eats A — however deep).
  IF EXISTS (
    WITH RECURSIVE tree AS (
      SELECT bl.component_product_id
      FROM boms b JOIN bom_lines bl ON bl.bom_id = b.id
      WHERE b.product_id = p_component_id AND b.active AND b.org_id = p_org_id
      UNION
      SELECT bl.component_product_id
      FROM tree t
      JOIN boms b ON b.product_id = t.component_product_id AND b.active AND b.org_id = p_org_id
      JOIN bom_lines bl ON bl.bom_id = b.id
    )
    SELECT 1 FROM tree WHERE component_product_id = p_product_id
  ) THEN
    RAISE EXCEPTION 'This would make the product an ingredient of itself (recipe cycle)';
  END IF;

  SELECT id INTO v_bom_id
  FROM boms
  WHERE org_id = p_org_id AND product_id = p_product_id AND active = true
  LIMIT 1;

  IF v_bom_id IS NULL THEN
    INSERT INTO boms (org_id, product_id, version, active, created_by)
    VALUES (p_org_id, p_product_id, 1, true, auth.uid())
    RETURNING id INTO v_bom_id;
  END IF;

  INSERT INTO bom_lines (bom_id, org_id, component_product_id, qty_per_unit, uom, per_units, stage)
  VALUES (v_bom_id, p_org_id, p_component_id, p_qty, p_uom, p_per_units, p_stage)
  ON CONFLICT (bom_id, component_product_id) DO UPDATE SET
    qty_per_unit = EXCLUDED.qty_per_unit,
    uom          = EXCLUDED.uom,
    per_units    = EXCLUDED.per_units,
    stage        = EXCLUDED.stage
  RETURNING id INTO v_line_id;

  RETURN v_line_id;
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_bom_line(INTEGER, INTEGER, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT)
  TO authenticated;

-- ── 3. Transform-aware posting ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION post_count_action(
  p_org_id          INTEGER,
  p_machine_id      INTEGER,
  p_day             DATE DEFAULT NULL,
  p_counts_override NUMERIC DEFAULT NULL,
  p_product_id      INTEGER DEFAULT NULL
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_day          DATE;
  v_action       RECORD;
  v_counts       NUMERIC;
  v_post_id      INTEGER;
  v_bom_id       INTEGER;
  v_avg_cost     NUMERIC;
  v_line         RECORD;
  v_lines        INTEGER := 0;
  v_is_transform BOOLEAN := false;
  v_rolled_cost  NUMERIC := 0;
BEGIN
  IF NOT is_org_admin(p_org_id) THEN
    RAISE EXCEPTION 'Only org admins can post count actions';
  END IF;

  v_day := COALESCE(p_day, (now() AT TIME ZONE 'Africa/Nairobi')::date);

  SELECT id INTO v_post_id
  FROM count_action_posts
  WHERE machine_id = p_machine_id AND day = v_day;
  IF v_post_id IS NOT NULL THEN
    RETURN v_post_id;   -- already posted; run twice = run once
  END IF;

  SELECT shots INTO v_counts
  FROM machine_day_production
  WHERE machine_id = p_machine_id AND day = v_day;
  v_counts := COALESCE(p_counts_override, v_counts, 0);

  IF v_counts <= 0 THEN
    RAISE EXCEPTION 'No counts recorded for % on %', p_machine_id, v_day;
  END IF;

  IF p_product_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM products
      WHERE id = p_product_id AND org_id = p_org_id
        AND kind IN ('finished_good', 'component')
    ) THEN
      RAISE EXCEPTION 'Product not found or cannot be posted';
    END IF;

    SELECT id INTO v_bom_id
    FROM boms
    WHERE org_id = p_org_id AND product_id = p_product_id AND active = true
    LIMIT 1;

    IF v_bom_id IS NULL THEN
      RAISE EXCEPTION 'Product has no recipe — add its packaging lines first';
    END IF;

    -- A packaging line consuming an in-house product makes this a TRANSFORM:
    -- the posted product is being assembled, so its output is produced too.
    SELECT EXISTS (
      SELECT 1 FROM bom_lines bl
      JOIN products p ON p.id = bl.component_product_id
      WHERE bl.bom_id = v_bom_id AND bl.stage = 'packaging'
        AND p.kind IN ('component', 'finished_good')
    ) INTO v_is_transform;

    INSERT INTO count_action_posts (org_id, machine_id, day, counts, product_id, posted_by)
    VALUES (p_org_id, p_machine_id, v_day, v_counts, p_product_id, auth.uid())
    RETURNING id INTO v_post_id;

    FOR v_line IN
      SELECT component_product_id, qty_per_unit, uom, per_units
      FROM bom_lines WHERE bom_id = v_bom_id AND stage = 'packaging'
    LOOP
      v_lines := v_lines + 1;
      SELECT COALESCE(
        SUM(sm.quantity * sm.unit_cost) FILTER (WHERE sm.quantity > 0 AND sm.unit_cost IS NOT NULL)
        / NULLIF(SUM(sm.quantity) FILTER (WHERE sm.quantity > 0 AND sm.unit_cost IS NOT NULL), 0),
        0
      ) INTO v_avg_cost
      FROM stock_movements sm
      WHERE sm.product_id = v_line.component_product_id AND sm.org_id = p_org_id;

      INSERT INTO stock_movements
        (org_id, product_id, quantity, movement_type, unit_cost, source_type, source_id, note)
      VALUES
        (p_org_id, v_line.component_product_id,
         -(v_line.qty_per_unit * v_counts / v_line.per_units),
         'production_consume', v_avg_cost,
         'count_action', v_post_id,
         v_counts::text || ' processed: ' || v_line.qty_per_unit::text || ' ' || v_line.uom ||
         CASE WHEN v_line.per_units = 1 THEN '' ELSE ' per ' || v_line.per_units::text END ||
         ' on ' || v_day::text);

      v_rolled_cost := v_rolled_cost + (v_avg_cost * v_line.qty_per_unit / v_line.per_units);
    END LOOP;

    IF v_lines = 0 THEN
      RAISE EXCEPTION 'Product has no packaging lines in its recipe';
    END IF;

    IF v_is_transform THEN
      INSERT INTO stock_movements
        (org_id, product_id, quantity, movement_type, unit_cost, source_type, source_id, note)
      VALUES
        (p_org_id, p_product_id, v_counts, 'production_output', v_rolled_cost,
         'count_action', v_post_id,
         v_counts::text || ' assembled on ' || v_day::text);
    END IF;

    RETURN v_post_id;
  END IF;

  -- No product chosen → the machine's fixed fallback action.
  SELECT * INTO v_action
  FROM machine_count_actions
  WHERE machine_id = p_machine_id AND org_id = p_org_id;
  IF v_action IS NULL THEN
    RAISE EXCEPTION 'No per-count action configured for this machine';
  END IF;

  INSERT INTO count_action_posts (org_id, machine_id, day, counts, posted_by)
  VALUES (p_org_id, p_machine_id, v_day, v_counts, auth.uid())
  RETURNING id INTO v_post_id;

  SELECT COALESCE(
    SUM(sm.quantity * sm.unit_cost) FILTER (WHERE sm.quantity > 0 AND sm.unit_cost IS NOT NULL)
    / NULLIF(SUM(sm.quantity) FILTER (WHERE sm.quantity > 0 AND sm.unit_cost IS NOT NULL), 0),
    0
  ) INTO v_avg_cost
  FROM stock_movements sm
  WHERE sm.product_id = v_action.product_id AND sm.org_id = p_org_id;

  INSERT INTO stock_movements
    (org_id, product_id, quantity, movement_type, unit_cost, source_type, source_id, note)
  VALUES
    (p_org_id, v_action.product_id,
     -(v_action.qty_per_count * v_counts),
     'production_consume', v_avg_cost,
     'count_action', v_post_id,
     v_counts::text || ' counts × ' || v_action.qty_per_count::text || ' on ' || v_day::text);

  RETURN v_post_id;
END;
$$;

GRANT EXECUTE ON FUNCTION post_count_action(INTEGER, INTEGER, DATE, NUMERIC, INTEGER)
  TO authenticated;

-- ── Moulders may confirm components; never raw/consumables ────────────────────

-- confirm_machine_output takes any product today; add the guard that the
-- confirmed product is something we actually make.
CREATE OR REPLACE FUNCTION confirm_output_kind_guard() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM products
    WHERE id = NEW.product_id AND kind IN ('finished_good', 'component')
  ) THEN
    RAISE EXCEPTION 'Production runs can only make finished goods or components';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS production_runs_kind_guard ON production_runs;
CREATE TRIGGER production_runs_kind_guard
  BEFORE INSERT ON production_runs
  FOR EACH ROW EXECUTE FUNCTION confirm_output_kind_guard();
