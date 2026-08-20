import { describe, expect, it } from "vitest";
import { counterDelta, totalFromReadings } from "./deltas.js";

describe("counter deltas with reset detection", () => {
  it("normal increase", () => {
    expect(counterDelta(100, 250)).toEqual({ delta: 150, reset: false });
  });

  it("no change", () => {
    expect(counterDelta(250, 250)).toEqual({ delta: 0, reset: false });
  });

  it("reset: counter went backwards → new value is the delta", () => {
    expect(counterDelta(250, 30)).toEqual({ delta: 30, reset: true });
  });

  it("first observation is baseline, not production", () => {
    expect(counterDelta(null, 5000)).toEqual({ delta: 0, reset: false });
  });

  it("sentinel/unavailable current → no statement", () => {
    expect(counterDelta(100, null)).toBeNull();
  });

  it("plan example: [100, 250, 30, 45] → deltas 150, 30, 15 (never negative)", () => {
    // First value 100 is the baseline (delta 0), then 150 + 30(reset) + 15 = 195
    expect(totalFromReadings([100, 250, 30, 45])).toBe(195);
  });

  it("sentinel gaps mid-sequence don't corrupt the total", () => {
    // 100→200 = 100; null skipped (prev stays 200); 200→260 = 60
    expect(totalFromReadings([100, 200, null, 260])).toBe(160);
  });

  it("reset to zero then climb", () => {
    expect(totalFromReadings([500, 0, 10])).toBe(10);
  });
});
