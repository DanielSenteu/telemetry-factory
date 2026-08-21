import { createClient } from "@/lib/supabase/server";
import { ProductionTabs } from "@/components/app/production-tabs";

export default async function ProductionPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const { data: accounts } = await supabase
    .from("accounts")
    .select("org_id")
    .eq("user_id", user!.id)
    .limit(1);
  return <ProductionTabs orgId={accounts![0].org_id} />;
}
