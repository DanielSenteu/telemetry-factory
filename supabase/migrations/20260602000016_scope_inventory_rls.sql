-- Scope the inventory tables (added in 0014) to the user's org(s), matching the
-- pattern established for every other data table in migration 0010. Until this,
-- products / product_aliases / stock_movements used permissive USING (true)
-- policies — any authenticated user could read every org's inventory.

DROP POLICY IF EXISTS "Authenticated access on products" ON products;
CREATE POLICY "Org-scoped access on products" ON products
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));

DROP POLICY IF EXISTS "Authenticated access on product_aliases" ON product_aliases;
CREATE POLICY "Org-scoped access on product_aliases" ON product_aliases
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));

DROP POLICY IF EXISTS "Authenticated access on stock_movements" ON stock_movements;
CREATE POLICY "Org-scoped access on stock_movements" ON stock_movements
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));

-- Views run as their owner and bypass underlying-table RLS by default. Set
-- security_invoker so product_stock honours the querying user's policies
-- (Postgres 15+), preventing it from leaking other orgs' stock.
ALTER VIEW product_stock SET (security_invoker = true);
