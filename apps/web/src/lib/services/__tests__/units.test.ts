import { describe, it, expect } from "vitest";
import { canonicalUnit, unitFamily, familyMembers, convert } from "../units";

describe("unit families", () => {
  it("recognises canonical units and free-text spellings from existing data", () => {
    expect(canonicalUnit("kg")).toBe("kg");
    expect(canonicalUnit("grams")).toBe("g");
    expect(canonicalUnit("Pieces")).toBe("each");
    expect(canonicalUnit("mystery-unit")).toBe(null);
  });

  it("groups by family", () => {
    expect(unitFamily("kg")).toBe("mass");
    expect(unitFamily("each")).toBe("count");
    expect(unitFamily("ml")).toBe("volume");
    expect(unitFamily("bags")).toBe(null); // cross-family packaging is NOT a unit here
  });

  it("family members offer only same-family units; unknown units stand alone", () => {
    expect(familyMembers("kg").map((m) => m.value).sort()).toEqual(["g", "kg"]);
    expect(familyMembers("bags")).toEqual([{ value: "bags", label: "bags" }]);
  });
});

describe("convert — exact within a family, refuses across", () => {
  it("kg ↔ g is exact both ways", () => {
    expect(convert(2.5, "kg", "g")).toBe(2500);
    expect(convert(750, "g", "kg")).toBe(0.75);
  });
  it("free-text spellings convert too (recipe says grams, stock says kg)", () => {
    expect(convert(1, "kilograms", "grams")).toBe(1000);
  });
  it("same unit is identity, even when unknown", () => {
    expect(convert(7, "bags", "bags")).toBe(7);
  });
  it("cross-family refuses loudly — bag→kg is a per-material fact, not math", () => {
    expect(() => convert(1, "kg", "each")).toThrow(/different families/);
    expect(() => convert(1, "bags", "kg")).toThrow(/unknown unit/);
  });
});
