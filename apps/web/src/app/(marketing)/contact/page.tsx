export default function ContactPage() {
  return (
    <section className="mx-auto max-w-6xl px-6 py-20 grid md:grid-cols-2 gap-14">
      <div>
        <h1 className="font-display text-5xl font-bold tracking-tight">Book a virtual demo.</h1>
        <p className="mt-4 text-lg text-black/55 leading-relaxed">
          Leave your details and we will set up an online meeting. We explain
          what Industrial-Sync does and show you the platform live: a real
          factory floor running on it, in real time, machines counting as we
          speak. If it fits your operation, we arrange a factory visit from
          there.
        </p>
        <div className="mt-8 flex flex-col gap-3">
          <a href="tel:+254745435732" className="gloss rounded-xl px-5 py-4 flex items-center gap-4 hover:ring-1 hover:ring-black/15 transition-shadow">
            <span className="font-mono text-sm text-black/40 w-20">Call</span>
            <span className="font-mono font-semibold">+254 745 435 732</span>
          </a>
          <a href="https://wa.me/254745435732" target="_blank" rel="noopener noreferrer" className="gloss rounded-xl px-5 py-4 flex items-center gap-4 hover:ring-1 hover:ring-black/15 transition-shadow">
            <span className="font-mono text-sm text-black/40 w-20">WhatsApp</span>
            <span className="font-mono font-semibold">+254 745 435 732</span>
          </a>
          <a href="mailto:info@telemetrynetworks.net" className="gloss rounded-xl px-5 py-4 flex items-center gap-4 hover:ring-1 hover:ring-black/15 transition-shadow">
            <span className="font-mono text-sm text-black/40 w-20">Email</span>
            <span className="font-mono font-semibold">info@telemetrynetworks.net</span>
          </a>
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
            <span className="text-sm font-medium text-black/70">What do you manufacture?</span>
            <textarea rows={3} className="rounded-lg border border-black/10 px-3.5 py-2.5 text-sm outline-none focus:border-black/30" placeholder="e.g. medical containers, caps, packaging, household goods…" />
          </label>
          <button className="h-12 rounded-lg bg-[var(--ink)] text-white font-medium hover:bg-black transition-colors">
            Book my demo
          </button>
          <p className="text-xs text-black/40 text-center">We reply within one working day.</p>
        </div>
      </div>
    </section>
  );
}
