import { createClient } from "@/lib/supabase/server";
import { Dashboard } from "@/components/app/dashboard";

export default async function DashboardPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const { data: accounts } = await supabase
    .from("accounts")
    .select("org_id")
    .eq("user_id", user!.id)
    .limit(1);
  return <Dashboard orgId={accounts![0].org_id} />;
}
