import { createClient, SupabaseClient, SupabaseClientOptions } from "@supabase/supabase-js";

export function createSupabaseClient(
  url: string,
  anonKey: string,
  options?: SupabaseClientOptions<"public">
): SupabaseClient {
  return createClient(url, anonKey, options);
}
