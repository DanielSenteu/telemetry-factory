"use client";

import { motion, AnimatePresence } from "motion/react";

export function Modal({
  open,
  onClose,
  title,
  children,
  wide = false,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  children: React.ReactNode;
  wide?: boolean;
}) {
  return (
    <AnimatePresence>
      {open && (
        <motion.div
          className="fixed inset-0 z-50 flex items-end sm:items-center justify-center"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
        >
          <div className="absolute inset-0 bg-black/35" onClick={onClose} />
          <motion.div
            initial={{ y: 24, opacity: 0 }}
            animate={{ y: 0, opacity: 1 }}
            exit={{ y: 24, opacity: 0 }}
            transition={{ duration: 0.22, ease: [0.22, 1, 0.36, 1] }}
            className={`relative gloss rounded-t-2xl sm:rounded-2xl w-full ${wide ? "sm:max-w-2xl" : "sm:max-w-md"} max-h-[88vh] overflow-y-auto p-6`}
          >
            <div className="flex items-center justify-between gap-4 mb-4">
              <h2 className="font-display text-xl font-bold">{title}</h2>
              <button onClick={onClose} className="size-10 rounded-lg hover:bg-black/5 text-black/50 text-xl" aria-label="Close">
                ×
              </button>
            </div>
            {children}
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}

export const field = "h-12 w-full rounded-lg border border-black/10 px-3.5 text-base outline-none focus:border-black/30 bg-white";
export const primaryBtn =
  "h-12 w-full rounded-lg bg-[var(--ink)] text-white font-medium hover:bg-black transition-colors disabled:opacity-60";
