import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DiskQueue } from "./queue.js";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "fa-queue-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe("DiskQueue", () => {
  it("appends, seals, and reads back in order", () => {
    const q = new DiskQueue(dir);
    q.append({ n: 1 });
    q.append({ n: 2 });
    expect(q.segments()).toHaveLength(0); // nothing sealed yet
    q.rotate();
    const segs = q.segments();
    expect(segs).toHaveLength(1);
    expect(q.readSegment(segs[0]!)).toEqual([{ n: 1 }, { n: 2 }]);
  });

  it("auto-rotates when a segment fills up", () => {
    const q = new DiskQueue(dir, 2);
    q.append({ n: 1 });
    q.append({ n: 2 }); // hits maxSegmentLines
    q.append({ n: 3 });
    expect(q.segments()).toHaveLength(1);
    q.rotate();
    expect(q.segments()).toHaveLength(2);
  });

  it("ships oldest segment first", () => {
    const q = new DiskQueue(dir, 1);
    q.append({ n: 1 });
    q.append({ n: 2 });
    q.append({ n: 3 });
    const all = q.segments().flatMap((s) => q.readSegment(s));
    expect(all).toEqual([{ n: 1 }, { n: 2 }, { n: 3 }]);
  });

  it("survives a restart: leftover current.ndjson gets sealed", () => {
    // simulate a crashed run that left an unsealed current file
    writeFileSync(join(dir, "current.ndjson"), JSON.stringify({ n: 99 }) + "\n");
    const q = new DiskQueue(dir);
    const segs = q.segments();
    expect(segs).toHaveLength(1);
    expect(q.readSegment(segs[0]!)).toEqual([{ n: 99 }]);
  });

  it("deleteSegment removes only the acked segment", () => {
    const q = new DiskQueue(dir, 1);
    q.append({ n: 1 });
    q.append({ n: 2 });
    const [first, second] = q.segments();
    q.deleteSegment(first!);
    expect(q.segments()).toEqual([second]);
  });

  it("rotate on empty queue is a no-op", () => {
    const q = new DiskQueue(dir);
    q.rotate();
    q.rotate();
    expect(q.segments()).toHaveLength(0);
  });
});
