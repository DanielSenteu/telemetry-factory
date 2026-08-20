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

const ACCOUNTS = Deno.env.get("ZOHO_ACCOUNTS_DOMAIN") ?? "https://accounts.zoho.com";
const API = Deno.env.get("ZOHO_API_DOMAIN") ?? "https://www.zohoapis.com";

/** Access tokens live an hour; we mint a fresh one per invocation and never store it. */
async function getAccessToken(orgId: number): Promise<string> {
  const refresh =
    Deno.env.get(`ZOHO_REFRESH_TOKEN_${orgId}`) ?? Deno.env.get("ZOHO_REFRESH_TOKEN");
  if (!refresh) throw new Error(`no Zoho refresh token configured for org ${orgId}`);

  const res = await fetch(`${ACCOUNTS}/oauth/v2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: Deno.env.get("ZOHO_CLIENT_ID")!,
      client_secret: Deno.env.get("ZOHO_CLIENT_SECRET")!,
      grant_type: "refresh_token",
      refresh_token: refresh,
    }),
  });
  const body = await res.json();
  // Zoho answers 200 with an {error} body rather than an HTTP error status.
  if (!body.access_token) throw new Error(`token refresh failed: ${body.error ?? res.status}`);
  return body.access_token as string;
}

let rateRemaining = Number.POSITIVE_INFINITY;

async function zohoGet(
  path: string,
  params: Record<string, string>,
  token: string,
  orgId: string,
): Promise<Record<string, unknown>> {
  const qs = new URLSearchParams({ organization_id: orgId, ...params });
  const res = await fetch(`${API}/books/v3/${path}?${qs}`, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` },
  });

  const remaining = res.headers.get("x-rate-limit-remaining");
  if (remaining) rateRemaining = Number(remaining);

  if (res.status === 429) throw new Error("zoho rate limit hit (429)");
  const body = await res.json();
  if (body.code && body.code !== 0) throw new Error(`zoho ${body.code}: ${body.message}`);
  return body;
}

/** Bounded-concurrency map — plain, because a dependency for this would be silly. */
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
 *  names are translated. Note item_total is net of tax on inclusive-tax
 *  invoices, which is what we want for demand revenue. */
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

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  let body: { org_id?: number; mode?: string; max_docs?: number };
  try {
    body = await req.json();
  } catch {
    return json({ error: "body must be JSON" }, 400);
  }
  const orgId = Number(body.org_id);
  if (!Number.isInteger(orgId)) return json({ error: "org_id required" }, 400);

  // ── auth: an org admin's JWT, or the cron shared secret ───────────────
  // Cron has no user to be, so it carries a secret instead. Everything else
  // must prove admin membership of the org it is asking us to sync.
  const cronSecret = Deno.env.get("SYNC_CRON_SECRET");
  const isCron = cronSecret && req.headers.get("x-cron-secret") === cronSecret;

  if (!isCron) {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "missing Authorization" }, 401);
    const asUser = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: isAdmin, error } = await asUser.rpc("is_org_admin", { p_org_id: orgId });
    if (error || !isAdmin) return json({ error: "not an admin of this org" }, 403);
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: conn, error: connError } = await supabase
    .from("integration_connections")
    .select("id, org_id, external_org_id, config, cursor_modified_at, active")
    .eq("org_id", orgId)
    .eq("provider", PROVIDER)
    .maybeSingle();

  // Distinguish "no such row" from "could not reach the database" — swallowing
  // the error makes a misconfigured service key look exactly like a missing
  // connection, which is a genuinely confusing hour to spend.
  if (connError) {
    return json({ error: `could not read connection: ${connError.message}` }, 500);
  }
  if (!conn) return json({ error: `no ${PROVIDER} connection for org ${orgId}` }, 404);
  if (!conn.active) return json({ error: "connection is inactive" }, 409);
  if (!conn.external_org_id) return json({ error: "connection has no external_org_id" }, 409);

  const mode = body.mode === "backfill" ? "backfill" : "incremental";
  const maxDocs = Math.max(1, Math.min(body.max_docs ?? DEFAULT_MAX_DOCS, 2000));
  const zohoOrg = String(conn.external_org_id);
  const config = (conn.config ?? {}) as Record<string, unknown>;

  let processed = 0;
  let done = false;
  let newestModified: string | null = conn.cursor_modified_at ?? null;
  let backfillPage = Number(config.backfill_page ?? 1);
  let incrementalPage = 1;

  // Postgres hands the cursor back as ...T13:33:54+00:00 while Zoho stamps
  // ...T16:33:54+0300 — the same instant, but string comparison would call the
  // Zoho one "newer" forever. Compare epoch milliseconds, never text.
  const cursorMs = conn.cursor_modified_at ? Date.parse(conn.cursor_modified_at) : null;
  const isNewer = (t?: string | null) =>
    !!t && (cursorMs === null || Number.isNaN(cursorMs) || Date.parse(t) > cursorMs);

  try {
    const token = await getAccessToken(orgId);

    while (processed < maxDocs && rateRemaining > RATE_LIMIT_FLOOR) {
      // Backfill sorts by date ASCENDING so that invoices created during a
      // multi-hour run append at the end instead of shifting the pages we have
      // not read yet. Incremental sorts by last_modified_time DESCENDING and
      // stops as soon as it reaches something we already have.
      const params = mode === "backfill"
        ? {
          per_page: String(PAGE_SIZE),
          page: String(backfillPage),
          sort_column: "date",
          sort_order: "A",
        }
        : {
          per_page: String(PAGE_SIZE),
          page: String(incrementalPage),
          sort_column: "last_modified_time",
          sort_order: "D",
        };

      const list = await zohoGet("invoices", params, token, zohoOrg);
      const summaries = (list.invoices ?? []) as ZohoInvoiceSummary[];
      if (summaries.length === 0) {
        done = true;
        break;
      }

      // Incremental: everything at or before the cursor is already ours. Sorted
      // newest-modified first, so the first page that yields nothing fresh means
      // we have caught up — anything further back is older still.
      const fresh = mode === "incremental"
        ? summaries.filter((s) => isNewer(s.last_modified_time))
        : summaries;

      const slice = fresh.slice(0, maxDocs - processed);

      // The expensive part: line items only exist on the detail endpoint.
      const details = await pooled(slice, DETAIL_CONCURRENCY, async (s) => {
        const d = await zohoGet(`invoices/${s.invoice_id}`, {}, token, zohoOrg);
        return d.invoice as ZohoInvoiceDetail;
      });

      for (const detail of details) {
        if (!detail) continue;
        const { doc, lines } = normalise(detail);
        const { error } = await supabase.rpc("ingest_external_document", {
          p_org_id: orgId,
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
        if (summaries.length < PAGE_SIZE) done = true;   // last page
      } else {
        // Caught up as soon as a page contains anything we already had, or the
        // provider ran out of pages. Otherwise walk further back in time.
        if (fresh.length < summaries.length || summaries.length < PAGE_SIZE) done = true;
        else incrementalPage += 1;
      }
      if (done) break;
    }

    await supabase
      .from("integration_connections")
      .update({
        // The cursor only advances on a clean slice. A crash mid-run means we
        // re-read a little next time, which is free (unchanged documents are
        // no-ops) and far better than skipping.
        cursor_modified_at: mode === "incremental" && done ? newestModified : conn.cursor_modified_at,
        config: { ...config, backfill_page: backfillPage, backfill_done: mode === "backfill" ? done : config.backfill_done },
        last_sync_at: new Date().toISOString(),
        last_sync_status: done ? "ok" : "partial",
        last_sync_error: null,
      })
      .eq("id", conn.id);

    return json({
      mode,
      processed,
      done,
      backfill_page: backfillPage,
      rate_limit_remaining: Number.isFinite(rateRemaining) ? rateRemaining : null,
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    await supabase
      .from("integration_connections")
      .update({
        last_sync_at: new Date().toISOString(),
        last_sync_status: "error",
        last_sync_error: message,
        // Partial progress is still progress: keep the page we reached.
        config: { ...config, backfill_page: backfillPage },
      })
      .eq("id", conn.id);
    return json({ error: message, processed }, 502);
  }
});
