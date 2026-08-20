// The ~15 (of 455) TECHMATION OPC UA parameters we consume.
// Source: docs/hardware/TECHMATION OPCUA Parameter of Injection Machine（EN）202409.pdf
//
// Each parameter has a browse/ID name (e.g. "tmShotCount") and a numeric NodeId
// in the vendor doc. Real boxes are addressed by NodeId; which namespace they
// live in will be confirmed against a physical box on go-live day, so the
// node-id *form* is configurable per machine profile — the agent logic keys off
// the stable `key` only.

export type ParamKind = "hot" | "status";
export type ParamType = "UInt16" | "UInt32" | "Float" | "String";

export interface ParamDef {
  /** Stable internal key — also the column name in machine_readings. */
  key: string;
  /** Vendor ID / browse name, e.g. "tmShotCount". */
  id: string;
  /** Numeric NodeId from the vendor PDF (informational until verified on real hardware). */
  vendorNodeId: number;
  type: ParamType;
  /** hot = datachange subscription; status = slow poll (vendor says ≥30s). */
  kind: ParamKind;
}

export const PARAMS: ParamDef[] = [
  // -- status (polled) --
  { key: "online_state", id: "tmOnlineState", vendorNodeId: 123457, type: "UInt16", kind: "status" },
  { key: "machine_mac", id: "tmMachineMac", vendorNodeId: 123459, type: "String", kind: "status" },
  { key: "machine_ip", id: "tmMachineIP", vendorNodeId: 123460, type: "String", kind: "status" },
  { key: "operate_mode", id: "tmOperateMode", vendorNodeId: 1117792, type: "UInt16", kind: "status" },
  { key: "motor_state", id: "tmMotorState", vendorNodeId: 1117789, type: "UInt16", kind: "status" },
  { key: "heat_state", id: "tmHeatState", vendorNodeId: 1117788, type: "UInt16", kind: "status" },
  { key: "craft_id", id: "tmCraftID", vendorNodeId: 1125680, type: "String", kind: "status" },
  { key: "material", id: "tmMaterial", vendorNodeId: 1125681, type: "String", kind: "status" },
  { key: "mold_cavity", id: "tmMoldCavity", vendorNodeId: 1125380, type: "UInt16", kind: "status" },
  { key: "plan_count", id: "tmPlanCount", vendorNodeId: 1125381, type: "UInt32", kind: "status" },
  { key: "alarm_state", id: "tmAlarmState", vendorNodeId: 1117790, type: "UInt16", kind: "status" },
  { key: "alarm_id_1", id: "tmAlarmID1", vendorNodeId: 123461, type: "String", kind: "status" },
  { key: "power_kwh", id: "tmPowerConsumption", vendorNodeId: 1117290, type: "Float", kind: "status" },

  // -- status: job / recipe settings (confirmed live on Haijing HJ168S AK628S controller) --
  // Note: browse names for color/temps/injection profile confirmed on hardware via OPC UA
  // browser; numeric NodeIds not yet extracted from PDF — string-form IDs are what the
  // agent actually uses (ns=1;s=<id>) and are confirmed working.
  { key: "color",           id: "tmColor",         vendorNodeId: 0, type: "String", kind: "status" },

  // Barrel zone temperatures — actual (°C)
  { key: "temp1_current",   id: "tmBarrelTemp1",   vendorNodeId: 0, type: "Float",  kind: "status" },
  { key: "temp2_current",   id: "tmBarrelTemp2",   vendorNodeId: 0, type: "Float",  kind: "status" },
  { key: "temp3_current",   id: "tmBarrelTemp3",   vendorNodeId: 0, type: "Float",  kind: "status" },
  { key: "temp4_current",   id: "tmBarrelTemp4",   vendorNodeId: 0, type: "Float",  kind: "status" },
  { key: "temp5_current",   id: "tmBarrelTemp5",   vendorNodeId: 0, type: "Float",  kind: "status" },
  // Hydraulic oil temperature — actual (°C)
  { key: "temp_oil_current",id: "tmOilTemp",        vendorNodeId: 0, type: "Float",  kind: "status" },

  // Barrel zone temperatures — setpoints (°C)
  { key: "temp1_set",       id: "tmBarrelTempSet1", vendorNodeId: 0, type: "Float",  kind: "status" },
  { key: "temp2_set",       id: "tmBarrelTempSet2", vendorNodeId: 0, type: "Float",  kind: "status" },
  { key: "temp3_set",       id: "tmBarrelTempSet3", vendorNodeId: 0, type: "Float",  kind: "status" },
  { key: "temp4_set",       id: "tmBarrelTempSet4", vendorNodeId: 0, type: "Float",  kind: "status" },
  { key: "temp5_set",       id: "tmBarrelTempSet5", vendorNodeId: 0, type: "Float",  kind: "status" },

  // Injection profile (only stages 1-2 carry real data on this craft; 3-6 unused)
  { key: "inj_press_1",     id: "tmInjPress1",     vendorNodeId: 0, type: "Float",  kind: "status" },
  { key: "inj_press_2",     id: "tmInjPress2",     vendorNodeId: 0, type: "Float",  kind: "status" },
  { key: "inj_speed_1",     id: "tmInjSpeed1",     vendorNodeId: 0, type: "Float",  kind: "status" },
  { key: "inj_speed_2",     id: "tmInjSpeed2",     vendorNodeId: 0, type: "Float",  kind: "status" },

  // Cycle stage timings (seconds)
  { key: "cooling_time",    id: "tmCoolingTime",   vendorNodeId: 0, type: "Float",  kind: "status" },
  { key: "hold_time_1",     id: "tmHoldTime1",     vendorNodeId: 0, type: "Float",  kind: "status" },
  { key: "inj2_hold_time",  id: "tmInj2HoldTime",  vendorNodeId: 0, type: "Float",  kind: "status" },

  // -- hot (datachange subscription) --
  { key: "shot_count", id: "tmShotCount", vendorNodeId: 1117188, type: "UInt32", kind: "hot" },
  { key: "inferior_count", id: "tmInferior", vendorNodeId: 1117191, type: "Float", kind: "hot" },
  { key: "cycle_time", id: "tmCycleTime", vendorNodeId: 1114738, type: "Float", kind: "hot" },
];

export const PARAM_BY_KEY = new Map(PARAMS.map((p) => [p.key, p]));

/** Default node-id builder: string identifier in namespace 1 (what our simulator
 *  exposes, and UaExpert shows Techmation boxes browse by ID name). Overridable
 *  per machine in config once verified against real hardware. */
export function defaultNodeId(p: ParamDef): string {
  return `ns=1;s=${p.id}`;
}
