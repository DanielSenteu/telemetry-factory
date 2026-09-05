"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

// The frame every app screen lives in: wordmark, four tabs, factory name,
// sign out. Tablet-first — every target comfortably over 44px.
const TABS = [
  { href: "/app", label: "Dashboard" },
  { href: "/app/materials", label: "Materials" },
  { href: "/app/production", label: "Production" },
  { href: "/app/sales", label: "Sales" },
  { href: "/app/variance", label: "Variance Reports" },
];

export function AppShell({
  orgName,
  email,
  children,
}: {
  orgId: number;
  orgName: string;
  email: string;
  children: React.ReactNode;
}) {
  const pathname = usePathname();
  const router = useRouter();

  const signOut = async () => {
    await createClient().auth.signOut();
    router.push("/");
    router.refresh();
  };

  return (
    <div className="min-h-screen bg-[var(--paper)] text-[var(--ink)] flex flex-col">
      <header className="sticky top-0 z-40 backdrop-blur-md bg-white/75 border-b border-black/5">
        <div className="mx-auto max-w-7xl px-4 md:px-6 h-16 flex items-center gap-3 md:gap-6">
          <Link href="/app" className="font-display font-bold flex items-center gap-2 shrink-0">
            <span className="inline-block size-2.5 rounded-full bg-[var(--accent)]" aria-hidden />
            <span className="hidden sm:inline">Industrial-Sync</span>
          </Link>
          <nav className="flex items-center gap-1 md:gap-2">
            {TABS.map((t) => {
              const active = t.href === "/app" ? pathname === "/app" : pathname.startsWith(t.href);
              return (
                <Link
                  key={t.href}
                  href={t.href}
                  className={`px-3 md:px-5 py-2.5 rounded-lg text-sm md:text-base font-semibold transition-colors ${
                    active ? "bg-[var(--ink)] text-white" : "text-black/55 hover:text-black hover:bg-black/5"
                  }`}
                >
                  {t.label}
                </Link>
              );
            })}
          </nav>
          <div className="ml-auto flex items-center gap-3 min-w-0">
            <span className="hidden md:block text-sm text-black/50 truncate">{orgName}</span>
            <button
              onClick={signOut}
              title={email}
              className="px-3 py-2.5 rounded-lg text-sm font-medium text-black/50 hover:text-black hover:bg-black/5 transition-colors"
            >
              Sign out
            </button>
          </div>
        </div>
      </header>
      <main className="flex-1 mx-auto w-full max-w-7xl px-4 md:px-6 py-6">{children}</main>
    </div>
  );
}
