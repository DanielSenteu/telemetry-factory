"use client";

import { field } from "@/components/app/modal";
import { canonicalUnit, unitOptions } from "@/lib/services/units";

// The dropdown behind "Counted in" — units grouped by family, so free text
// like "Kgs"/"kilos" stops fragmenting the data. A pre-existing custom unit
// (e.g. "bags") stays selectable so editing a legacy product never destroys
// its unit; new products pick from the families.

const FAMILY_LABEL: Record<string, string> = {
  mass: "Weight",
  count: "Count",
  length: "Length",
  volume: "Volume",
};

export function UnitSelect({
  value,
  onChange,
  className,
}: {
  value: string;
  onChange: (u: string) => void;
  className?: string;
}) {
  const custom = value && !canonicalUnit(value) ? value : null;
  return (
    <select className={className ?? field} value={value} onChange={(e) => onChange(e.target.value)}>
      {!value && <option value="">Choose…</option>}
      {custom && <option value={custom}>{custom} (custom)</option>}
      {unitOptions().map(([family, units]) => (
        <optgroup key={family} label={FAMILY_LABEL[family] ?? family}>
          {units.map((u) => (
            <option key={u.value} value={u.value}>{u.label}</option>
          ))}
        </optgroup>
      ))}
    </select>
  );
}
