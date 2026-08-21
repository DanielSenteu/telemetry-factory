"use client";

import { useEffect, useState } from "react";
import { Modal, field, primaryBtn } from "@/components/app/modal";
import {
  confirmMachineOutput,
  postManualStockAdjustment,
  listFinishedGoods,
  type Product,
} from "@/lib/services/production";
import { mapMachineCraft, type MachineRow } from "@/lib/services/machines";

// ── Confirm today's output ────────────────────────────
// Prefilled from what the machine itself counted; the human confirms reality.
export function ConfirmOutputDialog({
  orgId,
  machine,
  productId,
  suggestedGood,
  suggestedScrap,
  open,
  onClose,
  onDone,
}: {
  orgId: number;
  machine: MachineRow;
  productId: number | null;
  suggestedGood: number;
  suggestedScrap: number;
  open: boolean;
  onClose: () => void;
  onDone: () => void;
}) {
  const [good, setGood] = useState(String(suggestedGood));
  const [scrap, setScrap] = useState(String(suggestedScrap));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    if (!productId) return;
    setBusy(true);
    setError(null);
    try {
      await confirmMachineOutput(orgId, machine.machine_id, productId, Number(good) || 0, Number(scrap) || 0);
      onDone();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal open={open} onClose={onClose} title={`Confirm output — ${machine.name}`}>
      {!productId ? (
        <p className="text-sm text-black/60">
          This machine&apos;s job isn&apos;t linked to a product yet — link it first (tap the
          <span className="mx-1 font-mono text-[11px] font-semibold text-amber-700 bg-amber-100 rounded px-1.5 py-0.5">unmapped</span>
          badge on the card), then confirm.
        </p>
      ) : (
        <div className="flex flex-col gap-4">
          <p className="text-sm text-black/55">
            Counted by the machine today — adjust if reality differed, then confirm. This adds the
            finished goods to stock and deducts material by the recipe.
          </p>
          <label className="flex flex-col gap-1.5">
            <span className="text-sm font-medium text-black/70">Good parts</span>
            <input type="number" inputMode="numeric" className={field + " font-mono"} value={good} onChange={(e) => setGood(e.target.value)} />
          </label>
          <label className="flex flex-col gap-1.5">
            <span className="text-sm font-medium text-black/70">Scrap</span>
            <input type="number" inputMode="numeric" className={field + " font-mono"} value={scrap} onChange={(e) => setScrap(e.target.value)} />
          </label>
          {error && <p className="text-sm text-red-600">{error}</p>}
          <button className={primaryBtn} disabled={busy} onClick={submit}>
            {busy ? "Confirming…" : `Confirm ${Number(good).toLocaleString()} good parts`}
          </button>
          <p className="text-xs text-black/40 text-center">
            Already confirmed today for this machine? Confirming again is safe — it won&apos;t double-count.
          </p>
        </div>
      )}
    </Modal>
  );
}

// ── Record an event (the three overrides) ─────────────
const EVENTS = [
  { key: "power_outage", label: "Untracked production", hint: "Made during a power cut or offline run — adds stock, uses material by the recipe", sign: 1 },
  { key: "waste", label: "Waste", hint: "Broken or spoiled at end of day — removes stock", sign: -1 },
  { key: "rejects", label: "Rejects", hint: "Failed parts — removes stock; plastic can go to the regrind pool", sign: -1 },
] as const;

export function RecordEventDialog({
  orgId,
  open,
  onClose,
  onDone,
}: {
  orgId: number;
  open: boolean;
  onClose: () => void;
  onDone: () => void;
}) {
  const [products, setProducts] = useState<Product[]>([]);
  const [kind, setKind] = useState<(typeof EVENTS)[number]["key"] | null>(null);
  const [productId, setProductId] = useState("");
  const [qty, setQty] = useState("");
  const [toRegrind, setToRegrind] = useState(true);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    listFinishedGoods(orgId).then(setProducts).catch(() => setProducts([]));
  }, [open, orgId]);

  const ev = EVENTS.find((e) => e.key === kind);
  const submit = async () => {
    if (!ev || !productId || !Number(qty)) return;
    setBusy(true);
    setError(null);
    try {
      await postManualStockAdjustment(orgId, Number(productId), ev.sign * Math.abs(Number(qty)), ev.key, {
        routeToRegrind: ev.key === "rejects" && toRegrind,
        note: note || null,
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
    <Modal open={open} onClose={onClose} title="Record an event">
      {!kind ? (
        <div className="flex flex-col gap-3">
          {EVENTS.map((e) => (
            <button
              key={e.key}
              onClick={() => setKind(e.key)}
              className="gloss rounded-xl p-4 text-left hover:ring-1 hover:ring-black/15 transition-shadow"
            >
              <div className="font-semibold">{e.label}</div>
              <div className="text-sm text-black/55 mt-0.5">{e.hint}</div>
            </button>
          ))}
        </div>
      ) : (
        <div className="flex flex-col gap-4">
          <button onClick={() => setKind(null)} className="text-sm text-black/50 hover:text-black text-left">
            ← {ev!.label}
          </button>
          <label className="flex flex-col gap-1.5">
            <span className="text-sm font-medium text-black/70">Product</span>
            <select className={field} value={productId} onChange={(e) => setProductId(e.target.value)}>
              <option value="">Choose…</option>
              {products.map((p) => (
                <option key={p.id} value={p.id}>{p.name}</option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-1.5">
            <span className="text-sm font-medium text-black/70">How many units?</span>
            <input type="number" inputMode="numeric" className={field + " font-mono"} value={qty} onChange={(e) => setQty(e.target.value)} />
          </label>
          {kind === "rejects" && (
            <label className="flex items-center gap-3 py-1">
              <input type="checkbox" className="size-5" checked={toRegrind} onChange={(e) => setToRegrind(e.target.checked)} />
              <span className="text-sm text-black/70">Send the plastic to the regrind pool</span>
            </label>
          )}
          <label className="flex flex-col gap-1.5">
            <span className="text-sm font-medium text-black/70">Note (optional)</span>
            <input className={field} value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. outage 14:00–16:00" />
          </label>
          {error && <p className="text-sm text-red-600">{error}</p>}
          <button className={primaryBtn} disabled={busy || !productId || !Number(qty)} onClick={submit}>
            {busy
              ? "Recording…"
              : ev!.sign > 0
                ? `Add ${Number(qty || 0).toLocaleString()} to stock`
                : `Remove ${Number(qty || 0).toLocaleString()} from stock`}
          </button>
        </div>
      )}
    </Modal>
  );
}

// ── Link a job to a product ───────────────────────────
export function MapCraftDialog({
  orgId,
  machine,
  open,
  onClose,
  onDone,
}: {
  orgId: number;
  machine: MachineRow | null;
  open: boolean;
  onClose: () => void;
  onDone: () => void;
}) {
  const [products, setProducts] = useState<Product[]>([]);
  const [productId, setProductId] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    listFinishedGoods(orgId).then(setProducts).catch(() => setProducts([]));
  }, [open, orgId]);

  const submit = async () => {
    if (!machine?.craft_id || !productId) return;
    setBusy(true);
    setError(null);
    try {
      await mapMachineCraft(orgId, machine.machine_id, machine.craft_id, Number(productId));
      onDone();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal open={open} onClose={onClose} title={`What is ${machine?.name ?? ""} making?`}>
      <div className="flex flex-col gap-4">
        <p className="text-sm text-black/55">
          The machine calls this job <span className="font-mono font-semibold">{machine?.craft_id}</span>. Tell us
          which product that is — once linked, it&apos;s remembered forever.
        </p>
        <select className={field} value={productId} onChange={(e) => setProductId(e.target.value)}>
          <option value="">Choose a product…</option>
          {products.map((p) => (
            <option key={p.id} value={p.id}>{p.name}</option>
          ))}
        </select>
        {error && <p className="text-sm text-red-600">{error}</p>}
        <button className={primaryBtn} disabled={busy || !productId} onClick={submit}>
          {busy ? "Linking…" : "Link product"}
        </button>
      </div>
    </Modal>
  );
}
