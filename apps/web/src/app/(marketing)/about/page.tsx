import { RevealInView } from "@/components/marketing/reveal";

export default function AboutPage() {
  return (
    <>
      <section className="mx-auto max-w-3xl px-6 pt-20 pb-16">
        <h1 className="font-display text-5xl font-bold tracking-tight">Why Industrial-Sync exists.</h1>
        <RevealInView className="mt-8 flex flex-col gap-5 text-lg text-black/65 leading-relaxed">
          <p>
            Industrial-Sync began on a real factory floor in Nairobi — a manufacturer
            running injection moulding machines all day, selling thousands of
            units a week, and still unable to answer the simplest question in
            manufacturing: <em className="text-black">what do we have, and what should we make next?</em>
          </p>
          <p>
            The invoicing system knew what sold but not what was on the shelf.
            The machines knew every shot they had fired but told no one. Stock
            was whatever the last person to count it said it was. Every system
            held a piece; nothing held the loop.
          </p>
          <p>
            So we built the loop. Machines counted honestly, invoices became
            stock, recipes deducted material, sales history became a demand
            picture — and for the first time the numbers agreed with the floor.
          </p>
          <p>
            We deliberately do not try to be everything. Industrial-Sync is not an ERP,
            not an accounting suite, not an HR system. It does one thing with
            depth: production, materials and stock for factories that mould —
            built to survive power cuts, patchy internet and busy hands, because
            that is what real floors are like.
          </p>
        </RevealInView>
      </section>

      <section className="bg-white border-y border-black/5">
        <RevealInView className="mx-auto max-w-3xl px-6 py-14">
          <h2 className="font-display text-2xl font-bold">Where this goes.</h2>
          <ul className="mt-6 flex flex-col gap-4">
            {[
              ["Now", "Live floor, materials and stock, recipes and costing, sales mirroring, production planning."],
              ["Next", "More machine brands and controllers. Point-of-sale integration so shop sales deduct stock the same way invoices do."],
              ["Then", "Multi-site factories on one screen, and the patterns three years of your own data can teach — when a machine drifts, when a material runs short, before it happens."],
            ].map(([k, v]) => (
              <li key={k} className="flex gap-5">
                <span className="font-mono text-sm text-[var(--accent)] font-semibold w-12 shrink-0 pt-0.5">{k}</span>
                <span className="text-black/65">{v}</span>
              </li>
            ))}
          </ul>
          <p className="mt-8 text-sm text-black/45">
            Industrial-Sync is built by Telemetry, Nairobi.
          </p>
        </RevealInView>
      </section>
    </>
  );
}
