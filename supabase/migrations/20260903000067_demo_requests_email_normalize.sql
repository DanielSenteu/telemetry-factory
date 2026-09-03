-- Migration 67: demo_requests — email field + server-side normalization
--
-- 1. email column (optional; phone stays the required contact), format-checked.
-- 2. A BEFORE trigger normalizes what the form (or anyone hitting the API)
--    sends: email lowercased and trimmed, phone stripped to digits with one
--    optional leading +. Normalization lives in the database so the data is
--    clean no matter what client wrote it.
-- 3. Phone format tightened to E.164 shape: +, then 7-15 digits.

ALTER TABLE demo_requests
  ADD COLUMN email TEXT
  CHECK (email IS NULL OR (
    char_length(email) <= 254
    AND email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
  ));

CREATE OR REPLACE FUNCTION normalize_demo_request() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.email := NULLIF(lower(btrim(COALESCE(NEW.email, ''))), '');
  -- Keep one leading +, drop everything that isn't a digit.
  NEW.phone := CASE WHEN btrim(NEW.phone) LIKE '+%' THEN '+' ELSE '' END
               || regexp_replace(NEW.phone, '[^0-9]', '', 'g');
  NEW.name         := btrim(NEW.name);
  NEW.company      := NULLIF(btrim(COALESCE(NEW.company, '')), '');
  NEW.manufactures := NULLIF(btrim(COALESCE(NEW.manufactures, '')), '');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS demo_requests_normalize_trg ON demo_requests;
CREATE TRIGGER demo_requests_normalize_trg
  BEFORE INSERT OR UPDATE ON demo_requests
  FOR EACH ROW EXECUTE FUNCTION normalize_demo_request();

-- E.164 shape after normalization: optional +, 7-15 digits.
ALTER TABLE demo_requests
  ADD CONSTRAINT demo_requests_phone_shape
  CHECK (phone ~ '^\+?[0-9]{7,15}$');
