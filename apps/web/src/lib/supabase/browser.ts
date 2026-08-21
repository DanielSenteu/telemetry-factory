import { createBrowserClient } from "@supabase/ssr";

// One browser client shared by all client-side services — same singleton
// pattern the v1 services were written against, so they port unchanged.
export const supabase = createBrowserClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
);
