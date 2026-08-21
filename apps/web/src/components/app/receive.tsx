"use client";

import { useCallback, useRef, useState } from "react";
import { field, primaryBtn } from "@/components/app/modal";
import {
  uploadAndExtract,
  confirmInvoice,
  listProductAliases,
  type ExtractedInvoice,
} from "@/lib/services/invoices";
import { listProducts, createProduct, type StockedProduct } from "@/lib/services/inventory";

// Receive: photograph the supplier invoice, the AI reads it, you check it,
// stock goes up at what it actually cost. The alias memory means a supplier's
// wording maps itself after the first time.

type ReviewLine = {
  key: number;
  description: string;
  quantity: number;
  unit_price: number;
  total_price: number;
  product_id: number | "" | "new";
  auto: boolean;
};

const norm = (s: string | null | undefined) => (s || "").trim().toLowerCase();

export function Receive({ orgId }: { orgId: number }) {
  const [stage, setStage] = useState<"idle" | "reading" | "review" | "done">("idle");
  const [error, setError] = useState<string | null>(null);
  const [invoice, setInvoice] = useState<ExtractedInvoice | null>(null);
  const [lines, setLines] = useState<ReviewLine[]>([]);
  const [products, setProducts] = useState<StockedProduct[]>([]);
  const [busy, setBusy] = useState(false);
  const [stockedCount, setStockedCount] = useState(0);
  const fileRef = useRef<HTMLInputElement>(null);

  const startExtract = useCallback(
    async (file: File) => {
      setStage("reading");
      setError(null);
      try {
        const [extracted, prods, aliases] = await Promise.all([
          uploadAndExtract(orgId, file),
          listProducts(orgId),
          listProductAliases(orgId),
        ]);
        setProducts(prods);

        // Alias memory: vendor+text first, plain text second — v1's exact order.
        const byVendorText = new Map<string, number>();
        const byText = new Map<string, number>();
        for (const a of aliases) {
          byVendorText.set(`${norm(a.vendor_name)}||${norm(a.raw_text)}`, a.product_id);
          if (!byText.has(norm(a.raw_text))) byText.set(norm(a.raw_text), a.product_id);
        }
        const vendor = norm(extracted.vendor_name);
        setInvoice(extracted);
        setLines(
          extracted.line_items.map((l, i) => {
            const pid = byVendorText.get(`${vendor}||${norm(l.description)}`) ?? byText.get(norm(l.description));
            return { key: i, ...l, product_id: pid ?? "", auto: pid != null };
          }),
        );
        setStage("review");
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
        setStage("idle");
      }
    },
    [orgId],
  );

  const confirm = async () => {
    if (!invoice) return;
    setBusy(true);
    setError(null);
    try {
      const items = lines.map((l) => ({
        description: l.description,
        quantity: l.quantity,
        unit_price: l.unit_price,
        total_price: l.total_price,
        product_id: typeof l.product_id === "number" ? l.product_id : null,
      }));
      await confirmInvoice(orgId, invoice, items);
      setStockedCount(items.filter((i) => i.product_id != null).length);
      setStage("done");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const reset = () => {
    setStage("idle");
    setInvoice(null);
    setLines([]);
    setError(null);
  };

  if (stage === "idle" || stage === "reading") {
    return (
      <div className="max-w-xl flex flex-col gap-4">
        <div>
          <h1 className="font-display text-2xl font-bold">Receive material</h1>
          <p className="mt-1 text-sm text-black/55">
            Photograph the supplier invoice — we read it, you check it, stock goes up at what it actually cost.
          </p>
        </div>
        <button
          onClick={() => fileRef.current?.click()}
          disabled={stage === "reading"}
          className="gloss rounded-2xl p-10 text-center hover:ring-1 hover:ring-black/15 transition-shadow disabled:opacity-70"
        >
          {stage === "reading" ? (
            <div className="flex flex-col items-center gap-3">
              <span className="relative flex size-3">
                <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-[var(--accent)] opacity-60" />
                <span className="relative inline-flex size-3 rounded-full bg-[var(--accent)]" />
              </span>
              <span className="font-mono text-sm text-black/60">reading the invoice…</span>
              <span className="text-xs text-black/40">usually 10–20 seconds</span>
            </div>
          ) : (
            <div className="flex flex-col items-center gap-2">
              <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" className="text-black/40">
                <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z" />
                <circle cx="12" cy="13" r="4" />
              </svg>
              <span className="font-semibold">Photograph or upload the invoice</span>
              <span className="text-sm text-black/45">photo or PDF</span>
            </div>
          )}
        </button>
        <input
          ref={fileRef}
          type="file"
          accept="image/*,application/pdf"
          capture="environment"
          className="hidden"
          onChange={(e) => {
            const f = e.target.files?.[0];
            if (f) startExtract(f);
            e.target.value = "";
          }}
        />
        {error && <div className="rounded-xl bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">{error}</div>}
      </div>
    );
  }

  if (stage === "done") {
    return (
      <div className="max-w-xl flex flex-col gap-4">
        <div className="gloss rounded-2xl p-8 text-center flex flex-col items-center gap-3">
          <span className="size-12 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] flex items-center justify-center">
            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"><path d="M20 6L9 17l-5-5" /></svg>
          </span>
          <h2 className="font-display text-xl font-bold">Stock updated</h2>
          <p className="text-sm text-black/55">
            {stockedCount > 0
              ? `${stockedCount} line${stockedCount === 1 ? "" : "s"} added to stock at invoice cost. The rest were recorded without stock.`
              : "Invoice recorded. No lines were linked to materials, so stock is unchanged."}
          </p>
          <button onClick={reset} className="mt-2 h-12 px-6 rounded-lg bg-[var(--ink)] text-white font-medium hover:bg-black transition-colors">
            Receive another
          </button>
        </div>
      </div>
    );
  }

  // review
  return (
    <div className="max-w-2xl flex flex-col gap-4">
      <div>
        <h1 className="font-display text-2xl font-bold">Check what we read</h1>
        <p className="mt-1 text-sm text-black/55">Fix anything the camera got wrong, link each line to a material, then confirm.</p>
      </div>

      <div className="gloss rounded-2xl p-6 grid grid-cols-2 gap-4">
        {(
          [
            ["Supplier", "vendor_name", "text"],
            ["Invoice number", "invoice_number", "text"],
            ["Date", "invoice_date", "date"],
            ["Total (KES)", "total_amount", "number"],
          ] as const
        ).map(([label, key, type]) => (
          <label key={key} className="flex flex-col gap-1.5">
            <span className="text-sm font-medium text-black/70">{label}</span>
            <input
              type={type}
              className={field + (type === "number" ? " font-mono" : "")}
              value={invoice?.[key] ?? ""}
              onChange={(e) =>
                setInvoice((inv) => inv && { ...inv, [key]: type === "number" ? Number(e.target.value) : e.target.value })
              }
            />
          </label>
        ))}
      </div>

      <div className="flex flex-col gap-3">
        {lines.map((l, idx) => (
          <ReviewLineCard
            key={l.key}
            line={l}
            products={products}
            orgId={orgId}
            onChange={(nl) => setLines((ls) => ls.map((x, i) => (i === idx ? nl : x)))}
            onProductCreated={(p) => setProducts((ps) => [...ps, p])}
          />
        ))}
      </div>

      {error && <div className="rounded-xl bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">{error}</div>}

      <div className="flex gap-3">
        <button onClick={reset} className="h-12 px-5 rounded-lg border border-black/15 font-medium hover:bg-black/[0.04] transition-colors">
          Start over
        </button>
        <button onClick={confirm} disabled={busy} className={primaryBtn + " flex-1"}>
          {busy
            ? "Confirming…"
            : `Confirm — ${lines.filter((l) => typeof l.product_id === "number").length} of ${lines.length} lines to stock`}
        </button>
      </div>
    </div>
  );
}

function ReviewLineCard({
  line,
  products,
  orgId,
  onChange,
  onProductCreated,
}: {
  line: ReviewLine;
  products: StockedProduct[];
  orgId: number;
  onChange: (l: ReviewLine) => void;
  onProductCreated: (p: StockedProduct) => void;
}) {
  const [creating, setCreating] = useState(false);
  const [newName, setNewName] = useState("");
  const [newUom, setNewUom] = useState("g");
  const [busy, setBusy] = useState(false);

  const create = async () => {
    setBusy(true);
    try {
      const p = await createProduct(orgId, { name: newName.trim(), kind: "raw_material", unit_of_measure: newUom || "g" });
      onProductCreated({ ...p, on_hand: 0, avg_unit_cost: 0, stock_value: 0 });
      onChange({ ...line, product_id: p.id, auto: false });
      setCreating(false);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="gloss rounded-2xl p-5 flex flex-col gap-3">
      <div className="flex items-baseline gap-3">
        <span className="font-medium flex-1">{line.description || <em className="text-black/40">unnamed line</em>}</span>
        <span className="font-mono text-sm text-black/55 tabular-nums">
          {line.quantity.toLocaleString()} × {line.unit_price.toLocaleString()} ={" "}
          <span className="font-semibold text-black/80">{line.total_price.toLocaleString()}</span>
        </span>
      </div>
      {!creating ? (
        <div className="flex items-center gap-2">
          <select
            className={field + " flex-1"}
            value={typeof line.product_id === "number" ? line.product_id : ""}
            onChange={(e) => {
              const v = e.target.value;
              if (v === "new") {
                setNewName(line.description);
                setCreating(true);
                onChange({ ...line, product_id: "", auto: false });
                return;
              }
              onChange({ ...line, product_id: v === "" ? "" : Number(v), auto: false });
            }}
          >
            <option value="">Record only — not a stocked material</option>
            {products
              .filter((p) => p.kind !== "finished_good")
              .map((p) => (
                <option key={p.id} value={p.id}>{p.name}</option>
              ))}
            <option value="new">＋ New material…</option>
          </select>
          {line.auto && typeof line.product_id === "number" && (
            <span className="font-mono text-[11px] font-semibold text-[var(--accent)] bg-[var(--accent-soft)] rounded px-2 py-1">
              remembered
            </span>
          )}
        </div>
      ) : (
        <div className="flex flex-wrap items-end gap-2">
          <label className="flex flex-col gap-1 flex-1 min-w-44">
            <span className="text-xs font-medium text-black/60">New material name</span>
            <input className={field} value={newName} onChange={(e) => setNewName(e.target.value)} />
          </label>
          <label className="flex flex-col gap-1 w-24">
            <span className="text-xs font-medium text-black/60">Unit</span>
            <input className={field} value={newUom} onChange={(e) => setNewUom(e.target.value)} />
          </label>
          <button onClick={create} disabled={busy || !newName.trim()} className="h-12 px-4 rounded-lg bg-[var(--ink)] text-white text-sm font-medium disabled:opacity-50">
            {busy ? "…" : "Create"}
          </button>
          <button onClick={() => { setCreating(false); onChange({ ...line, product_id: "" }); }} className="h-12 px-3 rounded-lg text-sm text-black/50 hover:bg-black/5">
            Cancel
          </button>
        </div>
      )}
    </div>
  );
}
