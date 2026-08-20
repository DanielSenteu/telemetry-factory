"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { INTRO_DONE_EVENT } from "./reveal";

// The Shotline welcome: black screen, three typed lines with a terminal
// cursor, then a WATER WAVE — drawn on canvas, real randomness, foam and
// spray — sweeps across and the homepage is simply there.
//
// Rules it lives by:
//   * plays once per browser session; only a FINISHED run counts as seen
//   * a tap/click anywhere skips it instantly
//   * prefers-reduced-motion skips it entirely
//   * it overlays the already-rendered page, so the reveal costs zero wait

const LINES = [
  { text: "Welcome to", cls: "text-2xl md:text-3xl text-white/60" },
  { text: "Shotline", cls: "font-display text-6xl md:text-8xl font-bold tracking-tight text-white" },
  { text: "Your all-in-one manufacturing solution", cls: "text-xl md:text-2xl text-white/70" },
];
const TYPE_MS = 82;
const LINE_PAUSE_MS = 620;
const HOLD_MS = 2000;
const SEEN_KEY = "shotline-intro-seen";
const subscribeNever = () => () => {};

// ── The wave ──────────────────────────────────────────
// A crest whose shape is a sum of drifting sines (periods chosen never to
// divide evenly — the edge never repeats), three depth layers, a foam line,
// foam flecks, and spray particles with velocity + gravity. Math.random is
// real here: no two plays are the same.

function WaveCanvas({ onDone }: { onDone: () => void }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const doneRef = useRef(onDone);
  useEffect(() => {
    doneRef.current = onDone;
  }, [onDone]);

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const W = window.innerWidth;
    const H = window.innerHeight;
    canvas.width = W * dpr;
    canvas.height = H * dpr;
    ctx.scale(dpr, dpr);

    const paper =
      getComputedStyle(document.documentElement).getPropertyValue("--paper").trim() || "#fcfcfb";

    const DUR = 2200;
    const LEAD = 150; // how far spray + ghost layers run ahead of the body
    const start = performance.now();
    const smooth = (u: number) => (u <= 0 ? 0 : u >= 1 ? 1 : u * u * (3 - 2 * u));

    type Drop = { x: number; y: number; vx: number; vy: number; r: number; life: number; max: number };
    const drops: Drop[] = [];

    // Crest x-position for a given y — layered sines drifting at different speeds.
    const edge = (y: number, t: number, ph: number) =>
      26 * Math.sin(y * 0.011 + t * 0.0042 + ph) +
      14 * Math.sin(y * 0.023 - t * 0.0031 + ph * 1.7) +
      9 * Math.sin(y * 0.047 + t * 0.0057 + ph * 0.6) +
      5 * Math.sin(y * 0.003 + t * 0.0019 + ph * 2.3);

    let raf = 0;
    const frame = (now: number) => {
      const t = now - start;
      const p = smooth(t / DUR);
      const base = p * (W + LEAD + 80) - LEAD;

      ctx.clearRect(0, 0, W, H);

      // Depth layers: ghost spray first, then mid water, then the paper body.
      const layers = [
        { off: 84, alpha: 0.13, ph: 2.1, fill: "255,255,255" },
        { off: 38, alpha: 0.34, ph: 0.9, fill: "255,255,255" },
      ];
      for (const L of layers) {
        ctx.beginPath();
        ctx.moveTo(base + L.off + edge(0, t, L.ph), 0);
        for (let y = 8; y <= H; y += 8) ctx.lineTo(base + L.off + edge(y, t, L.ph), y);
        ctx.lineTo(-LEAD * 2, H);
        ctx.lineTo(-LEAD * 2, 0);
        ctx.closePath();
        ctx.fillStyle = `rgba(${L.fill},${L.alpha})`;
        ctx.fill();
      }

      // The body — this is what actually clears the screen.
      ctx.beginPath();
      ctx.moveTo(base + edge(0, t, 0), 0);
      for (let y = 8; y <= H; y += 8) ctx.lineTo(base + edge(y, t, 0), y);
      ctx.lineTo(-LEAD * 2, H);
      ctx.lineTo(-LEAD * 2, 0);
      ctx.closePath();
      ctx.fillStyle = paper;
      ctx.fill();

      // Foam line along the crest.
      ctx.beginPath();
      ctx.moveTo(base + edge(0, t, 0), 0);
      for (let y = 6; y <= H; y += 6) ctx.lineTo(base + edge(y, t, 0), y);
      ctx.strokeStyle = "rgba(255,255,255,0.95)";
      ctx.lineWidth = 5;
      ctx.stroke();

      // Foam flecks — churn just behind and ahead of the crest.
      if (p > 0.02 && p < 0.99) {
        for (let i = 0; i < 14; i++) {
          const y = Math.random() * H;
          const x = base + edge(y, t, 0) + (Math.random() * 26 - 8);
          ctx.beginPath();
          ctx.arc(x, y, 0.8 + Math.random() * 3.2, 0, Math.PI * 2);
          ctx.fillStyle = `rgba(255,255,255,${0.25 + Math.random() * 0.5})`;
          ctx.fill();
        }
        // Spray: launched off the crest, ballistic, fading.
        for (let i = 0; i < 5; i++) {
          const y = Math.random() * H;
          drops.push({
            x: base + edge(y, t, 0) + 4,
            y,
            vx: 2.5 + Math.random() * 5.5,
            vy: (Math.random() - 0.5) * 7,
            r: 1.2 + Math.random() * 3.4,
            life: 0,
            max: 22 + Math.random() * 26,
          });
        }
      }
      for (let i = drops.length - 1; i >= 0; i--) {
        const d = drops[i];
        d.x += d.vx;
        d.y += d.vy;
        d.vy += 0.14; // gravity
        d.vx *= 0.985;
        d.life++;
        if (d.life >= d.max) {
          drops.splice(i, 1);
          continue;
        }
        ctx.beginPath();
        ctx.arc(d.x, d.y, d.r * (1 - d.life / d.max / 2), 0, Math.PI * 2);
        ctx.fillStyle = `rgba(255,255,255,${0.85 * (1 - d.life / d.max)})`;
        ctx.fill();
      }

      if (p >= 1 && drops.length === 0) {
        ctx.fillStyle = paper;
        ctx.fillRect(0, 0, W, H);
        doneRef.current();
        return;
      }
      raf = requestAnimationFrame(frame);
    };
    raf = requestAnimationFrame(frame);
    return () => cancelAnimationFrame(raf);
  }, []);

  return <canvas ref={ref} className="absolute inset-0 pointer-events-none" aria-hidden />;
}

// ── The intro ─────────────────────────────────────────

export function Intro() {
  const reduced = useReducedMotion();
  const [phase, setPhase] = useState<"typing" | "wave" | "done">("typing");
  const [typed, setTyped] = useState<string[]>(["", "", ""]);
  const [line, setLine] = useState(0);
  const skipped = useRef(false);

  const seen = useSyncExternalStore(
    subscribeNever,
    () => sessionStorage.getItem(SEEN_KEY) === "1",
    () => true,
  );
  const show = !seen && !reduced;
  // Marked seen only when the intro FINISHES (skip or wave complete) — marking
  // at mount made the first re-render read "seen" and unmount the overlay.
  const finish = () => {
    sessionStorage.setItem(SEEN_KEY, "1");
    // Tell the page beneath to begin its entrance — the overlay fades out
    // while the hero rises, so the reveal overlaps instead of popping.
    window.dispatchEvent(new Event(INTRO_DONE_EVENT));
    setPhase("done");
  };

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
        exit={{ opacity: 0, transition: { duration: 0.6 } }}
        aria-label="Skip intro"
        role="button"
      >
        <div className="flex flex-col items-start gap-4 px-8">
          {LINES.map((l, i) => (
            <div key={i} className={l.cls} style={{ minHeight: "1em" }}>
              {typed[i]}
              {i === cursorLine && phase === "typing" && (
                <span className="inline-block w-[2px] h-[1.05em] align-[-0.12em] ml-1.5 bg-white term-cursor" />
              )}
            </div>
          ))}
        </div>

        {phase === "wave" && <WaveCanvas onDone={finish} />}

        <span className="absolute bottom-6 right-8 text-xs text-white/30 font-mono">tap to skip</span>
      </motion.div>
    </AnimatePresence>
  );
}
