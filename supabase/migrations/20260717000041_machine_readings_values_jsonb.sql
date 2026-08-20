-- Add a flexible `values` JSONB column to machine_readings for machine-type-specific
-- params that don't warrant dedicated typed columns:
--   • Haijing HJ168S extended fields: barrel temps (actual + setpoints), oil temp,
--     injection press/speed, cooling/hold timings, job color.
--   • CV-350 pillow packing machine fields: bags_produced mirrors shot_count; remaining
--     fields (servo counters, temp_a/b, pack_speed, length, positions) live here.
--   • Any future machine type's unique params.
--
-- Existing named columns (shot_count, inferior_count, cycle_time, craft_id, etc.) stay
-- as-is and keep working for Haijing's core metrics. This is purely additive.

ALTER TABLE machine_readings ADD COLUMN IF NOT EXISTS values JSONB;

-- Also add controller_type to machines so the dashboard knows how to label columns
-- ("shots today" vs "bags today", etc.) without parsing raw data.
ALTER TABLE machines ADD COLUMN IF NOT EXISTS controller_type TEXT;

COMMENT ON COLUMN machine_readings.values IS
  'Machine-type-specific readings that do not have dedicated typed columns. '
  'Haijing: barrel temps, injection profile. CV-350: servo counters, pack speed, positions.';

COMMENT ON COLUMN machines.controller_type IS
  'Collector protocol / machine family: "techmation-opcua" | "xinje-modbus-tcp". '
  'Used by the dashboard to label metrics correctly per machine type.';
