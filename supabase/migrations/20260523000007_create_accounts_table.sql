CREATE TABLE accounts (
  id         SERIAL PRIMARY KEY,
  org_id     INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  email      TEXT NOT NULL,
  role       TEXT NOT NULL DEFAULT 'worker',
  user_id    UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(org_id, email)
);

ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated access on accounts" ON accounts
  FOR ALL TO authenticated USING (true) WITH CHECK (true);
