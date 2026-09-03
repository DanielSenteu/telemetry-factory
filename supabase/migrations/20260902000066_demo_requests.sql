-- Migration 66: demo_requests — the "Book a virtual demo" form, wired for real
--
-- Public visitors submit the contact form without an account, so the anon
-- role may INSERT — and do nothing else. Nobody can read the leads through
-- the public API (no SELECT policy for anon/authenticated); they are read
-- via Supabase Studio / service role. Length CHECKs bound junk input; the
-- form adds a honeypot client-side.

CREATE TABLE demo_requests (
  id           SERIAL PRIMARY KEY,
  name         TEXT NOT NULL CHECK (char_length(name)    BETWEEN 1 AND 200),
  company      TEXT     CHECK (company      IS NULL OR char_length(company)      <= 200),
  phone        TEXT NOT NULL CHECK (char_length(phone)   BETWEEN 3 AND 50),
  manufactures TEXT     CHECK (manufactures IS NULL OR char_length(manufactures) <= 2000),
  source       TEXT NOT NULL DEFAULT 'website',
  handled      BOOLEAN NOT NULL DEFAULT false,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE demo_requests ENABLE ROW LEVEL SECURITY;

-- Anyone may leave their details; nobody may read them back publicly.
CREATE POLICY "Public may request a demo" ON demo_requests
  FOR INSERT TO anon, authenticated
  WITH CHECK (true);

GRANT INSERT ON demo_requests TO anon, authenticated;
GRANT USAGE ON SEQUENCE demo_requests_id_seq TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON demo_requests TO service_role;
GRANT USAGE, SELECT ON SEQUENCE demo_requests_id_seq TO service_role;
