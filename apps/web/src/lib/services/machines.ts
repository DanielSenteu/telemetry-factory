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

export async function mapMachineCraft(orgId: number, machineId: number, craftId: string, productId: number) {
  const { error } = await supabase.rpc("map_machine_craft", {
    p_org_id: orgId,
    p_machine_id: machineId,
    p_craft_id: craftId,
    p_product_id: productId,
    p_cavity_override: null,
  });
  if (error) throw new Error(error.message);
}

export async function listProductsForMapping(orgId: number) {
  const { data, error } = await supabase
    .from("products")
    .select("id, name, sku")
    .eq("org_id", orgId)
    .eq("kind", "finished_good")
    .eq("active", true)
    .order("name");
  if (error) throw new Error(error.message);
  return data || [];
}
