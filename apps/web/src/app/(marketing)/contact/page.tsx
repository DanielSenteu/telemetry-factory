export default function ContactPage() {
  return (
    <section className="mx-auto max-w-6xl px-6 py-20 grid md:grid-cols-2 gap-14">
      <div>
        <h1 className="font-display text-5xl font-bold tracking-tight">Book a factory visit.</h1>
        <p className="mt-4 text-lg text-black/55 leading-relaxed">
          Tell us a little about your factory and we will call you to arrange a
          visit. A technician walks your floor, looks at your machines, and you
          get a straight answer on what wiring in takes.
        </p>
        <div className="mt-8 flex flex-col gap-3">
          <div className="gloss rounded-xl px-5 py-4 flex items-center gap-4">
            <span className="font-mono text-sm text-black/40 w-20">Call</span>
            <span className="font-mono font-semibold">[YOUR PHONE]</span>
          </div>
          <div className="gloss rounded-xl px-5 py-4 flex items-center gap-4">
            <span className="font-mono text-sm text-black/40 w-20">WhatsApp</span>
            <span className="font-mono font-semibold">[YOUR WHATSAPP]</span>
          </div>
          <div className="gloss rounded-xl px-5 py-4 flex items-center gap-4">
            <span className="font-mono text-sm text-black/40 w-20">Email</span>
            <span className="font-mono font-semibold">[YOUR EMAIL]</span>
          </div>
        </div>
      </div>
      <div className="gloss rounded-2xl p-8">
        <div className="flex flex-col gap-5">
          {[
            ["Your name", "text"],
            ["Company", "text"],
            ["Phone", "tel"],
          ].map(([label, type]) => (
            <label key={label} className="flex flex-col gap-1.5">
              <span className="text-sm font-medium text-black/70">{label}</span>
              <input type={type} className="h-11 rounded-lg border border-black/10 px-3.5 text-sm outline-none focus:border-black/30" />
            </label>
          ))}
          <label className="flex flex-col gap-1.5">
            <span className="text-sm font-medium text-black/70">What do you mould?</span>
            <textarea rows={3} className="rounded-lg border border-black/10 px-3.5 py-2.5 text-sm outline-none focus:border-black/30" placeholder="e.g. medical containers, caps, household goods…" />
          </label>
          <button className="h-12 rounded-lg bg-[var(--ink)] text-white font-medium hover:bg-black transition-colors">
            Request a visit
          </button>
          <p className="text-xs text-black/40 text-center">We reply within one working day.</p>
        </div>
      </div>
    </section>
  );
}
