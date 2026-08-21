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
    supabase.from("products").select("*").eq("org_id", orgId).order("name"),
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
