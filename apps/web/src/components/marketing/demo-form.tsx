"use client";

import { useState } from "react";
import { supabase } from "@/lib/supabase/browser";

// The "Book a virtual demo" form. Writes straight into demo_requests with the
// public anon key: visitors may insert and nothing else (RLS). The hidden
// "website" field is a honeypot — humans never see it, naive bots fill it,
// and we quietly drop those. Phone is entered as country code + national
// number and submitted in international format; the database normalizes
// again on the way in, so the stored data is clean regardless of client.

const field =
  "h-11 rounded-lg border border-black/10 px-3.5 text-sm outline-none focus:border-black/30";

// dial code, label, national-number digit cap (leading 0 is dropped on submit)
const COUNTRIES: Array<[string, string, number]> = [
  ["+254", "🇰🇪 Kenya (+254)", 10],
  ["+255", "🇹🇿 Tanzania (+255)", 10],
  ["+256", "🇺🇬 Uganda (+256)", 10],
  ["+250", "🇷🇼 Rwanda (+250)", 10],
  ["+251", "🇪🇹 Ethiopia (+251)", 10],
  ["+257", "🇧🇮 Burundi (+257)", 8],
  ["+211", "🇸🇸 South Sudan (+211)", 10],
  ["+252", "🇸🇴 Somalia (+252)", 9],
  ["+243", "🇨🇩 DR Congo (+243)", 10],
  ["+260", "🇿🇲 Zambia (+260)", 10],
  ["+234", "🇳🇬 Nigeria (+234)", 11],
  ["+233", "🇬🇭 Ghana (+233)", 10],
  ["+27", "🇿🇦 South Africa (+27)", 10],
  ["+20", "🇪🇬 Egypt (+20)", 11],
  ["+971", "🇦🇪 UAE (+971)", 9],
  ["+91", "🇮🇳 India (+91)", 10],
  ["+86", "🇨🇳 China (+86)", 11],
  ["+44", "🇬🇧 UK (+44)", 11],
  ["+1", "🇺🇸 US / Canada (+1)", 10],
];

export function DemoForm() {
  const [name, setName] = useState("");
  const [company, setCompany] = useState("");
  const [dial, setDial] = useState("+254");
  const [phone, setPhone] = useState("");
  const [email, setEmail] = useState("");
  const [manufactures, setManufactures] = useState("");
  const [honeypot, setHoneypot] = useState("");
  const [state, setState] = useState<"idle" | "busy" | "done" | "error">("idle");

  const cap = COUNTRIES.find(([d]) => d === dial)?.[2] ?? 12;
  const emailTrimmed = email.trim().toLowerCase();
  const emailOk = emailTrimmed === "" || /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(emailTrimmed);
  const phoneDigits = phone.replace(/\D/g, "");
  const canSubmit = !!name.trim() && phoneDigits.length >= 7 && emailOk;

  const submit = async () => {
    if (!canSubmit) return;
    if (honeypot) {
      setState("done"); // bot: pretend success, store nothing
      return;
    }
    setState("busy");
    const { error } = await supabase.from("demo_requests").insert({
      name: name.trim().slice(0, 200),
      company: company.trim().slice(0, 200) || null,
      // international format: dial code + national number without its leading 0
      phone: `${dial}${phoneDigits.replace(/^0/, "")}`,
      email: emailTrimmed || null,
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
      <div className="flex flex-col gap-1.5">
        <span className="text-sm font-medium text-black/70">Phone</span>
        <div className="flex gap-2">
          <select
            className={field + " w-36 shrink-0"}
            value={dial}
            onChange={(e) => { setDial(e.target.value); }}
            aria-label="Country code"
          >
            {COUNTRIES.map(([d, label]) => (
              <option key={d} value={d}>{label}</option>
            ))}
          </select>
          <input
            type="tel"
            inputMode="numeric"
            className={field + " flex-1 font-mono"}
            value={phone}
            maxLength={cap}
            onChange={(e) => setPhone(e.target.value.replace(/[^\d]/g, "").slice(0, cap))}
            placeholder="745 435 732"
            autoComplete="tel-national"
          />
        </div>
      </div>
      <label className="flex flex-col gap-1.5">
        <span className="text-sm font-medium text-black/70">Email</span>
        <input
          type="email"
          className={field}
          value={email}
          maxLength={254}
          onChange={(e) => setEmail(e.target.value)}
          autoComplete="email"
          placeholder="you@company.com"
        />
        {email !== "" && !emailOk && (
          <span className="text-xs text-red-600">That doesn&apos;t look like an email address.</span>
        )}
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
        disabled={state === "busy" || !canSubmit}
        className="h-12 rounded-lg bg-[var(--ink)] text-white font-medium hover:bg-black transition-colors disabled:opacity-50"
      >
        {state === "busy" ? "Sending…" : "Book my demo"}
      </button>
      <p className="text-xs text-black/40 text-center">We reply within one working day.</p>
    </div>
  );
}
