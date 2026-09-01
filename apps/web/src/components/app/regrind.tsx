"use client";

import { useCallback, useEffect, useState } from "react";
import { Modal, field, primaryBtn } from "@/components/app/modal";
import { convert, familyMembers, canonicalUnit } from "@/lib/services/units";
import { getRegrindBalances, postRegrindUse, type RegrindBalance } from "@/lib/services/inventory";

// The regrind pool: plastic that exists physically but isn't in a sack.
// Runners accumulate automatically; grinding them and loading them back is
// the one manual step, logged here.

// Amount in the material's OWN unit — no g/kg conversion. The regrind pool
// and raw-material stock share one unit per material, so the number posts 1:1.
function amt(v: number) {
  return Number(v).toLocaleString(undefined, { maximumFractionDigits: 2 });
}

export function Regrind({ orgId }: { orgId: number }) {
  const [rows, setRows] = useState<RegrindBalance[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [logging, setLogging] = useState(false);

  const load = useCallback(async () => {
    try {
      setRows(await getRegrindBalances(orgId));
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

  const available = (rows || []).filter((r) => Number(r.balance_g) > 0);

  return (
    <div className="flex flex-col gap-5">
      <div className="flex items-start gap-3 flex-wrap">
        <div>
          <h1 className="font-display text-2xl font-bold">Regrind pool</h1>
          <p className="mt-1 text-sm text-black/55 max-w-lg">
            Runner plastic recovered from every confirmed run. Ground it and loaded it back into a machine?
            Log it — the weight returns to raw material stock.
          </p>
        </div>
        <button
          onClick={() => setLogging(true)}
          disabled={available.length === 0}
          className="ml-auto h-11 px-4 rounded-lg bg-[var(--ink)] text-white text-sm font-semibold hover:bg-black transition-colors disabled:opacity-40"
        >
          Log regrind use
        </button>
      </div>

      {error && <div className="rounded-xl bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">{error}</div>}

      {rows === null ? (
        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
          {[0, 1].map((i) => (
            <div key={i} className="gloss rounded-2xl h-36 animate-pulse" />
          ))}
        </div>
      ) : rows.length === 0 ? (
        <div className="gloss rounded-2xl p-10 text-center">
          <h2 className="font-display text-lg font-bold">No regrind yet</h2>
          <p className="mt-2 text-sm text-black/55 max-w-md mx-auto">
            Runners land here automatically once production runs are confirmed and the product&apos;s recipe
            has its mould setup (runner weight per shot).
          </p>
        </div>
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
          {rows.map((r) => {
            const u = r.unit_of_measure;
            const empty = Number(r.balance_g) <= 0;
            return (
              <div key={r.material_product_id} className={`gloss rounded-2xl p-5 flex flex-col gap-3 ${empty ? "opacity-70" : ""}`}>
                <div className="flex items-center gap-2.5">
                  <span className={`inline-flex size-2.5 rounded-full ${empty ? "bg-black/25" : "bg-[var(--accent)]"}`} />
                  <span className="font-display font-bold tracking-tight truncate">{r.material_name}</span>
                  <span className={`ml-auto font-mono text-[11px] font-bold tracking-widest ${empty ? "text-black/40" : "text-[var(--accent)]"}`}>
                    {empty ? "EMPTY" : "AVAILABLE"}
                  </span>
                </div>
                <div className="flex items-baseline gap-2">
                  <span className="font-mono text-4xl font-semibold tabular-nums leading-none">{amt(Number(r.balance_g))}</span>
                  <span className="text-sm text-black/45">{u} in the pool</span>
                </div>
                <div className="flex flex-wrap gap-2 text-xs font-mono text-black/55">
                  <span className="rounded-lg bg-black/[0.045] px-2.5 py-1.5">
                    {amt(Number(r.total_in_g))} {u} recovered
                  </span>
                  <span className="rounded-lg bg-black/[0.045] px-2.5 py-1.5">
                    {amt(Number(r.total_out_g))} {u} returned
                  </span>
                </div>
              </div>
            );
          })}
        </div>
      )}

      {logging && (
        <LogUseDialog orgId={orgId} balances={available} onClose={() => setLogging(false)} onDone={load} />
      )}
    </div>
  );
}

function LogUseDialog({
  orgId,
  balances,
  onClose,
  onDone,
}: {
  orgId: number;
  balances: RegrindBalance[];
  onClose: () => void;
  onDone: () => void;
}) {
  const [materialId, setMaterialId] = useState(balances.length === 1 ? String(balances[0].material_product_id) : "");
  const [qty, setQty] = useState("");
  const [entryUnit, setEntryUnit] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const selected = balances.find((b) => String(b.material_product_id) === materialId);
  const matUnit = selected?.unit_of_measure ?? "";
  const members = familyMembers(matUnit);
  // Typed in any family member; posted in the material's own unit.
  const q = (() => {
    const typed = Number(qty) || 0;
    if (!typed || !entryUnit || entryUnit === matUnit) return typed;
    try { return convert(typed, entryUnit, matUnit); } catch { return typed; }
  })();
  const over = selected && q > Number(selected.balance_g);

  const submit = async () => {
    if (!materialId || q <= 0) return;
    setBusy(true);
    setError(null);
    try {
      await postRegrindUse(orgId, Number(materialId), q, note || null);
      onDone();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal open onClose={onClose} title="Log regrind use">
      <div className="flex flex-col gap-4">
        <p className="text-sm text-black/55">
          The amount you log leaves the pool and returns to raw material stock — ready for recipes to consume.
        </p>
        <label className="flex flex-col gap-1.5">
          <span className="text-sm font-medium text-black/70">Material</span>
          <select className={field} value={materialId} onChange={(e) => { setMaterialId(e.target.value); setEntryUnit(""); }}>
            <option value="">Choose…</option>
            {balances.map((b) => (
              <option key={b.material_product_id} value={b.material_product_id}>
                {b.material_name} — {amt(Number(b.balance_g))} {b.unit_of_measure} available
              </option>
            ))}
          </select>
        </label>
        <div className="flex items-end gap-3">
          <label className="flex flex-col gap-1.5 flex-1">
            <span className="text-sm font-medium text-black/70">Amount loaded back</span>
            <input type="number" inputMode="decimal" className={field + " font-mono"} value={qty} onChange={(e) => setQty(e.target.value)} />
          </label>
          {members.length > 1 ? (
            <label className="flex flex-col gap-1.5 w-40">
              <span className="text-sm font-medium text-black/70">In</span>
              <select className={field} value={entryUnit || canonicalUnit(matUnit) || matUnit} onChange={(e) => setEntryUnit(e.target.value)}>
                {members.map((u) => (
                  <option key={u.value} value={u.value}>{u.label}</option>
                ))}
              </select>
            </label>
          ) : (
            selected && <span className="text-sm text-black/50 pb-3.5">{matUnit}</span>
          )}
        </div>
        {entryUnit && selected && entryUnit !== matUnit && q > 0 && (
          <span className="text-xs font-mono text-black/45 -mt-2">= {q.toLocaleString(undefined, { maximumFractionDigits: 2 })} {matUnit}</span>
        )}
        {over && (
          <p className="text-sm text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2">
            That&apos;s more than the pool holds — allowed if the scale says so, but double-check the number.
          </p>
        )}
        <label className="flex flex-col gap-1.5">
          <span className="text-sm font-medium text-black/70">Note (optional)</span>
          <input className={field} value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. ground Friday's runners" />
        </label>
        {error && <p className="text-sm text-red-600">{error}</p>}
        <button className={primaryBtn} disabled={busy || !materialId || q <= 0} onClick={submit}>
          {busy ? "Logging…" : selected && q > 0 ? `Return ${amt(q)} ${selected.unit_of_measure} to stock` : "Return to stock"}
        </button>
      </div>
    </Modal>
  );
}
