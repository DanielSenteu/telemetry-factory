// Delta computation for cumulative machine counters (shot count, inferior count).
//
// Counters are monotonically increasing per job/power-cycle, but RESET to ~0 on
// machine reboot or new job. A negative naive delta means "reset happened":
// we take the new value itself as the delta (everything counted since reset).
// This can only ever UNDER-count (cycles between last reading and the reset are
// lost) — never over-count, never negative. Under-counting on reboot is the
// correct failure direction for production numbers.

export interface DeltaResult {
  delta: number;
  reset: boolean;
}

export function counterDelta(previous: number | null, current: number | null): DeltaResult | null {
  if (current === null) return null; // sentinel/unavailable now — no statement possible
  if (previous === null) return { delta: 0, reset: false }; // first observation: baseline only
  if (current >= previous) return { delta: current - previous, reset: false };
  return { delta: current, reset: true };
}

/** Fold a sequence of cumulative readings into total production, reset-aware. */
export function totalFromReadings(values: Array<number | null>): number {
  let total = 0;
  let prev: number | null = null;
  for (const v of values) {
    const r = counterDelta(prev, v);
    if (r) {
      total += r.delta;
      prev = v;
    }
  }
  return total;
}
