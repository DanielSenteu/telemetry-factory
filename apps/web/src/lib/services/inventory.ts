// Ported from v1 inventoryService.js. Stock is DERIVED from the movements
// ledger via the product_stock view — there is no stored quantity to drift.

import { supabase } from "@/lib/supabase/browser";

export type StockedProduct = {
  id: number;
  name: string;
  sku: string | null;
  kind: "raw_material" | "finished_good" | "consumable";
  unit_of_measure: string;
  sale_price: number | null;
  reorder_point: number | null;
  on_hand: number;
  avg_unit_cost: number;
  stock_value: number;
};

export async function listProducts(orgId: number): Promise<StockedProduct[]> {
  const [{ data: products, error: pErr }, { data: stock, error: sErr }] = await Promise.all([
    supabase.from("products").select("*").eq("org_id", orgId).eq("active", true).order("name"),
    supabase.from("product_stock").select("*").eq("org_id", orgId),
  ]);
  if (pErr) throw new Error(pErr.message);
  if (sErr) throw new Error(sErr.message);

  const stockById = new Map((stock || []).map((s) => [s.product_id, s]));
  return (products || []).map((p) => {
    const s = stockById.get(p.id);
    return {
      ...p,
      on_hand: s?.on_hand ?? 0,
      avg_unit_cost: s?.avg_unit_cost ?? 0,
      stock_value: s?.stock_value ?? 0,
    };
  });
}

export async function createProduct(
  orgId: number,
  data: { name: string; kind: string; unit_of_measure: string; sale_price?: number | null },
) {
  const { data: product, error } = await supabase
    .from("products")
    .insert({ ...data, org_id: orgId })
    .select()
    .single();
  if (error) throw new Error(error.message);
  return product;
}

export async function listMovements(productId: number, limit = 40) {
  const { data, error } = await supabase
    .from("stock_movements")
    .select("id, quantity, movement_type, unit_cost, source_type, note, created_at")
    .eq("product_id", productId)
    .order("created_at", { ascending: false })
    .limit(limit);
  if (error) throw new Error(error.message);
  return data || [];
}

// ── Regrind pool ──────────────────────────────────────
// Runners accumulate automatically when production is confirmed (recipes carry
// runner weight per shot). Logging use moves grams out of the pool and back
// into raw material stock as 'regrind_return' — fixed by migration 55; this is
// the feature's first working UI.

export type RegrindBalance = {
  material_product_id: number;
  material_name: string;
  balance_g: number;
  total_in_g: number;
  total_out_g: number;
};

export async function getRegrindBalances(orgId: number): Promise<RegrindBalance[]> {
  const { data, error } = await supabase.rpc("regrind_balances", { p_org_id: orgId });
  if (error) throw new Error(error.message);
  return data || [];
}

export async function postRegrindUse(orgId: number, materialProductId: number, qtyG: number, note: string | null) {
  const { error } = await supabase.rpc("post_regrind_use", {
    p_org_id: orgId,
    p_material_product_id: materialProductId,
    p_qty_g: qtyG,
    p_note: note,
  });
  if (error) throw new Error(error.message);
}

// ── Movement history ──────────────────────────────────

export type Movement = {
  id: number;
  product_id: number;
  quantity: number;
  movement_type: string;
  unit_cost: number | null;
  source_type: string | null;
  note: string | null;
  created_at: string;
  products: { name: string; unit_of_measure: string } | null;
};

export async function listRecentMovements(orgId: number, productId?: number, limit = 60): Promise<Movement[]> {
  let q = supabase
    .from("stock_movements")
    .select("id, product_id, quantity, movement_type, unit_cost, source_type, note, created_at, products(name, unit_of_measure)")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
    .limit(limit);
  if (productId) q = q.eq("product_id", productId);
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return (data || []) as unknown as Movement[];
}

// ── Edit / archive / delete ───────────────────────────

export async function updateProduct(
  id: number,
  fields: { name?: string; unit_of_measure?: string; sale_price?: number | null; reorder_point?: number | null },
) {
  const { error } = await supabase.from("products").update(fields).eq("id", id);
  if (error) throw new Error(error.message);
}

/** How many stock movements reference this product — decides delete vs archive. */
export async function countMovements(productId: number): Promise<number> {
  const { count, error } = await supabase
    .from("stock_movements")
    .select("id", { count: "exact", head: true })
    .eq("product_id", productId);
  if (error) throw new Error(error.message);
  return count ?? 0;
}

/** Hard delete — ONLY safe when the product has no ledger history (FK cascades). */
export async function deleteProduct(id: number) {
  const { error } = await supabase.from("products").delete().eq("id", id);
  if (error) throw new Error(error.message);
}

/** Archive — hides from lists but keeps the product and its ledger intact. */
export async function archiveProduct(id: number) {
  const { error } = await supabase.from("products").update({ active: false }).eq("id", id);
  if (error) throw new Error(error.message);
}

// ── Manual stock entry ────────────────────────────────
// Materials don't only arrive by invoice — opening stock, a stock-take
// correction, or a hand-added bag all go through here as an 'adjustment'
// movement. A positive quantity carries a unit cost so the weighted-average
// cost stays right; a negative one is a manual removal.

export async function adjustStockManual(
  orgId: number,
  productId: number,
  quantity: number, // + add, − remove
  opts: { unitCost?: number | null; note?: string | null } = {},
) {
  const { error } = await supabase.from("stock_movements").insert({
    org_id: orgId,
    product_id: productId,
    quantity,
    movement_type: "adjustment",
    unit_cost: quantity > 0 ? (opts.unitCost ?? null) : null,
    source_type: "manual",
    note: opts.note ?? null,
  });
  if (error) throw new Error(error.message);
}
