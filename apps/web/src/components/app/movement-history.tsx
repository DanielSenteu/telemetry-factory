"use client";

import { useCallback, useEffect, useState } from "react";
import { field } from "@/components/app/modal";
import { listRecentMovements, listProducts, type Movement, type StockedProduct } from "@/lib/services/inventory";
import { formatNairobi } from "@/lib/services/machines-logic";

// History: why is this number what it is? Every stock figure is a sum of
// these events — append-only, each one traceable to what caused it. Same
// visual language as the live feed on the marketing site: time, dot, plain
// sentence.

const TYPE_META: Record<string, { dot: string; verb: string; sign: 1 | -1 }> = {
  purchase: { dot: "bg-[var(--accent)]", verb: "received", sign: 1 },
  production_output: { dot: "bg-[var(--accent)]", verb: "made", sign: 1 },
  regrind_return: { dot: "bg-[var(--accent)]", verb: "regrind returned", sign: 1 },
  sale: { dot: "bg-sky-500", verb: "sold", sign: -1 },
  production_consume: { dot: "bg-black/30", verb: "used by production", sign: -1 },
  wastage: { dot: "bg-amber-400", verb: "waste / rejects", sign: -1 },
  adjustment: { dot: "bg-black/30", verb: "adjustment", sign: 1 },
};

function fmtQty(q: number, uom: string) {
  const n = Math.abs(Number(q));
  if (uom === "g" && n >= 1000) return `${(n / 1000).toLocaleString(undefined, { maximumFractionDigits: 1 })} kg`;
  return `${n.toLocaleString()} ${uom}`;
}

export function MovementHistory({ orgId }: { orgId: number }) {
  const [rows, setRows] = useState<Movement[] | null>(null);
  const [products, setProducts] = useState<StockedProduct[]>([]);
  const [filter, setFilter] = useState("");
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [m, p] = await Promise.all([
        listRecentMovements(orgId, filter ? Number(filter) : undefined),
        products.length ? Promise.resolve(products) : listProducts(orgId),
      ]);
      setRows(m);
      if (!products.length) setProducts(p as StockedProduct[]);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
    // products intentionally not a dep — loaded once, reused
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orgId, filter]);

  useEffect(() => {
    let gone = false;
    Promise.resolve().then(() => { if (!gone) load(); });
    return () => { gone = true; };
  }, [load]);

  // Group by Kenyan day for scannability
  const groups: Array<{ day: string; items: Movement[] }> = [];
  for (const m of rows || []) {
    const day = formatNairobi(m.created_at, { weekday: "short", day: "numeric", month: "short" });
    const last = groups[groups.length - 1];
    if (last && last.day === day) last.items.push(m);
    else groups.push({ day, items: [m] });
  }

  return (
    <div className="flex flex-col gap-5 max-w-3xl">
      <div className="flex items-center gap-3 flex-wrap">
        <div>
          <h1 className="font-display text-2xl font-bold">Every movement</h1>
          <p className="mt-1 text-sm text-black/55">
            Stock is a sum of events, not a number someone typed. This is the full trail.
          </p>
        </div>
        <select className={field + " ml-auto w-auto max-w-56"} value={filter} onChange={(e) => setFilter(e.target.value)}>
          <option value="">All products</option>
          {products.map((p) => (
            <option key={p.id} value={p.id}>{p.name}</option>
          ))}
        </select>
      </div>

      {error && <div className="rounded-xl bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">{error}</div>}

      {rows === null ? (
        <div className="gloss rounded-2xl h-72 animate-pulse" />
      ) : rows.length === 0 ? (
        <div className="gloss rounded-2xl p-10 text-center">
          <h2 className="font-display text-lg font-bold">Nothing yet</h2>
          <p className="mt-2 text-sm text-black/55">Receive material, confirm a run, or record an event — it all lands here.</p>
        </div>
      ) : (
        <div className="flex flex-col gap-5">
          {groups.map((g) => (
            <div key={g.day} className="gloss rounded-2xl p-5">
              <div className="font-mono text-xs font-semibold tracking-widest text-black/40 pb-1">{g.day.toUpperCase()}</div>
              {g.items.map((m) => {
                const meta = TYPE_META[m.movement_type] ?? { dot: "bg-black/30", verb: m.movement_type, sign: 1 };
                const uom = m.products?.unit_of_measure ?? "";
                const positive = Number(m.quantity) > 0;
                return (
                  <div key={m.id} className="flex items-center gap-3.5 py-3 border-t border-black/5 first:border-t-0">
                    <span className="font-mono text-xs text-black/40 w-11 shrink-0">{formatNairobi(m.created_at)}</span>
                    <span className={`size-2.5 rounded-full shrink-0 ${meta.dot}`} />
                    <span className="text-sm min-w-0 flex-1 truncate">
                      <span className={`font-mono font-semibold ${positive ? "text-[var(--accent)]" : "text-black/70"}`}>
                        {positive ? "+" : "−"}{fmtQty(m.quantity, uom)}
                      </span>{" "}
                      <span className="font-medium">{m.products?.name ?? `#${m.product_id}`}</span>{" "}
                      <span className="text-black/50">— {meta.verb}</span>
                      {m.note && <span className="text-black/40"> · {m.note}</span>}
                    </span>
                    {m.unit_cost != null && Number(m.unit_cost) > 0 && (
                      <span className="font-mono text-xs text-black/40 shrink-0 hidden sm:inline">@ {Number(m.unit_cost).toFixed(2)}</span>
                    )}
                  </div>
                );
              })}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
