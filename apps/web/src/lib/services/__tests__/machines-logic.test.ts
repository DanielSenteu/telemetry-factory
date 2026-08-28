import { describe, it, expect } from "vitest";
import {
  deriveMachineState,
  goodParts,
  agentIsStale,
  nairobiDateString,
  nairobiPresetRange,
  eatRangeToUtc,
  machineProfile,
  effectiveCavity,
  OFFLINE_AFTER_MS,
  type MachineRow,
} from "../machines-logic";

// Ported from v1's machinesService tests, plus the EAT boundary cases added
// when localMidnightISO was replaced. These exist so a refactor of state or
// timezone logic fails loudly instead of misreporting a factory floor.

const NOW = Date.parse("2026-07-06T12:00:00Z");
const secondsAgo = (s: number) => new Date(NOW - s * 1000).toISOString();

const base: MachineRow = {
  machine_id: 1,
  name: "IMM-1",
  machine_type: null,
  observed_at: secondsAgo(10),
  online_state: 1,
  operate_mode: 2,
  motor_state: 1,
  cycle_time: 18.2,
  craft_id: "SYR-1",
  product_id: 7,
  product_name: "Container",
  mold_cavity: 8,
  power_kwh: 100,
  today_shots: 100,
  today_parts_gross: 800,
  today_scrap: 12,
  recent_shots: 5,
  alarms: null,
};

describe("deriveMachineState", () => {
  it("healthy auto-mode machine is running", () => {
    expect(deriveMachineState(base, NOW)).toBe("running");
  });
  it("never-reported machine is offline", () => {
    expect(deriveMachineState({ ...base, observed_at: null }, NOW)).toBe("offline");
  });
  it("stale data is offline even if the last reading looked healthy", () => {
    expect(deriveMachineState({ ...base, observed_at: secondsAgo(OFFLINE_AFTER_MS / 1000 + 1) }, NOW)).toBe("offline");
  });
  it("active alarm wins over running", () => {
    expect(deriveMachineState({ ...base, alarms: { state: 1, ids: ["E-04"] } }, NOW)).toBe("alarm");
  });
  it("motor off with no recent output is idle", () => {
    expect(deriveMachineState({ ...base, motor_state: 0, recent_shots: 0 }, NOW)).toBe("idle");
  });
  it("CV-350 (no motor_state) counts as running on recent output alone", () => {
    expect(deriveMachineState({ ...base, motor_state: null, operate_mode: null, recent_shots: 3 }, NOW)).toBe("running");
  });
  it("CV-350 without recent output is idle, not offline, while data is fresh", () => {
    expect(deriveMachineState({ ...base, motor_state: null, operate_mode: null, recent_shots: 0 }, NOW)).toBe("idle");
  });
});

describe("goodParts", () => {
  it("gross minus scrap", () => {
    expect(goodParts(base)).toBe(788);
  });
  it("floors at zero — scrap can never make production negative", () => {
    expect(goodParts({ ...base, today_parts_gross: 5, today_scrap: 9 })).toBe(0);
  });
});

describe("agentIsStale", () => {
  it("fresh heartbeat is not stale", () => {
    expect(agentIsStale({ id: 1, name: "a", last_seen_at: secondsAgo(10), active: true }, NOW)).toBe(false);
  });
  it("old heartbeat is stale", () => {
    expect(agentIsStale({ id: 1, name: "a", last_seen_at: secondsAgo(120), active: true }, NOW)).toBe(true);
  });
  it("never seen is stale", () => {
    expect(agentIsStale({ id: 1, name: "a", last_seen_at: null, active: true }, NOW)).toBe(true);
  });
});

describe("Nairobi time (UTC+3) — the boundaries that misfiled v1 production", () => {
  it("22:00 UTC is already tomorrow in Kenya", () => {
    expect(nairobiDateString(new Date("2026-07-06T22:00:00Z"))).toBe("2026-07-07");
    expect(nairobiDateString(new Date("2026-07-06T12:00:00Z"))).toBe("2026-07-06");
  });
  it("'today' preset follows the Kenyan date", () => {
    expect(nairobiPresetRange("today", new Date("2026-07-06T22:00:00Z"))).toEqual({
      from: "2026-07-07",
      to: "2026-07-07",
    });
  });
  it("'week' preset snaps back to Monday", () => {
    // 2026-07-08 is a Wednesday
    expect(nairobiPresetRange("week", new Date("2026-07-08T12:00:00Z")).from).toBe("2026-07-06");
  });
  it("a Kenyan day converts to UTC bounds 21:00 previous day → 21:00 same day", () => {
    expect(eatRangeToUtc("2026-07-06", "2026-07-06")).toEqual({
      since: "2026-07-05T21:00:00.000Z",
      until: "2026-07-06T21:00:00.000Z",
    });
  });
});

describe("machineProfile — what one count means", () => {
  it("null / injection machines count shots and use cavities", () => {
    expect(machineProfile(null).kind).toBe("shots");
    expect(machineProfile("injection").usesCavities).toBe(true);
  });
  it("wrapping machines count finished units directly", () => {
    const p = machineProfile("wrapping");
    expect(p.kind).toBe("actions");
    expect(p.countNoun).toBe("wrapped");
    expect(p.usesCavities).toBe(false);
  });
  it("monitor-only machines count nothing", () => {
    expect(machineProfile("monitor").kind).toBe("monitor");
  });
  it("an unknown type is an action machine, never a molder by accident", () => {
    const p = machineProfile("laser-cutter");
    expect(p.kind).toBe("actions");
    expect(p.usesCavities).toBe(false);
  });
});

describe("effectiveCavity — three opinions, one winner", () => {
  it("controller value wins when it is the only opinion", () => {
    expect(effectiveCavity(8, null, null)).toEqual({ value: 8, source: "controller", recipe: null, mismatch: false });
  });
  it("unset / zero controller falls back to 1 (the invisible-wrong-count case)", () => {
    expect(effectiveCavity(null, null, null).value).toBe(1);
    expect(effectiveCavity(0, null, null)).toMatchObject({ value: 1, source: "default" });
  });
  it("override beats the controller", () => {
    expect(effectiveCavity(1, 12, 12)).toMatchObject({ value: 12, source: "override", mismatch: false });
  });
  it("recipe disagreement is flagged, whoever is winning", () => {
    expect(effectiveCavity(1, null, 12)).toMatchObject({ value: 1, mismatch: true, recipe: 12 });
    expect(effectiveCavity(12, null, 12).mismatch).toBe(false);
  });
  it("a zero/negative recipe is treated as unset, not as a mismatch", () => {
    expect(effectiveCavity(8, null, 0).mismatch).toBe(false);
  });
});
