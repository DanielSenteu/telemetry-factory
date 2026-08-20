// Vendor sentinel values meaning "parameter not open for use on this machine".
// Source: TECHMATION OPC UA PDF, Notes section (p.41):
//   -1, 65535 (0xFFFF), 655.35, 6553.5, 4294967295 (0xFFFFFFFF), 42949672.95, 42949672
// A sentinel must become NULL, never data — 65,535 shots is a lie, not a shift record.
//
// Float32 trap (caught by the simulator smoke test): sentinels transmitted as
// OPC UA Float arrive rounded to 32-bit — 4294967295 arrives as 4294967296
// (= Math.fround(4294967295)). So the match set contains each sentinel AND its
// float32 image, matched exactly; a tiny ABSOLUTE epsilon covers float64
// arithmetic noise on the decimal ones. No relative tolerance — a wide band
// around 0xFFFFFFFF would swallow legitimate neighbors like 4294967294.

const RAW_SENTINELS = [-1, 65535, 655.35, 6553.5, 4294967295, 42949672.95, 42949672];

const SENTINELS: number[] = [...new Set(RAW_SENTINELS.flatMap((s) => [s, Math.fround(s)]))];

const EPSILON = 1e-6;

export function isSentinel(value: number): boolean {
  for (const s of SENTINELS) {
    if (value === s || Math.abs(value - s) < EPSILON) return true;
  }
  return false;
}

/** Null out sentinel numerics. Strings pass through (vendor terminates them with
 *  a trailing "0" sometimes — trim handled at read time, not here). */
export function cleanNumeric(value: number | null | undefined): number | null {
  if (value === null || value === undefined) return null;
  if (Number.isNaN(value)) return null;
  return isSentinel(value) ? null : value;
}
