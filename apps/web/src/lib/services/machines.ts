// Ported from v1 apps/web-admin/src/lib/machinesService.js — the proven
// machine-dashboard service. Logic unchanged; only typed and repointed at the
// v2 browser client. CONVENTIONS rule 6: Kenya time is a decision — all day
// boundaries go through the EAT helpers here.

import { supabase } from "@/lib/supabase/browser";

export const OFFLINE_AFTER_MS = 120_000; // no reading in 2 min ⇒ machine offline
export const AGENT_STALE_MS = 60_000;    // last_seen_at older ⇒ collector offline

const EAT_MS = 3 * 60 * 60 * 1000;

export type MachineRow = {
  machine_id: number;
  name: string;
  machine_type: string | null;
  observed_at: string | null;
  online_state: number | null;
  operate_mode: number | null;
  motor_state: number | null;
  cycle_time: number | null;
  craft_id: string | null;
  product_name: string | null;
  mold_cavity: number | null;
  power_kwh: number | null;
  today_shots: number;
  today_parts_gross: number;
  today_scrap: number;
  recent_shots: number;
  alarms: { state: number; ids: string[] } | null;
};

export type FactoryAgent = { id: number; name: string; last_seen_at: string | null; active: boolean };

export function nairobiDateString(date = new Date()): string {
  const nd = new Date(date.getTime() + EAT_MS);
  return `${nd.getUTCFullYear()}-${String(nd.getUTCMonth() + 1).padStart(2, "0")}-${String(nd.getUTCDate()).padStart(2, "0")}`;
}

export function nairobiPresetRange(preset: "today" | "yesterday" | "week", now = new Date()) {
  const nd = new Date(now.getTime() + EAT_MS);
  const y = nd.getUTCFullYear(), mo = nd.getUTCMonth(), d = nd.getUTCDate(), dow = nd.getUTCDay();
  const kd = (ky: number, km: number, kday: number) => nairobiDateString(new Date(Date.UTC(ky, km, kday)));
  const today = kd(y, mo, d);
  if (preset === "yesterday") { const t = kd(y, mo, d - 1); return { from: t, to: t }; }
  if (preset === "week") { const back = dow === 0 ? 6 : dow - 1; return { from: kd(y, mo, d - back), to: today }; }
  return { from: today, to: today };
}

export function formatNairobi(isoString: string | null, opts: Intl.DateTimeFormatOptions = { hour: "2-digit", minute: "2-digit", hour12: false }) {
  if (!isoString) return "—";
  return new Date(isoString).toLocaleString("en-KE", { timeZone: "Africa/Nairobi", ...opts });
}

/** Snapshot for an inclusive Kenya date range ('YYYY-MM-DD' both ends). */
export async function getMachineDashboard(orgId: number, from: string, to: string): Promise<MachineRow[]> {
  const [fy, fm, fd] = from.split("-").map(Number);
  const [ty, tm, td] = to.split("-").map(Number);
  const pSince = new Date(Date.UTC(fy, fm - 1, fd) - EAT_MS).toISOString();
  const pUntil = new Date(Date.UTC(ty, tm - 1, td + 1) - EAT_MS).toISOString();
  const { data, error } = await supabase.rpc("machine_dashboard_snapshot", {
    p_org_id: orgId,
    p_since: pSince,
    p_until: pUntil,
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
    .order("name");
  if (error) throw new Error(error.message);
  return data || [];
}

// Machine state, derived from the latest reading. Order matters:
// offline (silent/stale) > alarm > running > idle. online_state=0 with fresh
// data is standby (idle), not offline — "offline" is reserved for stale data.
// CV-350 (Modbus) has no motor_state: recent output is the running signal.
export function deriveMachineState(row: MachineRow, nowMs = Date.now()): "running" | "idle" | "alarm" | "offline" {
  if (!row.observed_at) return "offline";
  if (nowMs - Date.parse(row.observed_at) > OFFLINE_AFTER_MS) return "offline";
  if (row.alarms && row.alarms.state > 0) return "alarm";
  const recentActivity = row.recent_shots > 0;
  if (row.motor_state === 1 && (row.operate_mode === 2 || recentActivity)) return "running";
  if (row.motor_state == null && recentActivity) return "running";
  return "idle";
}

export function goodParts(row: MachineRow): number {
  return Math.max(0, row.today_parts_gross - Math.round(row.today_scrap));
}

export function agentIsStale(agent: FactoryAgent, nowMs = Date.now()): boolean {
  return !agent.last_seen_at || nowMs - Date.parse(agent.last_seen_at) > AGENT_STALE_MS;
}
