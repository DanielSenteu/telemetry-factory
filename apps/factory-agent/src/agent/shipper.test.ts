import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DiskQueue } from "../lib/queue.js";
import { Shipper } from "./shipper.js";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "fa-ship-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

const OPTS = { cloudUrl: "https://cloud.test/ingest", agentToken: "tok" };

function ok(): Response {
  return new Response("{}", { status: 200 });
}

describe("Shipper", () => {
  it("posts sealed segments oldest-first and deletes on ack", async () => {
    const q = new DiskQueue(dir, 1);
    q.append({ n: 1 });
    q.append({ n: 2 });
    const fetchFn = vi.fn().mockResolvedValue(ok());
    const shipper = new Shipper(q, { ...OPTS, fetchFn });

    const acked = await shipper.flushOnce();

    expect(acked).toBe(2);
    expect(q.segments()).toHaveLength(0);
    expect(fetchFn).toHaveBeenCalledTimes(2);
    const bodies = fetchFn.mock.calls.map((c) => JSON.parse(c[1].body).readings[0].n);
    expect(bodies).toEqual([1, 2]);
    const [, init] = fetchFn.mock.calls[0]!;
    expect(init.headers["x-agent-token"]).toBe("tok");
  });

  it("seals the current file as part of the flush", async () => {
    const q = new DiskQueue(dir);
    q.append({ n: 1 }); // still in current.ndjson
    const fetchFn = vi.fn().mockResolvedValue(ok());
    const acked = await new Shipper(q, { ...OPTS, fetchFn }).flushOnce();
    expect(acked).toBe(1);
  });

  it("keeps segments on failure and backs off, then resends", async () => {
    const q = new DiskQueue(dir, 1);
    q.append({ n: 1 });
    q.append({ n: 2 });
    const fetchFn = vi
      .fn()
      .mockResolvedValueOnce(new Response("nope", { status: 500 }))
      .mockResolvedValue(ok());
    const shipper = new Shipper(q, { ...OPTS, fetchFn });

    expect(await shipper.flushOnce()).toBe(0); // first pass fails, nothing lost
    expect(q.segments()).toHaveLength(2);

    expect(await shipper.flushOnce()).toBe(2); // retry delivers both, in order
    expect(q.segments()).toHaveLength(0);
  });

  it("network error (fetch rejects) is survivable", async () => {
    const q = new DiskQueue(dir, 1);
    q.append({ n: 1 });
    const fetchFn = vi.fn().mockRejectedValue(new Error("ECONNREFUSED"));
    expect(await new Shipper(q, { ...OPTS, fetchFn }).flushOnce()).toBe(0);
    expect(q.segments()).toHaveLength(1);
  });
});
