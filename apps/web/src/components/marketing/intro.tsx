"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { INTRO_DONE_EVENT } from "./reveal";

// The Industrial-Sync welcome.
//
// Act 1 — the terminal: black screen, three typed lines, a thin cursor
// blinking like a prompt.
// Act 2 — THE MOULD OPENS: a hairline parting line draws across the screen,
// then the black splits into two platens that glide apart — and the homepage
// is the part that was just moulded. The transition is the industry.
//
// Rules it lives by:
//   * plays once per browser session; only a FINISHED run counts as seen
//   * a tap/click anywhere skips it instantly
//   * prefers-reduced-motion skips it entirely
//   * it overlays the already-rendered page, so the reveal costs zero wait

const LINES = [
  { text: "Welcome to", cls: "text-2xl md:text-3xl text-white/60" },
  { text: "Industrial-Sync", cls: "font-display text-6xl md:text-8xl font-bold tracking-tight text-white" },
  { text: "Your all-in-one manufacturing solution", cls: "text-xl md:text-2xl text-white/70" },
];
const TYPE_MS = 82;
const LINE_PAUSE_MS = 620;
const HOLD_MS = 2000;

// Act 2 timing (ms from the moment the mould sequence starts)
const TEXT_FADE_S = 0.3;    // typed lines dim like a screen losing power
const LINE_DELAY_S = 0.15;  // parting line starts drawing
const LINE_DRAW_S = 0.5;    // hairline sweeps across
const SPLIT_DELAY_S = 0.8;  // platens begin to part
const SPLIT_S = 1.15;       // how long the opening takes
const HERO_EVENT_MS = 850;  // hero starts rising as the platens part

const SEEN_KEY = "industrial-sync-intro-seen";
const subscribeNever = () => () => {};
// Heavy machinery easing: slow to overcome inertia, confident glide, firm stop.
const PLATEN_EASE = [0.83, 0, 0.17, 1] as const;

export function Intro() {
  const reduced = useReducedMotion();
  const [phase, setPhase] = useState<"typing" | "open" | "done">("typing");
  const [typed, setTyped] = useState<string[]>(["", "", ""]);
  const [line, setLine] = useState(0);
  const skipped = useRef(false);

  const seen = useSyncExternalStore(
    subscribeNever,
    () => sessionStorage.getItem(SEEN_KEY) === "1",
    () => true,
  );
  const show = !seen && !reduced;

  // Marked seen only when the intro FINISHES (skip or mould fully open) —
  // marking at mount made the first re-render read "seen" and unmount it.
  const finish = () => {
    sessionStorage.setItem(SEEN_KEY, "1");
    window.dispatchEvent(new Event(INTRO_DONE_EVENT));
    setPhase("done");
  };

  // The typewriter.
  useEffect(() => {
    if (!show || phase !== "typing") return;
    if (line >= LINES.length) {
      const t = setTimeout(() => setPhase("open"), HOLD_MS);
      return () => clearTimeout(t);
    }
    const target = LINES[line].text;
    const current = typed[line];
    if (current.length < target.length) {
      const t = setTimeout(() => {
        setTyped((p) => p.map((s, i) => (i === line ? target.slice(0, s.length + 1) : s)));
      }, TYPE_MS);
      return () => clearTimeout(t);
    }
    const t = setTimeout(() => setLine((l) => l + 1), LINE_PAUSE_MS);
    return () => clearTimeout(t);
  }, [show, phase, line, typed]);

  // As the platens part, tell the page beneath to begin its entrance — the
  // hero rises INSIDE the opening mould, not after it.
  useEffect(() => {
    if (phase !== "open") return;
    const t = setTimeout(() => window.dispatchEvent(new Event(INTRO_DONE_EVENT)), HERO_EVENT_MS);
    return () => clearTimeout(t);
  }, [phase]);

  const skip = () => {
    if (skipped.current) return;
    skipped.current = true;
    finish();
  };

  if (!show || phase === "done") return null;

  const cursorLine = Math.min(line, LINES.length - 1);
  const opening = phase === "open";

  return (
    <AnimatePresence>
      <motion.div
        key="intro"
        className={`fixed inset-0 z-50 flex items-center justify-center cursor-pointer select-none ${opening ? "bg-transparent pointer-events-none" : "bg-black"}`}
        onClick={skip}
        aria-label="Skip intro"
        role="button"
      >
        {/* The platens — one screen of black, parting at the horizontal centre. */}
        <motion.div
          className="absolute inset-x-0 top-0 h-1/2 bg-black"
          animate={opening ? { y: "-100%" } : { y: 0 }}
          transition={{ duration: SPLIT_S, ease: PLATEN_EASE, delay: opening ? SPLIT_DELAY_S : 0 }}
          onAnimationComplete={() => opening && finish()}
          style={{ boxShadow: "0 1px 0 rgba(255,255,255,0.14)" }}
        />
        <motion.div
          className="absolute inset-x-0 bottom-0 h-1/2 bg-black"
          animate={opening ? { y: "100%" } : { y: 0 }}
          transition={{ duration: SPLIT_S, ease: PLATEN_EASE, delay: opening ? SPLIT_DELAY_S : 0 }}
          style={{ boxShadow: "0 -1px 0 rgba(255,255,255,0.14)" }}
        />

        {/* The parting line — drawn across the seam just before the mould opens. */}
        {opening && (
          <motion.div
            className="absolute left-0 top-1/2 h-px w-full origin-left"
            style={{ background: "var(--accent)", boxShadow: "0 0 12px 1px color-mix(in oklch, var(--accent), transparent 35%)" }}
            initial={{ scaleX: 0, opacity: 1 }}
            animate={{ scaleX: 1, opacity: [1, 1, 0] }}
            transition={{
              scaleX: { duration: LINE_DRAW_S, ease: [0.65, 0, 0.35, 1], delay: LINE_DELAY_S },
              opacity: { duration: SPLIT_S, delay: SPLIT_DELAY_S, times: [0, 0.25, 1] },
            }}
          />
        )}

        {/* The typed lines — they dim as the machine takes over. */}
        <motion.div
          className="relative flex flex-col items-start gap-4 px-8"
          animate={opening ? { opacity: 0, scale: 0.985 } : { opacity: 1, scale: 1 }}
          transition={{ duration: TEXT_FADE_S, ease: "easeOut" }}
        >
          {LINES.map((l, i) => (
            <div key={i} className={l.cls} style={{ minHeight: "1em" }}>
              {typed[i]}
              {i === cursorLine && phase === "typing" && (
                <span className="inline-block w-[2px] h-[1.05em] align-[-0.12em] ml-1.5 bg-white term-cursor" />
              )}
            </div>
          ))}
        </motion.div>

        {!opening && (
          <span className="absolute bottom-6 right-8 text-xs text-white/30 font-mono">tap to skip</span>
        )}
      </motion.div>
    </AnimatePresence>
  );
}
