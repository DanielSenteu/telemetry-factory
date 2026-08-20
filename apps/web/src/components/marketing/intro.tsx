"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { INTRO_DONE_EVENT } from "./reveal";

// The Industrial-Sync welcome: THE NAME IS MOULDED, LIVE.
//
//   1. "Welcome to" types — terminal DNA
//   2. The wordmark appears as a hollow CAVITY (outlined letters)
//   3. Molten material floods in from the gate at the left and FILLS the
//      letterforms — rippling melt front, heat glow, rising embers
//   4. It COOLS: furnace orange -> solid white; the tagline settles in
//   5. The mould OPENS: clamp jolt, then the platens part — and the wordmark
//      SPLITS WITH THEM, sliced mid-letter, each half riding its platen away
//      as the page rises out of the mould.
//
// Rules: once per session (only a finished run counts), tap to skip,
// reduced-motion skips entirely, overlays the already-rendered page.

const WELCOME = "Welcome to";
const TAGLINE = "Your all-in-one manufacturing solution";
const typeDelay = () => 42 + Math.random() * 40;

// Mould-phase timeline (s)
const T_CAVITY = 0.1;  const D_CAVITY = 0.4;
const T_FILL   = 0.55; const D_FILL   = 1.75;
const T_COOL   = 2.45; const D_COOL   = 0.65;
const T_TAG    = 2.7;
const T_REL    = 3.6;                          // clamp release jolt
const T_SPLIT  = 3.75; const D_SPLIT  = 1.2;
const HERO_EVENT_MS = 4000;
const SPLIT_MS = 3750;

const SEEN_KEY = "industrial-sync-intro-seen";
const subscribeNever = () => () => {};
const PLATEN_EASE = [0.83, 0, 0.17, 1] as const;

const CHROME = [
  { pos: "top-6 left-8", text: "INDUSTRIAL-SYNC // CYCLE 04711" },
  { pos: "top-6 right-8", text: "CLAMP 1250 kN" },
  { pos: "bottom-6 left-8", text: "MOULD 41.8°C" },
];

// Vertical melt-front edge: a wavy right-hand boundary sweeping left -> right.
const FRONT_PATH = (() => {
  let d = "M18,0";
  for (let y = 0; y <= 240; y += 30) d += ` Q${y % 60 === 0 ? 4 : 30},${y + 15} 18,${y + 30}`;
  return d + " L-2400,240 L-2400,0 Z";
})();

const WORD = "Industrial-Sync";
const VB = "0 0 1000 240";
const TEXT_PROPS = {
  x: 500,
  y: 155,
  textAnchor: "middle" as const,
  fontSize: 88,
  fontWeight: 700,
  style: { fontFamily: "var(--font-display)", letterSpacing: "-2px" },
};

// Live telemetry beneath the moulding — pressure climbs as the cavity fills,
// melt temperature falls as it cools, and the shot counter increments the
// moment the mould opens: the machine made one more part, and the software
// was watching. This is the company in one row of numbers.
function CycleReadout() {
  const [ms, setMs] = useState(0);
  useEffect(() => {
    const start = performance.now();
    const id = setInterval(() => setMs(performance.now() - start), 66);
    return () => clearInterval(id);
  }, []);

  const clamp01 = (v: number) => Math.max(0, Math.min(1, v));
  const fill = clamp01((ms - T_FILL * 1000) / (D_FILL * 1000));
  const cool = clamp01((ms - T_COOL * 1000) / (D_COOL * 1000));
  const pressure = (92 * fill * (1 - cool * 0.87)).toFixed(1);
  const melt = (238 - (238 - 41.8) * cool).toFixed(1);
  const shot = ms >= SPLIT_MS ? "04712" : "04711";

  return (
    <div className="flex items-center gap-6 font-mono text-[12px] md:text-[13px] tracking-widest text-white/45 tabular-nums">
      <span>INJ <span className="text-white/80">{pressure}</span> MPa</span>
      <span>MELT <span className="text-white/80">{melt}</span> °C</span>
      <span>SHOT <span className={ms >= SPLIT_MS ? "text-[var(--accent)]" : "text-white/80"}>{shot}</span></span>
    </div>
  );
}

// The final, solid state of the whole stack — rendered identically inside each
// platen so the wordmark physically splits with the mould.
function SolidStack() {
  return (
    <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 px-8">
      <div className="text-2xl md:text-3xl text-white/60">{WELCOME}</div>
      <svg viewBox={VB} className="w-[min(92vw,900px)]" aria-hidden>
        <text {...TEXT_PROPS} fill="#ffffff">{WORD}</text>
      </svg>
      <div className="text-xl md:text-2xl text-white/70">{TAGLINE}</div>
    </div>
  );
}

export function Intro() {
  const reduced = useReducedMotion();
  const [phase, setPhase] = useState<"typing" | "mould" | "done">("typing");
  const [typed, setTyped] = useState("");
  const [split, setSplit] = useState(false);
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

  // Act 1: type "Welcome to".
  useEffect(() => {
    if (!show || phase !== "typing") return;
    if (typed.length < WELCOME.length) {
      const t = setTimeout(() => setTyped(WELCOME.slice(0, typed.length + 1)), typeDelay());
      return () => clearTimeout(t);
    }
    const t = setTimeout(() => setPhase("mould"), 350);
    return () => clearTimeout(t);
  }, [show, phase, typed]);

  // Act 2 keyed moments: the split swap and the hero rising.
  useEffect(() => {
    if (phase !== "mould") return;
    const a = setTimeout(() => setSplit(true), SPLIT_MS);
    const b = setTimeout(() => window.dispatchEvent(new Event(INTRO_DONE_EVENT)), HERO_EVENT_MS);
    return () => { clearTimeout(a); clearTimeout(b); };
  }, [phase]);

  const skip = () => {
    if (skipped.current) return;
    skipped.current = true;
    finish();
  };

  if (!show || phase === "done") return null;

  const mould = phase === "mould";

  return (
    <AnimatePresence>
      <motion.div
        key="intro"
        className={`fixed inset-0 z-50 cursor-pointer select-none ${split ? "bg-transparent pointer-events-none" : "bg-black"}`}
        onClick={skip}
        aria-label="Skip intro"
        role="button"
      >
        {/* Focus pull on the page as the part is released. */}
        {mould && (
          <motion.div
            className="absolute inset-0"
            initial={{ backdropFilter: "blur(9px)" }}
            animate={{ backdropFilter: "blur(0px)" }}
            transition={{ duration: D_SPLIT, delay: T_SPLIT, ease: "easeOut" }}
          />
        )}

        {/* Platens: black halves, each carrying its slice of the finished
            wordmark. Clamp-jolt 3px, then part — the name splits mid-letter. */}
        <motion.div
          className="absolute inset-x-0 top-0 h-1/2 bg-black overflow-hidden"
          animate={mould ? { y: [0, 3, 3, "-100%"] } : { y: 0 }}
          transition={mould ? { duration: T_SPLIT - T_REL + D_SPLIT, delay: T_REL, times: [0, 0.09, 0.12, 1], ease: ["easeOut", "linear", PLATEN_EASE] } : undefined}
          onAnimationComplete={() => mould && finish()}
          style={split ? { boxShadow: "0 1px 0 rgba(255,255,255,0.14)" } : undefined}
        >
          <div className={`absolute inset-x-0 top-0 h-screen ${split ? "opacity-100" : "opacity-0"}`}>
            <SolidStack />
          </div>
        </motion.div>
        <motion.div
          className="absolute inset-x-0 bottom-0 h-1/2 bg-black overflow-hidden"
          animate={mould ? { y: [0, -3, -3, "100%"] } : { y: 0 }}
          transition={mould ? { duration: T_SPLIT - T_REL + D_SPLIT, delay: T_REL, times: [0, 0.09, 0.12, 1], ease: ["easeOut", "linear", PLATEN_EASE] } : undefined}
          style={split ? { boxShadow: "0 -1px 0 rgba(255,255,255,0.14)" } : undefined}
        >
          <div className={`absolute inset-x-0 bottom-0 h-screen ${split ? "opacity-100" : "opacity-0"}`}>
            <SolidStack />
          </div>
        </motion.div>

        {/* The main stage — hidden the instant the platens take over. */}
        <div className={`absolute inset-0 flex flex-col items-center justify-center gap-2 px-8 ${split ? "opacity-0" : "opacity-100"}`}>
          <div className="text-2xl md:text-3xl text-white/60" style={{ minHeight: "1em" }}>
            {typed}
            {phase === "typing" && (
              <span className="inline-block w-[2px] h-[1.05em] align-[-0.12em] ml-1.5 bg-white term-cursor" />
            )}
          </div>

          {/* THE MOULDING. */}
          <div className="w-[min(92vw,900px)]" style={{ minHeight: "1px" }}>
            {mould && (
              <motion.svg viewBox={VB} className="w-full" initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ duration: 0.3, delay: T_CAVITY }} aria-hidden>
                <defs>
                  <linearGradient id="molten" x1="0" y1="0" x2="1" y2="0">
                    <stop offset="0%" stopColor="#ff7a1a" />
                    <stop offset="78%" stopColor="#ffa64d" />
                    <stop offset="100%" stopColor="#ffe9c2" />
                  </linearGradient>
                  <filter id="heat" x="-20%" y="-60%" width="140%" height="220%">
                    <feGaussianBlur stdDeviation="9" />
                  </filter>
                  <clipPath id="cavity">
                    <text {...TEXT_PROPS}>{WORD}</text>
                  </clipPath>
                </defs>

                {/* The cavity: hollow letterforms, faintly engraved. */}
                <motion.text
                  {...TEXT_PROPS}
                  fill="none"
                  stroke="rgba(255,255,255,0.28)"
                  strokeWidth="1.2"
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  transition={{ duration: D_CAVITY, delay: T_CAVITY }}
                >
                  {WORD}
                </motion.text>

                {/* Heat bloom behind the fill — fades as it cools. */}
                <motion.g
                  filter="url(#heat)"
                  initial={{ opacity: 0 }}
                  animate={{ opacity: [0, 0.9, 0.9, 0] }}
                  transition={{ duration: T_COOL + D_COOL - T_FILL, delay: T_FILL, times: [0, 0.25, 0.8, 1] }}
                >
                  <g clipPath="url(#cavity)">
                    <motion.g initial={{ x: -1040 }} animate={{ x: -6 }} transition={{ duration: D_FILL, delay: T_FILL, ease: [0.35, 0, 0.35, 1] }}>
                      <path d={FRONT_PATH} fill="url(#molten)" transform="translate(1040,0)" />
                    </motion.g>
                  </g>
                </motion.g>

                {/* The molten fill itself, clipped to the letterforms. */}
                <motion.g
                  initial={{ opacity: 1 }}
                  animate={{ opacity: 0 }}
                  transition={{ duration: D_COOL, delay: T_COOL }}
                >
                  <g clipPath="url(#cavity)">
                    <motion.g initial={{ x: -1040 }} animate={{ x: -6 }} transition={{ duration: D_FILL, delay: T_FILL, ease: [0.35, 0, 0.35, 1] }}>
                      <path d={FRONT_PATH} fill="url(#molten)" transform="translate(1040,0)" />
                    </motion.g>
                  </g>
                </motion.g>

                {/* The cooled part: solid white, revealed as the molten fades. */}
                <motion.text
                  {...TEXT_PROPS}
                  fill="#ffffff"
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  transition={{ duration: D_COOL, delay: T_COOL }}
                >
                  {WORD}
                </motion.text>

                {/* Embers rising off the melt. */}
                {[150, 320, 500, 680, 850].map((cx, i) => (
                  <motion.circle
                    key={cx}
                    cx={cx}
                    r={2 + (i % 3)}
                    fill="#ffb066"
                    initial={{ cy: 165, opacity: 0 }}
                    animate={{ cy: 30, opacity: [0, 0.85, 0] }}
                    transition={{ duration: 0.9, delay: T_FILL + 0.35 + i * 0.22, ease: "easeOut" }}
                  />
                ))}
              </motion.svg>
            )}
          </div>

          {mould && (
            <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: T_FILL, duration: 0.4 }} className="pt-1">
              <CycleReadout />
            </motion.div>
          )}

          {/* Tagline settles in once the part has cooled. */}
          <motion.div
            className="text-xl md:text-2xl text-white/70"
            initial={{ opacity: 0, y: 8 }}
            animate={mould ? { opacity: 1, y: 0 } : { opacity: 0, y: 8 }}
            transition={{ duration: 0.5, delay: mould ? T_TAG : 0, ease: "easeOut" }}
          >
            {TAGLINE}
          </motion.div>
        </div>

        {/* Quiet machine chrome. */}
        <motion.div animate={split ? { opacity: 0 } : { opacity: 1 }} transition={{ duration: 0.25 }}>
          {CHROME.map((c) => (
            <motion.span
              key={c.text}
              className={`absolute ${c.pos} text-[11px] tracking-widest text-white/20 font-mono`}
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ delay: 0.6, duration: 1.2 }}
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
