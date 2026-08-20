// Behavioral model of a fake injection molding machine (no OPC UA here — pure
// state machine, advanced by tick()). The OPC UA server in main.ts just exposes
// this state as tm* variables.
//
// Deliberately simulates every nasty behavior the vendor PDF warns about:
// - cumulative counters that RESET (reboot / new job)
// - sentinel values on params this "machine model" doesn't support
// - alarms with start/end times
// - mode changes (auto → manual → idle)

export type MachineState = "running" | "idle" | "alarm";

export interface SimOptions {
  name: string;
  /** Seconds per molding cycle (real machines ~8-30s; use 2 for lively demos). */
  cycleTimeSec?: number;
  /** Cavities in the loaded mold. */
  moldCavity?: number;
  /** Probability per cycle that a part is defective. */
  scrapRate?: number;
  /** Mean seconds between random alarms (0 = never). */
  alarmEverySec?: number;
  /** Mean seconds between counter resets (0 = never). */
  resetEverySec?: number;
  /** Simulate a machine whose power meter isn't wired (sentinel). */
  powerMeterAvailable?: boolean;
}

const ALARM_IDS = [
  "ERR_DSP_ERROR_113", // LackOfMaterial
  "ERR_DSP_ERROR_53", // MotorOverload
  "ERR_DSP_ERROR_6", // CycleTimeExceeded
  "ERR_DSP_ERROR_2", // PleaseCloseDoor
];

const CRAFTS = [
  { craftId: "SYR-BARREL-10ML", material: "PP-H030", color: "NATURAL", cavity: 8 },
  { craftId: "SYR-PLUNGER-10ML", material: "PP-H030", color: "WHITE", cavity: 16 },
  { craftId: "PETRI-90MM", material: "PS-GPPS", color: "CLEAR", cavity: 4 },
];

export class MachineModel {
  readonly name: string;
  state: MachineState = "running";
  shotCount = 0;
  inferiorCount = 0;
  cycleTimeSec: number;
  moldCavity: number;
  operateMode = 2; // Semi/Auto per vendor enum (0 manual, 1 semi, 2 auto)
  motorState = 1;
  heatState = 1;
  craftId: string;
  material: string;
  color: string;
  planCount = 20000;
  alarmState = 0;
  alarmId1 = "";
  powerKwh: number;
  resets = 0;

  private opts: Required<SimOptions>;
  private cycleAccumulator = 0;
  private alarmRemaining = 0;
  private idleRemaining = 0;

  constructor(options: SimOptions) {
    this.name = options.name;
    this.opts = {
      name: options.name,
      cycleTimeSec: options.cycleTimeSec ?? 2,
      moldCavity: options.moldCavity ?? 8,
      scrapRate: options.scrapRate ?? 0.03,
      alarmEverySec: options.alarmEverySec ?? 120,
      resetEverySec: options.resetEverySec ?? 300,
      powerMeterAvailable: options.powerMeterAvailable ?? true,
    };
    this.cycleTimeSec = this.opts.cycleTimeSec;
    this.moldCavity = this.opts.moldCavity;
    const craft = CRAFTS[Math.floor(Math.random() * CRAFTS.length)]!;
    this.craftId = craft.craftId;
    this.material = craft.material;
    this.color = craft.color;
    this.moldCavity = craft.cavity;
    // 4294967295 = vendor sentinel for "not available"
    this.powerKwh = this.opts.powerMeterAvailable ? 1500 + Math.random() * 500 : 4294967295;
  }

  /** Advance the machine by dt seconds. */
  tick(dt: number): void {
    if (this.state === "alarm") {
      this.alarmRemaining -= dt;
      if (this.alarmRemaining <= 0) this.clearAlarm();
      return;
    }
    if (this.state === "idle") {
      this.idleRemaining -= dt;
      if (this.idleRemaining <= 0) this.resume();
      return;
    }

    // running
    this.cycleAccumulator += dt;
    while (this.cycleAccumulator >= this.cycleTimeSec) {
      this.cycleAccumulator -= this.cycleTimeSec;
      this.completeCycle();
    }

    // random events, probability scaled by dt
    if (this.opts.alarmEverySec > 0 && Math.random() < dt / this.opts.alarmEverySec) {
      this.raiseAlarm();
    } else if (this.opts.resetEverySec > 0 && Math.random() < dt / this.opts.resetEverySec) {
      this.resetCounters();
    } else if (Math.random() < dt / 240) {
      this.goIdle(10 + Math.random() * 30);
    }
  }

  private completeCycle(): void {
    this.shotCount += 1;
    // each shot yields moldCavity parts; each part can be scrap
    for (let i = 0; i < this.moldCavity; i++) {
      if (Math.random() < this.opts.scrapRate) this.inferiorCount += 1;
    }
    if (this.powerKwh !== 4294967295) this.powerKwh += 0.05 + Math.random() * 0.02;
    // small cycle-time jitter, like a real hydraulic machine
    this.cycleTimeSec = this.opts.cycleTimeSec * (0.95 + Math.random() * 0.1);
  }

  raiseAlarm(): void {
    this.state = "alarm";
    this.alarmState = 1;
    this.alarmId1 = ALARM_IDS[Math.floor(Math.random() * ALARM_IDS.length)]!;
    this.motorState = 0;
    this.alarmRemaining = 15 + Math.random() * 45;
  }

  clearAlarm(): void {
    this.state = "running";
    this.alarmState = 0;
    this.alarmId1 = "";
    this.motorState = 1;
  }

  goIdle(seconds: number): void {
    this.state = "idle";
    this.operateMode = 0; // manual
    this.motorState = 0;
    this.idleRemaining = seconds;
  }

  resume(): void {
    this.state = "running";
    this.operateMode = 2;
    this.motorState = 1;
  }

  /** Reboot / job change: cumulative counters restart — the case deltas.ts handles. */
  resetCounters(): void {
    this.shotCount = 0;
    this.inferiorCount = 0;
    this.resets += 1;
  }
}
