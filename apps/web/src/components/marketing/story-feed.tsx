"use client";

import { useEffect, useRef, useState } from "react";
import { motion, useInView, useReducedMotion } from "motion/react";

// The power-cut day, told the way the product would tell it: entries arrive
// one at a time like live telemetry. The pause before "power cut" is the
// drama; the catch-up line landing right after it is the pitch.
const ENTRIES: Array<[time: string, text: string, tone: "ok" | "warn" | "info", holdMs: number]> = [
  ["07:42", "floor started — first cycle of the day", "ok", 650],
  ["09:12", "+240 containers made — IMM-1", "ok", 650],
  ["09:12", "−960 g polypropylene used — recipe", "info", 650],
  ["11:03", "power cut — data queued at factory", "warn", 1400],
  ["11:37", "power back — 34 min of readings caught up", "ok", 800],
  ["14:20", "−500 containers sold — invoice INV024285", "info", 650],
];

export function StoryFeed() {
  const ref = useRef<HTMLDivElement>(null);
  const inView = useInView(ref, { once: true, margin: "-100px" });
  const reduced = useReducedMotion();
  const [shown, setShown] = useState(0);

  useEffect(() => {
    if (!inView) return;
    if (reduced) {
      const id = requestAnimationFrame(() => setShown(ENTRIES.length));
      return () => cancelAnimationFrame(id);
    }
    if (shown >= ENTRIES.length) return;
    const hold = shown === 0 ? 350 : ENTRIES[shown - 1][3];
    const t = setTimeout(() => setShown((n) => n + 1), hold);
    return () => clearTimeout(t);
  }, [inView, reduced, shown]);

  return (
    <div ref={ref} className="flex flex-col gap-3 font-mono text-sm">
      <div className="flex items-center gap-2 text-xs tracking-widest text-white/40 pb-1">
        <span className="relative flex size-2">
          <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-[var(--accent)] opacity-60" />
          <span className="relative inline-flex size-2 rounded-full bg-[var(--accent)]" />
        </span>
        LIVE FEED
      </div>
      {ENTRIES.slice(0, shown).map(([t, e, tone], i) => (
        <motion.div
          key={i}
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.35, ease: "easeOut" }}
          className={`flex gap-4 rounded-xl px-4 py-3 ${
            tone === "warn" ? "bg-amber-500/10 text-amber-200/90" : "bg-white/5"
          }`}
        >
          <span className={tone === "warn" ? "text-amber-200/50" : "text-white/40"}>{t}</span>
          <span className={tone === "warn" ? "" : "text-white/85"}>{e}</span>
        </motion.div>
      ))}
    </div>
  );
}
