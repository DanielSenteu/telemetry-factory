// sync-zoho-books — the Zoho ADAPTER.
//
// This is the only file in the system that knows what a "Zoho" is. It handles
// OAuth refresh, pagination and field names, then hands the database a
// NORMALISED document via ingest_external_document(). The schema, the mapping
// and the demand views (migrations 51/52) never learn the vendor's vocabulary,
// which is why a second provider costs one more file like this and zero
// migrations.
//
// WHAT THE LIVE API ACTUALLY DOES (probed 2026-08-15, org 823632753 — every one
// of these was tested, not assumed):
//   • The invoice LIST does not include line_items. Line-level demand — the
//     entire point of this integration — needs one detail call PER INVOICE.
//     24,076 of them for a full backfill.
//   • last_modified_time= is an EXACT match, not "since". last_modified_time_start=
//     is silently ignored (a 2027 cutoff still returns a full page). Neither is
//     usable as an incremental filter.
//   • sort_column=last_modified_time DOES work. So incremental sync pages
//     newest-modified first and stops at the cursor — no filter needed.
//   • Rate limit is ~50,000 calls per ~19h window (x-rate-limit-remaining), so a
//     24k backfill fits inside one window, but only just once a day.
//
// WHY THIS IS RESUMABLE RATHER THAN ONE BIG RUN: an edge function has a wall
// clock measured in minutes and the backfill needs tens of thousands of calls.
// Each invocation does a BOUNDED slice, records where it got to, and returns
// { done: false } until there is nothing left. The caller (a button, or cron)
// simply calls again. Crash-safety falls out of the same design — every
// document is upserted idempotently, so a retried slice costs time, never
// correctness.
//
// Deploy:
//   supabase functions deploy sync-zoho-books
//   supabase secrets set ZOHO_CLIENT_ID=... ZOHO_CLIENT_SECRET=... ZOHO_REFRESH_TOKEN=...
//
// Multi-org note: the refresh token is read from ZOHO_REFRESH_TOKEN_<org_id>
// first, falling back to ZOHO_REFRESH_TOKEN. That keeps credentials out of the
// database (an admin-readable OAuth token is a leak waiting to happen) while
// still supporting more than one org. Supabase Vault is the upgrade path when
// the number of orgs makes named secrets unwieldy.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PROVIDER = "zoho_books";
const PAGE_SIZE = 200;
const DETAIL_CONCURRENCY = 6;      // polite; the quota is per-window, not per-second
const DEFAULT_MAX_DOCS = 400;      // per invocation — tuned to the edge wall clock
const RATE_LIMIT_FLOOR = 500;      // stop early rather than exhaust the org's quota

interface ZohoInvoiceSummary {
  invoice_id: string;
  invoice_number?: string;
  date?: string;
  last_modified_time?: string;
  customer_id?: string;
  status?: string;
  total?: number;
  balance?: number;
}

interface ZohoLineItem {
  line_item_id?: string;
  item_id?: string;
  name?: string;
  description?: string;
  quantity?: number;
  rate?: number;
  item_total?: number;
}

// The detail response carries ~150 fields; we name the dozen we read and keep
// the rest as unknown — the whole object is stored as payload regardless, so we
// never need to have anticipated a field to keep it.
interface ZohoInvoiceDetail extends ZohoInvoiceSummary {
  line_items?: ZohoLineItem[];
  [key: string]: unknown;
}

// The browser calls this from the admin app, so every response needs CORS
// headers and the preflight needs answering — without them the request never
// leaves the browser and surfaces only as "Failed to send a request to the Edge
// Function", which says nothing about the actual cause.
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-cron-secret",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// The SERVER-BASED OAuth app — ours, one for all customers. Per-connection
// data centre (accounts server + api domain) comes from the connection config,
// not env, so factories on .eu/.in/.com all work through the same function.
const OAUTH_CLIENT_ID = Deno.env.get("ZOHO_OAUTH_CLIENT_ID") ?? Deno.env.get("ZOHO_CLIENT_ID")!;
const OAUTH_CLIENT_SECRET = Deno.env.get("ZOHO_OAUTH_CLIENT_SECRET") ?? Deno.env.get("ZOHO_CLIENT_SECRET")!;

type Conn = {
  id: number;
  org_id: number;
  external_org_id: string;
  config: Record<string, unknown>;
  cursor_modified_at: string | null;
  backfill_done: boolean;
  active: boolean;
};

/** Per-connection rate context — cron syncs many connections; a module-level
 *  counter would let one org's quota gate another's. */
type Rate = { remaining: number };

async function getAccessToken(refreshToken: string, accountsServer: string): Promise<string> {
  const res = await fetch(`${accountsServer}/oauth/v2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: OAUTH_CLIENT_ID,
      client_secret: OAUTH_CLIENT_SECRET,
      grant_type: "refresh_token",
      refresh_token: refreshToken,
    }),
  });
  const body = await res.json();
  if (!body.access_token) throw new Error(`token refresh failed: ${body.error ?? res.status}`);
  return body.access_token as string;
}

async function zohoGet(
  apiDomain: string,
  path: string,
  params: Record<string, string>,
  token: string,
  zohoOrg: string,
  rate: Rate,
): Promise<Record<string, unknown>> {
  const qs = new URLSearchParams({ organization_id: zohoOrg, ...params });
  const res = await fetch(`${apiDomain}/books/v3/${path}?${qs}`, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` },
  });
  const remaining = res.headers.get("x-rate-limit-remaining");
  if (remaining) rate.remaining = Number(remaining);
  if (res.status === 429) throw new Error("zoho rate limit hit (429)");
  const body = await res.json();
  if (body.code && body.code !== 0) throw new Error(`zoho ${body.code}: ${body.message}`);
  return body;
}

async function pooled<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let cursor = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const i = cursor++;
      out[i] = await fn(items[i]);
    }
  });
  await Promise.all(workers);
  return out;
}

/** Zoho's shape → the generic shape the spine speaks. The ONLY place field
 *  names are translated. item_total is net of tax on inclusive-tax invoices,
 *  which is what we want for demand revenue. */
function normalise(detail: ZohoInvoiceDetail) {
  const lines = (detail.line_items ?? []) as ZohoLineItem[];
  return {
    doc: {
      external_id: String(detail.invoice_id),
      external_number: detail.invoice_number ?? null,
      doc_date: detail.date ?? null,
      external_modified_at: detail.last_modified_time ?? null,
      customer_external_id: detail.customer_id ? String(detail.customer_id) : null,
      total: detail.total ?? null,
      balance: detail.balance ?? null,
      external_status: detail.status ?? null,
      payload: detail,
    },
    lines: lines.map((li, i) => ({
      line_index: i,
      external_line_id: li.line_item_id ? String(li.line_item_id) : null,
      external_item_id: li.item_id ? String(li.item_id) : null,
      description: li.name ?? li.description ?? null,
      quantity: li.quantity ?? 0,
      unit_price: li.rate ?? null,
      line_total: li.item_total ?? null,
    })),
  };
}

/** Sync one connection. Returns a per-connection summary; never throws — a
 *  failure is recorded on that connection and the cron loop moves on. */
// deno-lint-ignore no-explicit-any
async function syncConnection(supabase: any, conn: Conn, mode: "backfill" | "incremental", maxDocs: number) {
  const config = conn.config ?? {};
  const accountsServer = (config.accounts_server as string) ?? "https://accounts.zoho.com";
  const apiDomain = (config.api_domain as string) ?? "https://www.zohoapis.com";
  const zohoOrg = String(conn.external_org_id);
  const rate: Rate = { remaining: Number.POSITIVE_INFINITY };

  let processed = 0;
  let done = false;
  let newestModified: string | null = conn.cursor_modified_at ?? null;
  let backfillPage = Number(config.backfill_page ?? 1);
  let incrementalPage = 1;

  const cursorMs = conn.cursor_modified_at ? Date.parse(conn.cursor_modified_at) : null;
  const isNewer = (t?: string | null) =>
    !!t && (cursorMs === null || Number.isNaN(cursorMs) || Date.parse(t) > cursorMs);

  try {
    // The token is read from Vault (service role only) — never from env.
    const { data: refreshToken, error: secErr } = await supabase.rpc("read_integration_secret", {
      p_connection_id: conn.id,
    });
    if (secErr) throw new Error(`could not read token: ${secErr.message}`);
    if (!refreshToken) throw new Error("no stored token — reconnect needed");

    const token = await getAccessToken(refreshToken, accountsServer);

    while (processed < maxDocs && rate.remaining > RATE_LIMIT_FLOOR) {
      const params = mode === "backfill"
        ? { per_page: String(PAGE_SIZE), page: String(backfillPage), sort_column: "date", sort_order: "A" }
        : { per_page: String(PAGE_SIZE), page: String(incrementalPage), sort_column: "last_modified_time", sort_order: "D" };

      const list = await zohoGet(apiDomain, "invoices", params, token, zohoOrg, rate);
      const summaries = (list.invoices ?? []) as ZohoInvoiceSummary[];
      if (summaries.length === 0) { done = true; break; }

      const fresh = mode === "incremental" ? summaries.filter((s) => isNewer(s.last_modified_time)) : summaries;
      const slice = fresh.slice(0, maxDocs - processed);

      const details = await pooled(slice, DETAIL_CONCURRENCY, async (s) => {
        const d = await zohoGet(apiDomain, `invoices/${s.invoice_id}`, {}, token, zohoOrg, rate);
        return d.invoice as ZohoInvoiceDetail;
      });

      for (const detail of details) {
        if (!detail) continue;
        const { doc, lines } = normalise(detail);
        const { error } = await supabase.rpc("ingest_external_document", {
          p_org_id: conn.org_id,
          p_connection_id: conn.id,
          p_source_system: PROVIDER,
          p_doc: doc,
          p_lines: lines,
        });
        if (error) throw new Error(`ingest failed for ${doc.external_number}: ${error.message}`);
        processed += 1;
        if (doc.external_modified_at && (!newestModified || doc.external_modified_at > newestModified)) {
          newestModified = doc.external_modified_at;
        }
      }

      if (mode === "backfill") {
        backfillPage += 1;
        if (summaries.length < PAGE_SIZE) done = true;
      } else {
        if (fresh.length < summaries.length || summaries.length < PAGE_SIZE) done = true;
        else incrementalPage += 1;
      }
      if (done) break;
    }

    await supabase.from("integration_connections").update({
      cursor_modified_at: mode === "incremental" && done ? newestModified : conn.cursor_modified_at,
      backfill_done: mode === "backfill" ? done : conn.backfill_done,
      config: { ...config, backfill_page: backfillPage },
      last_sync_at: new Date().toISOString(),
      last_sync_status: done ? "ok" : "partial",
      last_sync_error: null,
    }).eq("id", conn.id);

    return { connection_id: conn.id, org_id: conn.org_id, mode, processed, done, rate_remaining: Number.isFinite(rate.remaining) ? rate.remaining : null };
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    await supabase.from("integration_connections").update({
      last_sync_at: new Date().toISOString(),
      last_sync_status: "error",
      last_sync_error: message,
      config: { ...config, backfill_page: backfillPage },
    }).eq("id", conn.id);
    return { connection_id: conn.id, org_id: conn.org_id, mode, processed, error: message };
  }
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  let body: { connection_id?: number; org_id?: number; mode?: string; max_docs?: number };
  try { body = await req.json(); } catch { return json({ error: "body must be JSON" }, 400); }

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // ── auth ──────────────────────────────────────────────────────────────
  // Cron carries the shared secret and may sync ALL connections. A human must
  // prove admin of the specific org/connection they name.
  const cronSecret = Deno.env.get("SYNC_CRON_SECRET");
  const isCron = !!cronSecret && req.headers.get("x-cron-secret") === cronSecret;

  const mode = body.mode === "backfill" ? "backfill" : "incremental";
  const maxDocs = Math.max(1, Math.min(body.max_docs ?? DEFAULT_MAX_DOCS, 2000));

  // ── resolve which connections to sync ─────────────────────────────────
  let conns: Conn[] = [];
  const sel = "id, org_id, external_org_id, config, cursor_modified_at, backfill_done, active";

  if (body.connection_id || body.org_id) {
    let q = supabase.from("integration_connections").select(sel).eq("provider", PROVIDER).eq("active", true);
    q = body.connection_id ? q.eq("id", body.connection_id) : q.eq("org_id", body.org_id);
    const { data, error } = await q.maybeSingle();
    if (error) return json({ error: `could not read connection: ${error.message}` }, 500);
    if (!data) return json({ error: "no active connection found" }, 404);

    if (!isCron) {
      const authHeader = req.headers.get("Authorization");
      if (!authHeader) return json({ error: "missing Authorization" }, 401);
      const asUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
        global: { headers: { Authorization: authHeader } },
      });
      const { data: isAdmin, error: adminErr } = await asUser.rpc("is_org_admin", { p_org_id: data.org_id });
      if (adminErr || !isAdmin) return json({ error: "not an admin of this org" }, 403);
    }
    conns = [data as Conn];
  } else if (isCron) {
    // Cron with no target = every active connection, incremental. Connections
    // still backfilling continue their backfill on this same tick.
    const { data, error } = await supabase.from("integration_connections").select(sel).eq("provider", PROVIDER).eq("active", true);
    if (error) return json({ error: `could not list connections: ${error.message}` }, 500);
    conns = (data ?? []) as Conn[];
  } else {
    return json({ error: "connection_id or org_id required" }, 400);
  }

  // ── run ───────────────────────────────────────────────────────────────
  const results = [];
  for (const conn of conns) {
    // A connection mid-backfill keeps backfilling even under the cron's
    // incremental default, until its history is fully in.
    const effectiveMode = mode === "backfill" || conn.backfill_done === false ? "backfill" : "incremental";
    results.push(await syncConnection(supabase, conn, effectiveMode as "backfill" | "incremental", maxDocs));
  }

  return json({ synced: results.length, results });
});
