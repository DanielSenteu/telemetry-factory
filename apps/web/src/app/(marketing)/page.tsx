import Link from "next/link";
import { Button } from "@/components/ui/button";
import { Intro } from "@/components/marketing/intro";
import { LiveMachineCard } from "@/components/marketing/live-machine-card";

export default function HomePage() {
  return (
    <>
      <Intro />
      <section className="mx-auto max-w-6xl px-6 py-24 grid gap-16 md:grid-cols-2 items-center">
        <div className="flex flex-col gap-6">
          <div className="font-mono text-sm text-[var(--accent)] font-semibold tracking-wider">
            FOR INJECTION MOULDING FACTORIES
          </div>
          <h1 className="font-display text-5xl md:text-6xl font-bold tracking-tight leading-[1.05]">
            Your factory floor, live on one screen.
          </h1>
          <p className="text-lg text-black/60 leading-relaxed max-w-lg">
            Shotline wires into your moulding machines and shows you — shot by
            shot — what is running, what is in stock, and what to make next.
          </p>
          <div className="flex items-center gap-5 pt-2">
            <Button size="lg" className="bg-[var(--ink)] hover:bg-black text-base h-12 px-7" render={<Link href="/contact" />}>Book a factory visit</Button>
            <span className="text-sm text-black/50">
              or call <span className="font-mono font-semibold text-black/80">[YOUR PHONE]</span>
            </span>
          </div>
        </div>
        <div className="flex justify-center md:justify-end">
          <LiveMachineCard />
        </div>
      </section>
    </>
  );
}
