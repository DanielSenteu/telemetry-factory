import Link from "next/link";
import { Button } from "@/components/ui/button";

const nav = [
  { href: "/product", label: "How it works" },
  { href: "/how-it-works", label: "Getting started" },
  { href: "/about", label: "About" },
];

export default function MarketingLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen bg-[var(--paper)] text-[var(--ink)] flex flex-col">
      <header className="sticky top-0 z-40 backdrop-blur-md bg-white/70 border-b border-black/5">
        <div className="mx-auto max-w-6xl px-6 h-16 flex items-center gap-8">
          <Link href="/" className="font-display text-lg font-bold tracking-tight flex items-center gap-2">
            <span className="inline-block size-2.5 rounded-full bg-[var(--accent)]" aria-hidden />
            Industrial-Sync
          </Link>
          <nav className="hidden md:flex items-center gap-6 text-sm text-black/60">
            {nav.map((n) => (
              <Link key={n.href} href={n.href} className="hover:text-black transition-colors py-2">
                {n.label}
              </Link>
            ))}
          </nav>
          <div className="ml-auto flex items-center gap-3">
            <Button variant="ghost" nativeButton={false} render={<Link href="/login" />}>Log in</Button>
            <Button className="bg-[var(--ink)] hover:bg-black" nativeButton={false} render={<Link href="/contact" />}>Book a virtual demo</Button>
          </div>
        </div>
      </header>
      <main className="flex-1">{children}</main>
      <footer className="border-t border-black/5">
        <div className="mx-auto max-w-6xl px-6 py-10 flex flex-wrap items-center gap-6 text-sm text-black/50">
          <span className="font-display font-bold text-black/70">Industrial-Sync</span>
          <span>A Telemetry company · Nairobi, Kenya</span>
          <span className="ml-auto font-mono">
            <a href="tel:+254745435732" className="hover:text-black">+254 745 435 732</a>
            {" · "}
            <a href="mailto:info@telemetrynetworks.net" className="hover:text-black">info@telemetrynetworks.net</a>
          </span>
        </div>
      </footer>
    </div>
  );
}
