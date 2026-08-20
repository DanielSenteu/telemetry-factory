import Link from "next/link";
import { Button } from "@/components/ui/button";
import { Intro } from "@/components/marketing/intro";
import { LiveMachineCard } from "@/components/marketing/live-machine-card";
import { Reveal, RevealInView } from "@/components/marketing/reveal";

export default function HomePage() {
  return (
    <>
      <Intro />

      {/* ── Hero ── */}
      <section className="mx-auto max-w-6xl px-6 pt-24 pb-16 grid gap-16 md:grid-cols-2 items-center">
        <div className="flex flex-col gap-6">
          <Reveal delay={0}>
            <div className="font-mono text-sm text-[var(--accent)] font-semibold tracking-wider">
              FOR INJECTION MOULDING FACTORIES
            </div>
          </Reveal>
          <Reveal delay={0.1}>
            <h1 className="font-display text-5xl md:text-6xl font-bold tracking-tight leading-[1.05]">
              Your factory floor, live on one screen.
            </h1>
          </Reveal>
          <Reveal delay={0.2}>
            <p className="text-lg text-black/60 leading-relaxed max-w-lg">
              Industrial-Sync wires into your moulding machines and shows you — shot by
              shot — what is running, what is in stock, and what to make next.
            </p>
          </Reveal>
          <Reveal delay={0.3} className="flex items-center gap-5 pt-2">
            <Button size="lg" nativeButton={false} className="bg-[var(--ink)] hover:bg-black text-base h-12 px-7" render={<Link href="/contact" />}>Book a factory visit</Button>
            <span className="text-sm text-black/50">
              or call <span className="font-mono font-semibold text-black/80">[YOUR PHONE]</span>
            </span>
          </Reveal>
        </div>
        <Reveal delay={0.42} className="flex justify-center md:justify-end">
          <LiveMachineCard />
        </Reveal>
      </section>

      {/* ── Honest numbers ── */}
      <section className="border-y border-black/5 bg-white">
        <RevealInView className="mx-auto max-w-6xl px-6 py-10 grid grid-cols-2 md:grid-cols-4 gap-8">
          <div>
            <div className="font-mono text-3xl font-semibold">~2s</div>
            <div className="mt-1 text-sm text-black/50">between machine readings — you see cycles as they happen</div>
          </div>
          <div>
            <div className="font-mono text-3xl font-semibold">15+</div>
            <div className="mt-1 text-sm text-black/50">parameters read per machine: shots, scrap, cycle time, mould, alarms, energy</div>
          </div>
          <div>
            <div className="font-mono text-3xl font-semibold">0</div>
            <div className="mt-1 text-sm text-black/50">readings lost to an internet cut — data queues at the factory and catches up</div>
          </div>
          <div>
            <div className="font-mono text-3xl font-semibold">24,000+</div>
            <div className="mt-1 text-sm text-black/50">sales invoices mirrored in our first deployment — three years of demand history</div>
          </div>
        </RevealInView>
      </section>

      {/* ── The loop ── */}
      <section className="mx-auto max-w-6xl px-6 py-20">
        <RevealInView>
        <h2 className="font-display text-4xl font-bold tracking-tight">One loop, closed.</h2>
        <p className="mt-3 text-lg text-black/55 max-w-2xl">
          A factory is a flow: material comes in, machines turn it into product,
          product goes out. Most software watches one piece. Industrial-Sync watches the
          whole loop — so the numbers finally agree with the floor.
        </p>
        <div className="mt-10 grid md:grid-cols-4 gap-4">
          {[
            ["01", "Material arrives", "Photograph the supplier invoice. Industrial-Sync reads it and books the polypropylene into stock — at what it actually cost."],
            ["02", "Machines convert it", "Every shot is counted from the machine's own controller. Each product's recipe deducts the exact grams of material used."],
            ["03", "Product ships out", "Sales flow in from your invoicing system and deduct finished goods. The shelf count is real, not remembered."],
            ["04", "You decide what's next", "Demand, stock cover, machine hours and material sufficiency in one row — before the heaters are warm."],
          ].map(([n, t, d]) => (
            <div key={n} className="gloss rounded-2xl p-6">
              <div className="font-mono text-sm text-[var(--accent)] font-semibold">{n}</div>
              <div className="mt-2 font-display text-lg font-bold">{t}</div>
              <div className="mt-2 text-sm text-black/55 leading-relaxed">{d}</div>
            </div>
          ))}
        </div>
        </RevealInView>
      </section>

      {/* ── Real factories ── */}
      <section className="bg-[var(--ink)] text-white">
        <RevealInView className="mx-auto max-w-6xl px-6 py-20 grid md:grid-cols-2 gap-12 items-center">
          <div>
            <h2 className="font-display text-4xl font-bold tracking-tight">Built where the power cuts.</h2>
            <p className="mt-4 text-white/60 text-lg leading-relaxed">
              Industrial-Sync was built on a working factory floor in Nairobi, not in a
              demo lab. That shows in the details: when the power comes back
              before the internet does, your machines run and your data waits at
              the factory — then catches up on its own, in order, with nothing
              lost and nothing counted twice.
            </p>
            <p className="mt-4 text-white/60 text-lg leading-relaxed">
              And when production happens that no system saw — an outage, a
              manual run — the operator records it in two taps. Material use and
              unit costs stay correct, because the recipe does the arithmetic.
            </p>
          </div>
          <div className="flex flex-col gap-3 font-mono text-sm">
            {[
              ["07:42", "floor started — first cycle of the day"],
              ["09:12", "+240 containers made — IMM-1"],
              ["09:12", "−960 g polypropylene used — recipe"],
              ["11:03", "power cut — data queued at factory"],
              ["11:37", "power back — 34 min of readings caught up"],
              ["14:20", "−500 containers sold — invoice INV024285"],
            ].map(([t, e], i) => (
              <div key={i} className="flex gap-4 rounded-xl bg-white/5 px-4 py-3">
                <span className="text-white/40">{t}</span>
                <span className="text-white/85">{e}</span>
              </div>
            ))}
          </div>
        </RevealInView>
      </section>

      {/* ── Closing CTA ── */}
      <section className="mx-auto max-w-6xl px-6 py-24">
        <RevealInView className="text-center flex flex-col items-center gap-6">
        <h2 className="font-display text-4xl md:text-5xl font-bold tracking-tight">
          See your own machines on this screen.
        </h2>
        <p className="text-lg text-black/55 max-w-xl">
          A technician visits your factory, looks at your machines, and tells you
          exactly what wiring in would take. No obligation.
        </p>
        <div className="flex items-center gap-5">
          <Button size="lg" nativeButton={false} className="bg-[var(--ink)] hover:bg-black text-base h-12 px-7" render={<Link href="/contact" />}>Book a factory visit</Button>
          <Link href="/product" className="text-sm font-medium text-black/60 hover:text-black">
            or read what you get →
          </Link>
        </div>
        </RevealInView>
      </section>
    </>
  );
}
