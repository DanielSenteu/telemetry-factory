-- Migration 58: products.active — safe archive instead of destructive delete.
--
-- stock_movements.product_id is ON DELETE CASCADE, so hard-deleting a product
-- that has any movements silently wipes its entire ledger history. That is fine
-- for junk/test products with no history, but catastrophic for a real material.
-- `active` lets us ARCHIVE (hide from lists, keep history) instead — and the app
-- reserves hard delete for products with zero movements.

ALTER TABLE products ADD COLUMN IF NOT EXISTS active BOOLEAN NOT NULL DEFAULT true;
CREATE INDEX IF NOT EXISTS idx_products_org_active ON products(org_id, active);
