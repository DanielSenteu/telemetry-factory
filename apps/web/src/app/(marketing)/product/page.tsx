import Link from "next/link";
import { Button } from "@/components/ui/button";

// Every claim on this page maps to something the software actually does.
// When the explainer video exists it lands at the top of this page.

const SECTIONS = [
  {
    id: "floor",
    kicker: "THE FLOOR, LIVE",
    title: "Every machine, every shot, as it happens.",
    body: [
      "Shotline reads each machine's own controller — the same numbers the machine trusts. You see who is running, idle, in alarm or offline; the product on the mould; today's count; the cycle time; and every alarm with its code and when it started.",
      "Shots become parts automatically: an 8-cavity mould at 1,000 shots is 8,000 containers, minus the scrap the machine itself reports. Nobody writes tallies on a clipboard at 5pm.",
    ],
    facts: ["running · idle · alarm · offline — at a glance", "cycle time against what's normal for that mould", "alarms with codes, timestamps and durations", "readable from a metre away, on the tablet in your hand"],
  },
  {
    id: "stock",
    kicker: "MATERIALS & STOCK",
    title: "Stock that tells the truth.",
    body: [
      "Raw material comes in the way it actually arrives: a supplier invoice. Photograph it — Shotline reads the lines, books the kilograms into stock at what they really cost, and remembers that supplier's names for next time.",
      "Every product carries its recipe: grams of material per unit, cavities per mould, runner weight. When the machine makes 1,000 units, the recipe deducts the exact material used — and the runners go into a regrind pool, because sprues are material, not waste.",
      "The result is a stock ledger where nothing is typed and nothing drifts: additions from invoices, deductions from production and sales, every line traceable to the event that caused it.",
    ],
    facts: ["photograph an invoice → stock in, at real cost", "recipes deduct material automatically per unit made", "regrind tracked — runners return as usable material", "true unit cost from actual material prices, not guesses"],
  },
  {
    id: "next",
    kicker: "WHAT TO MAKE NEXT",
    title: "The morning decision, answered.",
    body: [
      "Shotline mirrors your sales — from the invoicing system you already use — and turns three years of history into a demand rate per product. Against live stock, that becomes weeks of cover: which products are safe, which run out this week.",
      "Then it does the arithmetic managers do on paper: to make 12,000 stool containers on IMM-2 takes 8.4 hours and 48 kg of polypropylene — and tells you if the polypropylene isn't there.",
    ],
    facts: ["demand per product from your real sales history", "weeks-of-cover on every finished good", "machine hours and material needed, per suggestion", "material shortfalls flagged before the run starts"],
  },
  {
    id: "real",
    kicker: "BUILT FOR REAL FLOORS",
    title: "Power cuts. Manual runs. Broken parts. Covered.",
    body: [
      "Internet down? Data queues on a small computer at your factory and catches up when the line returns — in order, nothing lost, nothing double-counted. Power cut mid-shift? The machines keep their counters and so do we.",
      "Production that no system saw — an outage run, a manual batch — gets recorded by the operator in two taps. The recipe still deducts the material; the cost stays honest. End-of-day waste and rejects are recorded the same way, and rejected parts can route to the regrind pool.",
      "Underneath it all, every number is append-only: corrections are new entries, never edits. When someone asks why a count is what it is, the answer is a list of events, not a shrug.",
    ],
    facts: ["offline-first: your data waits at the factory", "operator overrides for outages, waste and rejects", "costs stay correct through every correction", "append-only ledger — every number has a paper trail"],
  },
  {
    id: "integrations",
    kicker: "WORKS WITH WHAT YOU HAVE",
    title: "Keep your invoicing. We read it.",
    body: [
      "You do not have to change how you sell. Shotline mirrors sales from your invoicing system — read-only, one direction, nothing written back. Link each of their item names to your products once; every past and future invoice resolves automatically.",
      "In our first deployment we mirrored 24,000 invoices — three years of sales — in an afternoon, and the factory's demand picture existed for the first time.",
    ],
    facts: ["read-only — we never touch your invoicing data", "link an item once, history resolves retroactively", "sales deduct finished goods automatically", "works today with Zoho Books; more to come"],
  },
];

export default function ProductPage() {
  return (
    <>
      <section className="mx-auto max-w-6xl px-6 pt-20 pb-8">
        <h1 className="font-display text-5xl font-bold tracking-tight">What you get.</h1>
        <p className="mt-4 text-lg text-black/55 max-w-2xl">
          Five things, each one deep. Together they close the loop from raw
          material to sold product.
        </p>
      </section>
      {SECTIONS.map((s, i) => (
        <section key={s.id} id={s.id} className={i % 2 ? "bg-white border-y border-black/5" : ""}>
          <div className="mx-auto max-w-6xl px-6 py-16 grid md:grid-cols-2 gap-12">
            <div className={i % 2 ? "md:order-2" : ""}>
              <div className="font-mono text-sm text-[var(--accent)] font-semibold tracking-wider">{s.kicker}</div>
              <h2 className="mt-2 font-display text-3xl font-bold tracking-tight">{s.title}</h2>
              {s.body.map((p, j) => (
                <p key={j} className="mt-4 text-black/60 leading-relaxed">{p}</p>
              ))}
            </div>
            <div className={`flex flex-col gap-3 justify-center ${i % 2 ? "md:order-1" : ""}`}>
              {s.facts.map((f, j) => (
                <div key={j} className="gloss rounded-xl px-5 py-4 text-sm font-medium flex items-center gap-3">
                  <span className="size-1.5 rounded-full bg-[var(--accent)] shrink-0" />
                  {f}
                </div>
              ))}
            </div>
          </div>
        </section>
      ))}
      <section className="mx-auto max-w-6xl px-6 py-20 text-center flex flex-col items-center gap-5">
        <h2 className="font-display text-3xl font-bold">Want to see it on your machines?</h2>
        <Button size="lg" nativeButton={false} className="bg-[var(--ink)] hover:bg-black h-12 px-7" render={<Link href="/contact" />}>Book a factory visit</Button>
      </section>
    </>
  );
}
