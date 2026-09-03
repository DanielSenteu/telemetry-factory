import Link from "next/link";
import { Button } from "@/components/ui/button";
import { Intro } from "@/components/marketing/intro";
import { LiveMachineCard } from "@/components/marketing/live-machine-card";
import { Reveal, RevealInView } from "@/components/marketing/reveal";
import { Counter } from "@/components/marketing/counter";
import { StoryFeed } from "@/components/marketing/story-feed";

export default function HomePage() {
  return (
    <>
      <Intro />

      {/* ── Hero ── */}
      <section className="mx-auto max-w-6xl px-6 pt-24 pb-16 grid gap-16 md:grid-cols-2 items-center">
        <div className="flex flex-col gap-6">
          <Reveal delay={0}>
            <div className="font-mono text-sm text-[var(--accent)] font-semibold tracking-wider">
              A MANUFACTURING EXECUTION SYSTEM
            </div>
          </Reveal>
          <Reveal delay={0.1}>
            <h1 className="font-display text-5xl md:text-6xl font-bold tracking-tight leading-[1.05]">
              Your entire factory floor, transparent on one screen.
            </h1>
          </Reveal>
          <Reveal delay={0.2}>
            <p className="text-lg text-black/60 leading-relaxed max-w-lg">
              Industrial-Sync integrates directly into your machinery controllers, whether utilizing modern automation systems
              or legacy factory PLCs, retrieving key parameters natively from the machines. Powered by
              stable IIoT connectivity, our platform bridges the physical-to-digital
              divide to eliminate shop-floor data leaks completely. Management gets
              real-time, tamper-proof tracking, shot by shot, of exact production
              yields, live material deductions, and automated energy costs,
              transforming fragmented operations into a clear, unified business ledger.
            </p>
          </Reveal>
          <Reveal delay={0.3} className="flex items-center gap-5 pt-2">
            <Button size="lg" nativeButton={false} className="bg-[var(--ink)] hover:bg-black text-base h-12 px-7" render={<Link href="/contact" />}>Book a virtual demo</Button>
            <span className="text-sm text-black/50">
              or call <a href="tel:+254745435732" className="font-mono font-semibold text-black/80 hover:text-black">+254 745 435 732</a>
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
            <div className="font-mono text-3xl font-semibold"><Counter target={15} suffix="+" duration={1.1} /></div>
            <div className="mt-1 text-sm text-black/50">industrial parameters extracted continuously: real-time OEE, material scrap variances, mechanical alarms, and Specific Energy Consumption (SEC) per part</div>
          </div>
          <div>
            <div className="font-mono text-3xl font-semibold">±<Counter target={1.8} decimals={1} suffix="%" duration={1.4} /></div>
            <div className="mt-1 text-sm text-black/50">material balance accuracy. Most factories can&apos;t tell you where their material went. We reconciled six months of it, gram by gram</div>
          </div>
          <div>
            <div className="font-mono text-3xl font-semibold"><Counter target={2} prefix="~" suffix="s" duration={0.9} /></div>
            <div className="mt-1 text-sm text-black/50">between machine readings, so you see cycles as they happen</div>
          </div>
          <div>
            <div className="font-mono text-3xl font-semibold"><Counter target={0} /></div>
            <div className="mt-1 text-sm text-black/50">readings lost to an internet cut. Data queues at the factory and catches up</div>
          </div>
        </RevealInView>
      </section>

      {/* ── The loop ── */}
      <section className="mx-auto max-w-6xl px-6 py-20">
        <RevealInView>
        <h2 className="font-display text-4xl font-bold tracking-tight">One loop, closed.</h2>
        <p className="mt-3 text-lg text-black/55 max-w-2xl">
          A factory is a constant financial and physical flow: raw materials
          arrive, machinery transforms them, and finished inventory ships out.
          Industrial-Sync mirrors your complete production loop in real time,
          ensuring your warehouse ledger, physical machine cycles, and executive
          office metrics finally speak the exact same language.
        </p>
        <div className="mt-10 grid md:grid-cols-2 lg:grid-cols-3 gap-4">
          {[
            ["01", "Material Tracking & Verification", "Instantly log supplier invoices. Industrial-Sync automatically inputs raw polypropylene into your digital ledger at true cost, creating an air-tight line of sight from the warehouse to the machine barrel to stop material shrinkage."],
            ["02", "Precision Production Conversion", "Every single shot is extracted directly from the machine's native PLC brain. The system maps your exact product recipes against physical machine cycles, catching material waste, faked numbers, and floor leakage instantly."],
            ["03", "Sales & Demand Sync", "Sales flow in from your invoicing system and deduct finished goods automatically. The shelf count is real, not remembered, and three years of demand history stands behind every decision."],
            ["04", "Command & Capital Variance", "Stop flying blind on your working capital. Industrial-Sync automatically generates dynamic monthly variance reports, tracking exactly what percentage of your cash is tied up in warehouse stock versus active shop-floor inputs, eliminating inventory imbalances before they stall your production."],
            ["05", "Net-Zero & Tariff Optimization", "Industrial-Sync continuously converts raw machine kilowatt-hour (kWh) draw into live CO₂-equivalent (CO₂e) metrics. The platform maps your Specific Energy Consumption (SEC) per part natively, advising management on the most efficient times to run production to exploit off-peak tariffs, while keeping your facility instantly audit-ready for EPRA and UN Global Compact ESG reporting."],
            ["06", "BrainFloor AI Co-Pilot", "An interactive intelligence layer that cross-references all machine, material, and financial data 24/7. Management can chat directly with the floor to spot hidden leaks, optimize production runs, and catch maintenance anomalies before they cause a shutdown."],
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
            <h2 className="font-display text-4xl font-bold tracking-tight">Engineered for East African infrastructure.</h2>
            <p className="mt-4 text-white/60 text-lg leading-relaxed">
              Industrial-Sync was built directly inside operational factory floors in
              Nairobi, not in an isolated laboratory. The platform is hardened against
              local grid instability: when a power outage hits, your data queues safely
              on-site at the machine hardware layer. The moment power returns, the
              system automatically synchronizes the backlog with zero data corruption,
              zero duplication, absolute continuity.
            </p>
            <p className="mt-4 text-white/60 text-lg leading-relaxed">
              And when production happens that no system saw, like an outage or a
              manual run, the operator records it in two taps. Material use and
              unit costs stay correct, because the recipe does the arithmetic.
            </p>
          </div>
          <StoryFeed />
        </RevealInView>
      </section>

      {/* ── Closing CTA ── */}
      <section className="mx-auto max-w-6xl px-6 py-24">
        <RevealInView className="text-center flex flex-col items-center gap-6">
        <h2 className="font-display text-4xl md:text-5xl font-bold tracking-tight">
          See your own machines on this screen.
        </h2>
        <p className="text-lg text-black/55 max-w-xl">
          Our engineering team visits your facility, maps your current production
          lines, and delivers a tailored deployment blueprint to eliminate
          operational blind spots. No factory downtime, no complicated changes,
          and at absolutely no obligation.
        </p>
        <div className="flex items-center gap-5">
          <Button size="lg" nativeButton={false} className="bg-[var(--ink)] hover:bg-black text-base h-12 px-7" render={<Link href="/contact" />}>Book a virtual demo</Button>
          <Link href="/product" className="text-sm font-medium text-black/60 hover:text-black">
            See exactly how it works →
          </Link>
        </div>
        </RevealInView>
      </section>
    </>
  );
}
