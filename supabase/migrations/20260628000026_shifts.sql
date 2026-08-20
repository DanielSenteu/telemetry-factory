-- Scheduling (module 1: manager rostering). A SHIFT is a PLANNED work event —
-- the twin of timesheet_entries (the ACTUAL clock-in). Comparing the two later
-- (module 2) yields automatic late/absent/overtime detection and makes payroll
-- absences data-driven. Same event-ledger spine as the rest of the platform.
--
-- worker_id is NULLABLE: a shift with no worker is an "open shift" that can be
-- assigned (or, later, claimed by a worker on mobile). start_at/end_at are
-- TIMESTAMPTZ so night shifts crossing midnight work, and so they line up
-- directly with the timestamptz clock-ins for the module-2 comparison.

CREATE TABLE shifts (
  id            SERIAL PRIMARY KEY,
  org_id        INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  worker_id     INTEGER REFERENCES workers(id)    ON DELETE CASCADE,   -- NULL = open shift
  workplace_id  INTEGER REFERENCES workplaces(id) ON DELETE SET NULL,
  start_at      TIMESTAMPTZ NOT NULL,
  end_at        TIMESTAMPTZ NOT NULL,
  break_minutes INTEGER NOT NULL DEFAULT 0 CHECK (break_minutes >= 0),
  role          TEXT,
  -- draft = manager-only; published = visible to workers. accepted/declined are
  -- for worker self-service (module 3); included now so that lands without a
  -- schema change. cancelled keeps an audit trail instead of deleting.
  status        TEXT NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft', 'published', 'accepted', 'declined', 'cancelled')),
  notes         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by    UUID DEFAULT auth.uid(),
  CHECK (end_at > start_at)
);

CREATE INDEX idx_shifts_org_id    ON shifts(org_id);
CREATE INDEX idx_shifts_worker_id ON shifts(worker_id);
CREATE INDEX idx_shifts_start_at  ON shifts(start_at);

-- ── RLS — org-scoped, mirroring every other data table ─

ALTER TABLE shifts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org-scoped access on shifts" ON shifts
  FOR ALL TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));
