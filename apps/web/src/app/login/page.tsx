"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";

// Sales-led product: no signup. Accounts are created when we deploy to a
// factory, so the door is deliberately just a door.
export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const supabase = createClient();
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) {
      setError(
        error.message === "Invalid login credentials"
          ? "That email and password don't match. Check both and try again."
          : error.message,
      );
      setBusy(false);
      return;
    }
    router.push("/app");
    router.refresh();
  };

  return (
    <div className="min-h-screen bg-[var(--paper)] text-[var(--ink)] flex flex-col items-center justify-center px-6">
      <Link href="/" className="font-display text-xl font-bold flex items-center gap-2 mb-8">
        <span className="inline-block size-2.5 rounded-full bg-[var(--accent)]" aria-hidden />
        Industrial-Sync
      </Link>
      <form onSubmit={handleSubmit} className="gloss rounded-2xl p-8 w-full max-w-sm flex flex-col gap-5">
        <div>
          <h1 className="font-display text-2xl font-bold">Log in</h1>
          <p className="mt-1 text-sm text-black/50">Your factory is waiting.</p>
        </div>
        <label className="flex flex-col gap-1.5">
          <span className="text-sm font-medium text-black/70">Email</span>
          <input
            type="email"
            required
            autoComplete="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="h-12 rounded-lg border border-black/10 px-3.5 text-base outline-none focus:border-black/30"
          />
        </label>
        <label className="flex flex-col gap-1.5">
          <span className="text-sm font-medium text-black/70">Password</span>
          <input
            type="password"
            required
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="h-12 rounded-lg border border-black/10 px-3.5 text-base outline-none focus:border-black/30"
          />
        </label>
        {error && <p className="text-sm text-red-600">{error}</p>}
        <button
          type="submit"
          disabled={busy}
          className="h-12 rounded-lg bg-[var(--ink)] text-white font-medium hover:bg-black transition-colors disabled:opacity-60"
        >
          {busy ? "Logging in…" : "Log in"}
        </button>
        <p className="text-xs text-black/40 text-center leading-relaxed">
          Accounts are set up by your Industrial-Sync technician.
          <br />
          Locked out? Call us — it&apos;s faster than email.
        </p>
      </form>
    </div>
  );
}
