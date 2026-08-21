"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ConfirmOutputDialog,
  RecordEventDialog,
  MapCraftDialog,
} from "@/components/app/production-dialogs";
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

// The floor, live. One question, answered in the first second: is it running?
// Big mono counts readable at arm's length; state is always color + word.
const REFRESH_MS = 20_000;
const PRESETS = [
  { key: "today", label: "Today" },
  { key: "yesterday", label: "Yesterday" },
  { key: "week", label: "This week" },
] as const;

const STATE_STYLE: Record<string, { word: string; text: string; ring: string; led: string }> = {
  running: { word: "RUNNING", text: "text-[var(--accent)]", ring: "ring-1 ring-[var(--accent)]/40", led: "bg-[var(--accent)]" },
  idle: { word: "IDLE", text: "text-amber-600", ring: "ring-1 ring-amber-400/40", led: "bg-amber-400" },
  alarm: { word: "ALARM", text: "text-red-600", ring: "ring-1 ring-red-500/60", led: "bg-red-500" },
  offline: { word: "OFFLINE", text: "text-black/40", ring: "opacity-60", led: "bg-black/25" },
};

function MachineCard({
  row,
  nowMs,
  onConfirm,
  onMap,
}: {
  row: MachineRow;
  nowMs: number;
  onConfirm: (row: MachineRow) => void;
  onMap: (row: MachineRow) => void;
}) {
  const state = deriveMachineState(row, nowMs);
  const s = STATE_STYLE[state];
  const job = row.product_name ?? (row.craft_id ? `Job ${row.craft_id}` : null);

  return (
    <div className={`gloss rounded-2xl p-5 flex flex-col gap-3 ${s.ring}`}>
      <div className="flex items-center gap-2.5">
        <span className="relative flex size-3">
          {state === "running" && (
            <span className={`animate-ping absolute inline-flex h-full w-full rounded-full ${s.led} opacity-50`} />
          )}
          <span className={`relative inline-flex size-3 rounded-full ${s.led} ${state === "alarm" ? "animate-pulse" : ""}`} />
        </span>
        <span className="font-display font-bold text-lg tracking-tight">{row.name}</span>
        <span className={`ml-auto font-mono text-xs font-bold tracking-widest ${s.text}`}>{s.word}</span>
      </div>

      <div className="text-sm font-medium text-black/70 min-h-5">
        {job ?? <span className="text-black/40">No job</span>}
        {!row.product_name && row.craft_id && (
          <button
            onClick={() => onMap(row)}
            className="ml-2 text-[11px] font-mono font-semibold text-amber-700 bg-amber-100 hover:bg-amber-200 rounded px-2 py-1 transition-colors"
          >
            unmapped — link it
          </button>
        )}
      </div>

      <div className="flex items-baseline gap-2">
        <span className="font-mono text-4xl md:text-[2.6rem] font-semibold tabular-nums leading-none">
          {goodParts(row).toLocaleString()}
        </span>
        <span className="text-sm text-black/45">good parts</span>
      </div>

      <div className="flex flex-wrap gap-2 text-xs font-mono text-black/55">
        {row.cycle_time != null && (
          <span className="rounded-lg bg-black/[0.045] px-2.5 py-1.5">{Number(row.cycle_time).toFixed(1)}s cycle</span>
        )}
        <span className="rounded-lg bg-black/[0.045] px-2.5 py-1.5">{Math.round(row.today_scrap).toLocaleString()} scrap</span>
        {row.power_kwh != null && (
          <span className="rounded-lg bg-black/[0.045] px-2.5 py-1.5">{Number(row.power_kwh).toFixed(1)} kWh</span>
        )}
        {state === "alarm" && row.alarms?.ids?.length ? (
          <span className="rounded-lg bg-red-500/10 text-red-700 font-semibold px-2.5 py-1.5">
            {row.alarms.ids.join(" · ")}
          </span>
        ) : null}
        <span className="ml-auto text-black/35">{formatNairobi(row.observed_at)}</span>
      </div>
      {row.product_id != null && goodParts(row) > 0 && (
        <button
          onClick={() => onConfirm(row)}
          className="mt-1 h-11 rounded-lg border border-black/10 text-sm font-semibold hover:bg-black/[0.04] transition-colors"
        >
          Confirm today&apos;s output
        </button>
      )}
    </div>
  );
}

export function MachinesLive({ orgId }: { orgId: number }) {
  const [preset, setPreset] = useState<(typeof PRESETS)[number]["key"]>("today");
  const [rows, setRows] = useState<MachineRow[] | null>(null);
  const [agents, setAgents] = useState<FactoryAgent[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [updatedAt, setUpdatedAt] = useState<number | null>(null);
  const [confirming, setConfirming] = useState<MachineRow | null>(null);
  const [mapping, setMapping] = useState<MachineRow | null>(null);
  const [recording, setRecording] = useState(false);
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);

  const load = useCallback(async () => {
    try {
      const { from, to } = nairobiPresetRange(preset);
      const [m, a] = await Promise.all([getMachineDashboard(orgId, from, to), listFactoryAgents(orgId)]);
      setRows(m);
      setAgents(a);
      setUpdatedAt(Date.now());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [orgId, preset]);

  useEffect(() => {
    let cancelled = false;
    // async kick so the linter's set-state-in-effect rule stays honest
    Promise.resolve().then(() => { if (!cancelled) load(); });
    timer.current = setInterval(load, REFRESH_MS);
    return () => {
      cancelled = true;
      if (timer.current) clearInterval(timer.current);
    };
  }, [load]);

  // Render purity: no Date.now() in render — the refresh timestamp is the clock.
  const nowMs = updatedAt ?? 0;
  const collectorDown = agents.length > 0 && agents.every((a) => agentIsStale(a, nowMs));

  return (
    <div className="flex flex-col gap-5">
      <div className="flex items-center gap-3 flex-wrap">
        <h1 className="font-display text-2xl font-bold">The floor</h1>
        <div className="flex gap-1 ml-2">
          {PRESETS.map((p) => (
            <button
              key={p.key}
              onClick={() => setPreset(p.key)}
              className={`px-4 py-2 rounded-lg text-sm font-semibold transition-colors ${
                preset === p.key ? "bg-black/85 text-white" : "text-black/55 hover:bg-black/5"
              }`}
            >
              {p.label}
            </button>
          ))}
        </div>
        <div className="ml-auto flex items-center gap-3">
          {updatedAt && (
            <span className="text-xs font-mono text-black/40 hidden sm:inline">
              updated {formatNairobi(new Date(updatedAt).toISOString())}
            </span>
          )}
          <button
            onClick={() => setRecording(true)}
            className="h-11 px-4 rounded-lg bg-[var(--ink)] text-white text-sm font-semibold hover:bg-black transition-colors"
          >
            Record an event
          </button>
        </div>
      </div>

      {collectorDown && (
        <div className="rounded-xl bg-amber-50 border border-amber-200 px-4 py-3 text-sm text-amber-800">
          <span className="font-semibold">Factory collector offline.</span> Machines keep counting and data is
          queuing at the factory — it will catch up when the connection returns.
        </div>
      )}

      {error && (
        <div className="rounded-xl bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">
          Could not load machines: {error}. Retrying automatically.
        </div>
      )}

      {rows === null ? (
        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
          {[0, 1, 2].map((i) => (
            <div key={i} className="gloss rounded-2xl p-5 h-44 animate-pulse" />
          ))}
        </div>
      ) : rows.length === 0 ? (
        <div className="gloss rounded-2xl p-10 text-center">
          <h2 className="font-display text-lg font-bold">No machines yet</h2>
          <p className="mt-2 text-sm text-black/55 max-w-md mx-auto">
            Your machines register themselves automatically once the factory collector is running. If it is
            installed and this stays empty, call us.
          </p>
        </div>
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
          {rows.map((r) => (
            <MachineCard key={r.machine_id} row={r} nowMs={nowMs} onConfirm={setConfirming} onMap={setMapping} />
          ))}
        </div>
      )}

      {confirming && (
        <ConfirmOutputDialog
          orgId={orgId}
          machine={confirming}
          productId={confirming.product_id}
          suggestedGood={goodParts(confirming)}
          suggestedScrap={Math.round(confirming.today_scrap)}
          open
          onClose={() => setConfirming(null)}
          onDone={load}
        />
      )}
      {mapping && (
        <MapCraftDialog orgId={orgId} machine={mapping} open onClose={() => setMapping(null)} onDone={load} />
      )}
      {recording && (
        <RecordEventDialog orgId={orgId} open onClose={() => setRecording(false)} onDone={load} />
      )}
    </div>
  );
}
