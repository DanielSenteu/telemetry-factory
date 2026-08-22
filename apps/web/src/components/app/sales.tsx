"use client";

import { useCallback, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { field } from "@/components/app/modal";
import { PROVIDERS, type Provider } from "@/lib/integrations/registry";
import {
  getConnection,
  getImportedCount,
  listUnmappedItems,
  mapItemToProduct,
  getDemand,
  type IntegrationStatus,
  type UnmappedItem,
  type DemandRow,
} from "@/lib/services/sales";
import { listFinishedGoods, type Product } from "@/lib/services/production";
import { formatNairobi } from "@/lib/services/machines-logic";

// Sales: where the outside world's sales become our stock and demand. Connect
// is one click (redirect to the provider's own consent); no sync button — cron
// keeps it current.

export function Sales({ orgId }: { orgId: number }) {
  const params = useSearchParams();
  const [conn, setConn] = useState<IntegrationStatus | null | undefined>(undefined);

  const load = useCallback(async () => {
    setConn(await getConnection(orgId));
  }, [orgId]);

  useEffect(() => {
    let gone = false;
    Promise.resolve().then(() => { if (!gone) load(); });
    return () => { gone = true; };
  }, [load]);

  const justConnected = params.get("connected") === "1";
  const errorParam = params.get("error");

  if (conn === undefined) return <div className="gloss rounded-2xl h-48 animate-pulse max-w-2xl" />;

  return (
    <div className="flex flex-col gap-5">
      {errorParam && (
        <div className="rounded-xl bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700 max-w-2xl">
          Connecting didn&apos;t finish: {errorParam.replace(/_/g, " ")}. Try again, or call us.
        </div>
      )}
      {conn && conn.has_token ? (
        <Connected orgId={orgId} conn={conn} justConnected={justConnected} />
      ) : (
        <Gallery />
      )}
    </div>
  );
}

// ── Not connected: the provider gallery ───────────────
function Gallery() {
  return (
    <div className="max-w-3xl flex flex-col gap-5">
      <div>
        <h1 className="font-display text-2xl font-bold">Sales</h1>
        <p className="mt-1 text-sm text-black/55">
          Connect where you invoice today. We mirror your sales — read-only — so stock goes down as you sell
          and your best-sellers become a demand picture.
        </p>
      </div>
      <div className="grid gap-4 sm:grid-cols-2">
        {PROVIDERS.map((p) => (
          <ProviderCard key={p.key} provider={p} />
        ))}
      </div>
    </div>
  );
}

function ProviderCard({ provider }: { provider: Provider }) {
  const live = provider.status === "live";
  return (
    <div className={`gloss rounded-2xl p-5 flex flex-col gap-3 ${live ? "" : "opacity-80"}`}>
      <div className="flex items-center gap-2.5">
        <span className={`inline-flex size-2.5 rounded-full ${live ? "bg-[var(--accent)]" : "bg-black/25"}`} />
        <span className="font-display font-bold">{provider.label}</span>
        {!live && (
          <span className="ml-auto font-mono text-[10px] font-bold tracking-widest text-black/40">
            {provider.status === "coming_soon" ? "SOON" : "ON REQUEST"}
          </span>
        )}
      </div>
      <p className="text-sm text-black/55 flex-1">{provider.blurb}</p>
      {live && provider.connectPath ? (
        <a href={provider.connectPath} className="h-11 rounded-lg bg-[var(--ink)] text-white text-sm font-semibold hover:bg-black transition-colors flex items-center justify-center">
          Connect {provider.label}
        </a>
      ) : (
        <button disabled className="h-11 rounded-lg border border-black/10 text-sm font-medium text-black/40 cursor-default">
          {provider.status === "coming_soon" ? "Coming soon" : "Talk to us"}
        </button>
      )}
    </div>
  );
}

// ── Connected: status + link items + demand ───────────
function Connected({ orgId, conn, justConnected }: { orgId: number; conn: IntegrationStatus; justConnected: boolean }) {
  const [tab, setTab] = useState<"link" | "demand">("link");
  const [counts, setCounts] = useState<{ total: number; needsMapping: number } | null>(null);

  const loadCounts = useCallback(async () => {
    setCounts(await getImportedCount(orgId));
  }, [orgId]);

  useEffect(() => {
    let gone = false;
    Promise.resolve().then(() => { if (!gone) loadCounts(); });
    // While backfilling, poll so the count visibly climbs.
    const iv = conn.backfill_done ? null : setInterval(loadCounts, 8000);
    return () => { gone = true; if (iv) clearInterval(iv); };
  }, [loadCounts, conn.backfill_done]);

  return (
    <div className="flex flex-col gap-5">
      {justConnected && (
        <div className="rounded-xl bg-[var(--accent-soft)] border border-[var(--accent)]/30 px-4 py-3 text-sm text-[var(--accent)] max-w-3xl">
          <span className="font-semibold">Connected.</span> We&apos;re importing your sales now — this can take a while for years of history. It keeps going on its own.
        </div>
      )}

      <div className="gloss rounded-2xl p-5 flex flex-wrap items-center gap-x-6 gap-y-2 max-w-3xl">
        <div className="flex items-center gap-2.5">
          <span className="relative flex size-2.5">
            <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-[var(--accent)] opacity-50" />
            <span className="relative inline-flex size-2.5 rounded-full bg-[var(--accent)]" />
          </span>
          <span className="font-display font-bold">Zoho Books connected</span>
        </div>
        <div className="font-mono text-sm text-black/55">
          {counts ? `${counts.total.toLocaleString()} invoices` : "…"}
          {!conn.backfill_done && <span className="text-amber-600"> · importing history…</span>}
        </div>
        <div className="ml-auto font-mono text-xs text-black/40">
          {conn.last_sync_at ? `synced ${formatNairobi(conn.last_sync_at)}` : "first sync running"}
          {" · auto every 15 min"}
        </div>
        {conn.last_sync_status === "error" && conn.last_sync_error && (
          <div className="basis-full text-xs text-red-600">Last sync error: {conn.last_sync_error}</div>
        )}
      </div>

      <div className="flex gap-1 border-b border-black/5 -mx-1 px-1 max-w-3xl">
        {(["link", "demand"] as const).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`px-4 py-3 text-sm font-semibold border-b-2 -mb-px transition-colors ${tab === t ? "border-[var(--accent)] text-black" : "border-transparent text-black/50 hover:text-black"}`}
          >
            {t === "link" ? `Link items${counts?.needsMapping ? ` (${counts.needsMapping})` : ""}` : "What sells"}
          </button>
        ))}
      </div>

      {tab === "link" ? <LinkItems orgId={orgId} onMapped={loadCounts} /> : <Demand orgId={orgId} />}
    </div>
  );
}

function LinkItems({ orgId, onMapped }: { orgId: number; onMapped: () => void }) {
  const [items, setItems] = useState<UnmappedItem[] | null>(null);
  const [products, setProducts] = useState<Product[]>([]);
  const [choice, setChoice] = useState<Record<string, string>>({});
  const [savingId, setSavingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const [u, p] = await Promise.all([listUnmappedItems(orgId), listFinishedGoods(orgId)]);
    setItems(u);
    setProducts(p);
  }, [orgId]);

  useEffect(() => {
    let gone = false;
    Promise.resolve().then(() => { if (!gone) load(); });
    return () => { gone = true; };
  }, [load]);

  const link = async (it: UnmappedItem) => {
    const pid = Number(choice[it.external_item_id]);
    if (!pid) return;
    setSavingId(it.external_item_id);
    setError(null);
    try {
      await mapItemToProduct(orgId, it.external_item_id, pid, it.description);
      await load();
      onMapped();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSavingId(null);
    }
  };

  if (items === null) return <div className="gloss rounded-2xl h-40 animate-pulse max-w-3xl" />;

  return (
    <div className="max-w-3xl flex flex-col gap-3">
      <p className="text-sm text-black/55">
        Their item names, ordered by how much has sold — linking the top of the list clears the most invoices.
        You only link each once; every past and future invoice follows.
      </p>
      {error && <p className="text-sm text-red-600">{error}</p>}
      {items.length === 0 ? (
        <div className="gloss rounded-2xl p-8 text-center text-sm text-black/55">
          Nothing waiting — everything imported so far is linked, or the first import is still running.
        </div>
      ) : (
        items.map((it) => (
          <div key={it.external_item_id} className="gloss rounded-2xl p-4 flex flex-col gap-3">
            <div className="flex items-baseline gap-3">
              <span className="font-medium flex-1 truncate">{it.description || it.external_item_id}</span>
              <span className="font-mono text-sm text-black/50 tabular-nums">
                {Number(it.total_quantity).toLocaleString()} sold · {it.document_count} inv
              </span>
            </div>
            <div className="flex items-center gap-2">
              <select className={field + " flex-1"} value={choice[it.external_item_id] ?? ""} onChange={(e) => setChoice((c) => ({ ...c, [it.external_item_id]: e.target.value }))}>
                <option value="">Which of our products is this?</option>
                {products.map((p) => (
                  <option key={p.id} value={p.id}>{p.name}</option>
                ))}
              </select>
              <button onClick={() => link(it)} disabled={!choice[it.external_item_id] || savingId === it.external_item_id} className="h-12 px-5 rounded-lg bg-[var(--ink)] text-white text-sm font-medium disabled:opacity-40">
                {savingId === it.external_item_id ? "…" : "Link"}
              </button>
            </div>
          </div>
        ))
      )}
    </div>
  );
}

function Demand({ orgId }: { orgId: number }) {
  const [rows, setRows] = useState<DemandRow[] | null>(null);
  const [months, setMonths] = useState(12);

  useEffect(() => {
    let gone = false;
    getDemand(orgId, months).then((r) => !gone && setRows(r)).catch(() => !gone && setRows([]));
    return () => { gone = true; };
  }, [orgId, months]);

  if (rows === null) return <div className="gloss rounded-2xl h-40 animate-pulse max-w-3xl" />;

  return (
    <div className="max-w-3xl flex flex-col gap-3">
      <div className="flex items-center justify-between">
        <p className="text-sm text-black/55">Average per month is what to plan production against.</p>
        <select className={field + " w-auto"} value={months} onChange={(e) => setMonths(Number(e.target.value))}>
          <option value={3}>3 months</option>
          <option value={12}>12 months</option>
          <option value={36}>3 years</option>
        </select>
      </div>
      {rows.length === 0 ? (
        <div className="gloss rounded-2xl p-8 text-center text-sm text-black/55">No sales imported yet.</div>
      ) : (
        <div className="gloss rounded-2xl p-5 flex flex-col">
          {rows.slice(0, 40).map((r) => (
            <div key={r.product_id ?? r.external_item_id} className="flex items-center gap-3 py-3 border-t border-black/5 first:border-t-0">
              <span className="font-medium flex-1 truncate">{r.description || r.external_item_id}</span>
              <span className="font-mono text-sm tabular-nums w-24 text-right">{Math.round(r.quantity).toLocaleString()} sold</span>
              <span className="font-mono text-sm font-semibold tabular-nums w-24 text-right">{Math.round(r.perMonth).toLocaleString()}/mo</span>
              {!r.product_id && <span className="font-mono text-[10px] font-bold text-amber-700 bg-amber-100 rounded px-1.5 py-1">not linked</span>}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
