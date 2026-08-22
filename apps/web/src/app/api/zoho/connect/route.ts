import { NextResponse, type NextRequest } from "next/server";
import { cookies } from "next/headers";
import { createClient } from "@/lib/supabase/server";

// Step 1 of one-click connect: verify the user is an org admin, then redirect
// their browser to Zoho's consent page. Scopes live HERE, in the URL we build —
// the customer never sees or types them. A signed state nonce (echoed by Zoho)
// guards the callback against CSRF.
const SCOPES = [
  "ZohoBooks.invoices.READ",
  "ZohoBooks.contacts.READ",
  "ZohoBooks.settings.READ",
].join(",");

function randomState() {
  return crypto.randomUUID().replace(/-/g, "") + crypto.randomUUID().replace(/-/g, "");
}

export async function GET(request: NextRequest) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.redirect(new URL("/login", request.url));

  const clientId = process.env.ZOHO_OAUTH_CLIENT_ID;
  if (!clientId) {
    return NextResponse.redirect(new URL("/app/sales?error=not_configured", request.url));
  }

  const state = randomState();
  (await cookies()).set("zoho_oauth_state", state, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    maxAge: 600,
    path: "/",
  });

  const redirectUri = new URL("/api/zoho/callback", request.url).toString();
  const auth = new URL("https://accounts.zoho.com/oauth/v2/auth");
  auth.searchParams.set("response_type", "code");
  auth.searchParams.set("client_id", clientId);
  auth.searchParams.set("scope", SCOPES);
  auth.searchParams.set("redirect_uri", redirectUri);
  auth.searchParams.set("access_type", "offline"); // ← makes Zoho return a refresh token
  auth.searchParams.set("prompt", "consent");
  auth.searchParams.set("state", state);

  return NextResponse.redirect(auth.toString());
}
