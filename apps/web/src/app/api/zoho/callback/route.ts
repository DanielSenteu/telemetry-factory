import { NextResponse, type NextRequest } from "next/server";
import { cookies } from "next/headers";
import { createClient } from "@/lib/supabase/server";

// Step 2 of one-click connect. Zoho redirects the browser back here with a
// short-lived code. Server-side we: verify the state nonce, exchange the code
// for a permanent refresh token, discover the Zoho org id, create the
// connection, store the token in Vault (write-only), and fire the first sync
// immediately — all before the manager's page finishes loading.

const backTo = (req: NextRequest, q: string) => NextResponse.redirect(new URL(`/app/sales?${q}`, req.url));

export async function GET(request: NextRequest) {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const returnedState = url.searchParams.get("state");
  const errorParam = url.searchParams.get("error");
  // Zoho tells us the data centre; every API base follows from it.
  const location = (url.searchParams.get("location") || "us").toLowerCase();
  const accountsServer = url.searchParams.get("accounts-server") || "https://accounts.zoho.com";

  if (errorParam) return backTo(request, `error=${encodeURIComponent(errorParam)}`);
  if (!code) return backTo(request, "error=no_code");

  const cookieStore = await cookies();
  const savedState = cookieStore.get("zoho_oauth_state")?.value;
  cookieStore.delete("zoho_oauth_state");
  if (!savedState || savedState !== returnedState) return backTo(request, "error=state_mismatch");

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.redirect(new URL("/login", request.url));
  const { data: accounts } = await supabase.from("accounts").select("org_id").eq("user_id", user.id).limit(1);
  const orgId = accounts?.[0]?.org_id;
  if (!orgId) return backTo(request, "error=no_org");

  const clientId = process.env.ZOHO_OAUTH_CLIENT_ID;
  const clientSecret = process.env.ZOHO_OAUTH_CLIENT_SECRET;
  if (!clientId || !clientSecret) return backTo(request, "error=not_configured");

  const redirectUri = new URL("/api/zoho/callback", request.url).toString();

  // ── Exchange the code for tokens (server-side; the browser never sees them) ──
  const tokenRes = await fetch(`${accountsServer}/oauth/v2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: clientId,
      client_secret: clientSecret,
      redirect_uri: redirectUri,
      code,
    }),
  });
  const token = await tokenRes.json();
  if (!token.refresh_token) {
    // Zoho only returns a refresh token on the FIRST consent for a scope set.
    return backTo(request, `error=${encodeURIComponent(token.error || "no_refresh_token")}`);
  }
  const apiDomain: string = token.api_domain || "https://www.zohoapis.com";

  // ── Discover the Zoho organization id (first one; most factories have one) ──
  const orgRes = await fetch(`${apiDomain}/books/v3/organizations`, {
    headers: { Authorization: `Zoho-oauthtoken ${token.access_token}` },
  });
  const orgBody = await orgRes.json();
  const zohoOrg = orgBody?.organizations?.[0];
  if (!zohoOrg?.organization_id) return backTo(request, "error=no_zoho_org");

  // ── Create the connection (cutover defaults to today), then vault the token ──
  const { data: connId, error: connErr } = await supabase.rpc("upsert_integration_connection", {
    p_org_id: orgId,
    p_provider: "zoho_books",
    p_external_org_id: String(zohoOrg.organization_id),
    p_config: { location, api_domain: apiDomain, accounts_server: accountsServer, org_name: zohoOrg.name },
    p_cutover: null, // null → the RPC defaults it to CURRENT_DATE
  });
  if (connErr) return backTo(request, `error=${encodeURIComponent(connErr.message)}`);

  const { error: secErr } = await supabase.rpc("store_integration_secret", {
    p_connection_id: connId,
    p_token: token.refresh_token,
  });
  if (secErr) return backTo(request, `error=${encodeURIComponent(secErr.message)}`);

  // ── Fire the first sync immediately (backfill; resumable, cron continues it) ──
  const fnUrl = `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/sync-zoho-books`;
  fetch(fnUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-cron-secret": process.env.SYNC_CRON_SECRET ?? "",
    },
    body: JSON.stringify({ connection_id: connId, mode: "backfill" }),
  }).catch(() => {}); // fire-and-forget; cron picks it up regardless

  return backTo(request, "connected=1");
}
