"use client";

import { useCallback, useEffect, useState } from "react";
import { Modal, field, primaryBtn } from "@/components/app/modal";
import {
  getMachineInspectorData,
  machineProfile,
  effectiveCavity,
  deriveMachineState,
  formatNairobi,
  getCountAction,
  setMovementCountAction,
  clearCountAction,
  postCountAction,
  listConsumables,
  listProductsForMapping,
  mapMachineCraft,
  type MachineRow,
  type MachineInspectorData,
  type CountAction,
} from "@/lib/services/machines";

// The machine, opened up. Two questions a glance must answer:
// what is this machine actually telling us, and what do we make of it.

const timeFmt: Intl.DateTimeFormatOptions = {
  day: "2-digit",
  month: "short",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hour12: false,
};

function label(key: string) {
  return key.replace(/_/g, " ");
}

function fmt(v: number | string | boolean | null): string {
  if (v === null || v === undefined) return "—";
  if (typeof v === "number") return Number.isInteger(v) ? v.toLocaleString() : v.toLocaleString(undefined, { maximumFractionDigits: 2 });
  return String(v);
}

function Signal({ name, value }: { name: string; value: string }) {
  return (
    <div className="rounded-lg bg-black/[0.035] px-3 py-2 flex flex-col gap-0.5 min-w-0">
      <span className="text-[11px] uppercase tracking-wider text-black/40 truncate">{name}</span>
      <span className="font-mono text-sm font-semibold tabular-nums truncate">{value}</span>
    </div>
  );
}

function SectionTitle({ children }: { children: React.ReactNode }) {
  return (
    <h3 className="font-mono text-[11px] font-bold tracking-widest text-black/40 uppercase">{children}</h3>
  );
}

// End-of-day posting for action machines. Primary flow: "what was wrapped
// today?" — pick the product, and the day's counts bill through THAT
// product's packaging recipe lines. Fallback: a fixed rule ("each count uses
// 1 wrapper") for machines whose consumption never varies. Either way it
// posts ONE aggregated movement per day; the machine's own product is never
// touched (the moulder already counted it).
function CountActionSection({
  orgId,
  machineId,
  countNoun,
  todayCounts,
}: {
  orgId: number;
  machineId: number;
  countNoun: string;
  todayCounts: number;
}) {
  const [action, setAction] = useState<CountAction | null | undefined>(undefined);
  const [consumables, setConsumables] = useState<Array<{ id: number; name: string; unit_of_measure: string }>>([]);
  const [finishedGoods, setFinishedGoods] = useState<Array<{ id: number; name: string }>>([]);
  const [wrapProductId, setWrapProductId] = useState("");
  const [editing, setEditing] = useState(false);
  const [productId, setProductId] = useState("");
  const [qtyPer, setQtyPer] = useState("");
  const [busy, setBusy] = useState<null | "save" | "post" | "clear">(null);
  const [posted, setPosted] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [a, c, fg] = await Promise.all([
        getCountAction(orgId, machineId),
        listConsumables(orgId),
        listProductsForMapping(orgId),
      ]);
      setAction(a);
      setConsumables(c);
      setFinishedGoods(fg);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [orgId, machineId]);

  useEffect(() => {
    let gone = false;
    Promise.resolve().then(() => { if (!gone) load(); });
    return () => { gone = true; };
  }, [load]);

  const save = async () => {
    if (!productId || !Number(qtyPer)) return;
    setBusy("save");
    setError(null);
    try {
      await setMovementCountAction(orgId, machineId, Number(productId), Number(qtyPer));
      setEditing(false);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const clear = async () => {
    setBusy("clear");
    setError(null);
    try {
      await clearCountAction(orgId, machineId);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const post = async () => {
    setBusy("post");
    setError(null);
    try {
      await postCountAction(orgId, machineId, undefined, wrapProductId ? Number(wrapProductId) : undefined);
      setPosted(true);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const actionProduct = action?.product_id ? consumables.find((c) => c.id === action.product_id) : null;
  const canPost = posted ? false : todayCounts > 0 && (!!wrapProductId || !!action);

  return (
    <div className="flex flex-col gap-2.5">
      <SectionTitle>End of day</SectionTitle>
      {error && <p className="text-sm text-red-600">{error}</p>}
      {action === undefined ? (
        <div className="rounded-lg bg-black/[0.035] h-9 animate-pulse" />
      ) : !editing ? (
        <>
          <label className="flex flex-col gap-1.5">
            <span className="text-sm font-medium text-black/70">What was it {countNoun === "wrapped" ? "wrapping" : "processing"} today?</span>
            <select className={field} value={wrapProductId} onChange={(e) => { setWrapProductId(e.target.value); setPosted(false); }}>
              <option value="">{action ? "No product — use the fixed rule below" : "Choose a product…"}</option>
              {finishedGoods.map((p) => (
                <option key={p.id} value={p.id}>{p.name}</option>
              ))}
            </select>
          </label>
          {wrapProductId !== "" && (
            <p className="text-xs text-black/45 -mt-1">
              The day&apos;s counts will bill through this product&apos;s <span className="font-semibold">packaging</span> recipe lines.
            </p>
          )}

          {action && (
            <div className="rounded-xl border border-black/10 p-3 flex items-center gap-3 flex-wrap">
              <span className="text-sm">
                Fixed rule: each count uses{" "}
                <span className="font-mono font-semibold">
                  {Number(action.qty_per_count).toLocaleString()} {actionProduct?.unit_of_measure ?? ""}
                </span>{" "}
                of <span className="font-semibold">{actionProduct?.name ?? `Product ${action.product_id}`}</span>
              </span>
              <div className="ml-auto flex gap-2">
                <button onClick={() => { setEditing(true); setProductId(String(action.product_id ?? "")); setQtyPer(String(action.qty_per_count ?? "")); }} className="text-sm text-black/50 hover:text-black px-2 py-1">
                  Change
                </button>
                <button onClick={clear} disabled={busy === "clear"} className="text-sm text-black/50 hover:text-red-600 px-2 py-1">
                  {busy === "clear" ? "Removing…" : "Remove"}
                </button>
              </div>
            </div>
          )}
          {!action && (
            <button onClick={() => setEditing(true)} className="self-start text-sm text-black/50 hover:text-black">
              + Set a fixed rule instead (each count always uses the same material)
            </button>
          )}

          <button
            onClick={post}
            disabled={busy === "post" || !canPost}
            className={primaryBtn + " h-11"}
          >
            {posted
              ? "Posted — stock updated"
              : busy === "post"
                ? "Posting…"
                : `Post today's usage (${todayCounts.toLocaleString()} ${countNoun})`}
          </button>
          <p className="text-xs text-black/45">
            Posts once per day as a single stock movement — posting again the same day does nothing.
          </p>
        </>
      ) : (
        <div className="flex flex-wrap items-end gap-3">
          <label className="flex flex-col gap-1.5 flex-1 min-w-44">
            <span className="text-sm font-medium text-black/70">Each count uses…</span>
            <select className={field} value={productId} onChange={(e) => setProductId(e.target.value)}>
              <option value="">Choose a material…</option>
              {consumables.map((c) => (
                <option key={c.id} value={c.id}>{c.name}</option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-1.5 w-36">
            <span className="text-sm font-medium text-black/70">
              Amount ({consumables.find((c) => c.id === Number(productId))?.unit_of_measure || "per count"})
            </span>
            <input type="number" inputMode="decimal" className={field + " font-mono"} value={qtyPer} onChange={(e) => setQtyPer(e.target.value)} />
          </label>
          <button
            onClick={save}
            disabled={busy === "save" || !productId || !Number(qtyPer)}
            className="h-12 px-6 rounded-lg bg-[var(--ink)] text-white font-medium hover:bg-black transition-colors disabled:opacity-50"
          >
            {busy === "save" ? "Saving…" : "Save"}
          </button>
          <button onClick={() => setEditing(false)} className="h-12 px-4 text-sm text-black/50 hover:text-black">
            Cancel
          </button>
        </div>
      )}
    </div>
  );
}

export function MachineInspector({
  orgId,
  row,
  nowMs,
  onClose,
}: {
  orgId: number;
  row: MachineRow;
  nowMs: number;
  onClose: () => void;
}) {
  const [data, setData] = useState<MachineInspectorData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [settingOverride, setSettingOverride] = useState(false);

  const load = useCallback(async () => {
    try {
      setData(await getMachineInspectorData(orgId, row.machine_id));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [orgId, row.machine_id]);

  useEffect(() => {
    let gone = false;
    Promise.resolve().then(() => { if (!gone) load(); });
    return () => { gone = true; };
  }, [load]);

  const profile = machineProfile(row.machine_type);
  const state = deriveMachineState(row, nowMs);
  const mapping = data?.mappings.find((m) => m.craft_id === row.craft_id) ?? null;
  const verdict = effectiveCavity(row.mold_cavity, mapping?.cavity_override, mapping?.recipe_cavities);

  // The standard signals, shown only when the machine actually sends them.
  const signals: Array<[string, string]> = [];
  if (row.shot_count != null) signals.push(["counter", fmt(row.shot_count)]);
  if (row.cycle_time != null) signals.push(["cycle", `${Number(row.cycle_time).toFixed(2)}s`]);
  if (row.mold_cavity != null) signals.push(["cavities (panel)", fmt(row.mold_cavity)]);
  if (row.power_kwh != null) signals.push(["power", `${Number(row.power_kwh).toFixed(1)} kWh`]);
  if (row.plan_count != null) signals.push(["plan count", fmt(row.plan_count)]);
  if (row.craft_id != null) signals.push(["job", row.craft_id]);
  if (row.material != null) signals.push(["material", row.material]);
  if (row.operate_mode != null) signals.push(["operate mode", fmt(row.operate_mode)]);
  if (row.motor_state != null) signals.push(["motor", row.motor_state === 1 ? "on" : "off"]);
  if (row.heat_state != null) signals.push(["heat", row.heat_state === 1 ? "on" : "off"]);
  if (row.online_state != null) signals.push(["online flag", fmt(row.online_state)]);

  const extras = data?.extraValues ? Object.entries(data.extraValues) : [];

  return (
    <Modal open onClose={onClose} title={row.name} wide>
      <div className="flex flex-col gap-6">
        {/* Identity line */}
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs font-mono text-black/45 -mt-2">
          <span className="font-bold tracking-widest uppercase text-black/60">{state}</span>
          {row.machine_type && <span className="rounded bg-black/[0.05] px-2 py-0.5">{row.machine_type}</span>}
          {row.mac && <span>{row.mac}</span>}
          {row.ip && <span>{row.ip}</span>}
          <span className="ml-auto">
            last reading {row.observed_at ? formatNairobi(row.observed_at, timeFmt) : "never"}
          </span>
        </div>

        {error && (
          <div className="rounded-xl bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">{error}</div>
        )}

        {/* ── What the machine reports ── */}
        <div className="flex flex-col gap-2.5">
          <SectionTitle>What the machine reports</SectionTitle>
          {signals.length === 0 ? (
            <p className="text-sm text-black/50">Nothing yet — no readings received from this machine.</p>
          ) : (
            <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
              {signals.map(([n, v]) => (
                <Signal key={n} name={n} value={v} />
              ))}
            </div>
          )}
          {row.alarms?.ids?.length ? (
            <div className="rounded-lg bg-red-500/10 text-red-700 text-sm font-mono font-semibold px-3 py-2">
              alarms: {row.alarms.ids.join(" · ")}
            </div>
          ) : null}

          {extras.length > 0 && (
            <>
              <div className="text-xs text-black/45 mt-1">
                More signals from this machine
                {data?.extraValuesAt ? ` — as of ${formatNairobi(data.extraValuesAt, timeFmt)}` : ""}
              </div>
              <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
                {extras.map(([k, v]) => (
                  <Signal key={k} name={label(k)} value={fmt(v)} />
                ))}
              </div>
            </>
          )}
        </div>

        {/* ── How the system reads it ── */}
        <div className="flex flex-col gap-2.5">
          <SectionTitle>How the system reads it</SectionTitle>
          <p className="text-sm text-black/70">{profile.reads}</p>

          {profile.usesCavities && (
            <div className="rounded-xl border border-black/10 p-3 flex flex-col gap-2">
              <div className="grid grid-cols-3 gap-2 text-center">
                {(
                  [
                    ["controller", row.mold_cavity != null && row.mold_cavity > 0 ? String(row.mold_cavity) : "—"],
                    ["recipe", verdict.recipe != null ? String(verdict.recipe) : "—"],
                    ["override", mapping?.cavity_override != null ? String(mapping.cavity_override) : "—"],
                  ] as const
                ).map(([src, val]) => (
                  <div
                    key={src}
                    className={`rounded-lg px-2 py-2 ${
                      verdict.source === src ? "bg-[var(--ink)] text-white" : "bg-black/[0.035] text-black/60"
                    }`}
                  >
                    <div className="text-[10px] uppercase tracking-wider opacity-70">{src}</div>
                    <div className="font-mono text-lg font-semibold tabular-nums">{val}</div>
                  </div>
                ))}
              </div>
              <div className="text-xs text-black/50">
                Counting with <span className="font-semibold text-black/70">{verdict.value}</span>{" "}
                {verdict.value === 1 ? "cavity" : "cavities"} (from the {verdict.source === "default" ? "1-cavity default" : verdict.source}).
              </div>
              {verdict.mismatch && (
                <div className="rounded-lg bg-amber-50 border border-amber-200 px-3 py-2 text-sm text-amber-800 flex flex-col gap-2">
                  <span>
                    The recipe says <span className="font-semibold">{verdict.recipe}</span> cavities but counting uses{" "}
                    <span className="font-semibold">{verdict.value}</span> — the parts numbers are off by that factor.
                  </span>
                  {mapping && verdict.recipe != null && (
                    <button
                      onClick={async () => {
                        setSettingOverride(true);
                        setError(null);
                        try {
                          await mapMachineCraft(orgId, row.machine_id, mapping.craft_id, mapping.product_id, verdict.recipe);
                          await load();
                        } catch (e) {
                          setError(e instanceof Error ? e.message : String(e));
                        } finally {
                          setSettingOverride(false);
                        }
                      }}
                      disabled={settingOverride}
                      className="self-start h-10 px-4 rounded-lg bg-amber-600 text-white text-sm font-semibold hover:bg-amber-700 transition-colors disabled:opacity-50"
                    >
                      {settingOverride ? "Recounting…" : `Count with the recipe's ${verdict.recipe} — recount history`}
                    </button>
                  )}
                </div>
              )}
            </div>
          )}

          <div className="flex flex-col gap-1.5">
            {data === null && !error ? (
              <div className="rounded-lg bg-black/[0.035] h-9 animate-pulse" />
            ) : data && data.mappings.length > 0 ? (
              data.mappings.map((m) => (
                <div
                  key={m.craft_id}
                  className={`flex items-center gap-2 rounded-lg px-3 py-2 text-sm ${
                    m.craft_id === row.craft_id ? "bg-black/[0.05]" : "bg-black/[0.02] text-black/55"
                  }`}
                >
                  <span className="font-mono text-xs">{m.craft_id}</span>
                  <span className="text-black/30">→</span>
                  <span className="font-medium truncate">{m.product_name ?? `Product ${m.product_id}`}</span>
                  {m.craft_id === row.craft_id && (
                    <span className="ml-auto font-mono text-[10px] font-bold tracking-widest text-[var(--accent)]">
                      CURRENT
                    </span>
                  )}
                </div>
              ))
            ) : (
              <p className="text-sm text-black/50">
                No jobs mapped to products yet — map them from the card when a job shows as unmapped.
              </p>
            )}
          </div>
        </div>

        {profile.kind === "actions" && (
          <CountActionSection
            orgId={orgId}
            machineId={row.machine_id}
            countNoun={profile.countNoun}
            todayCounts={row.today_shots}
          />
        )}
      </div>
    </Modal>
  );
}
