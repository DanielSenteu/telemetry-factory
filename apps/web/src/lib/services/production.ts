// Ported from v1 bomService.js — recipes, shot params, overrides, output
// confirmation. Logic unchanged; typed and pointed at the v2 browser client.

import { supabase } from "@/lib/supabase/browser";

export type BomLine = {
  id: number;
  component_product_id: number;
  qty_per_unit: number;
  uom: string;
  // The line consumes qty_per_unit per THIS MANY units of the product
  // ("1 box per 500 caps"). 1 = the ordinary per-unit line.
  per_units: number;
  // When the line bills: at the moulder's confirm or the wrapper's post.
  stage: "moulding" | "packaging";
  component_name: string;
};

export type Bom = {
  id: number;
  version: number;
  cavities: number | null;
  runner_weight_g: number | null;
  runner_material_product_id: number | null;
  lines: BomLine[];
};

export type Product = { id: number; name: string; sku: string | null; unit_of_measure?: string; kind?: string };

/** Products that can carry a recipe: sellable goods AND in-house components. */
export async function listFinishedGoods(orgId: number): Promise<Product[]> {
  const { data, error } = await supabase
    .from("products")
    .select("id, name, sku, kind")
    .eq("org_id", orgId)
    .in("kind", ["finished_good", "component"])
    .eq("active", true)
    .order("name");
  if (error) throw new Error(error.message);
  return data || [];
}

/** Everything a recipe line may consume — bought-in materials AND products
 *  made in-house (two-layer BOM: a moulded component is an ingredient to
 *  the sealing stage the way resin is to moulding). */
export async function listRawMaterials(orgId: number): Promise<Product[]> {
  const { data, error } = await supabase
    .from("products")
    .select("id, name, sku, unit_of_measure, kind")
    .eq("org_id", orgId)
    .in("kind", ["raw_material", "consumable", "component", "finished_good"])
    .eq("active", true)
    .order("name");
  if (error) throw new Error(error.message);
  return data || [];
}

export async function getBOMForProduct(orgId: number, productId: number): Promise<Bom | null> {
  const { data: bom, error: bErr } = await supabase
    .from("boms")
    .select("id, version, active, cavities, runner_weight_g, runner_material_product_id")
    .eq("org_id", orgId)
    .eq("product_id", productId)
    .eq("active", true)
    .maybeSingle();
  if (bErr) throw new Error(bErr.message);
  if (!bom) return null;

  const { data: lines, error: lErr } = await supabase
    .from("bom_lines")
    .select("id, component_product_id, qty_per_unit, uom, per_units, stage, products(name)")
    .eq("bom_id", bom.id)
    .order("id");
  if (lErr) throw new Error(lErr.message);

  return {
    ...bom,
    lines: (lines || []).map((l) => ({
      id: l.id,
      component_product_id: l.component_product_id,
      qty_per_unit: l.qty_per_unit,
      uom: l.uom,
      per_units: l.per_units ?? 1,
      stage: (l.stage as "moulding" | "packaging") ?? "moulding",
      component_name: (l.products as unknown as { name: string } | null)?.name ?? "Unknown",
    })),
  };
}

export async function upsertBOMLine(
  orgId: number,
  productId: number,
  componentId: number,
  qty: number,
  uom: string,
  perUnits: number = 1,
  stage: "moulding" | "packaging" = "moulding"
) {
  const { error } = await supabase.rpc("upsert_bom_line", {
    p_org_id: orgId,
    p_product_id: productId,
    p_component_id: componentId,
    p_qty: qty,
    p_uom: uom,
    p_per_units: perUnits,
    p_stage: stage,
  });
  if (error) throw new Error(error.message);
}

export async function deleteBOMLine(lineId: number) {
  const { error } = await supabase.from("bom_lines").delete().eq("id", lineId);
  if (error) throw new Error(error.message);
}

export async function updateBOMShotParams(
  orgId: number,
  productId: number,
  cavities: number | null,
  runnerWeightG: number | null,
  runnerMaterialProductId: number | null,
) {
  const { error } = await supabase.rpc("update_bom_shot_params", {
    p_org_id: orgId,
    p_product_id: productId,
    p_cavities: cavities,
    p_runner_weight_g: runnerWeightG,
    p_runner_material_product_id: runnerMaterialProductId,
  });
  if (error) throw new Error(error.message);
}

/** Confirm a machine's output for a date → production run + stock + BOM consumption + regrind-in. Idempotent per (machine, product, date). */
export async function confirmMachineOutput(
  orgId: number,
  machineId: number,
  productId: number,
  goodQty: number,
  scrapQty: number,
) {
  const { data, error } = await supabase.rpc("confirm_machine_output", {
    p_org_id: orgId,
    p_machine_id: machineId,
    p_product_id: productId,
    p_good_qty: goodQty,
    p_scrap_qty: scrapQty,
  });
  if (error) throw new Error(error.message);
  return data as number;
}

/** The three operator overrides. qty: positive = power-outage production, negative = waste/rejects. */
export async function postManualStockAdjustment(
  orgId: number,
  productId: number,
  qty: number,
  reasonType: "power_outage" | "waste" | "rejects",
  opts: { routeToRegrind?: boolean; machineId?: number | null; note?: string | null } = {},
) {
  const { data, error } = await supabase.rpc("post_manual_stock_adjustment", {
    p_org_id: orgId,
    p_product_id: productId,
    p_qty: qty,
    p_reason_type: reasonType,
    p_route_to_regrind: opts.routeToRegrind ?? false,
    p_machine_id: opts.machineId ?? null,
    p_note: opts.note ?? null,
  });
  if (error) throw new Error(error.message);
  return data as number;
}

// ── The production tree ───────────────────────────────────

export type TreeMaterialLine = {
  name: string;
  qty: number;
  per_units: number;
  uom: string;
  stage: string;
};

export type TreeNode = {
  product_id: number;
  parent_product_id: number | null;
  depth: number;
  link_qty: number | null;
  link_per_units: number | null;
  link_uom: string | null;
  name: string;
  kind: string;
  unit_of_measure: string;
  stage_name: string | null;
  cavities: number | null;
  runner_weight_g: number | null;
  runner_material: string | null;
  has_recipe: boolean;
  material_lines: TreeMaterialLine[];
};

/** The whole production story under a product — every made-here level,
 *  each node carrying its bought-in lines, mould setup and stage. */
export async function getRecipeTree(orgId: number, productId: number): Promise<TreeNode[]> {
  const { data, error } = await supabase.rpc("recipe_tree", {
    p_org_id: orgId,
    p_product_id: productId,
  });
  if (error) throw new Error(error.message);
  return data || [];
}

// ── Process stages: each factory's own step names ─────────

export type ProcessStage = { id: number; name: string; sort_order: number };

export async function listStages(orgId: number): Promise<ProcessStage[]> {
  const { data, error } = await supabase
    .from("process_stages")
    .select("id, name, sort_order")
    .eq("org_id", orgId)
    .order("sort_order")
    .order("id");
  if (error) throw new Error(error.message);
  return data || [];
}

export async function addStage(orgId: number, name: string) {
  const { error } = await supabase.from("process_stages").insert({
    org_id: orgId,
    name: name.trim(),
    sort_order: 99,
  });
  if (error) throw new Error(error.message);
}

export async function setProductStage(productId: number, stageId: number | null) {
  const { error } = await supabase.from("products").update({ made_at_stage_id: stageId }).eq("id", productId);
  if (error) throw new Error(error.message);
}

export async function getProductStage(productId: number): Promise<number | null> {
  const { data, error } = await supabase
    .from("products")
    .select("made_at_stage_id")
    .eq("id", productId)
    .single();
  if (error) throw new Error(error.message);
  return data?.made_at_stage_id ?? null;
}
