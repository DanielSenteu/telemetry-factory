import { readFileSync } from "node:fs";

export interface MachineConfig {
  /** Display name until the box tells us its MAC. */
  name: string;
  /** e.g. opc.tcp://192.168.2.130:16664 (real box) or opc.tcp://127.0.0.1:26543 (simulator) */
  endpoint: string;
}

export interface ModbusDeviceConfig {
  /** Display name, e.g. "CV-350". */
  name: string;
  /** IP of the Waveshare RS485-TO-ETH adapter. */
  host: string;
  /** Modbus TCP port (Waveshare default = 502). */
  port: number;
  /** Modbus slave / unit ID (Xinje PACK-30 default = 1). */
  unitId: number;
  /**
   * Stable unique identifier used as the "MAC" in the cloud (machines table keyed
   * by this per org). Pick something that never changes — e.g. "CV350-WAVESHARE-001".
   * The Waveshare box has no OPC UA identity, so we configure ours.
   */
  machineKey: string;
}

export interface AgentConfig {
  /** Cloud ingestion URL (Supabase edge function). Empty = local mode: log only. */
  cloudUrl: string;
  /** Org-bound agent token (from factory_agents). Empty = local mode. */
  agentToken: string;
  /** OPC UA machines (Haijing / tmSCADA boxes). */
  machines?: MachineConfig[];
  /** Modbus TCP devices (CV-350 via Waveshare RS485-TO-ETH). */
  modbusDevices?: ModbusDeviceConfig[];
  /** Poll interval for OPC UA status params, seconds (vendor: ≥30; simulator can go lower). */
  statusPollSec?: number;
  /** Poll interval for Modbus fast registers, milliseconds (default 1000). */
  modbusFastPollMs?: number;
  /** Poll interval for Modbus slow/static registers, seconds (default 30). */
  modbusSlowPollSec?: number;
}

export function loadConfig(path: string): AgentConfig {
  const raw = JSON.parse(readFileSync(path, "utf-8")) as AgentConfig;

  const hasMachines = Array.isArray(raw.machines) && raw.machines.length > 0;
  const hasModbus = Array.isArray(raw.modbusDevices) && raw.modbusDevices.length > 0;

  if (!hasMachines && !hasModbus) {
    throw new Error(`config ${path}: must have at least one entry in "machines" or "modbusDevices"`);
  }

  for (const m of raw.machines ?? []) {
    if (!m.endpoint?.startsWith("opc.tcp://")) {
      throw new Error(`config ${path}: machine "${m.name}" endpoint must start with opc.tcp://`);
    }
  }

  for (const d of raw.modbusDevices ?? []) {
    if (!d.host || !d.machineKey) {
      throw new Error(`config ${path}: modbusDevice "${d.name}" must have host and machineKey`);
    }
  }

  return {
    statusPollSec: 30,
    modbusFastPollMs: 1000,
    modbusSlowPollSec: 30,
    ...raw,
  };
}
