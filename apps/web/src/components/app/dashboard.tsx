"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import {
  getMachineDashboard,
  listFactoryAgents,
  deriveMachineState,
  goodParts,
  agentIsStale,
  nairobiPresetRange,
  formatNairobi,
  type MachineRow,
  type FactoryAgent,
} from "@/lib/services/machines";
import { listProducts, listRecentMovements, type StockedProduct, type Movement } from "@/lib/services/inventory";
import { getMonthlyDemandRates } from "@/lib/services/demand";

// The morning screen. The floor's arc is the page's arc: machines coming up,
// what's on the shelf, what's moving right now. Every panel is a doorway into
// its tab — this page answers, the tabs act.

const REFRESH_MS = 30_000;

const STATE_STYLE: Record<string, { word: string; text: string; led: string; extra?: string }> = {
  running: { word: "RUNNING", text: "text-[var(--accent)]", led: "bg-[var(--accent)]" },
  idle: { word: "IDLE", text: "text-amber-600", led: "bg-amber-400" },
  alarm: { word: "ALARM", text: "text-red-600", led: "bg-red-500", extra: "ring-1 ring-red-500/50" },
  offline: { word: "OFFLINE", text: "text-black/40", led: "bg-black/25", extra: "opacity-60" },
};

const MOVE_META: Record<string, { dot: string; verb: string }> = {
  purchase: { dot: "bg-[var(--accent)]", verb: "received" },
  production_output: { dot: "bg-[var(--accent)]", verb: "made" },
  regrind_return: { dot: "bg-[var(--accent)]", verb: "regrind returned" },
  sale: { dot: "bg-sky-500", verb: "sold" },
  production_consume: { dot: "bg-black/30", verb: "used by production" },
  wastage: { dot: "bg-amber-400", verb: "waste / rejects" },
  adjustment: { dot: "bg-black/30", verb: "adjustment" },
};

function qty(n: number, uom: string) {
  const v = Math.abs(Number(n));
  if (uom === "g" && v >= 1000) return `${(v / 1000).toLocaleString(undefined, { maximumFractionDigits: 1 })} kg`;
  return `${v.toLocaleString()}${uom === "each" ? "" : ` ${uom}`}`;
}

function CoverBadge({ weeks }: { weeks: number }) {
  const cls =
    weeks < 2
      ? "bg-red-500/10 text-red-600"
      : weeks < 4
        ? "bg-amber-400/15 text-amber-700"
        : "bg-[var(--accent-soft)] text-[var(--accent)]";
  const label = weeks < 0.1 ? "OUT" : `${weeks < 10 ? weeks.toFixed(1) : Math.round(weeks)} wk`;
  return <span className={`font-mono text-[11px] font-bold rounded-md px-2 py-1 ${cls}`}>{label}</span>;
}

function PanelHeader({ title, href, hint }: { title: string; href: string; hint?: string }) {
  return (
    <div className="flex items-baseline gap-3">
      <h2 className="font-display text-lg font-bold">{title}</h2>
      {hint && <span className="text-xs text-black/40">{hint}</span>}
      <Link href={href} className="ml-auto text-sm font-medium text-black/45 hover:text-black transition-colors">
        View all →
      </Link>
    </div>
  );
}

export function Dashboard({ orgId }: { orgId: number }) {
  const [machines, setMachines] = useState<MachineRow[] | null>(null);
  const [agents, setAgents] = useState<FactoryAgent[]>([]);
  const [stock, setStock] = useState<StockedProduct[] | null>(null);
  const [moves, setMoves] = useState<Movement[] | null>(null);
  const [demand, setDemand] = useState<Map<number, number>>(new Map());
  const [updatedAt, setUpdatedAt] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);

  const load = useCallback(async () => {
    try {
      const { from, to } = nairobiPresetRange("today");
      const [m, a, s, mv, d] = await Promise.all([
        getMachineDashboard(orgId, from, to),
        listFactoryAgents(orgId),
        listProducts(orgId),
        listRecentMovements(orgId, undefined, 8),
        getMonthlyDemandRates(orgId).catch(() => new Map<number, number>()),
      ]);
      setMachines(m);
      setAgents(a);
      setStock(s);
      setMoves(mv);
      setDemand(d);
      setUpdatedAt(Date.now());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [orgId]);

  useEffect(() => {
    let gone = false;
    Promise.resolve().then(() => { if (!gone) load(); });
    timer.current = setInterval(load, REFRESH_MS);
    return () => {
      gone = true;
      if (timer.current) clearInterval(timer.current);
    };
  }, [load]);

  const nowMs = updatedAt ?? 0;
  const states = (machines || []).map((m) => deriveMachineState(m, nowMs));
  const upCount = states.filter((s) => s === "running").length;
  const collectorDown = agents.length > 0 && agents.every((a) => agentIsStale(a, nowMs));
  const raw = (stock || []).filter((p) => p.kind !== "finished_good");
  const finished = (stock || []).filter((p) => p.kind === "finished_good");
  const todayStr = updatedAt
    ? formatNairobi(new Date(updatedAt).toISOString(), { weekday: "long", day: "numeric", month: "long" })
    : "";

  return (
    <div className="flex flex-col gap-6">
      {/* Day strip */}
      <div className="flex items-center gap-3 flex-wrap">
        <h1 className="font-display text-2xl font-bold">{todayStr || "Today"}</h1>
        {machines !== null && machines.length > 0 && (
          <span className="font-mono text-sm text-black/50">
            <span className="text-black/80 font-semibold">{upCount}</span> of {machines.length} machines running
          </span>
        )}
        {updatedAt && (
          <span className="ml-auto text-xs font-mono text-black/40">updated {formatNairobi(new Date(updatedAt).toISOString())}</span>
        )}
      </div>

      {collectorDown && (
        <div className="rounded-xl bg-amber-50 border border-amber-200 px-4 py-3 text-sm text-amber-800">
          <span className="font-semibold">Factory collector offline.</span> Machines keep counting; data is
          queuing at the factory and will catch up on its own.
        </div>
      )}
      {error && (
        <div className="rounded-xl bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">
          Could not load the dashboard: {error}. Retrying automatically.
        </div>
      )}

      {/* The floor */}
      <section className="flex flex-col gap-3">
        <PanelHeader title="The floor" href="/app/production" />
        {machines === null ? (
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            {[0, 1, 2, 3].map((i) => (
              <div key={i} className="gloss rounded-2xl h-28 animate-pulse" />
            ))}
          </div>
        ) : machines.length === 0 ? (
          <div className="gloss rounded-2xl p-8 text-center text-sm text-black/55">
            No machines yet — they register themselves once the collector runs.
          </div>
        ) : (
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            {machines.map((m, i) => {
              const st = STATE_STYLE[states[i]];
              return (
                <Link
                  key={m.machine_id}
                  href="/app/production"
                  className={`gloss rounded-2xl p-4 flex flex-col gap-2 hover:ring-1 hover:ring-black/15 transition-shadow ${st.extra ?? ""}`}
                >
                  <div className="flex items-center gap-2">
                    <span className="relative flex size-2.5">
                      {states[i] === "running" && (
                        <span className={`animate-ping absolute inline-flex h-full w-full rounded-full ${st.led} opacity-50`} />
                      )}
                      <span className={`relative inline-flex size-2.5 rounded-full ${st.led} ${states[i] === "alarm" ? "animate-pulse" : ""}`} />
                    </span>
                    <span className="font-display font-bold text-sm tracking-tight truncate">{m.name}</span>
                    <span className={`ml-auto font-mono text-[10px] font-bold tracking-widest ${st.text}`}>{st.word}</span>
                  </div>
                  <div className="text-xs text-black/55 truncate min-h-4">
                    {m.product_name ?? (m.craft_id ? `Job ${m.craft_id}` : "No job")}
                  </div>
                  <div className="flex items-baseline gap-1.5">
                    <span className="font-mono text-2xl font-semibold tabular-nums leading-none">{goodParts(m).toLocaleString()}</span>
                    <span className="text-[11px] text-black/40">today</span>
                    {m.cycle_time != null && (
                      <span className="ml-auto font-mono text-[11px] text-black/40">{Number(m.cycle_time).toFixed(1)}s</span>
                    )}
                  </div>
                </Link>
              );
            })}
          </div>
        )}
      </section>

      {/* Stock panels */}
      <div className="grid gap-4 lg:grid-cols-2">
        <section className="gloss rounded-2xl p-5 flex flex-col gap-1">
          <PanelHeader title="Raw materials" href="/app/materials" />
          {stock === null ? (
            <div className="h-32 rounded-lg bg-black/5 animate-pulse mt-2" />
          ) : raw.length === 0 ? (
            <p className="text-sm text-black/50 py-4">No materials yet — add them in Materials.</p>
          ) : (
            raw.slice(0, 5).map((p) => (
              <div key={p.id} className="flex items-center gap-3 py-2.5 border-t border-black/5 first:border-t-0 first:mt-1">
                <span className="font-medium text-sm flex-1 truncate">{p.name}</span>
                <span className={`font-mono font-semibold text-sm tabular-nums ${Number(p.on_hand) < 0 ? "text-red-600" : ""}`}>
                  {qty(Number(p.on_hand), p.unit_of_measure)}
                </span>
              </div>
            ))
          )}
        </section>

        <section className="gloss rounded-2xl p-5 flex flex-col gap-1">
          <PanelHeader title="Finished goods" href="/app/materials" hint="cover from real sales" />
          {stock === null ? (
            <div className="h-32 rounded-lg bg-black/5 animate-pulse mt-2" />
          ) : finished.length === 0 ? (
            <p className="text-sm text-black/50 py-4">No finished goods yet.</p>
          ) : (
            finished.slice(0, 5).map((p) => {
              const rate = demand.get(p.id);
              const weeks = rate && rate > 0 ? Number(p.on_hand) / (rate / 4.33) : null;
              return (
                <div key={p.id} className="flex items-center gap-3 py-2.5 border-t border-black/5 first:border-t-0 first:mt-1">
                  <span className="font-medium text-sm flex-1 truncate">{p.name}</span>
                  <span className={`font-mono font-semibold text-sm tabular-nums ${Number(p.on_hand) < 0 ? "text-red-600" : ""}`}>
                    {qty(Number(p.on_hand), p.unit_of_measure)}
                  </span>
                  {weeks != null && <CoverBadge weeks={Math.max(0, weeks)} />}
                </div>
              );
            })
          )}
        </section>
      </div>

      {/* Happening now */}
      <section className="gloss rounded-2xl p-5 flex flex-col gap-1">
        <PanelHeader title="Happening now" href="/app/materials" />
        {moves === null ? (
          <div className="h-40 rounded-lg bg-black/5 animate-pulse mt-2" />
        ) : moves.length === 0 ? (
          <p className="text-sm text-black/50 py-4">
            Quiet so far — receive material, confirm a run or record an event and it shows up here.
          </p>
        ) : (
          moves.map((m) => {
            const meta = MOVE_META[m.movement_type] ?? { dot: "bg-black/30", verb: m.movement_type };
            const positive = Number(m.quantity) > 0;
            return (
              <div key={m.id} className="flex items-center gap-3.5 py-2.5 border-t border-black/5 first:border-t-0 first:mt-1">
                <span className="font-mono text-xs text-black/40 w-11 shrink-0">{formatNairobi(m.created_at)}</span>
                <span className={`size-2.5 rounded-full shrink-0 ${meta.dot}`} />
                <span className="text-sm min-w-0 flex-1 truncate">
                  <span className={`font-mono font-semibold ${positive ? "text-[var(--accent)]" : "text-black/70"}`}>
                    {positive ? "+" : "−"}{qty(m.quantity, m.products?.unit_of_measure ?? "")}
                  </span>{" "}
                  <span className="font-medium">{m.products?.name ?? `#${m.product_id}`}</span>{" "}
                  <span className="text-black/50">— {meta.verb}</span>
                  {m.note && <span className="text-black/40"> · {m.note}</span>}
                </span>
              </div>
            );
          })
        )}
      </section>
    </div>
  );
}
