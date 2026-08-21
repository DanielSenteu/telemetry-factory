// Demand rates from the sales mirror (external_demand_monthly, built in the
// Zoho integration). Used for display math only — weeks-of-cover badges.
// The Make Next suggestion engine is deliberately NOT built yet.

import { supabase } from "@/lib/supabase/browser";

/** Average units/month per product over the last `months` calendar months. */
export async function getMonthlyDemandRates(orgId: number, months = 3): Promise<Map<number, number>> {
  const since = new Date();
  since.setMonth(since.getMonth() - months);
  const sinceStr = `${since.getFullYear()}-${String(since.getMonth() + 1).padStart(2, "0")}-01`;

  const { data, error } = await supabase
    .from("external_demand_monthly")
    .select("product_id, month, quantity_sold")
    .eq("org_id", orgId)
    .not("product_id", "is", null)
    .gte("month", sinceStr);
  if (error) throw new Error(error.message);

  const byProduct = new Map<number, { qty: number; months: Set<string> }>();
  for (const r of data || []) {
    const e = byProduct.get(r.product_id) ?? { qty: 0, months: new Set<string>() };
    e.qty += Number(r.quantity_sold || 0);
    e.months.add(r.month);
    byProduct.set(r.product_id, e);
  }
  const rates = new Map<number, number>();
  for (const [pid, e] of byProduct) {
    if (e.months.size > 0) rates.set(pid, e.qty / e.months.size);
  }
  return rates;
}
