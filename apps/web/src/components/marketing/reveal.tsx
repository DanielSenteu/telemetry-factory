"use client";

import { useEffect, useState } from "react";
import { motion, useReducedMotion } from "motion/react";

export const INTRO_DONE_EVENT = "industrial-sync:intro-done";
const SEEN_KEY = "industrial-sync-intro-seen";
const EASE = [0.22, 1, 0.36, 1] as const;

// Above-the-fold reveal: waits for the intro to finish (or fires immediately
// when there is no intro this session), then rises into place. Stagger with
// `delay` so the hero assembles rather than pops.
export function Reveal({
  children,
  delay = 0,
  className,
}: {
  children: React.ReactNode;
  delay?: number;
  className?: string;
}) {
  const reduced = useReducedMotion();
  const [go, setGo] = useState(false);

  useEffect(() => {
    const start = () => setGo(true);
    if (reduced || sessionStorage.getItem(SEEN_KEY) === "1") {
      const id = requestAnimationFrame(start);
      return () => cancelAnimationFrame(id);
    }
    window.addEventListener(INTRO_DONE_EVENT, start, { once: true });
    return () => window.removeEventListener(INTRO_DONE_EVENT, start);
  }, [reduced]);

  return (
    <motion.div
      className={className}
      initial={{ opacity: 0, y: 26 }}
      animate={go ? { opacity: 1, y: 0 } : { opacity: 0, y: 26 }}
      transition={reduced ? { duration: 0 } : { duration: 0.75, ease: EASE, delay }}
    >
      {children}
    </motion.div>
  );
}

// Below-the-fold: rises gently the first time it scrolls into view.
export function RevealInView({
  children,
  delay = 0,
  className,
}: {
  children: React.ReactNode;
  delay?: number;
  className?: string;
}) {
  const reduced = useReducedMotion();
  return (
    <motion.div
      className={className}
      initial={reduced ? false : { opacity: 0, y: 24 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: "-80px" }}
      transition={{ duration: 0.65, ease: EASE, delay }}
    >
      {children}
    </motion.div>
  );
}
