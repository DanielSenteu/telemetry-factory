"use client";

import { useState } from "react";
import { MaterialsStock } from "@/components/app/materials-stock";
import { Receive } from "@/components/app/receive";

const TABS = [
  { key: "stock", label: "Stock" },
  { key: "receive", label: "Receive" },
  { key: "regrind", label: "Regrind" },
] as const;

export function MaterialsTabs({ orgId }: { orgId: number }) {
  const [tab, setTab] = useState<(typeof TABS)[number]["key"]>("stock");
  return (
    <div className="flex flex-col gap-5">
      <div className="flex gap-1 border-b border-black/5 -mx-1 px-1">
        {TABS.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={`px-4 py-3 text-sm md:text-base font-semibold border-b-2 -mb-px transition-colors ${
              tab === t.key ? "border-[var(--accent)] text-black" : "border-transparent text-black/50 hover:text-black"
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>
      {tab === "stock" && <MaterialsStock orgId={orgId} />}
      {tab === "receive" && <Receive orgId={orgId} />}
      {tab === "regrind" && (
        <div className="gloss rounded-2xl p-8 max-w-xl">
          <h2 className="font-display text-lg font-bold">Regrind pool</h2>
          <p className="mt-2 text-sm text-black/55">Coming next — balances per material and logging ground runners back into stock.</p>
        </div>
      )}
    </div>
  );
}
