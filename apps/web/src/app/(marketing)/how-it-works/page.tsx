import Link from "next/link";
import { Button } from "@/components/ui/button";

export default function HowItWorksPage() {
  return (
    <>
      <section className="mx-auto max-w-6xl px-6 pt-20 pb-12">
        <h1 className="font-display text-5xl font-bold tracking-tight">How it starts.</h1>
        <p className="mt-4 text-lg text-black/55 max-w-2xl">
          No self-service signup, no credit card form. Factories are physical —
          so the first step is physical too.
        </p>
      </section>

      <section className="mx-auto max-w-6xl px-6 pb-16 grid md:grid-cols-3 gap-6">
        {[
          ["1", "Book a visit", "A technician walks your floor with you. We look at your machines and their controllers, your material flow, and how you sell today. You get a straight answer on what wiring in takes — and a quote. No obligation."],
          ["2", "We wire it in", "A small computer joins your factory network and reads each machine's controller. Your machines never touch the internet — they stay on their own local network, exactly as the manufacturers intend. Nothing about how you run production changes."],
          ["3", "You watch it flow", "The dashboard is live from day one: machines first, then stock as invoices and recipes come in, then demand as your sales history mirrors across. Most of the setup is us; your part is naming things once — this item is that product."],
        ].map(([n, t, d]) => (
          <div key={n} className="gloss rounded-2xl p-7">
            <div className="font-mono size-11 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] flex items-center justify-center text-lg font-semibold">{n}</div>
            <h2 className="mt-4 font-display text-xl font-bold">{t}</h2>
            <p className="mt-2 text-sm text-black/60 leading-relaxed">{d}</p>
          </div>
        ))}
      </section>

      <section className="bg-white border-y border-black/5">
        <div className="mx-auto max-w-6xl px-6 py-16">
          <h2 className="font-display text-3xl font-bold tracking-tight">Straight answers to fair questions.</h2>
          <div className="mt-8 grid md:grid-cols-2 gap-x-12 gap-y-8">
            {[
              ["Does Industrial Sync control my machines?", "No — and it never will. We read, we never write. Your machines take instructions from their own controllers and nobody else. If Industrial Sync vanished tomorrow, your production would not notice."],
              ["What machines does it work with?", "We started with injection moulding machines on Techmation controllers, read through the manufacturer's own gateway. On the visit we look at exactly what you run — that is what the visit is for."],
              ["What happens when the internet goes down?", "Production continues and so does the counting. Readings queue on the factory computer and upload when the connection returns — in order, deduplicated, nothing lost. This is not an add-on; it is how the system works all the time."],
              ["Do I have to leave my invoicing system?", "No. Industrial Sync mirrors your sales read-only. You keep invoicing exactly as you do today; we turn that history into stock movements and a demand picture."],
              ["Who sees my data?", "Your factory's data belongs to your factory. Access is per-organization at the database level — not a checkbox in our app, a wall in the infrastructure."],
              ["What does it cost?", "It depends on machines and scope, which is why the visit comes first. The quote is itemised and the visit costs you nothing."],
            ].map(([q, a]) => (
              <div key={q}>
                <h3 className="font-display font-bold">{q}</h3>
                <p className="mt-2 text-sm text-black/60 leading-relaxed">{a}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section className="mx-auto max-w-6xl px-6 py-20 text-center flex flex-col items-center gap-5">
        <h2 className="font-display text-3xl font-bold">The visit is the first step.</h2>
        <Button size="lg" nativeButton={false} className="bg-[var(--ink)] hover:bg-black h-12 px-7" render={<Link href="/contact" />}>Book a factory visit</Button>
      </section>
    </>
  );
}
