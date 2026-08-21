import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { AppShell } from "@/components/app/shell";

// The building behind the door. Session verified server-side; the factory is
// resolved from the user's account — one factory, one org, no picker.
export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: accounts } = await supabase
    .from("accounts")
    .select("org_id, role, organizations(name)")
    .eq("user_id", user.id)
    .limit(1);

  const account = accounts?.[0];
  if (!account) {
    // Authenticated but not provisioned — an account we haven't linked yet.
    redirect("/login?unprovisioned");
  }

  const orgName =
    (account.organizations as unknown as { name: string } | null)?.name ?? "Your factory";

  return (
    <AppShell orgId={account.org_id} orgName={orgName} email={user.email ?? ""}>
      {children}
    </AppShell>
  );
}
