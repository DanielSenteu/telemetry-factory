import { createClient } from "@/lib/supabase/server";
import { MaterialsStock } from "@/components/app/materials-stock";

export default async function MaterialsPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const { data: accounts } = await supabase
    .from("accounts")
    .select("org_id")
    .eq("user_id", user!.id)
    .limit(1);
  return <MaterialsStock orgId={accounts![0].org_id} />;
}
