import Link from "next/link";
import { Button } from "@/components/ui/button";
import { LiveMachineCard } from "@/components/marketing/live-machine-card";
import { RevealInView } from "@/components/marketing/reveal";

// Page 2 — "How it works": six steps that close the loop, then BrainFloor AI
// as the crowning premium module at the bottom.

const SECTIONS = [
  {
    id: "floor",
    kicker: "01 · THE FLOOR, LIVE",
    title: "Every machine, every shot, as it happens.",
    body: [
      "Industrial-Sync splices directly into your machine's native computer brains — like your Techmation SCADA units and line PLCs — to read the exact numbers the machine trusts. No more waiting for supervisors to type up numbers or pass around unverified tallies. You see which machine is running, which is idling on your bill, and exactly what mould is running in real time.",
      "Shots become products automatically. If an 8-cavity mould clicks 1,000 times, that is 8,000 units on your books, minus the exact scrap the machine logs. The communication breakdown between the floor and the office is permanently dead. Nobody fakes a clipboard count at 5 PM ever again.",
    ],
    facts: [
      ["Live Machine State", "Running, idle, alarm, or offline — visible at a single glance."],
      ["Performance Benchmarking", "Cycle time tracked against what is mathematically normal for that specific mould."],
      ["Native Code Extraction", "Machine alarms caught with factory error codes, precise timestamps, and exact durations."],
      ["Floor-Hardened Visibility", "Clean, bold dashboards readable from a metre away on the operator's tablet."],
    ],
  },
  {
    id: "stock",
    kicker: "02 · MATERIALS & STOCK",
    title: "Stock that tells the truth.",
    body: [
      "Raw material should be tracked exactly how it arrives: at true cost. You photograph a supplier invoice, and Industrial-Sync reads the lines, books the kilograms, and maps the true purchase price instantly. You will know exactly where your capital is tied up without waiting for the end-of-month stock take — completely eliminating the blindspots of imported materials not yet received or currently in transit overseas.",
      "Every product on your floor carries its exact recipe: the precise grams of polymer per unit, cavities per mould, and runner weights. When your machine executes a run, the system automatically deducts the exact material used. Even your runners are routed straight into a digital regrind pool — because sprues are usable material, not missing inventory.",
      "The result is an air-tight stock ledger where nothing drifts and nothing is guessed. At the end of the month, the platform automatically generates an Executive Variance Report, mapping your total value movement, inventory margins, and changes in stock levels from the previous month — so every single shilling is traceable straight back to the machine event that caused it.",
    ],
    facts: [
      ["Smart Invoice Logging", "Photograph any supplier invoice to bring material into stock at actual cost."],
      ["Automated Recipe Deductions", "Material stock counts drop natively per unit made, eliminating variance gaps."],
      ["Regrind Tracking Suite", "Reclaimed runners are tracked and returned to your inventory as usable material."],
      ["Capital Variance & Costing", "Monthly reports tracking value movement, transit ratios, and margins from real market prices."],
    ],
  },
  {
    id: "next",
    kicker: "03 · WHAT TO MAKE NEXT",
    title: "The morning decision, answered.",
    body: [
      "Industrial-Sync links directly to your sales history — pulling a read-only stream from the invoicing software you already use — and translates years of client data into a live demand rate. Balanced against your live warehouse stock, the system calculates your exact weeks-of-cover. You see instantly which products are safe and which ones run out this week.",
      "This completely kills capital overcommitment and inventory imbalances. The system handles the heavy math managers usually stress over on paper: it calculates, from production order, that a run of 12,000 surgical containers requires exactly 5.4 machine hours and 95 kg of polypropylene. If the polymer isn't in the warehouse, the system flags the shortfall before the heating bands are even turned on. Your most critical bottlenecks are never overshadowed.",
    ],
    facts: [
      ["Historical Demand Mapping", "Production forecasting driven by your real, historical sales data."],
      ["Live Stock Cover", "Real-time visibility into exactly how many weeks of supply you have left per product."],
      ["Resource Prediction", "Machine hours and raw materials calculated automatically per production order."],
      ["Pre-Run Shortfall Alerts", "Material deficits flagged on your dashboard before your operators prep the line."],
    ],
  },
  {
    id: "real",
    kicker: "04 · BUILT FOR REAL FLOORS",
    title: "Power cuts. Manual runs. Broken parts. Covered.",
    body: [
      "A standard cloud system assumes your internet and power will never drop. Industrial-Sync was engineered inside real, breathing factory floors in Nairobi where the grid fluctuates. Internet down? Your data queues safely in the database at the local hardware edge layer and catches up automatically when the line returns. Power cut mid-shift? The machines keep their memory, and our gateways don't lose a single data packet.",
      "Production that happens off the grid — an emergency manual run or a sudden outage — is logged by the operator in just two taps on our floor app. The product recipe still deducts the raw material, and your unit costs stay absolutely honest.",
      "Underneath it all, our database ledger is strictly append-only. Corrections are logged as new entries, never edited or deleted. When you audit a count, you get a bulletproof timeline of real events, completely eliminating those unfinished stories between shifts.",
    ],
    facts: [
      ["Offline-First Architecture", "Your data waits safely in the local database until the network stabilizes."],
      ["Two-Tap Operator Overrides", "Easy logging for power outages, floor waste, and rejected parts."],
      ["Protected Cost Controls", "Material and financial unit costs stay 100% accurate through every adjustment."],
      ["Tamper-Proof Ledger", "An append-only database path ensures every single number has an unalterable history."],
    ],
  },
  {
    id: "integrations",
    kicker: "05 · WORKS WITH WHAT YOU HAVE",
    title: "Keep your invoicing. We read it.",
    body: [
      "You don't need to change how your sales team operates or throw out the invoicing software you trust. Industrial-Sync mirrors your active platforms — like Zoho Books or Oracle — in a secure, read-only, one-direction stream. We never write data back or alter your accounts. You link your invoice items to your physical product recipes once, and your entire operational history resolves retroactively.",
      "In our very first deployment, we mirrored 24,000 legacy invoices. Three years of fragmented sales history were instantly transformed into a live, clear demand picture. Your departments are unified overnight, and the owner knows the exact stock-out balances and material margins in real time.",
    ],
    facts: [
      ["Encrypted Read-Only Sync", "We pull sales records securely without ever touching or modifying your financial data."],
      ["Retroactive Matching", "Link a product item once, and the system automatically charts its entire historical demand."],
      ["Automated Sales Deductions", "Shipped invoices trigger automatic finished goods deductions from your inventory."],
      ["Native ERP & Books Sync", "Built to plug straight into Zoho Books, Oracle, or any modern bookkeeping system with an open API from day one."],
    ],
  },
  {
    id: "energy",
    kicker: "06 · ENERGY & COMPLIANCE",
    title: "Automated Net-Zero & Tariff Optimization.",
    body: [
      "Stop treating electricity as an uncontrollable factory overhead. Industrial-Sync clamps smart energy meters directly onto individual machine lines, matching your live kilowatt-hour (kWh) current draw against your physical production counts. You get a transparent look at your true Specific Energy Consumption (SEC) per part.",
      "Our background engine automatically converts this raw energy data into live carbon footprint (CO₂e) logs. The platform maps your power efficiency shift by shift, advising your team on the best times to run heavy loads to exploit cheap off-peak Kenya Power tariffs. You slash your electricity bills while keeping your facility instantly audit-ready for EPRA energy regulations and UN Global Compact sustainability compliance.",
    ],
    facts: [
      ["Barrel-Level Energy Metering", "Continuous electrical current and kWh tracking per individual machine line."],
      ["Automated Scope 2 Reporting", "Raw power usage converted natively into verifiable carbon footprint logs (CO₂e)."],
      ["Time-of-Use Optimization", "Live dashboard metrics that help your team shift heavy runs to dodge peak tariff premiums."],
      ["1-Click Regulatory Exports", "Sustainability audits generated automatically to satisfy EPRA and global ESG frameworks."],
    ],
  },
];

const BRAINFLOOR_FACTS: Array<[string, string]> = [
  ["Deep Pattern Recognition", "Catches silent material variations, faked shift logs, and mechanical wear before lines stall."],
  ["Conversational Factory Chatbox", "Query the floor instantly: “Where exactly did our money leak during the previous night shift, which machines caused unlogged downtime, and why? Also, how much did we overspend on peak Kenya Power tariffs for that exact run?”"],
  ["Predictive Maintenance", "Early warnings on mechanical drive friction and heater band degradation to eliminate sudden floor panic."],
  ["Dynamic Resource Balancing", "Matches live workforce shifts against upcoming invoice demand to optimize your most critical bottlenecks."],
];

export default function ProductPage() {
  return (
    <>
      <section className="mx-auto max-w-6xl px-6 pt-20 pb-8">
        <h1 className="font-display text-5xl font-bold tracking-tight">How it works.</h1>
        <p className="mt-4 text-lg text-black/55 max-w-2xl">
          Six simple steps that connect your entire factory. From the moment raw
          material arrives, to the exact second a machine makes a product,
          straight to your final sales receipts — we close the loop so your
          numbers finally tell the truth.
        </p>
      </section>
      {SECTIONS.map((s, i) => (
        <section key={s.id} id={s.id} className={i % 2 ? "bg-white border-y border-black/5" : ""}>
          <RevealInView className="mx-auto max-w-6xl px-6 py-16 grid md:grid-cols-2 gap-12">
            <div className={i % 2 ? "md:order-2" : ""}>
              <div className="font-mono text-sm text-[var(--accent)] font-semibold tracking-wider">{s.kicker}</div>
              <h2 className="mt-2 font-display text-3xl font-bold tracking-tight">{s.title}</h2>
              {s.body.map((p, j) => (
                <p key={j} className="mt-4 text-black/60 leading-relaxed">{p}</p>
              ))}
            </div>
            <div className={`flex flex-col gap-3 justify-center ${i % 2 ? "md:order-1" : ""}`}>
              {s.id === "floor" && (
                <div className="flex justify-center pb-2">
                  <LiveMachineCard />
                </div>
              )}
              {s.facts.map(([label, text], j) => (
                <div key={j} className="gloss rounded-xl px-5 py-4 text-sm flex items-start gap-3">
                  <span className="size-1.5 rounded-full bg-[var(--accent)] shrink-0 mt-1.5" />
                  <span>
                    <span className="font-semibold">{label}:</span>{" "}
                    <span className="text-black/60">{text}</span>
                  </span>
                </div>
              ))}
            </div>
          </RevealInView>
        </section>
      ))}

      {/* ── BrainFloor AI — the crowning premium module ── */}
      <section className="bg-[var(--ink)] text-white">
        <RevealInView className="mx-auto max-w-6xl px-6 py-24">
          <div className="font-mono text-sm text-[var(--accent)] font-semibold tracking-widest">
            PREMIUM MODULE · BRAINFLOOR AI
          </div>
          <h2 className="mt-3 font-display text-4xl md:text-5xl font-bold tracking-tight">
            The autonomous plant engineer that never sleeps.
          </h2>
          <div className="mt-8 grid md:grid-cols-2 gap-12">
            <div className="flex flex-col gap-4 text-white/65 leading-relaxed">
              <p>
                Industrial-Sync doesn&apos;t just log numbers — it thinks. Our intelligence layer connects every
                data pipeline in your facility into a single brain. By cross-referencing live PLC machine
                registers and energy draw with active material levels across any ERP — including Zoho, Oracle,
                or SAP — BrainFloor AI continuously tracks your entire operation 24/7 to spot hidden anomalies
                and operational patterns that human eyes completely miss.
              </p>
              <p>
                Moving beyond standard Predictive AI, which simply flags potential failures, BrainFloor uses
                Prescriptive Analytics to advise management on exactly how to optimize production runs to hit
                target margins. This intelligence is delivered through a built-in conversational co-pilot chat
                box that puts the entire factory&apos;s data into plain English.
              </p>
              <p>
                From day one, the system uses straight math to answer queries, and within 3 to 6 months, the AI
                fully maps your floor&apos;s unique behavioral heartbeat — unlocking elite-level predictive
                insights. You ask real, raw operational questions, and the AI instantly bridges your physical
                machine metrics with your business financials to give you immediate, actionable execution.
              </p>
            </div>
            <div className="flex flex-col gap-3 justify-center">
              {BRAINFLOOR_FACTS.map(([label, text], j) => (
                <div key={j} className="rounded-xl px-5 py-4 text-sm bg-white/[0.06] border border-white/10 flex items-start gap-3">
                  <span className="size-1.5 rounded-full bg-[var(--accent)] shrink-0 mt-1.5" />
                  <span>
                    <span className="font-semibold text-white">{label}:</span>{" "}
                    <span className="text-white/60">{text}</span>
                  </span>
                </div>
              ))}
            </div>
          </div>
        </RevealInView>
      </section>

      <section className="mx-auto max-w-6xl px-6 py-20 text-center flex flex-col items-center gap-5">
        <h2 className="font-display text-3xl font-bold">Want to see it on your machines?</h2>
        <Button size="lg" nativeButton={false} className="bg-[var(--ink)] hover:bg-black h-12 px-7" render={<Link href="/contact" />}>Book a virtual demo</Button>
      </section>
    </>
  );
}
