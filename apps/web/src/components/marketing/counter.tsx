"use client";

import { useEffect, useRef, useState } from "react";
import { useInView, useReducedMotion } from "motion/react";

// A stat that counts itself up when it scrolls into view. A printed number is
// skimmed; a number you watch arrive is felt.
export function Counter({
  target,
  prefix = "",
  suffix = "",
  duration = 1.4,
  decimals = 0,
  className,
}: {
  target: number;
  prefix?: string;
  suffix?: string;
  duration?: number;
  decimals?: number;
  className?: string;
}) {
  const ref = useRef<HTMLSpanElement>(null);
  const inView = useInView(ref, { once: true, margin: "-60px" });
  const reduced = useReducedMotion();
  const [value, setValue] = useState(0);

  useEffect(() => {
    if (!inView) return;
    if (reduced || target === 0) {
      const id = requestAnimationFrame(() => setValue(target));
      return () => cancelAnimationFrame(id);
    }
    const start = performance.now();
    let raf = 0;
    const tick = (now: number) => {
      const u = Math.min(1, (now - start) / (duration * 1000));
      const eased = 1 - Math.pow(1 - u, 3);
      const factor = Math.pow(10, decimals);
      setValue(Math.round(target * eased * factor) / factor);
      if (u < 1) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [inView, reduced, target, duration, decimals]);

  return (
    <span ref={ref} className={className}>
      {prefix}
      {value.toLocaleString(undefined, { minimumFractionDigits: decimals, maximumFractionDigits: decimals })}
      {suffix}
    </span>
  );
}
