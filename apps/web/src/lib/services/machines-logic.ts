// Pure machine logic — no I/O, fully unit-tested. Ported from v1
// machinesService.js with its test suite (which v2 initially forgot: the code
// crossed, the tests didn't — caught in review, CONVENTIONS rule 15).

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
  product_id: number | null;
  product_name: string | null;
  mold_cavity: number | null;
  power_kwh: number | null;
  today_shots: number;
  today_parts_gross: number;
  today_scrap: number;
  recent_shots: number;
  alarms: { state: number; ids: string[] } | null;
  // Returned by the snapshot RPC; optional so fixtures stay minimal.
  mac?: string | null;
  ip?: string | null;
  heat_state?: number | null;
  plan_count?: number | null;
  shot_count?: number | null;
  material?: string | null;
};

// ── Machine profiles ──────────────────────────────────────
// What one count MEANS differs per machine kind; the profile registry lives
// in code, never in per-customer config (CONVENTIONS rule 8). Per-machine
// config is parameters only (cavity override, mappings), never meaning.

export type MachineProfile = {
  kind: "shots" | "actions" | "monitor";
  /** Label under the big number on the card. */
  countNoun: string;
  /** Whether shots × cavities applies (injection molding). */
  usesCavities: boolean;
  /** One-sentence interpretation, shown in the inspector. */
  reads: string;
};

export function machineProfile(machineType: string | null | undefined): MachineProfile {
  switch ((machineType || "").toLowerCase()) {
    case "":
    case "injection":
      return {
        kind: "shots",
        countNoun: "good parts",
        usesCavities: true,
        reads: "Counts shots — every cycle fills the mould once. Parts = shots × cavities.",
      };
    case "wrapping":
      return {
        kind: "actions",
        countNoun: "wrapped",
        usesCavities: false,
        reads: "Each count is one finished unit, straight off the machine. No cavities involved.",
      };
    case "monitor":
      return {
        kind: "monitor",
        countNoun: "",
        usesCavities: false,
        reads: "Reports state only — output is recorded manually.",
      };
    default:
      return {
        kind: "actions",
        countNoun: "units",
        usesCavities: false,
        reads: "Each count is one finished unit, straight off the machine.",
      };
  }
}

// ── Cavity verdict ────────────────────────────────────────
// Three opinions can exist: the controller panel (reported per reading), the
// recipe's mould setup, and an admin override on the craft mapping. The
// override wins, then the controller, then 1. A recipe that disagrees with
// the value in use is a mismatch worth flagging — parts counting and material
// balance would be using different mould geometries.

export type CavityVerdict = {
  value: number;
  source: "override" | "controller" | "default";
  recipe: number | null;
  mismatch: boolean;
};

export function effectiveCavity(
  controller: number | null | undefined,
  override: number | null | undefined,
  recipe: number | null | undefined
): CavityVerdict {
  const value =
    override != null && override > 0 ? override : controller != null && controller > 0 ? controller : 1;
  const source =
    override != null && override > 0 ? "override" : controller != null && controller > 0 ? "controller" : "default";
  const rec = recipe != null && recipe > 0 ? recipe : null;
  return { value, source, recipe: rec, mismatch: rec != null && rec !== value };
}

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

export function eatRangeToUtc(from: string, to: string) {
  const [fy, fm, fd] = from.split("-").map(Number);
  const [ty, tm, td] = to.split("-").map(Number);
  return {
    since: new Date(Date.UTC(fy, fm - 1, fd) - EAT_MS).toISOString(),
    until: new Date(Date.UTC(ty, tm - 1, td + 1) - EAT_MS).toISOString(),
  };
}

export function formatNairobi(isoString: string | null, opts: Intl.DateTimeFormatOptions = { hour: "2-digit", minute: "2-digit", hour12: false }) {
  if (!isoString) return "—";
  return new Date(isoString).toLocaleString("en-KE", { timeZone: "Africa/Nairobi", ...opts });
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
