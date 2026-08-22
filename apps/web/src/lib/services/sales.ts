// Sales = the integrations surface. Provider-blind: everything speaks the
// generic spine (external_documents / external_entity_map / demand view), never
// a vendor's vocabulary. Connecting is a browser redirect to the provider's
// own consent; there is no sync button (cron drives it).

import { supabase } from "@/lib/supabase/browser";

export type IntegrationStatus = {
  id: number;
  provider: string;
  external_org_id: string | null;
  stock_cutover_date: string | null;
  active: boolean;
  backfill_done: boolean;
  last_sync_at: string | null;
  last_sync_status: string | null;
  last_sync_error: string | null;
  connected_at: string | null;
  has_token: boolean;
};

export async function getConnection(orgId: number, provider = "zoho_books"): Promise<IntegrationStatus | null> {
  const { data, error } = await supabase
    .from("integration_status")
    .select("*")
    .eq("org_id", orgId)
    .eq("provider", provider)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return data;
}

export async function getImportedCount(orgId: number, provider = "zoho_books"): Promise<{ total: number; needsMapping: number }> {
  const [{ count: total }, { count: needsMapping }] = await Promise.all([
    supabase.from("external_documents").select("id", { count: "exact", head: true }).eq("org_id", orgId).eq("source_system", provider),
    supabase.from("external_documents").select("id", { count: "exact", head: true }).eq("org_id", orgId).eq("source_system", provider).eq("import_state", "needs_mapping"),
  ]);
  return { total: total ?? 0, needsMapping: needsMapping ?? 0 };
}

export type UnmappedItem = {
  external_item_id: string;
  description: string | null;
  document_count: number;
  total_quantity: number;
  last_sold_on: string | null;
};

export async function listUnmappedItems(orgId: number, provider = "zoho_books"): Promise<UnmappedItem[]> {
  const { data, error } = await supabase
    .from("external_unmapped_items")
    .select("external_item_id, description, document_count, total_quantity, last_sold_on")
    .eq("org_id", orgId)
    .eq("source_system", provider)
    .order("total_quantity", { ascending: false })
    .limit(200);
  if (error) throw new Error(error.message);
  return data || [];
}

export async function mapItemToProduct(orgId: number, externalItemId: string, productId: number, label: string | null, provider = "zoho_books") {
  const { error } = await supabase.rpc("map_external_entity", {
    p_org_id: orgId,
    p_source_system: provider,
    p_entity_type: "product",
    p_external_id: externalItemId,
    p_label: label,
    p_contact_id: null,
    p_product_id: productId,
  });
  if (error) throw new Error(error.message);
}

export type DemandRow = { product_id: number | null; external_item_id: string | null; description: string | null; quantity: number; revenue: number; months: number; perMonth: number };

export async function getDemand(orgId: number, months = 12, provider = "zoho_books"): Promise<DemandRow[]> {
  const since = new Date();
  since.setMonth(since.getMonth() - months);
  const sinceStr = `${since.getFullYear()}-${String(since.getMonth() + 1).padStart(2, "0")}-01`;
  const { data, error } = await supabase
    .from("external_demand_monthly")
    .select("product_id, external_item_id, description, quantity_sold, revenue, month")
    .eq("org_id", orgId)
    .eq("source_system", provider)
    .gte("month", sinceStr);
  if (error) throw new Error(error.message);

  const byItem = new Map<string, DemandRow>();
  for (const r of data || []) {
    const key = r.product_id ? `p:${r.product_id}` : `x:${r.external_item_id}`;
    const e = byItem.get(key) ?? { product_id: r.product_id, external_item_id: r.external_item_id, description: r.description, quantity: 0, revenue: 0, months: 0, perMonth: 0 };
    e.quantity += Number(r.quantity_sold || 0);
    e.revenue += Number(r.revenue || 0);
    e.months += 1;
    byItem.set(key, e);
  }
  return Array.from(byItem.values())
    .map((e) => ({ ...e, perMonth: e.months ? e.quantity / e.months : 0 }))
    .sort((a, b) => b.quantity - a.quantity);
}
