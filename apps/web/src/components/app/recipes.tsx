"use client";

import { useCallback, useEffect, useState } from "react";
import { field } from "@/components/app/modal";
import {
  listFinishedGoods,
  listRawMaterials,
  getBOMForProduct,
  upsertBOMLine,
  deleteBOMLine,
  updateBOMShotParams,
  type Bom,
  type Product,
} from "@/lib/services/production";

// Recipes: what one unit is made of. This is what makes production deduct
// material automatically — the single most valuable minute of setup a factory
// does in this product.
export function Recipes({ orgId }: { orgId: number }) {
  const [products, setProducts] = useState<Product[]>([]);
  const [materials, setMaterials] = useState<Product[]>([]);
  const [productId, setProductId] = useState<number | null>(null);
  const [bom, setBom] = useState<Bom | null>(null);
  const [loadingBom, setLoadingBom] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // add-line form
  const [componentId, setComponentId] = useState("");
  const [qty, setQty] = useState("");
  // shot params form
  const [cavities, setCavities] = useState("");
  const [runnerG, setRunnerG] = useState("");
  const [runnerMat, setRunnerMat] = useState("");
  const [saving, setSaving] = useState<null | "line" | "shot">(null);

  useEffect(() => {
    let gone = false;
    Promise.all([listFinishedGoods(orgId), listRawMaterials(orgId)])
      .then(([fg, rm]) => {
        if (gone) return;
        setProducts(fg);
        setMaterials(rm);
      })
      .catch((e) => !gone && setError(e.message));
    return () => {
      gone = true;
    };
  }, [orgId]);

  const loadBom = useCallback(
    async (pid: number) => {
      setLoadingBom(true);
      setError(null);
      try {
        const b = await getBOMForProduct(orgId, pid);
        setBom(b);
        setCavities(b?.cavities != null ? String(b.cavities) : "");
        setRunnerG(b?.runner_weight_g != null ? String(b.runner_weight_g) : "");
        setRunnerMat(b?.runner_material_product_id != null ? String(b.runner_material_product_id) : "");
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      } finally {
        setLoadingBom(false);
      }
    },
    [orgId],
  );

  const pick = (pid: number) => {
    setProductId(pid);
    setBom(null);
    setComponentId("");
    setQty("");
    loadBom(pid);
  };

  const addLine = async () => {
    if (!productId || !componentId || !Number(qty)) return;
    setSaving("line");
    setError(null);
    try {
      const selectedMat = materials.find((m) => m.id === Number(componentId));
      const uom = selectedMat?.unit_of_measure || "unit";
      await upsertBOMLine(orgId, productId, Number(componentId), Number(qty), uom);
      setComponentId("");
      setQty("");
      await loadBom(productId);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(null);
    }
  };

  const removeLine = async (lineId: number) => {
    if (!productId) return;
    setError(null);
    try {
      await deleteBOMLine(lineId);
      await loadBom(productId);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const saveShot = async () => {
    if (!productId) return;
    setSaving("shot");
    setError(null);
    try {
      await updateBOMShotParams(
        orgId,
        productId,
        cavities ? Number(cavities) : null,
        runnerG ? Number(runnerG) : null,
        runnerMat ? Number(runnerMat) : null,
      );
      await loadBom(productId);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(null);
    }
  };

  const selected = products.find((p) => p.id === productId);

  return (
    <div className="flex flex-col gap-5 max-w-3xl">
      <div>
        <h1 className="font-display text-2xl font-bold">Recipes</h1>
        <p className="mt-1 text-sm text-black/55">
          What one unit is made of. With a recipe, every confirmed run deducts material automatically — and
          runner plastic goes to the regrind pool.
        </p>
      </div>

      <label className="flex flex-col gap-1.5 max-w-sm">
        <span className="text-sm font-medium text-black/70">Product</span>
        <select className={field} value={productId ?? ""} onChange={(e) => e.target.value && pick(Number(e.target.value))}>
          <option value="">Choose a product…</option>
          {products.map((p) => (
            <option key={p.id} value={p.id}>{p.name}</option>
          ))}
        </select>
      </label>

      {error && <p className="text-sm text-red-600">{error}</p>}

      {productId && (
        <div className="flex flex-col gap-4">
          {/* Ingredients */}
          <div className="gloss rounded-2xl p-6">
            <h2 className="font-display text-lg font-bold">Per unit of {selected?.name}</h2>
            {loadingBom ? (
              <div className="mt-4 h-12 rounded-lg bg-black/5 animate-pulse" />
            ) : !bom || bom.lines.length === 0 ? (
              <p className="mt-3 text-sm text-black/55">
                No recipe yet. Add what one unit is made of below — for moulded parts that&apos;s usually just
                the plastic, in grams.
              </p>
            ) : (
              <div className="mt-3 flex flex-col">
                {bom.lines.map((l) => (
                  <div key={l.id} className="flex items-center gap-3 py-3 border-t border-black/5 first:border-t-0">
                    <span className="font-medium flex-1">{l.component_name}</span>
                    <span className="font-mono font-semibold tabular-nums">
                      {Number(l.qty_per_unit).toLocaleString()} {l.uom}
                    </span>
                    <button
                      onClick={() => removeLine(l.id)}
                      className="size-10 rounded-lg text-black/35 hover:text-red-600 hover:bg-red-50 transition-colors"
                      aria-label={`Remove ${l.component_name}`}
                    >
                      ×
                    </button>
                  </div>
                ))}
              </div>
            )}

            <div className="mt-4 pt-4 border-t border-black/5 flex flex-wrap items-end gap-3">
              <label className="flex flex-col gap-1.5 flex-1 min-w-44">
                <span className="text-sm font-medium text-black/70">Material</span>
                <select className={field} value={componentId} onChange={(e) => setComponentId(e.target.value)}>
                  <option value="">Choose…</option>
                  {materials.map((m) => (
                    <option key={m.id} value={m.id}>{m.name}</option>
                  ))}
                </select>
              </label>
              <label className="flex flex-col gap-1.5 w-40">
                <span className="text-sm font-medium text-black/70">
                  {(materials.find((m) => m.id === Number(componentId))?.unit_of_measure || "Amount")} per unit
                </span>
                <input type="number" inputMode="decimal" className={field + " font-mono"} value={qty} onChange={(e) => setQty(e.target.value)} />
              </label>
              <button
                onClick={addLine}
                disabled={saving === "line" || !componentId || !Number(qty)}
                className="h-12 px-6 rounded-lg bg-[var(--ink)] text-white font-medium hover:bg-black transition-colors disabled:opacity-50"
              >
                {saving === "line" ? "Adding…" : "Add"}
              </button>
            </div>
          </div>

          {/* Shot setup */}
          <div className="gloss rounded-2xl p-6">
            <h2 className="font-display text-lg font-bold">Mould setup</h2>
            <p className="mt-1 text-sm text-black/55">
              Cavities turn machine shots into part counts. Runner weight is the sprue plastic recovered into
              the regrind pool on every shot.
            </p>
            <div className="mt-4 flex flex-wrap items-end gap-3">
              <label className="flex flex-col gap-1.5 w-28">
                <span className="text-sm font-medium text-black/70">Cavities</span>
                <input type="number" inputMode="numeric" className={field + " font-mono"} value={cavities} onChange={(e) => setCavities(e.target.value)} />
              </label>
              <label className="flex flex-col gap-1.5 w-36">
                <span className="text-sm font-medium text-black/70">Runner (g/shot)</span>
                <input type="number" inputMode="decimal" className={field + " font-mono"} value={runnerG} onChange={(e) => setRunnerG(e.target.value)} />
              </label>
              <label className="flex flex-col gap-1.5 flex-1 min-w-44">
                <span className="text-sm font-medium text-black/70">Runner material</span>
                <select className={field} value={runnerMat} onChange={(e) => setRunnerMat(e.target.value)}>
                  <option value="">Choose…</option>
                  {materials.map((m) => (
                    <option key={m.id} value={m.id}>{m.name}</option>
                  ))}
                </select>
              </label>
              <button onClick={saveShot} disabled={saving === "shot"} className="h-12 px-6 rounded-lg border border-black/15 font-medium hover:bg-black/[0.04] transition-colors disabled:opacity-50">
                {saving === "shot" ? "Saving…" : "Save setup"}
              </button>
            </div>
          </div>
        </div>
      )}

      {!productId && products.length === 0 && (
        <div className="gloss rounded-2xl p-8 text-center">
          <p className="text-sm text-black/55">
            No products yet — products are set up with your technician during deployment.
          </p>
        </div>
      )}
    </div>
  );
}
