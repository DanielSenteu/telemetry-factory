"use client";

import type { TreeNode } from "@/lib/services/production";

// The production story, drawn: every made-here level under a product, all at
// once, from raw material to the sellable thing. Green means a step is fully
// described; amber marks what still needs filling in. Clicking a node selects
// it for editing below — the tree is the map, the editor cards are the pen.

function Chip({ tone, children }: { tone: "ok" | "warn" | "dim"; children: React.ReactNode }) {
  const cls =
    tone === "ok"
      ? "bg-[var(--accent)]/10 text-[var(--accent)]"
      : tone === "warn"
        ? "bg-amber-100 text-amber-800"
        : "bg-black/[0.05] text-black/55";
  return (
    <span className={`rounded px-2 py-0.5 text-[11px] font-mono font-semibold whitespace-nowrap ${cls}`}>
      {children}
    </span>
  );
}

function NodeCard({
  node,
  selected,
  onSelect,
}: {
  node: TreeNode;
  selected: boolean;
  onSelect: (id: number) => void;
}) {
  const isRoot = node.depth === 0;
  const needsMould = node.kind === "component" && (node.cavities == null || node.runner_weight_g == null);

  return (
    <button
      onClick={() => onSelect(node.product_id)}
      className={`w-full text-left gloss rounded-xl px-4 py-3 flex flex-col gap-1.5 transition-shadow ${
        selected ? "ring-2 ring-[var(--accent)]/60" : "hover:ring-1 hover:ring-black/15"
      }`}
    >
      <div className="flex items-center gap-2 flex-wrap">
        {!isRoot && node.link_qty != null && (
          <span className="font-mono text-sm text-black/45">
            {Number(node.link_qty).toLocaleString()}
            {Number(node.link_per_units) !== 1 ? ` / ${Number(node.link_per_units).toLocaleString()}` : ""} ×
          </span>
        )}
        <span className="font-display font-bold">{node.name}</span>
        {node.stage_name ? (
          <Chip tone="dim">made at: {node.stage_name}</Chip>
        ) : (
          <Chip tone="warn">⚠ no stage set</Chip>
        )}
        <span className="ml-auto flex gap-1.5 flex-wrap justify-end">
          {!node.has_recipe ? (
            <Chip tone="warn">⚠ no recipe yet</Chip>
          ) : (
            <Chip tone="ok">✓ recipe</Chip>
          )}
          {node.kind === "component" &&
            (needsMould ? (
              <Chip tone="warn">⚠ mould setup missing</Chip>
            ) : (
              <Chip tone="ok">
                ✓ {node.cavities} cav · {Number(node.runner_weight_g).toLocaleString()} g runner
              </Chip>
            ))}
        </span>
      </div>
      {node.material_lines.length > 0 && (
        <div className="flex flex-wrap gap-1.5">
          {node.material_lines.map((l, i) => (
            <span key={i} className="rounded bg-black/[0.04] px-2 py-0.5 text-[11px] font-mono text-black/55">
              {Number(l.qty).toLocaleString()} {l.uom}
              {Number(l.per_units) !== 1 ? ` / ${Number(l.per_units).toLocaleString()}` : ""} {l.name}
            </span>
          ))}
        </div>
      )}
    </button>
  );
}

function Branch({
  nodes,
  parentId,
  selectedId,
  onSelect,
}: {
  nodes: TreeNode[];
  parentId: number;
  selectedId: number | null;
  onSelect: (id: number) => void;
}) {
  const children = nodes.filter((n) => n.parent_product_id === parentId);
  if (children.length === 0) return null;
  return (
    <div className="ml-5 pl-4 border-l-2 border-black/10 flex flex-col gap-2 pt-2">
      {children.map((c) => (
        <div key={c.product_id}>
          <NodeCard node={c} selected={selectedId === c.product_id} onSelect={onSelect} />
          <Branch nodes={nodes} parentId={c.product_id} selectedId={selectedId} onSelect={onSelect} />
        </div>
      ))}
    </div>
  );
}

export function RecipeTree({
  nodes,
  selectedId,
  onSelect,
}: {
  nodes: TreeNode[];
  selectedId: number | null;
  onSelect: (id: number) => void;
}) {
  const root = nodes.find((n) => n.depth === 0);
  if (!root) return null;
  return (
    <div className="flex flex-col gap-2">
      <NodeCard node={root} selected={selectedId === root.product_id} onSelect={onSelect} />
      <Branch nodes={nodes} parentId={root.product_id} selectedId={selectedId} onSelect={onSelect} />
    </div>
  );
}
