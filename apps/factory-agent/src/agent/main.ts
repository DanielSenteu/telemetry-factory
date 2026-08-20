// The factory agent: connects to every configured tmSCADA gateway, subscribes
// to hot params (datachange) + polls status params, filters sentinels, computes
// reset-aware deltas, and emits readings.
//
// Modes:
//   local mode (cloudUrl empty)  → readings go to stdout as JSON lines only
//   cloud mode (cloudUrl set)    → readings ALSO hit a disk queue and are
//     shipped in batches to the ingest-machine-readings edge function.
//     At-least-once delivery; the server dedupes on (machine_id, observed_at).
//
//   pnpm agent                    → uses ./config.json (falls back to config.example.json)
//   pnpm agent -- --config x.json

import {
  AttributeIds,
  MessageSecurityMode,
  OPCUAClient,
  SecurityPolicy,
  TimestampsToReturn,
  type ClientSession,
  type DataValue,
} from "node-opcua";
import { existsSync } from "node:fs";
import { loadConfig, type MachineConfig } from "../config.js";
import { PARAMS, defaultNodeId, type ParamDef } from "../params.js";
import { cleanNumeric } from "../lib/sentinel.js";
import { counterDelta } from "../lib/deltas.js";
import { DiskQueue } from "../lib/queue.js";
import { Shipper } from "./shipper.js";

interface Reading {
  machine: string;
  machine_mac: string | null;
  observed_at: string;
  values: Record<string, number | string | null>;
  shots_delta?: number;
  scrap_delta?: number;
  counter_reset?: boolean;
}

function log(kind: string, payload: unknown): void {
  console.log(JSON.stringify({ at: new Date().toISOString(), kind, ...(payload as object) }));
}

function extract(p: ParamDef, dv: DataValue): number | string | null {
  const v = dv.value?.value;
  if (v === null || v === undefined) return null;
  if (p.type === "String") {
    // vendor note: strings may carry junk after a terminator "0"
    const s = String(v);
    const nul = s.indexOf("\0");
    return (nul >= 0 ? s.slice(0, nul) : s).trim();
  }
  return cleanNumeric(Number(v));
}

class MachineConnection {
  private latest: Record<string, number | string | null> = {};
  private prevShots: number | null = null;
  private prevInferior: number | null = null;
  private emitTimer: NodeJS.Timeout | null = null;

  constructor(
    private machine: MachineConfig,
    private statusPollSec: number,
    private queue: DiskQueue | null
  ) {}

  async run(): Promise<void> {
    const client = OPCUAClient.create({
      applicationName: "alpha-factory-agent",
      securityMode: MessageSecurityMode.None,
      securityPolicy: SecurityPolicy.None,
      endpointMustExist: false,
      connectionStrategy: { initialDelay: 1000, maxDelay: 30_000, maxRetry: -1 }, // retry forever
    });

    client.on("backoff", (retry, delay) =>
      log("connect_backoff", { machine: this.machine.name, retry, delayMs: delay })
    );
    client.on("connection_lost", () => log("connection_lost", { machine: this.machine.name }));
    client.on("connection_reestablished", () =>
      log("connection_reestablished", { machine: this.machine.name })
    );

    await client.connect(this.machine.endpoint);
    const session = await client.createSession(); // anonymous, like the real box allows
    log("connected", { machine: this.machine.name, endpoint: this.machine.endpoint });

    await this.subscribeHot(session);
    await this.pollStatusForever(session);
  }

  private async subscribeHot(session: ClientSession): Promise<void> {
    const subscription = await session.createSubscription2({
      requestedPublishingInterval: 500,
      requestedLifetimeCount: 1000,
      requestedMaxKeepAliveCount: 20,
      maxNotificationsPerPublish: 100,
      publishingEnabled: true,
      priority: 10,
    });

    for (const p of PARAMS.filter((p) => p.kind === "hot")) {
      const item = await subscription.monitor(
        { nodeId: defaultNodeId(p), attributeId: AttributeIds.Value },
        { samplingInterval: 250, discardOldest: true, queueSize: 10 },
        TimestampsToReturn.Both
      );
      item.on("changed", (dv: DataValue) => {
        this.latest[p.key] = extract(p, dv);
        this.scheduleEmit();
      });
    }
  }

  private async pollStatusForever(session: ClientSession): Promise<void> {
    const statusParams = PARAMS.filter((p) => p.kind === "status");
    const nodes = statusParams.map((p) => ({ nodeId: defaultNodeId(p), attributeId: AttributeIds.Value }));
    // run forever; read errors are logged and retried on the next tick
    // (session reconnection is handled by node-opcua's connection strategy)
    for (;;) {
      try {
        const results = await session.read(nodes);
        results.forEach((dv, i) => {
          const p = statusParams[i]!;
          this.latest[p.key] = extract(p, dv);
        });
        this.scheduleEmit();
      } catch (err) {
        log("status_poll_error", { machine: this.machine.name, error: String(err) });
      }
      await new Promise((r) => setTimeout(r, this.statusPollSec * 1000));
    }
  }

  /** Debounce: many datachange events inside 1s collapse into one reading. */
  private scheduleEmit(): void {
    if (this.emitTimer) return;
    this.emitTimer = setTimeout(() => {
      this.emitTimer = null;
      this.emitReading();
    }, 1000);
  }

  private emitReading(): void {
    const shots = typeof this.latest.shot_count === "number" ? this.latest.shot_count : null;
    const inferior = typeof this.latest.inferior_count === "number" ? this.latest.inferior_count : null;

    const shotsD = counterDelta(this.prevShots, shots);
    const scrapD = counterDelta(this.prevInferior, inferior);
    if (shots !== null) this.prevShots = shots;
    if (inferior !== null) this.prevInferior = inferior;

    const reading: Reading = {
      machine: this.machine.name,
      machine_mac: (this.latest.machine_mac as string) ?? null,
      observed_at: new Date().toISOString(), // agent clock, never the machine's
      values: { ...this.latest },
      ...(shotsD ? { shots_delta: shotsD.delta, counter_reset: shotsD.reset } : {}),
      ...(scrapD ? { scrap_delta: scrapD.delta } : {}),
    };
    log("reading", reading);

    // Cloud mode: persist to the disk queue. The server keys machines by MAC,
    // so hold back the first second or two of readings until the initial
    // status poll has told us who this machine is (nothing is lost — counters
    // are cumulative, the next reading carries the same totals).
    if (this.queue && reading.machine_mac) this.queue.append(reading);
  }
}

// ---- entrypoint ----
const argIdx = process.argv.indexOf("--config");
const explicit = argIdx >= 0 ? process.argv[argIdx + 1] : undefined;
const configPath = explicit ?? (existsSync("config.json") ? "config.json" : "config.example.json");

const config = loadConfig(configPath);
const machines = config.machines ?? [];

if (machines.length === 0) {
  console.error(JSON.stringify({ at: new Date().toISOString(), kind: "fatal", error: "No OPC UA machines in config — use pnpm cv350 for Modbus devices" }));
  process.exit(1);
}

const cloudMode = Boolean(config.cloudUrl && config.agentToken);
log("agent_start", { configPath, machines: machines.length, cloudMode });

let queue: DiskQueue | null = null;
if (cloudMode) {
  queue = new DiskQueue("queue");
  new Shipper(queue, {
    cloudUrl: config.cloudUrl,
    agentToken: config.agentToken,
    log,
  }).start();
}

await Promise.all(
  machines.map((m) =>
    new MachineConnection(m, config.statusPollSec ?? 30, queue).run().catch((err) => {
      log("machine_fatal", { machine: m.name, error: String(err) });
    })
  )
);
