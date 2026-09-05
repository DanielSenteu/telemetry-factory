"use client";

import { useCallback, useEffect, useState } from "react";
import { field } from "@/components/app/modal";
import { convert, familyMembers, canonicalUnit } from "@/lib/services/units";
import { RecipeTree } from "@/components/app/recipe-tree";
import {
  listFinishedGoods,
  listRawMaterials,
  getBOMForProduct,
  upsertBOMLine,
  deleteBOMLine,
  updateBOMShotParams,
  getRecipeTree,
  listStages,
  addStage,
  setProductStage,
  getProductStage,
  type Bom,
  type Product,
  type TreeNode,
  type ProcessStage,
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
  // The production tree: rooted at the picked product; clicking a node edits it.
  const [rootId, setRootId] = useState<number | null>(null);
  const [tree, setTree] = useState<TreeNode[] | null>(null);
  // Stage vocabulary (per-factory step names) + the selected product's stage.
  const [stages, setStages] = useState<ProcessStage[]>([]);
  const [newStageName, setNewStageName] = useState("");
  const [madeAt, setMadeAt] = useState<string>("");

  // add-line form
  const [componentId, setComponentId] = useState("");
  const [qty, setQty] = useState("");
  // The unit the amount is TYPED in — any family member of the material's
  // unit; storage always converts back to the material's own unit.
  const [entryUnit, setEntryUnit] = useState("");
  const [perN, setPerN] = useState("");
  const [stage, setStage] = useState<"moulding" | "packaging">("moulding");
  // shot params form
  const [cavities, setCavities] = useState("");
  const [runnerG, setRunnerG] = useState("");
  const [runnerMat, setRunnerMat] = useState("");
  const [saving, setSaving] = useState<null | "line" | "shot">(null);

  useEffect(() => {
    let gone = false;
    Promise.all([listFinishedGoods(orgId), listRawMaterials(orgId), listStages(orgId)])
      .then(([fg, rm, st]) => {
        if (gone) return;
        setProducts(fg);
        setMaterials(rm);
        setStages(st);
      })
      .catch((e) => !gone && setError(e.message));
    return () => {
      gone = true;
    };
  }, [orgId]);

  const loadTree = useCallback(
    async (rid: number) => {
      try {
        setTree(await getRecipeTree(orgId, rid));
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      }
    },
    [orgId],
  );

  const loadStageFor = useCallback(async (pid: number) => {
    try {
      const s = await getProductStage(pid);
      setMadeAt(s != null ? String(s) : "");
    } catch {
      setMadeAt("");
    }
  }, []);

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

  // Picking from the dropdown roots the tree there and edits that product.
  const pick = (pid: number) => {
    setRootId(pid);
    setProductId(pid);
    setBom(null);
    setTree(null);
    setComponentId("");
    setQty("");
    loadBom(pid);
    loadTree(pid);
    loadStageFor(pid);
  };

  // Clicking a tree node keeps the tree rooted but edits that node below.
  const selectNode = (pid: number) => {
    setProductId(pid);
    setBom(null);
    setComponentId("");
    setQty("");
    loadBom(pid);
    loadStageFor(pid);
  };

  // Any edit refreshes both the editor and the tree it's part of.
  const refreshAfterEdit = async (pid: number) => {
    await loadBom(pid);
    if (rootId != null) await loadTree(rootId);
  };

  const addLine = async () => {
    if (!productId || !componentId || !Number(qty)) return;
    setSaving("line");
    setError(null);
    try {
      const selectedMat = materials.find((m) => m.id === Number(componentId));
      const uom = selectedMat?.unit_of_measure || "unit";
      // Typed in kg, stored in the material's own unit (g) — exact, in-family.
      const stored = entryUnit && entryUnit !== uom ? convert(Number(qty), entryUnit, uom) : Number(qty);
      await upsertBOMLine(orgId, productId, Number(componentId), stored, uom, Number(perN) || 1, stage);
      setComponentId("");
      setQty("");
      setEntryUnit("");
      setPerN("");
      setStage("moulding");
      await refreshAfterEdit(productId);
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
      await refreshAfterEdit(productId);
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
      await refreshAfterEdit(productId);
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

      {/* The factory's own step names */}
      <div className="flex items-center gap-2 flex-wrap">
        <span className="text-sm font-medium text-black/70">Steps:</span>
        {stages.map((s) => (
          <span key={s.id} className="rounded-lg bg-black/[0.05] px-3 py-1.5 text-sm font-medium">{s.name}</span>
        ))}
        <input
          className="h-9 w-36 rounded-lg border border-black/10 px-3 text-sm outline-none focus:border-black/30"
          placeholder="Add a step…"
          value={newStageName}
          onChange={(e) => setNewStageName(e.target.value)}
          onKeyDown={async (e) => {
            if (e.key === "Enter" && newStageName.trim()) {
              try {
                await addStage(orgId, newStageName);
                setNewStageName("");
                setStages(await listStages(orgId));
              } catch (err) {
                setError(err instanceof Error ? err.message : String(err));
              }
            }
          }}
        />
      </div>

      <label className="flex flex-col gap-1.5 max-w-sm">
        <span className="text-sm font-medium text-black/70">Product</span>
        <select className={field} value={rootId ?? ""} onChange={(e) => e.target.value && pick(Number(e.target.value))}>
          <option value="">Choose a product…</option>
          {products.map((p) => (
            <option key={p.id} value={p.id}>{p.name}{p.kind === "component" ? " (component)" : ""}</option>
          ))}
        </select>
      </label>

      {error && <p className="text-sm text-red-600">{error}</p>}

      {/* The production story, all levels at once */}
      {rootId && tree && tree.length > 0 && (
        <div className="flex flex-col gap-2">
          <h2 className="font-display text-lg font-bold">How it&apos;s made</h2>
          <RecipeTree nodes={tree} selectedId={productId} onSelect={selectNode} />
          <p className="text-xs text-black/45">
            Tap any step to edit it below. Amber marks what still needs filling in.
          </p>
        </div>
      )}

      {productId && (
        <div className="flex flex-col gap-4">
          {/* Which of the factory's steps makes the selected product */}
          <div className="flex items-center gap-3 flex-wrap">
            <span className="text-sm font-medium text-black/70">
              {selected?.name ?? "This product"} is made at:
            </span>
            <select
              className="h-10 rounded-lg border border-black/10 px-3 text-sm outline-none focus:border-black/30"
              value={madeAt}
              onChange={async (e) => {
                setMadeAt(e.target.value);
                try {
                  await setProductStage(productId, e.target.value ? Number(e.target.value) : null);
                  if (rootId != null) await loadTree(rootId);
                } catch (err) {
                  setError(err instanceof Error ? err.message : String(err));
                }
              }}
            >
              <option value="">Choose a step…</option>
              {stages.map((s) => (
                <option key={s.id} value={s.id}>{s.name}</option>
              ))}
            </select>
          </div>
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
                    <span className="font-medium flex-1">
                      {l.component_name}
                      {l.stage === "packaging" && (
                        <span className="ml-2 rounded bg-black/[0.06] px-2 py-0.5 text-[11px] font-mono font-semibold text-black/55">
                          PACKAGING
                        </span>
                      )}
                    </span>
                    <span className="font-mono font-semibold tabular-nums">
                      {Number(l.qty_per_unit).toLocaleString()} {l.uom}
                      {Number(l.per_units) !== 1 && (
                        <span className="text-black/45 font-normal"> / {Number(l.per_units).toLocaleString()} units</span>
                      )}
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
                <select className={field} value={componentId} onChange={(e) => { setComponentId(e.target.value); setEntryUnit(""); }}>
                  <option value="">Choose…</option>
                  {materials
                    .filter((m) => m.id !== productId)
                    .map((m) => (
                      <option key={m.id} value={m.id}>
                        {m.name}
                        {m.kind === "component" || m.kind === "finished_good" ? " — made here" : ""}
                      </option>
                    ))}
                </select>
              </label>
              {(() => {
                const matUom = materials.find((m) => m.id === Number(componentId))?.unit_of_measure || "";
                const members = familyMembers(matUom);
                const showUnitPick = members.length > 1;
                return (
                  <>
                    <label className="flex flex-col gap-1.5 w-32">
                      <span className="text-sm font-medium text-black/70">Amount</span>
                      <input type="number" inputMode="decimal" className={field + " font-mono"} value={qty} onChange={(e) => setQty(e.target.value)} />
                    </label>
                    {showUnitPick ? (
                      <label className="flex flex-col gap-1.5 w-40">
                        <span className="text-sm font-medium text-black/70">In</span>
                        <select className={field} value={entryUnit || canonicalUnit(matUom) || matUom} onChange={(e) => setEntryUnit(e.target.value)}>
                          {members.map((u) => (
                            <option key={u.value} value={u.value}>{u.label}</option>
                          ))}
                        </select>
                      </label>
                    ) : (
                      componentId && <span className="text-sm text-black/50 pb-3.5">{matUom || "units"}</span>
                    )}
                    <label className="flex flex-col gap-1.5 w-32">
                      <span className="text-sm font-medium text-black/70">Per how many</span>
                      <input type="number" inputMode="numeric" className={field + " font-mono"} value={perN} onChange={(e) => setPerN(e.target.value)} placeholder="1" />
                    </label>
                    <label className="flex flex-col gap-1.5 w-40">
                      <span className="text-sm font-medium text-black/70">Used at</span>
                      <select className={field} value={stage} onChange={(e) => setStage(e.target.value as "moulding" | "packaging")}>
                        <option value="moulding">Moulding</option>
                        <option value="packaging">Packaging / sealing</option>
                      </select>
                    </label>
                  </>
                );
              })()}
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
                  {materials
                    .filter((m) => m.kind === "raw_material")
                    .map((m) => (
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
