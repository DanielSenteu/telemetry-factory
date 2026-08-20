"use client";

import { useEffect, useState } from "react";

// A simulated-but-honest machine card: the same anatomy as the real dashboard
// card (LED / name / product / count / cycle), ticking like the floor does.
// Cycle ~18s in real life; sped up here so a visitor sees it move.
export function LiveMachineCard() {
  const [count, setCount] = useState(1240);
  const [cycle, setCycle] = useState(18.2);

  useEffect(() => {
    const t = setInterval(() => {
      setCount((c) => c + 8); // 8 cavities per shot
      setCycle(() => 17.8 + Math.random() * 0.9);
    }, 2600);
    return () => clearInterval(t);
  }, []);

  return (
    <div className="gloss rounded-2xl p-6 w-full max-w-sm">
      <div className="flex items-center gap-2.5">
        <span className="relative flex size-3">
          <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-[var(--accent)] opacity-60" />
          <span className="relative inline-flex size-3 rounded-full bg-[var(--accent)]" />
        </span>
        <span className="font-display font-bold tracking-wide">IMM-1</span>
        <span className="ml-auto text-xs font-mono font-semibold text-[var(--accent)]">RUNNING</span>
      </div>
      <div className="mt-3 text-sm font-medium text-black/70">Urine container 45ml</div>
      <div className="mt-2 flex items-baseline gap-2">
        <span className="font-mono text-5xl font-semibold tabular-nums">{count.toLocaleString()}</span>
        <span className="text-sm text-black/50">made today</span>
      </div>
      <div className="mt-4 flex gap-2 text-xs font-mono text-black/60">
        <span className="rounded-lg bg-black/[0.04] px-2.5 py-1.5">{cycle.toFixed(1)}s cycle</span>
        <span className="rounded-lg bg-black/[0.04] px-2.5 py-1.5">8 cavities</span>
      </div>
    </div>
  );
}
