"use client";

import { useState } from "react";
import { supabase } from "@/lib/supabase/browser";

// The "Book a virtual demo" form. Writes straight into demo_requests with the
// public anon key: visitors may insert and nothing else (RLS). The hidden
// "website" field is a honeypot — humans never see it, naive bots fill it,
// and we quietly drop those.

const field =
  "h-11 rounded-lg border border-black/10 px-3.5 text-sm outline-none focus:border-black/30";

export function DemoForm() {
  const [name, setName] = useState("");
  const [company, setCompany] = useState("");
  const [phone, setPhone] = useState("");
  const [manufactures, setManufactures] = useState("");
  const [honeypot, setHoneypot] = useState("");
  const [state, setState] = useState<"idle" | "busy" | "done" | "error">("idle");

  const submit = async () => {
    if (!name.trim() || !phone.trim()) return;
    if (honeypot) {
      setState("done"); // bot: pretend success, store nothing
      return;
    }
    setState("busy");
    const { error } = await supabase.from("demo_requests").insert({
      name: name.trim().slice(0, 200),
      company: company.trim().slice(0, 200) || null,
      phone: phone.trim().slice(0, 50),
      manufactures: manufactures.trim().slice(0, 2000) || null,
    });
    setState(error ? "error" : "done");
  };

  if (state === "done") {
    return (
      <div className="flex flex-col items-center text-center gap-3 py-10">
        <span className="inline-flex size-12 items-center justify-center rounded-full bg-[var(--accent)]/10 text-[var(--accent)] text-xl">✓</span>
        <h2 className="font-display text-xl font-bold">Request received.</h2>
        <p className="text-sm text-black/55 max-w-xs">
          We will call you within one working day to set up your demo. Talk soon.
        </p>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-5">
      <label className="flex flex-col gap-1.5">
        <span className="text-sm font-medium text-black/70">Your name</span>
        <input className={field} value={name} onChange={(e) => setName(e.target.value)} autoComplete="name" />
      </label>
      <label className="flex flex-col gap-1.5">
        <span className="text-sm font-medium text-black/70">Company</span>
        <input className={field} value={company} onChange={(e) => setCompany(e.target.value)} autoComplete="organization" />
      </label>
      <label className="flex flex-col gap-1.5">
        <span className="text-sm font-medium text-black/70">Phone</span>
        <input type="tel" className={field} value={phone} onChange={(e) => setPhone(e.target.value)} autoComplete="tel" />
      </label>
      <label className="flex flex-col gap-1.5">
        <span className="text-sm font-medium text-black/70">What do you manufacture?</span>
        <textarea
          rows={3}
          className="rounded-lg border border-black/10 px-3.5 py-2.5 text-sm outline-none focus:border-black/30"
          value={manufactures}
          onChange={(e) => setManufactures(e.target.value)}
          placeholder="e.g. medical containers, caps, packaging, household goods…"
        />
      </label>
      {/* Honeypot — humans never see or fill this. */}
      <input
        type="text"
        value={honeypot}
        onChange={(e) => setHoneypot(e.target.value)}
        tabIndex={-1}
        autoComplete="off"
        aria-hidden="true"
        className="absolute -left-[9999px] h-0 w-0 opacity-0"
      />
      {state === "error" && (
        <p className="text-sm text-red-600">
          That didn&apos;t go through. Please try again, or just call or WhatsApp us directly.
        </p>
      )}
      <button
        onClick={submit}
        disabled={state === "busy" || !name.trim() || !phone.trim()}
        className="h-12 rounded-lg bg-[var(--ink)] text-white font-medium hover:bg-black transition-colors disabled:opacity-50"
      >
        {state === "busy" ? "Sending…" : "Book my demo"}
      </button>
      <p className="text-xs text-black/40 text-center">We reply within one working day.</p>
    </div>
  );
}
