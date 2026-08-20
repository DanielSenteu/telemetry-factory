-- Attendance tables (from mobile-web-architecture.md)

CREATE TABLE IF NOT EXISTS workplaces (
  id               SERIAL PRIMARY KEY,
  name             TEXT NOT NULL,
  latitude         DOUBLE PRECISION NOT NULL,
  longitude        DOUBLE PRECISION NOT NULL,
  clock_in_radius  INTEGER DEFAULT 200,   -- meters
  clock_out_radius INTEGER DEFAULT 500,   -- meters
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS workers (
  id            SERIAL PRIMARY KEY,
  name          TEXT NOT NULL,
  email         TEXT UNIQUE NOT NULL,
  phone         TEXT,
  workplace_id  INTEGER REFERENCES workplaces(id),
  is_active     BOOLEAN DEFAULT TRUE,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS timesheet_entries (
  id            SERIAL PRIMARY KEY,
  worker_id     INTEGER REFERENCES workers(id),
  workplace_id  INTEGER REFERENCES workplaces(id),
  clock_in      TIMESTAMPTZ NOT NULL,
  clock_out     TIMESTAMPTZ,
  clock_in_lat  DOUBLE PRECISION,
  clock_in_lng  DOUBLE PRECISION,
  clock_out_lat DOUBLE PRECISION,
  clock_out_lng DOUBLE PRECISION,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);
