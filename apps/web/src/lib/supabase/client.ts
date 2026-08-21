import { createBrowserClient } from "@supabase/ssr";

// Browser-side Supabase client. Sessions live in cookies (not localStorage) so
// the server and middleware always agree on who is logged in.
export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  );
}
