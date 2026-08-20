export default function LoginPage() {
  return (
    <div className="min-h-screen bg-[var(--paper)] flex items-center justify-center">
      <div className="gloss rounded-2xl p-8 w-full max-w-sm">
        <div className="font-display text-xl font-bold flex items-center gap-2">
          <span className="inline-block size-2.5 rounded-full bg-[var(--accent)]" aria-hidden />
          Industrial Sync
        </div>
        <p className="mt-3 text-sm text-black/50">Auth wiring lands next — Supabase session via cookies.</p>
      </div>
    </div>
  );
}
