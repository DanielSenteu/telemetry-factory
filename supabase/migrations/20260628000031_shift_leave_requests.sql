-- Scheduling #3 (worker self-service) — step 2: REQUESTS.
-- Two kinds of "slips" a worker drops from the mobile app, that a manager
-- approves/declines on the web app:
--
--   leave_requests  — book days off. Admin stamps PAID or UNPAID on approval.
--                     Approving releases any of the worker's published shifts in
--                     that range back to the OPEN pool (worker_id → NULL) so a
--                     colleague can pick them up. The worker is then off.
--   shift_requests  — claim an OPEN shift (and, next round, swap/trade). Approving
--                     a claim assigns the shift to the requester, but ONLY if it
--                     wouldn't double-book them — enforced atomically server-side.
--
-- Safeguards live in the RPCs (SECURITY DEFINER), not the client: client checks
-- can be bypassed or race (two workers claiming the same open shift at once).
-- Mirrors the worker-self + is_org_admin() pattern from migrations 12 and 29.

-- ── Tables ────────────────────────────────────────────

CREATE TABLE leave_requests (
  id          SERIAL PRIMARY KEY,
  org_id      INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  worker_id   INTEGER NOT NULL REFERENCES workers(id)       ON DELETE CASCADE,
  start_date  DATE NOT NULL,
  end_date    DATE NOT NULL,               -- inclusive
  reason      TEXT,
  status      TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'approved', 'declined', 'cancelled')),
  paid        BOOLEAN,                      -- NULL until approved; admin decides
  decided_by  UUID,
  decided_at  TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (end_date >= start_date)
);
CREATE INDEX idx_leave_requests_org_id    ON leave_requests(org_id);
CREATE INDEX idx_leave_requests_worker_id ON leave_requests(worker_id);
CREATE INDEX idx_leave_requests_status    ON leave_requests(status);

CREATE TABLE shift_requests (
  id               SERIAL PRIMARY KEY,
  org_id           INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  worker_id        INTEGER NOT NULL REFERENCES workers(id)       ON DELETE CASCADE,  -- requester
  shift_id         INTEGER NOT NULL REFERENCES shifts(id)        ON DELETE CASCADE,  -- claim: the open shift; swap: requester's own shift
  type             TEXT NOT NULL DEFAULT 'claim'
                     CHECK (type IN ('claim', 'swap', 'drop')),
  target_worker_id INTEGER REFERENCES workers(id) ON DELETE CASCADE,  -- swap: the colleague (next round)
  target_shift_id  INTEGER REFERENCES shifts(id)  ON DELETE CASCADE,  -- swap: the colleague's shift offered back
  status           TEXT NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'approved', 'declined', 'cancelled')),
  decided_by       UUID,
  decided_at       TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_shift_requests_org_id    ON shift_requests(org_id);
CREATE INDEX idx_shift_requests_worker_id ON shift_requests(worker_id);
CREATE INDEX idx_shift_requests_shift_id  ON shift_requests(shift_id);
CREATE INDEX idx_shift_requests_status    ON shift_requests(status);

-- ── RLS — worker reads/creates own; admin reads/decides all ─

ALTER TABLE leave_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE shift_requests ENABLE ROW LEVEL SECURITY;

-- leave_requests
CREATE POLICY "Leave requests visible to admins and owning worker" ON leave_requests
  FOR SELECT TO authenticated
  USING (
    is_org_admin(org_id)
    OR worker_id IN (SELECT id FROM workers WHERE user_id = auth.uid())
  );

CREATE POLICY "Workers create own leave requests" ON leave_requests
  FOR INSERT TO authenticated
  WITH CHECK (
    worker_id IN (SELECT id FROM workers WHERE user_id = auth.uid())
    OR is_org_admin(org_id)
  );

-- Admins decide (via RPC). Workers may cancel their own still-pending request.
CREATE POLICY "Admins update leave, workers cancel own" ON leave_requests
  FOR UPDATE TO authenticated
  USING (
    is_org_admin(org_id)
    OR worker_id IN (SELECT id FROM workers WHERE user_id = auth.uid())
  )
  WITH CHECK (
    is_org_admin(org_id)
    OR worker_id IN (SELECT id FROM workers WHERE user_id = auth.uid())
  );

-- shift_requests
CREATE POLICY "Shift requests visible to admins and owning worker" ON shift_requests
  FOR SELECT TO authenticated
  USING (
    is_org_admin(org_id)
    OR worker_id IN (SELECT id FROM workers WHERE user_id = auth.uid())
  );

CREATE POLICY "Workers create own shift requests" ON shift_requests
  FOR INSERT TO authenticated
  WITH CHECK (
    worker_id IN (SELECT id FROM workers WHERE user_id = auth.uid())
    OR is_org_admin(org_id)
  );

CREATE POLICY "Admins update shift requests, workers cancel own" ON shift_requests
  FOR UPDATE TO authenticated
  USING (
    is_org_admin(org_id)
    OR worker_id IN (SELECT id FROM workers WHERE user_id = auth.uid())
  )
  WITH CHECK (
    is_org_admin(org_id)
    OR worker_id IN (SELECT id FROM workers WHERE user_id = auth.uid())
  );

-- ── Approval RPCs (SECURITY DEFINER — the real safeguards) ─

-- Approve an OPEN-shift claim: assign the shift to the requester, but only if the
-- shift is still open AND the requester has no overlapping shift. Atomic, so two
-- workers can't both win the same open shift.
CREATE OR REPLACE FUNCTION approve_shift_claim(p_request_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org_id    INTEGER;
  v_worker_id INTEGER;
  v_shift_id  INTEGER;
  v_status    TEXT;
  v_type      TEXT;
  v_start_at  TIMESTAMPTZ;
  v_end_at    TIMESTAMPTZ;
  v_shift_worker INTEGER;
BEGIN
  SELECT org_id, worker_id, shift_id, status, type
    INTO v_org_id, v_worker_id, v_shift_id, v_status, v_type
  FROM shift_requests WHERE id = p_request_id;

  IF v_org_id IS NULL THEN RAISE EXCEPTION 'Request not found'; END IF;
  IF NOT is_org_admin(v_org_id) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF v_status <> 'pending' THEN RAISE EXCEPTION 'Request is no longer pending'; END IF;
  IF v_type <> 'claim' THEN RAISE EXCEPTION 'Not a claim request'; END IF;

  SELECT worker_id, start_at, end_at INTO v_shift_worker, v_start_at, v_end_at
  FROM shifts WHERE id = v_shift_id;

  IF v_shift_worker IS NOT NULL THEN
    RAISE EXCEPTION 'This shift is no longer open';
  END IF;

  -- Safeguard: requester must not already work an overlapping shift.
  IF EXISTS (
    SELECT 1 FROM shifts s2
    WHERE s2.worker_id = v_worker_id
      AND s2.id <> v_shift_id
      AND s2.status <> 'cancelled'
      AND s2.start_at < v_end_at
      AND v_start_at < s2.end_at
  ) THEN
    RAISE EXCEPTION 'Worker already has an overlapping shift';
  END IF;

  UPDATE shifts SET worker_id = v_worker_id WHERE id = v_shift_id;

  UPDATE shift_requests
  SET status = 'approved', decided_by = auth.uid(), decided_at = now()
  WHERE id = p_request_id;

  -- Auto-decline any other pending claims on the same shift — it's taken now.
  UPDATE shift_requests
  SET status = 'declined', decided_by = auth.uid(), decided_at = now()
  WHERE shift_id = v_shift_id AND status = 'pending' AND id <> p_request_id;
END;
$$;

CREATE OR REPLACE FUNCTION decline_shift_request(p_request_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org_id INTEGER;
  v_status TEXT;
BEGIN
  SELECT org_id, status INTO v_org_id, v_status FROM shift_requests WHERE id = p_request_id;
  IF v_org_id IS NULL THEN RAISE EXCEPTION 'Request not found'; END IF;
  IF NOT is_org_admin(v_org_id) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF v_status <> 'pending' THEN RAISE EXCEPTION 'Request is no longer pending'; END IF;

  UPDATE shift_requests
  SET status = 'declined', decided_by = auth.uid(), decided_at = now()
  WHERE id = p_request_id;
END;
$$;

-- Approve leave: stamp paid/unpaid, then RELEASE the worker's published shifts in
-- the leave range back to the open pool. Returns how many shifts were released so
-- the UI can tell the admin.
CREATE OR REPLACE FUNCTION approve_leave(p_request_id INTEGER, p_paid BOOLEAN)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org_id     INTEGER;
  v_worker_id  INTEGER;
  v_start_date DATE;
  v_end_date   DATE;
  v_status     TEXT;
  v_released   INTEGER;
BEGIN
  SELECT org_id, worker_id, start_date, end_date, status
    INTO v_org_id, v_worker_id, v_start_date, v_end_date, v_status
  FROM leave_requests WHERE id = p_request_id;

  IF v_org_id IS NULL THEN RAISE EXCEPTION 'Request not found'; END IF;
  IF NOT is_org_admin(v_org_id) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF v_status <> 'pending' THEN RAISE EXCEPTION 'Request is no longer pending'; END IF;

  UPDATE leave_requests
  SET status = 'approved', paid = p_paid, decided_by = auth.uid(), decided_at = now()
  WHERE id = p_request_id;

  -- Release the worker's published shifts overlapping the leave dates → open pool.
  UPDATE shifts
  SET worker_id = NULL
  WHERE worker_id = v_worker_id
    AND status = 'published'
    AND start_at < (v_end_date + 1)::timestamptz   -- day after the last leave day
    AND end_at   > v_start_date::timestamptz;
  GET DIAGNOSTICS v_released = ROW_COUNT;

  RETURN v_released;
END;
$$;

CREATE OR REPLACE FUNCTION decline_leave(p_request_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org_id INTEGER;
  v_status TEXT;
BEGIN
  SELECT org_id, status INTO v_org_id, v_status FROM leave_requests WHERE id = p_request_id;
  IF v_org_id IS NULL THEN RAISE EXCEPTION 'Request not found'; END IF;
  IF NOT is_org_admin(v_org_id) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF v_status <> 'pending' THEN RAISE EXCEPTION 'Request is no longer pending'; END IF;

  UPDATE leave_requests
  SET status = 'declined', decided_by = auth.uid(), decided_at = now()
  WHERE id = p_request_id;
END;
$$;

-- ── Realtime — push status changes to the worker's app + the admin inbox ─
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'leave_requests') THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE leave_requests;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'shift_requests') THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE shift_requests;
    END IF;
  END IF;
END $$;
