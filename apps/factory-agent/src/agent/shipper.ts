// Ships queued readings to the cloud ingestion endpoint.
//
// Loop: every flushSec, seal the current queue file and POST sealed segments
// oldest-first. A segment is deleted only on a 2xx response; any failure stops
// the pass and backs off (5s → 60s, doubling), keeping everything on disk.
// Delivery is at-least-once — the server dedupes on (machine_id, observed_at).

import type { DiskQueue } from "../lib/queue.js";

export interface ShipperOptions {
  cloudUrl: string;
  agentToken: string;
  /** Seconds between flush passes (default 10). */
  flushSec?: number;
  /** Injectable for tests. */
  fetchFn?: typeof fetch;
  log?: (kind: string, payload: object) => void;
}

const BACKOFF_MIN_MS = 5_000;
const BACKOFF_MAX_MS = 60_000;

export class Shipper {
  private backoffMs = 0;
  private fetchFn: typeof fetch;
  private log: (kind: string, payload: object) => void;

  constructor(private queue: DiskQueue, private opts: ShipperOptions) {
    this.fetchFn = opts.fetchFn ?? fetch;
    this.log = opts.log ?? (() => {});
  }

  start(): void {
    const flushMs = (this.opts.flushSec ?? 10) * 1000;
    const tick = async (): Promise<void> => {
      for (;;) {
        await new Promise((r) => setTimeout(r, this.backoffMs || flushMs));
        await this.flushOnce();
      }
    };
    void tick();
  }

  /** One flush pass. Returns number of readings acked by the server. */
  async flushOnce(): Promise<number> {
    this.queue.rotate();
    let acked = 0;
    for (const seg of this.queue.segments()) {
      const readings = this.queue.readSegment(seg);
      if (readings.length === 0) {
        this.queue.deleteSegment(seg);
        continue;
      }
      try {
        const res = await this.fetchFn(this.opts.cloudUrl, {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-agent-token": this.opts.agentToken,
          },
          body: JSON.stringify({ readings }),
        });
        if (!res.ok) {
          throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`);
        }
        this.queue.deleteSegment(seg);
        acked += readings.length;
        this.backoffMs = 0;
        this.log("ship_ok", { readings: readings.length });
      } catch (err) {
        this.backoffMs = Math.min(Math.max(this.backoffMs * 2, BACKOFF_MIN_MS), BACKOFF_MAX_MS);
        this.log("ship_error", { error: String(err), retryInMs: this.backoffMs });
        return acked; // keep this segment and everything after it; retry later
      }
    }
    return acked;
  }
}
