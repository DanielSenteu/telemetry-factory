-- Migration 47: BOM shot parameters
--
-- Adds three fields to the boms header to support runner/regrind tracking:
--   cavities                  — how many parts come out of one shot (e.g. 16 for lids)
--   runner_weight_g           — grams of runner produced per shot (fixed, measured once)
--   runner_material_product_id— which raw material the runner recycles back into
--
-- When all three are set, confirm_machine_output (migration 48) will automatically
-- park runner weight into the regrind pool after each confirmed production run.

ALTER TABLE boms
  ADD COLUMN cavities                   SMALLINT,
  ADD COLUMN runner_weight_g            NUMERIC(10,3),
  ADD COLUMN runner_material_product_id INTEGER REFERENCES products(id) ON DELETE SET NULL;

-- ── update_bom_shot_params ────────────────────────────────────────────────────
-- Admin-only upsert for shot setup fields. Creates the BOM header if none exists.

CREATE OR REPLACE FUNCTION update_bom_shot_params(
  p_org_id                      INTEGER,
  p_product_id                  INTEGER,
  p_cavities                    SMALLINT,
  p_runner_weight_g             NUMERIC,
  p_runner_material_product_id  INTEGER
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_bom_id INTEGER;
BEGIN
  IF NOT is_org_admin(p_org_id) THEN
    RAISE EXCEPTION 'Only org admins can update BOM shot params';
  END IF;

  -- Get or create the active BOM header
  SELECT id INTO v_bom_id
  FROM boms
  WHERE org_id = p_org_id AND product_id = p_product_id AND active = true
  LIMIT 1;

  IF v_bom_id IS NULL THEN
    INSERT INTO boms (org_id, product_id, version, active, created_by)
    VALUES (p_org_id, p_product_id, 1, true, auth.uid())
    RETURNING id INTO v_bom_id;
  END IF;

  UPDATE boms SET
    cavities                   = p_cavities,
    runner_weight_g            = p_runner_weight_g,
    runner_material_product_id = p_runner_material_product_id
  WHERE id = v_bom_id;
END;
$$;

GRANT EXECUTE ON FUNCTION update_bom_shot_params(INTEGER, INTEGER, SMALLINT, NUMERIC, INTEGER)
  TO authenticated;
