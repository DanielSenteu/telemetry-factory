"use client";

import { useState } from "react";
import { MachinesLive } from "@/components/app/machines-live";
import { Recipes } from "@/components/app/recipes";

const TABS = [
  { key: "live", label: "Live floor" },
  { key: "recipes", label: "Recipes" },
] as const;

export function ProductionTabs({ orgId }: { orgId: number }) {
  const [tab, setTab] = useState<(typeof TABS)[number]["key"]>("live");
  return (
    <div className="flex flex-col gap-5">
      <div className="flex gap-1 border-b border-black/5 -mx-1 px-1">
        {TABS.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={`px-4 py-3 text-sm md:text-base font-semibold border-b-2 -mb-px transition-colors ${
              tab === t.key
                ? "border-[var(--accent)] text-black"
                : "border-transparent text-black/50 hover:text-black"
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>
      {tab === "live" && <MachinesLive orgId={orgId} />}
      {tab === "recipes" && <Recipes orgId={orgId} />}
    </div>
  );
}
