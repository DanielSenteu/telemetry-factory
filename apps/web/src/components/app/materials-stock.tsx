"use client";

import { useCallback, useEffect, useState } from "react";
import { Modal, field, primaryBtn } from "@/components/app/modal";
import { listProducts, createProduct, type StockedProduct } from "@/lib/services/inventory";

// Materials: what do we have? Raw materials and finished goods, every number
// derived from the append-only ledger — nothing typed, nothing to drift.

const KINDS = [
  { key: "finished_good", label: "Finished good", hint: "Something you make and sell — containers, polypots, speculums" },
  { key: "raw_material", label: "Raw material", hint: "What machines consume — polypropylene, colourant" },
  { key: "consumable", label: "Consumable", hint: "Used in production but not the product — packaging, labels" },
] as const;

function fmtQty(n: number, uom: string) {
  if (uom === "g" && Math.abs(n) >= 1000)
    return { value: (n / 1000).toLocaleString(undefined, { maximumFractionDigits: 1 }), unit: "kg" };
  return { value: Number(n).toLocaleString(), unit: uom };
}

function fmtKsh(n: number) {
  return `KES ${Number(n).toLocaleString(undefined, { maximumFractionDigits: 0 })}`;
}

// Stock status mirrors the floor's state language: color + word, never color alone.
function stockStatus(p: StockedProduct): { word: string; text: string; ring: string; dot: string } {
  const n = Number(p.on_hand);
  if (n < 0) return { word: "CHECK", text: "text-red-600", ring: "ring-1 ring-red-500/50", dot: "bg-red-500" };
  if (n === 0) return { word: "OUT", text: "text-amber-600", ring: "ring-1 ring-amber-400/40", dot: "bg-amber-400" };
  return { word: "IN STOCK", text: "text-[var(--accent)]", ring: "", dot: "bg-[var(--accent)]" };
}

function ProductCard({ p }: { p: StockedProduct }) {
  const s = stockStatus(p);
  const q = fmtQty(Number(p.on_hand), p.unit_of_measure);
  return (
    <div className={`gloss rounded-2xl p-5 flex flex-col gap-3 ${s.ring}`}>
      <div className="flex items-center gap-2.5">
        <span className={`inline-flex size-2.5 rounded-full ${s.dot}`} />
        <span className="font-display font-bold tracking-tight truncate">{p.name}</span>
        <span className={`ml-auto font-mono text-[11px] font-bold tracking-widest ${s.text}`}>{s.word}</span>
      </div>
      <div className="flex items-baseline gap-2">
        <span className={`font-mono text-4xl font-semibold tabular-nums leading-none ${Number(p.on_hand) < 0 ? "text-red-600" : ""}`}>
          {q.value}
        </span>
        <span className="text-sm text-black/45">{q.unit} on hand</span>
      </div>
      <div className="flex flex-wrap gap-2 text-xs font-mono text-black/55">
        {Number(p.avg_unit_cost) > 0 && (
          <span className="rounded-lg bg-black/[0.045] px-2.5 py-1.5">
            @ {Number(p.avg_unit_cost).toFixed(2)}/{p.unit_of_measure}
          </span>
        )}
        {Number(p.stock_value) !== 0 && (
          <span className="rounded-lg bg-black/[0.045] px-2.5 py-1.5">{fmtKsh(Number(p.stock_value))} value</span>
        )}
        {p.kind === "finished_good" && p.sale_price != null && (
          <span className="rounded-lg bg-[var(--accent-soft)] text-[var(--accent)] font-semibold px-2.5 py-1.5">
            sells @ {Number(p.sale_price).toLocaleString()}
          </span>
        )}
      </div>
    </div>
  );
}

function Section({ title, rows }: { title: string; rows: StockedProduct[] }) {
  if (rows.length === 0) return null;
  const totalValue = rows.reduce((a, r) => a + Number(r.stock_value || 0), 0);
  return (
    <section className="flex flex-col gap-3">
      <div className="flex items-baseline gap-3">
        <h2 className="font-display text-lg font-bold">{title}</h2>
        <span className="text-sm text-black/40">{rows.length}</span>
        <span className="ml-auto font-mono text-sm text-black/50">{fmtKsh(totalValue)}</span>
      </div>
      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
        {rows.map((p) => (
          <ProductCard key={p.id} p={p} />
        ))}
      </div>
    </section>
  );
}

export function MaterialsStock({ orgId }: { orgId: number }) {
  const [rows, setRows] = useState<StockedProduct[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);

  const load = useCallback(async () => {
    try {
      setRows(await listProducts(orgId));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [orgId]);

  useEffect(() => {
    let gone = false;
    Promise.resolve().then(() => { if (!gone) load(); });
    return () => { gone = true; };
  }, [load]);

  const raw = (rows || []).filter((r) => r.kind === "raw_material" || r.kind === "consumable");
  const finished = (rows || []).filter((r) => r.kind === "finished_good");

  return (
    <div className="flex flex-col gap-5">
      <div className="flex items-center gap-3">
        <h1 className="font-display text-2xl font-bold">Materials &amp; stock</h1>
        <button
          onClick={() => setAdding(true)}
          className="ml-auto h-11 px-4 rounded-lg bg-[var(--ink)] text-white text-sm font-semibold hover:bg-black transition-colors"
        >
          Add product
        </button>
      </div>

      {error && (
        <div className="rounded-xl bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">{error}</div>
      )}

      {rows !== null && rows.length > 0 && (
        <div className="grid grid-cols-3 gap-4">
          {[
            { label: "Total stock value", value: fmtKsh(rows.reduce((a, r) => a + Number(r.stock_value || 0), 0)) },
            { label: "Raw materials", value: fmtKsh(raw.reduce((a, r) => a + Number(r.stock_value || 0), 0)) },
            { label: "Finished goods", value: fmtKsh(finished.reduce((a, r) => a + Number(r.stock_value || 0), 0)) },
          ].map((t) => (
            <div key={t.label} className="gloss rounded-2xl px-5 py-4">
              <div className="font-mono text-xl md:text-2xl font-semibold tabular-nums">{t.value}</div>
              <div className="mt-0.5 text-xs md:text-sm text-black/50">{t.label}</div>
            </div>
          ))}
        </div>
      )}

      {rows === null ? (
        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
          {[0, 1, 2, 3, 4, 5].map((i) => (
            <div key={i} className="gloss rounded-2xl h-36 animate-pulse" />
          ))}
        </div>
      ) : rows.length === 0 ? (
        <div className="gloss rounded-2xl p-10 text-center">
          <h2 className="font-display text-lg font-bold">Nothing here yet</h2>
          <p className="mt-2 text-sm text-black/55 max-w-md mx-auto">
            Add your products and materials — then recipes, production and sales keep these numbers true by
            themselves.
          </p>
        </div>
      ) : (
        <>
          <Section title="Finished goods" rows={finished} />
          <Section title="Raw materials" rows={raw} />
        </>
      )}

      {adding && <AddProductDialog orgId={orgId} onClose={() => setAdding(false)} onDone={load} />}
    </div>
  );
}

function AddProductDialog({ orgId, onClose, onDone }: { orgId: number; onClose: () => void; onDone: () => void }) {
  const [kind, setKind] = useState<(typeof KINDS)[number]["key"] | null>(null);
  const [name, setName] = useState("");
  const [uom, setUom] = useState("");
  const [salePrice, setSalePrice] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const pickKind = (k: (typeof KINDS)[number]["key"]) => {
    setKind(k);
    setUom(k === "raw_material" ? "g" : "each");
  };

  const submit = async () => {
    if (!kind || !name.trim()) return;
    setBusy(true);
    setError(null);
    try {
      await createProduct(orgId, {
        name: name.trim(),
        kind,
        unit_of_measure: uom || "each",
        sale_price: kind === "finished_good" && salePrice ? Number(salePrice) : null,
      });
      onDone();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal open onClose={onClose} title="Add product">
      {!kind ? (
        <div className="flex flex-col gap-3">
          {KINDS.map((k) => (
            <button key={k.key} onClick={() => pickKind(k.key)} className="gloss rounded-xl p-4 text-left hover:ring-1 hover:ring-black/15 transition-shadow">
              <div className="font-semibold">{k.label}</div>
              <div className="text-sm text-black/55 mt-0.5">{k.hint}</div>
            </button>
          ))}
        </div>
      ) : (
        <div className="flex flex-col gap-4">
          <button onClick={() => setKind(null)} className="text-sm text-black/50 hover:text-black text-left">
            ← {KINDS.find((k) => k.key === kind)!.label}
          </button>
          <label className="flex flex-col gap-1.5">
            <span className="text-sm font-medium text-black/70">Name</span>
            <input className={field} value={name} onChange={(e) => setName(e.target.value)} placeholder={kind === "raw_material" ? "e.g. Polypropylene" : "e.g. Urine container 45ml"} />
          </label>
          <label className="flex flex-col gap-1.5">
            <span className="text-sm font-medium text-black/70">Counted in</span>
            <input className={field} value={uom} onChange={(e) => setUom(e.target.value)} placeholder="each / g / kg / pcs" />
          </label>
          {kind === "finished_good" && (
            <label className="flex flex-col gap-1.5">
              <span className="text-sm font-medium text-black/70">Sale price (KES, optional)</span>
              <input type="number" inputMode="decimal" className={field + " font-mono"} value={salePrice} onChange={(e) => setSalePrice(e.target.value)} />
            </label>
          )}
          {error && <p className="text-sm text-red-600">{error}</p>}
          <button className={primaryBtn} disabled={busy || !name.trim()} onClick={submit}>
            {busy ? "Adding…" : `Add ${name.trim() || "product"}`}
          </button>
        </div>
      )}
    </Modal>
  );
}
