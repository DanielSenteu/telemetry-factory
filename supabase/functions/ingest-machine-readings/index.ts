// Ingestion endpoint for the on-prem factory agent (apps/factory-agent).
//
// Auth: `x-agent-token` header (minted by create_factory_agent(), stored as a
// SHA-256 hash in factory_agents). NOT a Supabase JWT — deploy this function
// with --no-verify-jwt. The token→org binding is the multi-org boundary: a
// valid token can only ever write machines/readings into its own org.
//
// Contract (matches the agent's Reading shape):
//   POST { readings: [{ machine, machine_mac, observed_at, values: {...} }] }
//   → { machines: n, inserted: n, rejected: n }
//
// Idempotent: at-least-once delivery from the agent's disk queue is deduped
// here via ON CONFLICT (machine_id, observed_at) DO NOTHING.
//
// Machine types supported:
//   • "techmation-opcua"  — Haijing HJ168S (OPC UA via tmSCADA-iD201 box)
//   • "xinje-modbus-tcp"  — CV-350 packing machine (Modbus TCP via Waveshare)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const MAX_READINGS_PER_POST = 2000;
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000; // reject observed_at > now + 5min

interface AgentReading {
  machine: string;
  machine_mac: string | null;
  observed_at: string;
  values: Record<string, number | string | null>;
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Pull named Haijing extended fields from values into a JSONB object.
 *  Only includes keys that are actually present (not null) to keep the
 *  column sparse for readings that don't have these fields yet. */
function haijingExtendedValues(v: Record<string, number | string | null>): Record<string, unknown> | null {
  const HAIJING_EXTENDED_KEYS = [
    "color",
    "temp1_current", "temp2_current", "temp3_current", "temp4_current", "temp5_current",
    "temp_oil_current",
    "temp1_set", "temp2_set", "temp3_set", "temp4_set", "temp5_set",
    "inj_press_1", "inj_press_2",
    "inj_speed_1", "inj_speed_2",
    "cooling_time", "hold_time_1", "inj2_hold_time",
  ] as const;

  const out: Record<string, unknown> = {};
  let hasAny = false;
  for (const k of HAIJING_EXTENDED_KEYS) {
    if (v[k] !== null && v[k] !== undefined) {
      out[k] = v[k];
      hasAny = true;
    }
  }
  return hasAny ? out : null;
}

/** Build the values JSONB for a CV-350 reading. */
function cv350Values(v: Record<string, number | string | null>): Record<string, unknown> | null {
  const CV350_KEYS = [
    "servo_counter_1", "servo_counter_2", "servo_counter_3",
    "temp_a", "temp_b",
    "length_mm", "pack_speed_mpm",
    "thg_pos_mm", "cut_pos_1", "cut_pos_2",
    "secondary_counter",
  ] as const;

  const out: Record<string, unknown> = {};
  let hasAny = false;
  for (const k of CV350_KEYS) {
    if (v[k] !== null && v[k] !== undefined) {
      out[k] = v[k];
      hasAny = true;
    }
  }
  return hasAny ? out : null;
}

serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const token = req.headers.get("x-agent-token");
  if (!token) return json({ error: "missing x-agent-token" }, 401);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // ── authenticate the agent ────────────────────────────────────────────
  const tokenHash = await sha256Hex(token);
  const { data: agent } = await supabase
    .from("factory_agents")
    .select("id, org_id")
    .eq("token_hash", tokenHash)
    .eq("active", true)
    .maybeSingle();
  if (!agent) return json({ error: "invalid or inactive agent token" }, 403);

  // ── parse + validate batch ────────────────────────────────────────────
  let readings: AgentReading[];
  try {
    const body = await req.json();
    readings = body.readings;
    if (!Array.isArray(readings)) throw new Error("readings must be an array");
    if (readings.length > MAX_READINGS_PER_POST) {
      return json({ error: `max ${MAX_READINGS_PER_POST} readings per POST` }, 413);
    }
  } catch (e) {
    return json({ error: `bad request body: ${e instanceof Error ? e.message : e}` }, 400);
  }

  const now = Date.now();
  let rejected = 0;
  const valid = readings.filter((r) => {
    const t = Date.parse(r?.observed_at ?? "");
    const macOk = typeof r?.machine_mac === "string" && r.machine_mac.length > 0;
    const clockOk = Number.isFinite(t) && t <= now + MAX_CLOCK_SKEW_MS;
    if (!macOk || !clockOk || typeof r?.values !== "object" || r.values === null) {
      rejected += 1; // clock-insane or malformed: logged, never inserted
      return false;
    }
    return true;
  });

  // ── upsert machines by (org, MAC) ─────────────────────────────────────
  const byMac = new Map<string, AgentReading>();
  for (const r of valid) byMac.set(r.machine_mac!, r); // last reading wins for name/ip

  const machineIdByMac = new Map<string, number>();
  for (const [mac, r] of byMac) {
    // Identify machine type from the reading's values.machine_type marker
    const machineType = str(r.values.machine_type) ?? "techmation-opcua";

    const { data: machine, error } = await supabase
      .from("machines")
      .upsert(
        {
          org_id: agent.org_id,
          mac,
          name: r.machine,
          ip: str(r.values.machine_ip) ?? null,
          controller_series: machineType === "xinje-modbus-tcp" ? "Xinje PACK-30" : "Techmation AK628S",
          controller_type: machineType,
        },
        { onConflict: "org_id,mac" }
      )
      .select("id")
      .single();
    if (error || !machine) return json({ error: `machine upsert failed: ${error?.message}` }, 500);
    machineIdByMac.set(mac, machine.id);
  }

  // ── bulk insert readings (idempotent) ─────────────────────────────────
  const rows = valid.map((r) => {
    const v = r.values;
    const machineType = str(v.machine_type) ?? "techmation-opcua";
    const isCV350 = machineType === "xinje-modbus-tcp";

    const alarmState = num(v.alarm_state);
    const alarmId = str(v.alarm_id_1);

    return {
      org_id: agent.org_id,
      machine_id: machineIdByMac.get(r.machine_mac!)!,
      observed_at: r.observed_at,

      // ── Core OPC UA fields (Haijing / injection molding) ──
      // For CV-350: shot_count holds bags_produced (primary production counter).
      // All other injection-specific fields will be null for CV-350.
      online_state:   isCV350 ? (num(v.machine_status) === 3000 || num(v.machine_status) === 3001 || num(v.machine_status) === 3511 || num(v.machine_status) === 4000 || num(v.machine_status) === 4002 ? 1 : 0) : num(v.online_state),
      shot_count:     isCV350 ? num(v.bags_produced)    : num(v.shot_count),
      inferior_count: isCV350 ? null                    : num(v.inferior_count),
      operate_mode:   isCV350 ? num(v.machine_status)   : num(v.operate_mode),
      motor_state:    isCV350 ? null                    : num(v.motor_state),
      heat_state:     isCV350 ? null                    : num(v.heat_state),
      cycle_time:     isCV350 ? null                    : num(v.cycle_time),
      craft_id:       isCV350 ? null                    : str(v.craft_id),
      material:       isCV350 ? null                    : str(v.material),
      mold_cavity:    isCV350 ? null                    : num(v.mold_cavity),
      plan_count:     isCV350 ? null                    : num(v.plan_count),
      power_kwh:      isCV350 ? null                    : num(v.power_kwh),
      alarms:
        !isCV350 && alarmState && alarmState > 0
          ? { state: alarmState, ids: alarmId ? [alarmId] : [] }
          : null,

      // ── Machine-type-specific values (JSONB) ──
      values: isCV350 ? cv350Values(v) : haijingExtendedValues(v),
    };
  });

  if (rows.length > 0) {
    const { error } = await supabase
      .from("machine_readings")
      .upsert(rows, { onConflict: "machine_id,observed_at", ignoreDuplicates: true });
    if (error) return json({ error: `insert failed: ${error.message}` }, 500);
  }

  await supabase
    .from("factory_agents")
    .update({ last_seen_at: new Date().toISOString() })
    .eq("id", agent.id);

  return json({ machines: machineIdByMac.size, inserted: rows.length, rejected });
});
