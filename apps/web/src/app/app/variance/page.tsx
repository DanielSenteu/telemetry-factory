import { createClient } from "@/lib/supabase/server";
import { VarianceReports } from "@/components/app/variance-reports";

export default async function VariancePage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const { data: accounts } = await supabase.from("accounts").select("org_id").eq("user_id", user!.id).limit(1);
  return <VarianceReports orgId={accounts![0].org_id} />;
}
