// Disk-backed queue for readings awaiting cloud delivery.
//
// The boxes have no HistoryRead — anything we drop is gone forever — so every
// reading hits disk BEFORE we try the network. Segment design:
//
//   queue/current.ndjson          ← writer appends here
//   queue/seg-<ms>-<seq>.ndjson   ← sealed segments, shipped oldest-first
//
// The shipper seals `current`, POSTs whole segments, and deletes each segment
// only after the server acknowledges it. A crash between POST and delete means
// the segment is sent again — that's fine, delivery is at-least-once and the
// server dedupes on (machine_id, observed_at).

import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
} from "node:fs";
import { join } from "node:path";

export class DiskQueue {
  private seq = 0;
  private currentLines = 0;

  constructor(private dir: string, private maxSegmentLines = 500) {
    mkdirSync(dir, { recursive: true });
    // A current.ndjson left over from a crashed run: seal it so it ships.
    this.rotate();
  }

  private currentPath(): string {
    return join(this.dir, "current.ndjson");
  }

  append(obj: unknown): void {
    appendFileSync(this.currentPath(), JSON.stringify(obj) + "\n");
    this.currentLines += 1;
    if (this.currentLines >= this.maxSegmentLines) this.rotate();
  }

  /** Seal current.ndjson into an immutable segment (no-op if empty). */
  rotate(): void {
    const cur = this.currentPath();
    if (!existsSync(cur) || statSync(cur).size === 0) {
      this.currentLines = 0;
      return;
    }
    // Date.now() is 13 digits until the year 2286, so lexicographic sort = age
    // order; seq breaks ties within one process, and across restarts the
    // millisecond clock has moved on.
    const name = `seg-${Date.now()}-${String(this.seq++).padStart(6, "0")}.ndjson`;
    renameSync(cur, join(this.dir, name));
    this.currentLines = 0;
  }

  /** Absolute paths of sealed segments, oldest first. */
  segments(): string[] {
    return readdirSync(this.dir)
      .filter((f) => f.startsWith("seg-") && f.endsWith(".ndjson"))
      .sort()
      .map((f) => join(this.dir, f));
  }

  readSegment(path: string): unknown[] {
    return readFileSync(path, "utf-8")
      .split("\n")
      .filter((l) => l.trim().length > 0)
      .map((l) => JSON.parse(l));
  }

  deleteSegment(path: string): void {
    rmSync(path, { force: true });
  }
}
