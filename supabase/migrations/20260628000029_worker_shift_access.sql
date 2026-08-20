-- Scheduling #3 (worker self-service) — step 1: let workers READ their schedule
-- on the mobile app. The shifts policy from migration 26 is admin-only
-- (org_id IN user_org_ids(), which reads the accounts table). Workers authenticate
-- via workers.user_id — they have no accounts row — so today they can't see any
-- shift. Split the single policy into a broad SELECT and admin-only writes,
-- mirroring the worker-self pattern from migration 12 (is_org_admin + workers.user_id).
--
-- A worker may read: their own assigned shifts, and OPEN shifts (worker_id NULL)
-- in their org. Creating/editing shifts stays staff-only (workers will claim open
-- shifts via a request flow in a later step, not by writing shifts directly).

DROP POLICY IF EXISTS "Org-scoped access on shifts" ON shifts;

CREATE POLICY "Shifts: read by org staff, owning worker, or open in worker's org" ON shifts
  FOR SELECT TO authenticated
  USING (
    org_id IN (SELECT user_org_ids())
    OR worker_id IN (SELECT id FROM workers WHERE user_id = auth.uid())
    OR (worker_id IS NULL AND org_id IN (SELECT org_id FROM workers WHERE user_id = auth.uid()))
  );

CREATE POLICY "Shifts: insert by org staff" ON shifts
  FOR INSERT TO authenticated
  WITH CHECK (org_id IN (SELECT user_org_ids()));

CREATE POLICY "Shifts: update by org staff" ON shifts
  FOR UPDATE TO authenticated
  USING (org_id IN (SELECT user_org_ids()))
  WITH CHECK (org_id IN (SELECT user_org_ids()));

CREATE POLICY "Shifts: delete by org staff" ON shifts
  FOR DELETE TO authenticated
  USING (org_id IN (SELECT user_org_ids()));
