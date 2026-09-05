"use client";

import { useCallback, useEffect, useState } from "react";
import { field } from "@/components/app/modal";
import { nairobiDateString } from "@/lib/services/machines";
import { getVarianceReport, type VarianceLine } from "@/lib/services/production";

// The floor grades the system's counting, daily. Each line is a machine +
// product pair: what the system counted vs what the floor said. The main act
// is the day's PDF — one professional document for the whole floor.

const WARN_ERROR_PCT = 2; // amber above this; tune after real days

function fmtPct(n: number) {
  return `${Number(n).toLocaleString(undefined, { maximumFractionDigits: 2 })}%`;
}

/** Day totals: overall error weighted by the floor's units. */
function summarize(lines: VarianceLine[]) {
  const floorTotal = lines.reduce((a, l) => a + Number(l.floor_qty), 0);
  const absDiff = lines.reduce((a, l) => a + Math.abs(Number(l.diff)), 0);
  const errorPct = floorTotal > 0 ? (absDiff / floorTotal) * 100 : 0;
  return {
    floorTotal,
    systemTotal: lines.reduce((a, l) => a + Number(l.system_qty), 0),
    errorPct,
    accuracyPct: Math.max(0, 100 - errorPct),
    checked: lines.length,
    flagged: lines.filter((l) => Number(l.error_pct) > WARN_ERROR_PCT).length,
  };
}

async function downloadPdf(day: string, lines: VarianceLine[]) {
  const { default: jsPDF } = await import("jspdf");
  const { default: autoTable } = await import("jspdf-autotable");
  const s = summarize(lines);
  const doc = new jsPDF();

  doc.setFont("helvetica", "bold");
  doc.setFontSize(18);
  doc.text("Industrial-Sync", 14, 18);
  doc.setFontSize(13);
  doc.text("Daily Production Variance Report", 14, 27);
  doc.setFont("helvetica", "normal");
  doc.setFontSize(10);
  doc.setTextColor(110);
  doc.text(`Day: ${day}    Generated: ${new Date().toLocaleString("en-KE", { timeZone: "Africa/Nairobi" })}`, 14, 34);

  doc.setTextColor(0);
  doc.setFontSize(11);
  doc.text(
    `Floor-verified accuracy: ${fmtPct(s.accuracyPct)}    Lines checked: ${s.checked}    ` +
      `System total: ${s.systemTotal.toLocaleString()}    Floor total: ${s.floorTotal.toLocaleString()}    Flagged: ${s.flagged}`,
    14,
    43
  );

  // Grouped by machine — product and machine stay together as the pairs they ran as.
  const machines = [...new Map(lines.map((l) => [l.machine_id, l.machine_name])).entries()];
  let y = 50;
  for (const [machineId, machineName] of machines) {
    const rows = lines.filter((l) => l.machine_id === machineId);
    autoTable(doc, {
      startY: y,
      head: [[machineName, "System", "Floor", "Difference", "Error", "Accuracy", ""]],
      body: rows.map((l) => [
        l.product_name,
        Number(l.system_qty).toLocaleString(),
        Number(l.floor_qty).toLocaleString(),
        Number(l.diff) === 0 ? "0" : Number(l.diff) > 0 ? `+${Number(l.diff).toLocaleString()}` : Number(l.diff).toLocaleString(),
        fmtPct(l.error_pct),
        fmtPct(l.accuracy_pct),
        Number(l.error_pct) > WARN_ERROR_PCT ? "CHECK" : "OK",
      ]),
      styles: { fontSize: 9 },
      headStyles: { fillColor: [26, 23, 18], fontSize: 9 },
      didParseCell: (data) => {
        if (data.section === "body" && Number(rows[data.row.index]?.error_pct) > WARN_ERROR_PCT) {
          data.cell.styles.fillColor = [253, 243, 224];
        }
      },
    });
    y = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 6;
  }

  doc.setFontSize(8);
  doc.setTextColor(130);
  const pages = doc.getNumberOfPages();
  for (let i = 1; i <= pages; i++) {
    doc.setPage(i);
    doc.text(
      `Every number is traceable to the machine event that produced it.  ·  Page ${i} of ${pages}`,
      14,
      doc.internal.pageSize.getHeight() - 8
    );
  }

  doc.save(`variance-report-${day}.pdf`);
}

export function VarianceReports({ orgId }: { orgId: number }) {
  const [day, setDay] = useState(nairobiDateString());
  const [lines, setLines] = useState<VarianceLine[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setLines(await getVarianceReport(orgId, day, day));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [orgId, day]);

  useEffect(() => {
    let gone = false;
    Promise.resolve().then(() => { if (!gone) load(); });
    return () => { gone = true; };
  }, [load]);

  const s = lines ? summarize(lines) : null;
  const machines = lines ? [...new Map(lines.map((l) => [l.machine_id, l.machine_name])).entries()] : [];

  return (
    <div className="flex flex-col gap-5">
      <div className="flex items-center gap-3 flex-wrap">
        <div>
          <h1 className="font-display text-2xl font-bold">Variance reports</h1>
          <p className="mt-1 text-sm text-black/55 max-w-lg">
            What the system counted vs what the floor confirmed — per machine, per product, every day.
          </p>
        </div>
        <div className="ml-auto flex items-center gap-3">
          <input type="date" className={field + " w-44"} value={day} onChange={(e) => setDay(e.target.value)} />
          <button
            onClick={() => lines && lines.length > 0 && downloadPdf(day, lines)}
            disabled={!lines || lines.length === 0}
            className="h-11 px-4 rounded-lg bg-[var(--ink)] text-white text-sm font-semibold hover:bg-black transition-colors disabled:opacity-40"
          >
            Download PDF
          </button>
        </div>
      </div>

      {error && <div className="rounded-xl bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">{error}</div>}

      {s && lines && lines.length > 0 && (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          {[
            { label: "Floor-verified accuracy", value: fmtPct(s.accuracyPct) },
            { label: "Lines checked", value: String(s.checked) },
            { label: "System vs floor units", value: `${s.systemTotal.toLocaleString()} / ${s.floorTotal.toLocaleString()}` },
            { label: `Lines over ${WARN_ERROR_PCT}% error`, value: String(s.flagged) },
          ].map((t) => (
            <div key={t.label} className="gloss rounded-2xl px-5 py-4">
              <div className="font-mono text-xl md:text-2xl font-semibold tabular-nums">{t.value}</div>
              <div className="mt-0.5 text-xs md:text-sm text-black/50">{t.label}</div>
            </div>
          ))}
        </div>
      )}

      {lines === null ? (
        <div className="gloss rounded-2xl h-40 animate-pulse" />
      ) : lines.length === 0 ? (
        <div className="gloss rounded-2xl p-10 text-center">
          <h2 className="font-display text-lg font-bold">No confirmations on this day</h2>
          <p className="mt-2 text-sm text-black/55 max-w-md mx-auto">
            Variance lines appear as machines confirm their output — each confirmation records what the
            system counted next to what the floor said.
          </p>
        </div>
      ) : (
        machines.map(([machineId, machineName]) => {
          const rows = lines.filter((l) => l.machine_id === machineId);
          return (
            <section key={machineId} className="flex flex-col gap-2">
              <h2 className="font-display text-lg font-bold">{machineName}</h2>
              <div className="gloss rounded-2xl overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="text-left text-xs font-mono text-black/45 uppercase tracking-wider">
                      <th className="px-5 py-3">Product</th>
                      <th className="px-5 py-3 text-right">System</th>
                      <th className="px-5 py-3 text-right">Floor</th>
                      <th className="px-5 py-3 text-right">Difference</th>
                      <th className="px-5 py-3 text-right">Error</th>
                      <th className="px-5 py-3 text-right">Accuracy</th>
                    </tr>
                  </thead>
                  <tbody>
                    {rows.map((l, i) => {
                      const warn = Number(l.error_pct) > WARN_ERROR_PCT;
                      return (
                        <tr key={i} className={`border-t border-black/5 ${warn ? "bg-amber-50" : ""}`}>
                          <td className="px-5 py-3 font-medium">{l.product_name}</td>
                          <td className="px-5 py-3 text-right font-mono tabular-nums">{Number(l.system_qty).toLocaleString()}</td>
                          <td className="px-5 py-3 text-right font-mono tabular-nums">{Number(l.floor_qty).toLocaleString()}</td>
                          <td className={`px-5 py-3 text-right font-mono tabular-nums ${Number(l.diff) !== 0 ? "text-amber-700 font-semibold" : "text-black/45"}`}>
                            {Number(l.diff) > 0 ? "+" : ""}{Number(l.diff).toLocaleString()}
                          </td>
                          <td className="px-5 py-3 text-right font-mono tabular-nums">{fmtPct(l.error_pct)}</td>
                          <td className={`px-5 py-3 text-right font-mono tabular-nums font-semibold ${warn ? "text-amber-700" : "text-[var(--accent)]"}`}>
                            {fmtPct(l.accuracy_pct)}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </section>
          );
        })
      )}
    </div>
  );
}
