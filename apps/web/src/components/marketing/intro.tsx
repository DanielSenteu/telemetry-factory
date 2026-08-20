"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { INTRO_DONE_EVENT } from "./reveal";

// The Industrial-Sync welcome: ONE INJECTION MOULDING CYCLE.
//
//   CLAMP   — the mould is closed; the terminal types the name
//   INJECT  — the cursor glides to the gate (left edge); molten fill runs
//             across the seam, melt front leading
//   COOL    — the fill settles from white-hot to accent green
//   OPEN    — clamp pressure releases (3px jolt), the platens part
//   EJECT   — the page rises out of the open mould: the part
//
// A HUD narrates the stages like the machine's own controller would.
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
  { text: "> running a machine cycle …", cls: "font-mono text-sm md:text-base text-white/45 pt-4" },
];
const typeDelay = () => 55 + Math.random() * 52; // human jitter, not a metronome
const LINE_PAUSE_MS = 620;
const HOLD_MS = 1000;

// ── The cycle timeline (s from the moment Act 2 starts) ──
const T_MORPH = 0.15;  const D_MORPH = 0.55;  // cursor → gate
const T_INJ   = 0.72;  const D_FILL  = 0.78;  // fill runs the seam
const T_COOL  = 1.6;   const D_COOL  = 0.5;   // white-hot → accent
const T_REL   = 2.15;                          // clamp release jolt
const T_OPEN  = 2.3;   const D_SPLIT = 1.2;   // platens part
const HERO_EVENT_MS = 2750;                    // EJECT: page rises inside the gap

// Plain words, shown AT the seam — the intro narrates itself.
const STAGES: Array<[label: string, atMs: number]> = [
  ["injecting", 720],
  ["cooling", 1600],
  ["opening the mould", 2100],
  ["", 2750], // captions end; the page rising needs no words
];

const SEEN_KEY = "industrial-sync-intro-seen";
const subscribeNever = () => () => {};
const PLATEN_EASE = [0.83, 0, 0.17, 1] as const; // inertia, glide, firm stop

const CHROME = [
  { pos: "top-6 left-8", text: "INDUSTRIAL-SYNC // CYCLE 04711" },
  { pos: "top-6 right-8", text: "CLAMP 1250 kN" },
  { pos: "bottom-6 left-8", text: "MOULD 41.8°C" },
];

export function Intro() {
  const reduced = useReducedMotion();
  const [phase, setPhase] = useState<"typing" | "open" | "done">("typing");
  const [typed, setTyped] = useState<string[]>(["", "", "", ""]);
  const [line, setLine] = useState(0);
  const [stage, setStage] = useState(-1); // index into STAGES once opening
  const [cursorRect, setCursorRect] = useState<{ x: number; y: number; h: number } | null>(null);
  const cursorRef = useRef<HTMLSpanElement>(null);
  const skipped = useRef(false);

  const seen = useSyncExternalStore(
    subscribeNever,
    () => sessionStorage.getItem(SEEN_KEY) === "1",
    () => true,
  );
  const show = !seen && !reduced;

  const finish = () => {
    sessionStorage.setItem(SEEN_KEY, "1");
    window.dispatchEvent(new Event(INTRO_DONE_EVENT));
    setPhase("done");
  };

  // The typewriter (CLAMP stage — the mould is already closed).
  useEffect(() => {
    if (!show || phase !== "typing") return;
    if (line >= LINES.length) {
      const t = setTimeout(() => {
        const r = cursorRef.current?.getBoundingClientRect();
        if (r) setCursorRect({ x: r.left, y: r.top, h: r.height });
        setPhase("open");
      }, HOLD_MS);
      return () => clearTimeout(t);
    }
    const target = LINES[line].text;
    const current = typed[line];
    if (current.length < target.length) {
      const t = setTimeout(() => {
        setTyped((p) => p.map((s, i) => (i === line ? target.slice(0, s.length + 1) : s)));
      }, typeDelay());
      return () => clearTimeout(t);
    }
    const t = setTimeout(() => setLine((l) => l + 1), LINE_PAUSE_MS);
    return () => clearTimeout(t);
  }, [show, phase, line, typed]);

  // Cycle narration + the EJECT event that raises the hero.
  useEffect(() => {
    if (phase !== "open") return;
    const timers = STAGES.map(([, at], i) => setTimeout(() => setStage(i), at));
    timers.push(setTimeout(() => window.dispatchEvent(new Event(INTRO_DONE_EVENT)), HERO_EVENT_MS));
    return () => timers.forEach(clearTimeout);
  }, [phase]);

  const skip = () => {
    if (skipped.current) return;
    skipped.current = true;
    finish();
  };

  if (!show || phase === "done") return null;

  const cursorLine = Math.min(line, LINES.length - 1);
  const opening = phase === "open";
  const midY = typeof window !== "undefined" ? window.innerHeight / 2 : 400;
  const fullW = typeof window !== "undefined" ? window.innerWidth : 1200;

  return (
    <AnimatePresence>
      <motion.div
        key="intro"
        className={`fixed inset-0 z-50 flex items-center justify-center cursor-pointer select-none ${opening ? "bg-transparent pointer-events-none" : "bg-black"}`}
        onClick={skip}
        aria-label="Skip intro"
        role="button"
      >
        {/* Focus pull: the part sharpens as it is released. */}
        {opening && (
          <motion.div
            className="absolute inset-0"
            initial={{ backdropFilter: "blur(9px)" }}
            animate={{ backdropFilter: "blur(0px)" }}
            transition={{ duration: D_SPLIT, delay: T_OPEN, ease: "easeOut" }}
          />
        )}

        {/* The platens. Edge highlight exists ONLY while opening — during
            typing the screen is one unbroken black. Compress 3px (pressure
            release), then part. */}
        <motion.div
          className="absolute inset-x-0 top-0 h-1/2 bg-black"
          animate={opening ? { y: [0, 3, 3, "-100%"] } : { y: 0 }}
          transition={
            opening
              ? { duration: T_OPEN - T_REL + D_SPLIT, delay: T_REL, times: [0, 0.08, 0.11, 1], ease: ["easeOut", "linear", PLATEN_EASE] }
              : undefined
          }
          onAnimationComplete={() => opening && finish()}
          style={opening ? { boxShadow: "0 1px 0 rgba(255,255,255,0.14)" } : undefined}
        />
        <motion.div
          className="absolute inset-x-0 bottom-0 h-1/2 bg-black"
          animate={opening ? { y: [0, -3, -3, "100%"] } : { y: 0 }}
          transition={
            opening
              ? { duration: T_OPEN - T_REL + D_SPLIT, delay: T_REL, times: [0, 0.08, 0.11, 1], ease: ["easeOut", "linear", PLATEN_EASE] }
              : undefined
          }
          style={opening ? { boxShadow: "0 -1px 0 rgba(255,255,255,0.14)" } : undefined}
        />

        {/* INJECT: the cursor glides to the gate at the left edge… */}
        {opening && cursorRect && (
          <motion.div
            className="absolute"
            initial={{ left: cursorRect.x, top: cursorRect.y, width: 2, height: cursorRect.h, backgroundColor: "#ffffff", opacity: 1 }}
            animate={{
              left: [cursorRect.x, cursorRect.x, 4],
              top: [cursorRect.y, midY - 1, midY - 1],
              height: [cursorRect.h, 2, 2],
              opacity: [1, 1, 0],
            }}
            transition={{ duration: D_MORPH + 0.1, delay: T_MORPH, times: [0, 0.55, 1], ease: [0.65, 0, 0.35, 1] }}
          />
        )}
        {/* …and the molten fill runs the seam, cooling white-hot → accent. */}
        {opening && (
          <>
            <motion.div
              className="absolute left-0 h-[2px] w-full origin-left"
              style={{ top: midY - 1 }}
              initial={{ scaleX: 0, backgroundColor: "#ffffff", opacity: 1, boxShadow: "0 0 10px 1px rgba(255,255,255,0.55)" }}
              animate={{ scaleX: 1, backgroundColor: "var(--accent)", opacity: 0, boxShadow: "0 0 10px 1px rgba(255,255,255,0)" }}
              transition={{
                scaleX: { delay: T_INJ, duration: D_FILL, ease: [0.5, 0, 0.6, 1] },
                backgroundColor: { delay: T_COOL, duration: D_COOL, ease: "easeOut" },
                boxShadow: { delay: T_COOL, duration: D_COOL },
                opacity: { delay: T_OPEN + 0.25, duration: 0.55 },
              }}
            />
            {/* The melt front — a bright head leading the fill. */}
            <motion.div
              className="absolute size-[6px] rounded-full bg-white"
              style={{ top: midY - 3, boxShadow: "0 0 12px 3px rgba(255,255,255,0.8)" }}
              initial={{ left: 2, opacity: 0 }}
              animate={{ left: fullW - 4, opacity: [0, 1, 1, 0] }}
              transition={{ delay: T_INJ, duration: D_FILL, times: [0, 0.06, 0.9, 1], ease: [0.5, 0, 0.6, 1] }}
            />
          </>
        )}

        {/* Typed lines dim as the machine takes over. */}
        <motion.div
          className="relative flex flex-col items-start gap-4 px-8"
          animate={opening ? { opacity: 0, scale: 0.985 } : { opacity: 1, scale: 1 }}
          transition={{ duration: 0.3, ease: "easeOut" }}
        >
          {LINES.map((l, i) => (
            <div key={i} className={l.cls} style={{ minHeight: "1em" }}>
              {typed[i]}
              {i === cursorLine && phase === "typing" && (
                <span ref={cursorRef} className="inline-block w-[2px] h-[1.05em] align-[-0.12em] ml-1.5 bg-white term-cursor" />
              )}
            </div>
          ))}
        </motion.div>

        {/* The narration — one readable word at the seam, where the eyes are. */}
        {opening && stage >= 0 && STAGES[stage][0] !== "" && (
          <motion.div
            key={STAGES[stage][0]}
            className="absolute inset-x-0 text-center font-mono text-sm md:text-base tracking-[0.2em] text-white/75"
            style={{ top: midY + 26 }}
            initial={{ opacity: 0, y: 5 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.3, ease: "easeOut" }}
          >
            {STAGES[stage][0]}
          </motion.div>
        )}

        {/* Quiet machine chrome — rewards the second viewing. */}
        <motion.div animate={opening ? { opacity: 0 } : { opacity: 1 }} transition={{ duration: 0.25 }}>
          {CHROME.map((c) => (
            <motion.span
              key={c.text}
              className={`absolute ${c.pos} text-[11px] tracking-widest text-white/20 font-mono`}
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ delay: 0.8, duration: 1.2 }}
            >
              {c.text}
            </motion.span>
          ))}
          <span className="absolute bottom-6 right-8 text-xs text-white/30 font-mono">tap to skip</span>
        </motion.div>
      </motion.div>
    </AnimatePresence>
  );
}
