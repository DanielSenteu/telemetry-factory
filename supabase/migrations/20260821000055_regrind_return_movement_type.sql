-- Migration 55: allow 'regrind_return' stock movements — regrind use never worked.
--
-- Same disease as migration 53, second patient. post_regrind_use (migration 48)
-- returns ground runner material to raw stock by writing movement_type =
-- 'regrind_return' — a value the CHECK constraint from migration 14 has never
-- allowed. Every attempt to log regrind use since 2026-08-13 has failed on the
-- constraint. It hid because the pgTAP suites tested regrind ACCUMULATION
-- (which writes no stock movement) but never regrind USE.
--
-- Unlike 53, widening the constraint IS the right fix here: a regrind return is
-- a genuinely new event class — not a purchase, not production output (it is
-- raw material), not a stock-take adjustment. Reports that group by movement
-- type deserve to see it under its own name.
--
-- CONVENTIONS.md rule 2: allowed values live beside the code that writes them,
-- and grow in the same change. This migration exists because migration 48 broke
-- that rule before it was written.

ALTER TABLE stock_movements DROP CONSTRAINT stock_movements_movement_type_check;
ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_movement_type_check
  CHECK (movement_type IN (
    'purchase',            -- incoming invoice  (+)
    'sale',                -- outgoing sale     (-)
    'wastage',             -- spillage/breakage/waste/rejects (-)
    'adjustment',          -- manual stock-take correction (+/-)
    'production_consume',  -- manufacturing: raw material used (-)
    'production_output',   -- manufacturing: finished good made (+)
    'regrind_return'       -- ground runners returned to raw material stock (+)
  ));
