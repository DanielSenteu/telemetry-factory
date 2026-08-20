"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";

// The Shotline welcome: black screen, three typed lines, blinking cursor,
// then a wave sweeps left→right and the (already-rendered) homepage is there.
//
// Rules it lives by:
//   * plays once per browser session — navigating back to / never replays it
//   * a tap/click anywhere skips it instantly
//   * prefers-reduced-motion skips it entirely
//   * it OVERLAYS the loaded page, so the reveal costs zero wait

const LINES = [
  { text: "Welcome to", cls: "text-2xl md:text-3xl text-white/60" },
  { text: "Shotline", cls: "font-display text-6xl md:text-8xl font-bold tracking-tight text-white" },
  { text: "Your all-in-one manufacturing solution", cls: "text-xl md:text-2xl text-white/70" },
];
const TYPE_MS = 42;       // per character — typing, not loading
const LINE_PAUSE_MS = 280;
const HOLD_MS = 1200;     // cursor blinks after the last letter
const SEEN_KEY = "shotline-intro-seen";
const subscribeNever = () => () => {};

export function Intro() {
  const reduced = useReducedMotion();
  const [phase, setPhase] = useState<"typing" | "wave" | "done">("typing");
  const [typed, setTyped] = useState<string[]>(["", "", ""]);
  const [line, setLine] = useState(0);
  const skipped = useRef(false);

  // Session gate. useSyncExternalStore reads sessionStorage without a
  // server/client mismatch: the server snapshot says "seen" (renders nothing),
  // the client reads the real value on first render. The value is stable for
  // this mount, so the intro finishes playing even after we mark it seen.
  const seen = useSyncExternalStore(
    subscribeNever,
    () => sessionStorage.getItem(SEEN_KEY) === "1",
    () => true,
  );
  const show = !seen && !reduced;
  // Marked seen only when the intro actually FINISHES (skip or wave complete).
  // Marking at mount was a bug: the first re-render re-read storage, saw
  // "seen", and unmounted the overlay one frame in — the intro killed itself.
  const finish = () => {
    sessionStorage.setItem(SEEN_KEY, "1");
    setPhase("done");
  };

  // The typewriter.
  useEffect(() => {
    if (!show || phase !== "typing") return;
    if (line >= LINES.length) {
      const t = setTimeout(() => setPhase("wave"), HOLD_MS);
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

  const skip = () => {
    if (skipped.current) return;
    skipped.current = true;
    finish();
  };

  if (!show || phase === "done") return null;

  const cursorLine = Math.min(line, LINES.length - 1);

  return (
    <AnimatePresence>
      <motion.div
        key="intro"
        className="fixed inset-0 z-50 bg-black flex items-center justify-center cursor-pointer select-none"
        onClick={skip}
        exit={{ opacity: 0 }}
        aria-label="Skip intro"
        role="button"
      >
        <div className="flex flex-col items-start gap-4 px-8">
          {LINES.map((l, i) => (
            <div key={i} className={l.cls} style={{ minHeight: "1em" }}>
              {typed[i]}
              {i === cursorLine && phase === "typing" && (
                <span className="inline-block w-[0.55em] h-[1.05em] align-[-0.15em] ml-1 bg-[var(--accent)] animate-pulse" />
              )}
            </div>
          ))}
        </div>

        {phase === "wave" && (
          <motion.div
            className="absolute inset-y-0 -left-[60vw] w-[220vw]"
            style={{
              background: "var(--paper)",
              borderRadius: "0 50% 50% 0 / 0 50% 50% 0",
            }}
            initial={{ x: "-160vw" }}
            animate={{ x: "0vw" }}
            transition={{ duration: 0.8, ease: [0.7, 0, 0.3, 1] }}
            onAnimationComplete={finish}
          />
        )}

        <span className="absolute bottom-6 right-8 text-xs text-white/30 font-mono">tap to skip</span>
      </motion.div>
    </AnimatePresence>
  );
}
