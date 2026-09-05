"use client";

import { useEffect, useState } from "react";
import { Modal, field, primaryBtn } from "@/components/app/modal";
import { UnitSelect } from "@/components/app/unit-select";
import {
  updateProduct,
  archiveProduct,
  deleteProduct,
  countMovements,
  getProductLinks,
  adjustStockManual,
  type StockedProduct,
} from "@/lib/services/inventory";

// Manage a material/product: edit its details, add or remove stock by hand,
// and remove it safely — hard delete only when it has no ledger history,
// otherwise archive (keeps the history).
type Tab = "stock" | "edit" | "remove";

export function ProductManageDialog({
  orgId,
  product,
  onClose,
  onDone,
}: {
  orgId: number;
  product: StockedProduct;
  onClose: () => void;
  onDone: () => void;
}) {
  const [tab, setTab] = useState<Tab>("stock");

  return (
    <Modal open onClose={onClose} title={product.name}>
      <div className="flex gap-1 mb-4 -mt-1">
        {(["stock", "edit", "remove"] as const).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`px-3 py-2 rounded-lg text-sm font-semibold transition-colors ${
              tab === t ? "bg-black/85 text-white" : "text-black/55 hover:bg-black/5"
            }`}
          >
            {t === "stock" ? "Adjust stock" : t === "edit" ? "Edit" : "Remove"}
          </button>
        ))}
      </div>
      {tab === "stock" && <AdjustStock orgId={orgId} product={product} onDone={onDone} onClose={onClose} />}
      {tab === "edit" && <EditFields product={product} onDone={onDone} onClose={onClose} />}
      {tab === "remove" && <Remove orgId={orgId} product={product} onDone={onDone} onClose={onClose} />}
    </Modal>
  );
}

function AdjustStock({ orgId, product, onDone, onClose }: { orgId: number; product: StockedProduct; onDone: () => void; onClose: () => void }) {
  const [dir, setDir] = useState<"add" | "remove">("add");
  const [qty, setQty] = useState("");
  const [cost, setCost] = useState(product.avg_unit_cost ? String(product.avg_unit_cost) : "");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const uom = product.unit_of_measure;

  const submit = async () => {
    const n = Number(qty);
    if (!n || n <= 0) return;
    setBusy(true);
    setError(null);
    try {
      await adjustStockManual(orgId, product.id, dir === "add" ? n : -n, {
        unitCost: dir === "add" && cost ? Number(cost) : null,
        note: note || (dir === "add" ? "Manual stock added" : "Manual stock removed"),
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
    <div className="flex flex-col gap-4">
      <p className="text-sm text-black/55">
        On hand now: <span className="font-mono font-semibold">{Number(product.on_hand).toLocaleString()} {uom}</span>.
        Use this for opening stock, a stock-take correction, or material added by hand.
      </p>
      <div className="flex gap-2">
        {(["add", "remove"] as const).map((d) => (
          <button
            key={d}
            onClick={() => setDir(d)}
            className={`flex-1 h-11 rounded-lg text-sm font-semibold transition-colors ${
              dir === d ? (d === "add" ? "bg-[var(--accent)] text-white" : "bg-red-500 text-white") : "border border-black/10 text-black/60"
            }`}
          >
            {d === "add" ? "Add stock" : "Remove stock"}
          </button>
        ))}
      </div>
      <label className="flex flex-col gap-1.5">
        <span className="text-sm font-medium text-black/70">Quantity ({uom})</span>
        <input type="number" inputMode="decimal" className={field + " font-mono"} value={qty} onChange={(e) => setQty(e.target.value)} />
      </label>
      {dir === "add" && (
        <label className="flex flex-col gap-1.5">
          <span className="text-sm font-medium text-black/70">Cost per {uom} (KES, optional)</span>
          <input type="number" inputMode="decimal" className={field + " font-mono"} value={cost} onChange={(e) => setCost(e.target.value)} placeholder="keeps average cost accurate" />
        </label>
      )}
      <label className="flex flex-col gap-1.5">
        <span className="text-sm font-medium text-black/70">Reason (optional)</span>
        <input className={field} value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. opening stock, stock-take" />
      </label>
      {error && <p className="text-sm text-red-600">{error}</p>}
      <button className={primaryBtn} disabled={busy || !Number(qty)} onClick={submit}>
        {busy ? "Saving…" : dir === "add" ? `Add ${Number(qty || 0).toLocaleString()} ${uom}` : `Remove ${Number(qty || 0).toLocaleString()} ${uom}`}
      </button>
    </div>
  );
}

function EditFields({ product, onDone, onClose }: { product: StockedProduct; onDone: () => void; onClose: () => void }) {
  const [name, setName] = useState(product.name);
  const [uom, setUom] = useState(product.unit_of_measure);
  const [price, setPrice] = useState(product.sale_price != null ? String(product.sale_price) : "");
  const [reorder, setReorder] = useState(product.reorder_point != null ? String(product.reorder_point) : "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    if (!name.trim()) return;
    setBusy(true);
    setError(null);
    try {
      await updateProduct(product.id, {
        name: name.trim(),
        unit_of_measure: uom || "each",
        sale_price: product.kind === "finished_good" && price ? Number(price) : null,
        reorder_point: reorder ? Number(reorder) : null,
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
    <div className="flex flex-col gap-4">
      <label className="flex flex-col gap-1.5">
        <span className="text-sm font-medium text-black/70">Name</span>
        <input className={field} value={name} onChange={(e) => setName(e.target.value)} />
      </label>
      <label className="flex flex-col gap-1.5">
        <span className="text-sm font-medium text-black/70">Counted in</span>
        <UnitSelect value={uom} onChange={setUom} />
      </label>
      <label className="flex flex-col gap-1.5">
        <span className="text-sm font-medium text-black/70">Low-stock warning at ({product.unit_of_measure}, optional)</span>
        <input type="number" inputMode="decimal" className={field + " font-mono"} value={reorder} onChange={(e) => setReorder(e.target.value)} />
      </label>
      {product.kind === "finished_good" && (
        <label className="flex flex-col gap-1.5">
          <span className="text-sm font-medium text-black/70">Sale price (KES, optional)</span>
          <input type="number" inputMode="decimal" className={field + " font-mono"} value={price} onChange={(e) => setPrice(e.target.value)} />
        </label>
      )}
      {error && <p className="text-sm text-red-600">{error}</p>}
      <button className={primaryBtn} disabled={busy || !name.trim()} onClick={submit}>
        {busy ? "Saving…" : "Save changes"}
      </button>
    </div>
  );
}

function Remove({ orgId, product, onDone, onClose }: { orgId: number; product: StockedProduct; onDone: () => void; onClose: () => void }) {
  const [moves, setMoves] = useState<number | null>(null);
  const [links, setLinks] = useState<string[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let gone = false;
    countMovements(product.id).then((n) => !gone && setMoves(n)).catch(() => !gone && setMoves(0));
    getProductLinks(orgId, product.id).then((l) => !gone && setLinks(l)).catch(() => !gone && setLinks([]));
    return () => { gone = true; };
  }, [orgId, product.id]);

  const hasHistory = (moves ?? 0) > 0;
  const hasLinks = (links?.length ?? 0) > 0;
  const canHardDelete = !hasHistory && !hasLinks;

  const run = async () => {
    setBusy(true);
    setError(null);
    try {
      if (canHardDelete) await deleteProduct(product.id);
      else await archiveProduct(product.id);
      onDone();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  if (moves === null || links === null) return <div className="h-24 rounded-lg bg-black/5 animate-pulse" />;

  return (
    <div className="flex flex-col gap-4">
      {hasLinks && (
        <div className="rounded-xl bg-amber-50 border border-amber-200 px-4 py-3 text-sm text-amber-800 flex flex-col gap-1.5">
          <span className="font-semibold">Other things still point at this product:</span>
          <ul className="list-disc pl-5 flex flex-col gap-0.5">
            {links!.map((l, i) => (
              <li key={i}>{l}</li>
            ))}
          </ul>
          <span>
            So it can&apos;t be deleted outright — it will be <span className="font-semibold">archived</span> instead:
            hidden from your lists, with everything that references it staying consistent. To truly delete it,
            remove those links first.
          </span>
        </div>
      )}
      {!hasLinks && hasHistory && (
        <p className="text-sm text-black/60">
          This material has <span className="font-semibold">{moves} movement{moves === 1 ? "" : "s"}</span> of history.
          It will be <span className="font-semibold">archived</span> — hidden from your lists, but its ledger is kept so past
          numbers stay correct. It never really disappears.
        </p>
      )}
      {canHardDelete && (
        <p className="text-sm text-black/60">
          This material has no stock history and nothing points at it, so it will be{" "}
          <span className="font-semibold">deleted permanently</span>. Nothing is lost.
        </p>
      )}
      {error && <p className="text-sm text-red-600">{error}</p>}
      <button
        onClick={run}
        disabled={busy}
        className={`h-12 rounded-lg font-medium text-white transition-colors disabled:opacity-60 ${canHardDelete ? "bg-red-500 hover:bg-red-600" : "bg-black/85 hover:bg-black"}`}
      >
        {busy ? "…" : canHardDelete ? "Delete permanently" : "Archive material"}
      </button>
    </div>
  );
}
