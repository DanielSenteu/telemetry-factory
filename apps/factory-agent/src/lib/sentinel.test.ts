import { describe, expect, it } from "vitest";
import { cleanNumeric, isSentinel } from "./sentinel.js";

describe("sentinel filtering", () => {
  it("flags every documented sentinel value", () => {
    for (const s of [-1, 65535, 655.35, 6553.5, 4294967295, 42949672.95, 42949672]) {
      expect(isSentinel(s), `${s} should be a sentinel`).toBe(true);
    }
  });

  it("flags float-noise representations of sentinels", () => {
    expect(isSentinel(655.3500000001)).toBe(true);
    expect(isSentinel(6553.499999999)).toBe(true);
  });

  it("flags float32-rounded sentinels (as OPC UA Float transmits them)", () => {
    // caught live by the simulator: 4294967295 as Float arrives as 4294967296
    expect(isSentinel(Math.fround(4294967295))).toBe(true);
    expect(isSentinel(4294967296)).toBe(true);
    expect(isSentinel(Math.fround(655.35))).toBe(true);
    expect(isSentinel(Math.fround(42949672.95))).toBe(true);
  });

  it("passes real-world values through", () => {
    for (const v of [0, 1, 42, 654.35, 65534, 12.5, 4294967294, 100000]) {
      expect(isSentinel(v), `${v} should NOT be a sentinel`).toBe(false);
    }
  });

  it("cleanNumeric nulls sentinels, NaN, and missing; keeps data", () => {
    expect(cleanNumeric(65535)).toBeNull();
    expect(cleanNumeric(4294967295)).toBeNull();
    expect(cleanNumeric(NaN)).toBeNull();
    expect(cleanNumeric(undefined)).toBeNull();
    expect(cleanNumeric(null)).toBeNull();
    expect(cleanNumeric(0)).toBe(0);
    expect(cleanNumeric(1234)).toBe(1234);
  });
});
