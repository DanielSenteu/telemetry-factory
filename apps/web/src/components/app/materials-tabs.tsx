"use client";

import { useState } from "react";
import { MaterialsStock } from "@/components/app/materials-stock";
import { Receive } from "@/components/app/receive";
import { Regrind } from "@/components/app/regrind";
import { MovementHistory } from "@/components/app/movement-history";

const TABS = [
  { key: "stock", label: "Stock" },
  { key: "receive", label: "Receive" },
  { key: "regrind", label: "Regrind" },
  { key: "history", label: "History" },
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
      {tab === "regrind" && <Regrind orgId={orgId} />}
      {tab === "history" && <MovementHistory orgId={orgId} />}
    </div>
  );
}
