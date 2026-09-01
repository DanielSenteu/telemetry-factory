// Unit families — the measurement spine.
//
// Every unit belongs to a family; conversions WITHIN a family are exact,
// universal, and live here in code — never in configuration. Each material
// stores stock in ONE unit (its own — the "one material, one unit" rule);
// entry points may accept any unit of the same family and convert to the
// material's unit before anything is stored. Cross-family conversion
// (bag → kg) is deliberately absent: that is a per-material remembered fact,
// not arithmetic.

export type UnitFamily = "mass" | "count" | "length" | "volume";

/** factor = how many of the family's base unit one of this unit is. */
const UNITS: Record<string, { family: UnitFamily; factor: number; label: string }> = {
  // mass — base: gram
  g:     { family: "mass", factor: 1, label: "grams (g)" },
  kg:    { family: "mass", factor: 1000, label: "kilograms (kg)" },
  // count — base: piece
  each:  { family: "count", factor: 1, label: "pieces" },
  dozen: { family: "count", factor: 12, label: "dozens" },
  // length — base: metre
  mm:    { family: "length", factor: 0.001, label: "millimetres (mm)" },
  cm:    { family: "length", factor: 0.01, label: "centimetres (cm)" },
  m:     { family: "length", factor: 1, label: "metres (m)" },
  // volume — base: litre
  ml:    { family: "volume", factor: 0.001, label: "millilitres (ml)" },
  l:     { family: "volume", factor: 1, label: "litres (L)" },
};

// Free-text spellings already in the data map onto canonical units.
const ALIASES: Record<string, string> = {
  grams: "g", gram: "g", gr: "g",
  kgs: "kg", kilo: "kg", kilos: "kg", kilogram: "kg", kilograms: "kg",
  piece: "each", pieces: "each", pcs: "each", pc: "each", unit: "each", units: "each",
  litre: "l", litres: "l", liter: "l", liters: "l",
  metre: "m", metres: "m", meter: "m", meters: "m",
};

export function canonicalUnit(u: string | null | undefined): string | null {
  if (!u) return null;
  const k = u.trim().toLowerCase();
  if (UNITS[k]) return k;
  return ALIASES[k] ?? null;
}

export function unitFamily(u: string | null | undefined): UnitFamily | null {
  const c = canonicalUnit(u);
  return c ? UNITS[c].family : null;
}

export function unitLabel(u: string): string {
  const c = canonicalUnit(u);
  return c ? UNITS[c].label : u;
}

/** All units, grouped for dropdowns: [family, [{value, label}]][] */
export function unitOptions(): Array<[UnitFamily, Array<{ value: string; label: string }>]> {
  const grouped = new Map<UnitFamily, Array<{ value: string; label: string }>>();
  for (const [value, def] of Object.entries(UNITS)) {
    const list = grouped.get(def.family) ?? [];
    list.push({ value, label: def.label });
    grouped.set(def.family, list);
  }
  return [...grouped.entries()];
}

/** The units a value for `unit` may be entered in — its family members.
 *  Unknown/free-text units get no companions: entry stays in that unit. */
export function familyMembers(unit: string | null | undefined): Array<{ value: string; label: string }> {
  const c = canonicalUnit(unit);
  if (!c) return unit ? [{ value: unit, label: unit }] : [];
  const fam = UNITS[c].family;
  return Object.entries(UNITS)
    .filter(([, d]) => d.family === fam)
    .map(([value, d]) => ({ value, label: d.label }));
}

/** Exact conversion within one family. Throws on cross-family or unknown units. */
export function convert(value: number, from: string, to: string): number {
  const cf = canonicalUnit(from);
  const ct = canonicalUnit(to);
  if (cf === null || ct === null) {
    if ((from ?? "").trim().toLowerCase() === (to ?? "").trim().toLowerCase()) return value;
    throw new Error(`Cannot convert between "${from}" and "${to}" — unknown unit`);
  }
  if (cf === ct) return value;
  const f = UNITS[cf];
  const t = UNITS[ct];
  if (f.family !== t.family) {
    throw new Error(`Cannot convert ${from} (${f.family}) to ${to} (${t.family}) — different families`);
  }
  return (value * f.factor) / t.factor;
}
