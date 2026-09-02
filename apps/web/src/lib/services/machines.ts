// Network layer for machines — thin, typed calls over the proven v1 RPCs.
// All pure logic (state derivation, EAT time, part math) lives in
// machines-logic.ts where it is unit-tested without any I/O.

import { supabase } from "@/lib/supabase/browser";
import { eatRangeToUtc, type MachineRow, type FactoryAgent } from "./machines-logic";

export * from "./machines-logic";

/** Snapshot for an inclusive Kenya date range ('YYYY-MM-DD' both ends). */
export async function getMachineDashboard(orgId: number, from: string, to: string): Promise<MachineRow[]> {
  const { since, until } = eatRangeToUtc(from, to);
  const { data, error } = await supabase.rpc("machine_dashboard_snapshot", {
    p_org_id: orgId,
    p_since: since,
    p_until: until,
  });
  if (error) throw new Error(error.message);
  return data || [];
}

export async function listFactoryAgents(orgId: number): Promise<FactoryAgent[]> {
  const { data, error } = await supabase
    .from("factory_agents")
    .select("id, name, last_seen_at, active")
    .eq("org_id", orgId)
    .eq("active", true);
  if (error) throw new Error(error.message);
  return data || [];
}

export async function getUnmappedCrafts(orgId: number) {
  const { data, error } = await supabase.rpc("unmapped_machine_crafts", { p_org_id: orgId });
  if (error) throw new Error(error.message);
  return data || [];
}

export async function mapMachineCraft(
  orgId: number,
  machineId: number,
  craftId: string,
  productId: number,
  cavityOverride: number | null = null
) {
  const { error } = await supabase.rpc("map_machine_craft", {
    p_org_id: orgId,
    p_machine_id: machineId,
    p_craft_id: craftId,
    p_product_id: productId,
    p_cavity_override: cavityOverride,
  });
  if (error) throw new Error(error.message);
}

// ── Inspector ─────────────────────────────────────────────

export type MachineMapping = {
  craft_id: string;
  product_id: number;
  cavity_override: number | null;
  product_name: string | null;
  recipe_cavities: number | null;
};

export type MachineInspectorData = {
  /** The machine-specific extras (`values` JSONB) from the latest reading. */
  extraValues: Record<string, number | string | boolean | null> | null;
  extraValuesAt: string | null;
  mappings: MachineMapping[];
};

/** Per-machine cavity knowledge for the cards: override + recipe cavities,
 *  keyed "machineId:craftId". One org-wide fetch per dashboard load. */
export type CavityInfo = { override: number | null; recipe: number | null };

export async function getCavityInfo(orgId: number): Promise<Map<string, CavityInfo>> {
  const { data: maps, error } = await supabase
    .from("machine_product_map")
    .select("machine_id, craft_id, product_id, cavity_override")
    .eq("org_id", orgId);
  if (error) throw new Error(error.message);
  const rows = maps || [];
  const productIds = [...new Set(rows.map((m) => m.product_id))];
  const recipeByProduct = new Map<number, number>();
  if (productIds.length) {
    const { data: boms, error: bomErr } = await supabase
      .from("boms")
      .select("product_id, cavities")
      .eq("org_id", orgId)
      .eq("active", true)
      .in("product_id", productIds);
    if (bomErr) throw new Error(bomErr.message);
    for (const b of boms || []) {
      if (b.cavities != null) recipeByProduct.set(b.product_id, b.cavities);
    }
  }
  return new Map(
    rows.map((m) => [
      `${m.machine_id}:${m.craft_id}`,
      { override: m.cavity_override, recipe: recipeByProduct.get(m.product_id) ?? null },
    ])
  );
}

export async function getMachineInspectorData(orgId: number, machineId: number): Promise<MachineInspectorData> {
  const [reading, maps] = await Promise.all([
    supabase
      .from("machine_readings")
      .select("observed_at, values")
      .eq("machine_id", machineId)
      .order("observed_at", { ascending: false })
      .limit(1),
    supabase
      .from("machine_product_map")
      .select("craft_id, product_id, cavity_override, products(name)")
      .eq("org_id", orgId)
      .eq("machine_id", machineId),
  ]);
  if (reading.error) throw new Error(reading.error.message);
  if (maps.error) throw new Error(maps.error.message);

  const mapRows = maps.data || [];
  const productIds = [...new Set(mapRows.map((m) => m.product_id))];
  const recipeByProduct = new Map<number, number>();
  if (productIds.length) {
    const { data: boms, error: bomErr } = await supabase
      .from("boms")
      .select("product_id, cavities")
      .eq("org_id", orgId)
      .eq("active", true)
      .in("product_id", productIds);
    if (bomErr) throw new Error(bomErr.message);
    for (const b of boms || []) {
      if (b.cavities != null) recipeByProduct.set(b.product_id, b.cavities);
    }
  }

  const latest = reading.data?.[0];
  return {
    extraValues: (latest?.values as MachineInspectorData["extraValues"]) ?? null,
    extraValuesAt: latest?.observed_at ?? null,
    mappings: mapRows.map((m) => {
      // supabase-js types the FK embed loosely; at runtime a to-one embed is an object.
      const prod = m.products as unknown as { name: string } | { name: string }[] | null;
      return {
        craft_id: m.craft_id,
        product_id: m.product_id,
        cavity_override: m.cavity_override,
        product_name: (Array.isArray(prod) ? prod[0]?.name : prod?.name) ?? null,
        recipe_cavities: recipeByProduct.get(m.product_id) ?? null,
      };
    }),
  };
}

// ── Per-count actions (action machines) ───────────────────

export type CountAction = {
  machine_id: number;
  product_id: number;
  qty_per_count: number;
};

export async function getCountAction(orgId: number, machineId: number): Promise<CountAction | null> {
  const { data, error } = await supabase
    .from("machine_count_actions")
    .select("machine_id, product_id, qty_per_count")
    .eq("org_id", orgId)
    .eq("machine_id", machineId)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return data;
}

export async function setMovementCountAction(orgId: number, machineId: number, productId: number, qtyPerCount: number) {
  const { error } = await supabase.from("machine_count_actions").upsert({
    machine_id: machineId,
    org_id: orgId,
    product_id: productId,
    qty_per_count: qtyPerCount,
  });
  if (error) throw new Error(error.message);
}

export async function clearCountAction(orgId: number, machineId: number) {
  const { error } = await supabase
    .from("machine_count_actions")
    .delete()
    .eq("org_id", orgId)
    .eq("machine_id", machineId);
  if (error) throw new Error(error.message);
}

/** Post one day's counts. With productId ("what was wrapped today?") the
 *  product's PACKAGING recipe lines bill; without it, the machine's fixed
 *  fallback action does. Idempotent per machine per day. */
export async function postCountAction(orgId: number, machineId: number, day?: string, productId?: number) {
  const { error } = await supabase.rpc("post_count_action", {
    p_org_id: orgId,
    p_machine_id: machineId,
    p_day: day ?? null,
    p_counts_override: null,
    p_product_id: productId ?? null,
  });
  if (error) throw new Error(error.message);
}

export async function listConsumables(orgId: number) {
  const { data, error } = await supabase
    .from("products")
    .select("id, name, unit_of_measure")
    .eq("org_id", orgId)
    .in("kind", ["raw_material", "consumable"])
    .eq("active", true)
    .order("name");
  if (error) throw new Error(error.message);
  return data || [];
}

export async function listProductsForMapping(orgId: number) {
  // Moulders typically make in-house components now (two-layer BOM), so
  // craft mapping and wrap posting offer both.
  const { data, error } = await supabase
    .from("products")
    .select("id, name, sku")
    .eq("org_id", orgId)
    .in("kind", ["finished_good", "component"])
    .eq("active", true)
    .order("name");
  if (error) throw new Error(error.message);
  return data || [];
}
