// Fake tmSCADA-iD201: an OPC UA server exposing the same tm* parameters a real
// TECHMATION gateway box exposes, backed by MachineModel state machines.
//
//   pnpm simulator                 → 2 machines on ports 26543, 26544
//   pnpm simulator -- --machines 4 → more machines, sequential ports
//
// Matches the real box's constraints: anonymous auth, no security, UA-TCP binary.
// (Real boxes listen on 16664; we use 2654x locally to avoid colliding with a
// real gateway on a dev network.)

import { OPCUAServer, Variant, DataType, StatusCodes } from "node-opcua";
import { MachineModel } from "./machine-model.js";
import { PARAMS, type ParamDef } from "../params.js";

const TICK_MS = 500;
const BASE_PORT = 26543;

function argInt(flag: string, fallback: number): number {
  const i = process.argv.indexOf(flag);
  const raw = i >= 0 ? process.argv[i + 1] : undefined;
  const n = raw ? parseInt(raw, 10) : NaN;
  return Number.isFinite(n) ? n : fallback;
}

function fakeMac(index: number): string {
  return `00:1A:C5:00:00:${(index + 1).toString(16).padStart(2, "0").toUpperCase()}`;
}

function paramValue(model: MachineModel, p: ParamDef, mac: string, port: number): Variant {
  const str = (v: string) => new Variant({ dataType: DataType.String, value: v });
  const u16 = (v: number) => new Variant({ dataType: DataType.UInt16, value: v });
  const u32 = (v: number) => new Variant({ dataType: DataType.UInt32, value: v });
  const f32 = (v: number) => new Variant({ dataType: DataType.Float, value: v });

  switch (p.key) {
    case "online_state": return u16(1);
    case "machine_mac": return str(mac);
    case "machine_ip": return str(`127.0.0.1:${port}`);
    case "operate_mode": return u16(model.operateMode);
    case "motor_state": return u16(model.motorState);
    case "heat_state": return u16(model.heatState);
    case "craft_id": return str(model.craftId);
    case "material": return str(model.material);
    case "mold_cavity": return u16(model.moldCavity);
    case "plan_count": return u32(model.planCount);
    case "alarm_state": return u16(model.alarmState);
    case "alarm_id_1": return str(model.alarmId1);
    case "power_kwh": return f32(model.powerKwh);
    case "shot_count": return u32(model.shotCount);
    case "inferior_count": return f32(model.inferiorCount);
    case "cycle_time": return f32(model.cycleTimeSec);
    default: return new Variant({ dataType: DataType.StatusCode, value: StatusCodes.BadNodeIdUnknown });
  }
}

async function startMachine(index: number, cycleTimeSec: number): Promise<void> {
  const port = BASE_PORT + index;
  const name = `SIM-IMM-${index + 1}`;
  const mac = fakeMac(index);
  const model = new MachineModel({
    name,
    cycleTimeSec,
    // machine 2 pretends its power meter isn't wired → sentinel exercise
    powerMeterAvailable: index !== 1,
  });

  const server = new OPCUAServer({
    port,
    resourcePath: "",
    buildInfo: { productName: "tmSCADA-iD201-SIM", buildNumber: "3", buildDate: new Date("2024-10-01") },
  });

  await server.initialize();
  const addressSpace = server.engine.addressSpace!;
  const ns = addressSpace.getOwnNamespace();
  const device = ns.addObject({
    organizedBy: addressSpace.rootFolder.objects,
    browseName: "tmMachine",
  });

  for (const p of PARAMS) {
    const dataType =
      p.type === "String" ? "String" : p.type === "Float" ? "Float" : p.type === "UInt32" ? "UInt32" : "UInt16";
    ns.addVariable({
      componentOf: device,
      browseName: p.id,
      nodeId: `s=${p.id}`,
      dataType,
      minimumSamplingInterval: 100,
      value: { get: () => paramValue(model, p, mac, port) },
    });
  }

  setInterval(() => model.tick(TICK_MS / 1000), TICK_MS);

  await server.start();
  console.log(
    `[simulator] ${name} listening on opc.tcp://127.0.0.1:${port}  (mac ${mac}, craft ${model.craftId}, cavity ${model.moldCavity})`
  );
}

const machineCount = argInt("--machines", 2);
const cycleTimeSec = argInt("--cycle", 2);

console.log(`[simulator] starting ${machineCount} fake machine(s), cycle ~${cycleTimeSec}s ...`);
for (let i = 0; i < machineCount; i++) {
  await startMachine(i, cycleTimeSec);
}
console.log(`[simulator] up. Ctrl+C to stop.`);
