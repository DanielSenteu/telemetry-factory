import { createClient } from "@/lib/supabase/server";
import { Sales } from "@/components/app/sales";

export default async function SalesPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const { data: accounts } = await supabase.from("accounts").select("org_id").eq("user_id", user!.id).limit(1);
  return <Sales orgId={accounts![0].org_id} />;
}
