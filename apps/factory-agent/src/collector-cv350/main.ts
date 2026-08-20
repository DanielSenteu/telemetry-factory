// CV-350 pillow packing machine collector (Color Vision Technology, Dongguan).
// Controller: Xinje PACK-30 (ZG3/ZGM family HMI+PLC).
//
// Physical path:
//   Laptop --Ethernet--> Waveshare RS485-TO-ETH (192.168.1.200) --RS485--> Xinje PLC
//
// Protocol: Modbus TCP, port 502, unit ID 1.
//   Waveshare must be configured as TCP Server + "Modbus TCP Protocol" (not raw).
//   Serial settings: 19200 baud, 8N1, even parity.
//
// Register map (all confirmed live against hardware):
//   Reg   0    — machine status code (U16). Running: 3000/3001/3511/4000/4002. Stopped/fault: 10300.
//   Reg 2100    — servo counter 1 (U16, cumulative)
//   Reg 2104    — servo counter 2 (U16, cumulative)
//   Reg 2200    — servo counter 3 (U16, cumulative)
//   Reg 2021    — temperature A (Float32, regs 2021-2022)  ~150-154 °C normal
//   Reg 2303    — temperature B (Float32, regs 2303-2304)  ~47-106 °C depending on state
//   Reg 3001    — length (Float32, regs 3001-3002)         static 150.0 mm
//   Reg 3013    — pack speed (Float32, regs 3013-3014)     ~15.9 m/min at steady run
//   Reg 20002   — bags produced (U16, triple-mirrored at 20002/20004/20008) — PRIMARY counter
//   Reg 43221   — THG position (Float32)                   static 30.0 mm
//   Reg 58626   — position 1 (U16)                         static 70 (cut or thing pos — not yet disambiguated)
//   Reg 58690   — position 2 (U16)                         static 70 (same)
//   Reg 43104   — secondary counter (U16)                  climbs with bags_produced, offset ~52
//
// Polling strategy:
//   fast (~1 s): status, bags_produced, servo counters, temps, pack speed — anything that changes during a run
//   slow (~30 s): length, thg_pos, cut positions, secondary counter — slow/static
//
// Cloud delivery: same DiskQueue + Shipper as the Haijing OPC UA agent.
// The edge function maps bags_produced → shot_count (primary production counter).
//
// Run: pnpm cv350   (reads config.json, falls back to config.example.json)
// Start via Windows Task Scheduler like the Haijing agent (see FACTORY-SETUP.md).

import { existsSync } from "node:fs";
// modbus-serial is a CJS package; its types don't declare a constructor in ESM
// context so we use our own minimal interface for the methods we call.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const ModbusRTU = require("modbus-serial") as new () => ModbusClient;

interface ModbusClient {
  setTimeout(ms: number): void;
  connectTCP(host: string, opts: { port: number }): Promise<void>;
  setID(id: number): void;
  readHoldingRegisters(addr: number, len: number): Promise<{ data: number[]; buffer: Buffer }>;
}

import { loadConfig, type ModbusDeviceConfig } from "../config.js";
import { counterDelta } from "../lib/deltas.js";
import { DiskQueue } from "../lib/queue.js";
import { Shipper } from "../agent/shipper.js";

// ── Register addresses ────────────────────────────────────────────────────────

/** Fast registers: polled every ~1 s. */
const FAST_REGS = {
  machine_status:    { addr: 0,     len: 1, type: "U16"     },
  bags_produced:     { addr: 20002, len: 1, type: "U16"     },
  servo_counter_1:   { addr: 2100,  len: 1, type: "U16"     },
  servo_counter_2:   { addr: 2104,  len: 1, type: "U16"     },
  servo_counter_3:   { addr: 2200,  len: 1, type: "U16"     },
  temp_a:            { addr: 2021,  len: 2, type: "Float32"  },
  temp_b:            { addr: 2303,  len: 2, type: "Float32"  },
  pack_speed_mpm:    { addr: 3013,  len: 2, type: "Float32"  },
} as const;

/** Slow registers: polled every ~30 s (recipe settings / static). */
const SLOW_REGS = {
  length_mm:         { addr: 3001,  len: 2, type: "Float32"  },
  thg_pos_mm:        { addr: 43221, len: 2, type: "Float32"  },
  cut_pos_1:         { addr: 58626, len: 1, type: "U16"      },
  cut_pos_2:         { addr: 58690, len: 1, type: "U16"      },
  secondary_counter: { addr: 43104, len: 1, type: "U16"      },
} as const;

type FastKey = keyof typeof FAST_REGS;
type SlowKey = keyof typeof SLOW_REGS;

// ── Logging ──────────────────────────────────────────────────────────────────

function log(kind: string, payload: unknown): void {
  console.log(JSON.stringify({ at: new Date().toISOString(), kind, ...(payload as object) }));
}

// ── Modbus read helpers ───────────────────────────────────────────────────────

/** Read a single U16 holding register. Returns null on any error. */
async function readU16(client: ModbusClient, addr: number): Promise<number | null> {
  try {
    const { data } = await client.readHoldingRegisters(addr, 1);
    return data[0] ?? null;
  } catch {
    return null;
  }
}

/** Read a Float32 from two consecutive holding registers (big-endian, IEEE 754). */
async function readFloat32(client: ModbusClient, addr: number): Promise<number | null> {
  try {
    const { buffer } = await client.readHoldingRegisters(addr, 2);
    return buffer.readFloatBE(0);
  } catch {
    return null;
  }
}

// ── CV-350 device collector ───────────────────────────────────────────────────

class CV350Collector {
  private latest: Partial<Record<FastKey | SlowKey, number | null>> = {};
  private prevBags: number | null = null;
  private prevServo1: number | null = null;
  private prevServo2: number | null = null;
  private prevServo3: number | null = null;

  constructor(
    private device: ModbusDeviceConfig,
    private queue: DiskQueue | null,
    private fastPollMs: number,
    private slowPollSec: number,
  ) {}

  async run(): Promise<void> {
    // Connect once; reconnect loop is handled below.
    for (;;) {
      try {
        await this.runSession();
      } catch (err) {
        log("cv350_connect_error", { machine: this.device.name, error: String(err) });
        // Back off 10 s before retrying the whole connection
        await sleep(10_000);
      }
    }
  }

  private async runSession(): Promise<void> {
    const client = new ModbusRTU();
    client.setTimeout(3000);

    log("cv350_connecting", {
      machine: this.device.name,
      host: this.device.host,
      port: this.device.port,
      unitId: this.device.unitId,
    });

    await client.connectTCP(this.device.host, { port: this.device.port });
    client.setID(this.device.unitId);

    log("cv350_connected", { machine: this.device.name });

    // Start slow-poll loop in the background (it will run until session dies)
    void this.slowPollLoop(client);

    // Fast-poll loop in the foreground
    for (;;) {
      await this.fastPoll(client);
      this.emitReading();
      await sleep(this.fastPollMs);
    }
  }

  private async fastPoll(client: ModbusClient): Promise<void> {
    for (const [key, reg] of Object.entries(FAST_REGS) as [FastKey, typeof FAST_REGS[FastKey]][]) {
      const val = reg.type === "Float32"
        ? await readFloat32(client, reg.addr)
        : await readU16(client, reg.addr);
      this.latest[key] = val;
    }
  }

  private async slowPollLoop(client: ModbusClient): Promise<void> {
    for (;;) {
      for (const [key, reg] of Object.entries(SLOW_REGS) as [SlowKey, typeof SLOW_REGS[SlowKey]][]) {
        const val = reg.type === "Float32"
          ? await readFloat32(client, reg.addr)
          : await readU16(client, reg.addr);
        this.latest[key] = val;
      }
      await sleep(this.slowPollSec * 1000);
    }
  }

  private emitReading(): void {
    const bags = this.latest.bags_produced ?? null;
    const s1   = this.latest.servo_counter_1 ?? null;
    const s2   = this.latest.servo_counter_2 ?? null;
    const s3   = this.latest.servo_counter_3 ?? null;

    // Reset-aware deltas for all cumulative counters
    const bagsD  = counterDelta(this.prevBags,   bags);
    const servo1D = counterDelta(this.prevServo1, s1);
    const servo2D = counterDelta(this.prevServo2, s2);
    const servo3D = counterDelta(this.prevServo3, s3);

    if (bags  !== null) this.prevBags   = bags;
    if (s1    !== null) this.prevServo1 = s1;
    if (s2    !== null) this.prevServo2 = s2;
    if (s3    !== null) this.prevServo3 = s3;

    const reading = {
      machine:     this.device.name,
      machine_mac: this.device.machineKey,   // stable configured ID (no real MAC on this path)
      observed_at: new Date().toISOString(),
      values: {
        // marker so the edge function knows which code path to use
        machine_type: "xinje-modbus-tcp",

        // fast fields
        machine_status:  this.latest.machine_status  ?? null,
        bags_produced:   bags,
        servo_counter_1: s1,
        servo_counter_2: s2,
        servo_counter_3: s3,
        temp_a:          this.latest.temp_a          ?? null,
        temp_b:          this.latest.temp_b          ?? null,
        pack_speed_mpm:  this.latest.pack_speed_mpm  ?? null,

        // slow / static fields
        length_mm:         this.latest.length_mm         ?? null,
        thg_pos_mm:        this.latest.thg_pos_mm        ?? null,
        cut_pos_1:         this.latest.cut_pos_1         ?? null,
        cut_pos_2:         this.latest.cut_pos_2         ?? null,
        secondary_counter: this.latest.secondary_counter ?? null,
      },
      // deltas
      ...(bagsD   ? { bags_delta:   bagsD.delta,   counter_reset: bagsD.reset }   : {}),
      ...(servo1D ? { servo1_delta: servo1D.delta } : {}),
      ...(servo2D ? { servo2_delta: servo2D.delta } : {}),
      ...(servo3D ? { servo3_delta: servo3D.delta } : {}),
    };

    log("cv350_reading", reading);

    if (this.queue) this.queue.append(reading);
  }
}

// ── helpers ───────────────────────────────────────────────────────────────────

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

// ── entrypoint ────────────────────────────────────────────────────────────────

const argIdx = process.argv.indexOf("--config");
const explicit = argIdx >= 0 ? process.argv[argIdx + 1] : undefined;
const configPath = explicit ?? (existsSync("config.json") ? "config.json" : "config.example.json");

const config = loadConfig(configPath);

if (!config.modbusDevices || config.modbusDevices.length === 0) {
  console.error(JSON.stringify({ at: new Date().toISOString(), kind: "fatal", error: "No modbusDevices in config" }));
  process.exit(1);
}

const cloudMode = Boolean(config.cloudUrl && config.agentToken);
log("cv350_agent_start", { configPath, devices: config.modbusDevices.length, cloudMode });

let queue: DiskQueue | null = null;
if (cloudMode) {
  queue = new DiskQueue("queue-cv350");
  new Shipper(queue, {
    cloudUrl: config.cloudUrl,
    agentToken: config.agentToken,
    log,
  }).start();
}

await Promise.all(
  config.modbusDevices.map((d) =>
    new CV350Collector(
      d,
      queue,
      config.modbusFastPollMs ?? 1000,
      config.modbusSlowPollSec ?? 30,
    ).run().catch((err) => {
      log("cv350_fatal", { machine: d.name, error: String(err) });
    })
  )
);
