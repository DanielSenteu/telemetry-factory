-- Migration 51: Integrations spine — mirroring documents from outside systems.
--
-- Alpha Surgicals invoice out of Zoho Books (24k invoices, 2023→today) and will
-- keep doing so. This is a MIRROR, not a migration: one direction, read-only,
-- no write-back, no conflict resolution, ever.
--
-- WHAT ZOHO ACTUALLY HOLDS (probed 2026-08-15, org 823632753):
--   customers (176), an item catalogue with sale prices (287), and 24,076
--   invoices. It holds NO stock levels (stock_on_hand null on every item), NO
--   reorder points (1 item of 287), NO raw materials (zero hits across all 287
--   names), and effectively no order book (9 sales orders). It is an invoicing
--   system with a price list attached.
--
-- WHY WE WANT IT: nobody currently knows what is on the shelf — not Zoho, not
-- us. Our stock ledger only ever increases, because production flows in from the
-- factory agent while sales leave through Zoho where we cannot see them. This
-- feed closes that loop and makes our system the only place in the business that
-- can answer "what do we have, and what should we make next".
--
-- WHAT THIS DELIBERATELY DOES NOT DO: touch the general ledger. No journal
-- entries, no VAT, no AR. Roughly half of Zoho's invoices are zero-rated and
-- some mix 0% and 16% on one document, which our org-level single-rate model
-- cannot express — and replaying three years of sales into the books would
-- collide with accounts that already exist. Stock and demand only.
--
-- The design rule that shapes every table: THE SPINE IS GENERIC, THE ADAPTER IS
-- NOT. Nothing here names Zoho in a column or a constraint. Adding another
-- source later is one new edge function and zero migrations. What we do NOT
-- build is a configurable field-mapping layer — mapping semantics live in
-- adapter code, in git, tested; config here is credentials, cursors and toggles,
-- never meaning.
--
-- Additive & default-safe: no existing table changes behaviour, and orgs without
-- the 'integrations' module see nothing at all.

-- ── 1. Connections — one per (org, provider) ──────────
--
-- NOTE ON SECRETS: refresh tokens are NOT stored here. They live as edge
-- function secrets, reachable only by the service role. This table is
-- admin-readable, and an admin-readable OAuth token is a credential leak waiting
-- for its first RLS mistake.
--
-- UNIQUE (org_id, provider) is a safety constraint, not tidiness: an org
-- mirroring both Zoho Books and Zoho CRM could ingest the same commercial event
-- twice under two different external ids, and no key can dedupe that because the
-- ids genuinely differ. One source per provider, chosen deliberately.

CREATE TABLE integration_connections (
  id                  SERIAL PRIMARY KEY,
  org_id              INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  provider            TEXT    NOT NULL,          -- 'zoho_books', 'shopify', ...
  -- The provider's own tenant id (Zoho organization_id, Shopify shop domain).
  -- Opaque to us; the adapter knows what it means.
  external_org_id     TEXT,
  -- Provider-shaped, NON-SECRET settings (data centre, branch filter, ...).
  -- JSONB so a new provider never needs a migration.
  config              JSONB   NOT NULL DEFAULT '{}'::JSONB,

  -- Documents dated BEFORE this date import as records only and never move
  -- stock. History is for demand analysis; deducting three years of sales from
  -- today's shelf would drive every product deeply negative, since we hold no
  -- matching purchase history for traded goods and only recent production
  -- history for moulded ones. NULL = never move stock (pure demand mirror).
  stock_cutover_date  DATE,

  -- Incremental sync high-water mark: the newest external_modified_at we have
  -- successfully ingested. The adapter asks for "modified since this" and moves
  -- it forward only after a batch lands.
  cursor_modified_at  TIMESTAMPTZ,

  last_sync_at        TIMESTAMPTZ,
  last_sync_status    TEXT CHECK (last_sync_status IN ('ok', 'partial', 'error')),
  last_sync_error     TEXT,
  active              BOOLEAN NOT NULL DEFAULT true,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (org_id, provider)
);

CREATE INDEX idx_integration_connections_org_id ON integration_connections(org_id);

-- ── 2. Entity map — alias engine deployment #8 ────────
--
-- The other seven deployments (products, accounts, contacts, machine crafts...)
-- resolve RAW TEXT, because that is all a PDF or a machine controller offers. An
-- API is different: it hands us a stable primary key. So this maps on external
-- ids, which do not drift when someone renames a customer in Zoho.
-- external_label exists purely so the mapping UI can show a human name.
--
-- This small table is what makes the big one tractable: 287 items + 176 contacts
-- is the entire human-judgement surface behind 24,076 invoices. Map the
-- dimensions once and the facts resolve themselves.
--
-- It is also where a business distinction gets recorded that Zoho does not know:
-- most of the catalogue is TRADED goods (autoclaves, incubators, anesthesia
-- machines — bought in and resold), while a handful are MOULDED in-house
-- (containers, polypots, speculums, polythene bags). Only the latter connect to
-- production planning. There is no naming convention to tell them apart — one
-- item of 287 uses an 'FG-' prefix — so it is a human call made once, here, by
-- pointing the mapping at a product we already classify.

CREATE TABLE external_entity_map (
  id             SERIAL PRIMARY KEY,
  org_id         INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  source_system  TEXT    NOT NULL,
  entity_type    TEXT    NOT NULL CHECK (entity_type IN ('contact', 'product')),
  external_id    TEXT    NOT NULL,
  external_label TEXT,                                    -- name as it reads in the source
  contact_id     INTEGER REFERENCES contacts(id) ON DELETE CASCADE,
  product_id     INTEGER REFERENCES products(id) ON DELETE CASCADE,
  mapped_by      UUID    DEFAULT auth.uid(),
  mapped_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (org_id, source_system, entity_type, external_id),

  -- Exactly one target, matching entity_type. Cheaper than two tables needing
  -- two of every policy, index and query.
  CHECK (
    (entity_type = 'contact' AND contact_id IS NOT NULL AND product_id IS NULL) OR
    (entity_type = 'product' AND product_id IS NOT NULL AND contact_id IS NULL)
  )
);

CREATE INDEX idx_external_entity_map_org_id ON external_entity_map(org_id);
CREATE INDEX idx_external_entity_map_lookup
  ON external_entity_map(org_id, source_system, entity_type, external_id);

-- ── 3. External documents — the landing table ─────────
--
-- WHY THIS UPSERTS IN PLACE rather than being append-only like the rest of the
-- system: our append-only rule protects LEDGER EVENTS, where history is the
-- product. This is a mirror cache of someone else's live record — Zoho remains
-- the system of record, stays running indefinitely, and can be re-fetched at any
-- time. Versioning 24k invoices every time a status flips 'sent' → 'paid' would
-- buy storage, not truth. The stock movements this produces stay append-only
-- exactly as before.
--
-- payload holds the provider's complete response, unnormalised. When we get an
-- extraction wrong we re-derive from what we hold, without re-fetching and
-- without depending on a vendor not having changed the record meanwhile.

CREATE TABLE external_documents (
  id                   BIGSERIAL PRIMARY KEY,
  org_id               INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  connection_id        INTEGER REFERENCES integration_connections(id) ON DELETE CASCADE,
  source_system        TEXT    NOT NULL,
  doc_type             TEXT    NOT NULL CHECK (doc_type IN ('sales_invoice')),
  external_id          TEXT    NOT NULL,
  external_number      TEXT,                               -- 'INV024287' — what a human quotes
  doc_date             DATE,
  external_modified_at TIMESTAMPTZ,                        -- the sync cursor's raw material
  payload              JSONB   NOT NULL,

  -- Denormalised summary (source of truth stays payload) so the inbox can filter
  -- and sort 24k rows without opening JSONB on every one.
  customer_external_id TEXT,
  total                NUMERIC(14,2),
  balance              NUMERIC(14,2),                      -- >0 ⇒ still owed
  external_status      TEXT,                               -- provider's own word: sent/paid/overdue/...

  -- Our processing state.
  --   pending       — landed, not yet resolved
  --   needs_mapping — blocked on an unmapped item (the exception queue)
  --   records_only  — pre-cutover, or no mapped products. A HEALTHY end state:
  --                   the document still counts toward demand history.
  --   stocked       — stock movements exist for this document
  --   error         — processing failed; import_error says why
  import_state         TEXT    NOT NULL DEFAULT 'pending'
                       CHECK (import_state IN ('pending', 'needs_mapping', 'records_only', 'stocked', 'error')),
  import_error         TEXT,
  fetched_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- The idempotency key. Re-running a full backfill, replaying a webhook, or two
  -- syncs racing all collapse onto the same row.
  UNIQUE (org_id, source_system, doc_type, external_id)
);

CREATE INDEX idx_external_documents_org_id   ON external_documents(org_id);
CREATE INDEX idx_external_documents_inbox    ON external_documents(org_id, import_state, doc_date DESC);
CREATE INDEX idx_external_documents_cursor   ON external_documents(org_id, source_system, external_modified_at DESC);
CREATE INDEX idx_external_documents_customer ON external_documents(org_id, customer_external_id);

-- ── 4. Document lines — the demand signal ─────────────
--
-- Line items are normalised out of the payload rather than left in JSONB
-- because this is the table the whole integration exists to produce: three years
-- of "what sold, how much, when" per product. Aggregating that across 24k
-- documents through JSONB extraction would be slow and unindexable; here it is
-- one GROUP BY.
--
-- product_id is nullable on purpose. An unmapped item still records demand
-- against its external identity — we learn "this thing sells 400/month" before
-- anyone decides what it is on our side.

CREATE TABLE external_document_lines (
  id               BIGSERIAL PRIMARY KEY,
  org_id           INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  document_id      BIGINT  NOT NULL REFERENCES external_documents(id) ON DELETE CASCADE,
  line_index       INTEGER NOT NULL,                       -- position within the document
  external_line_id TEXT,
  external_item_id TEXT,                                   -- joins external_entity_map
  description      TEXT,
  quantity         NUMERIC(12,3) NOT NULL DEFAULT 0,
  unit_price       NUMERIC(14,2),
  line_total       NUMERIC(14,2),
  product_id       INTEGER REFERENCES products(id) ON DELETE SET NULL,  -- resolved at import

  -- Re-importing a changed document replaces its lines; this keeps that idempotent.
  UNIQUE (document_id, line_index)
);

CREATE INDEX idx_external_document_lines_org_id  ON external_document_lines(org_id);
CREATE INDEX idx_external_document_lines_doc     ON external_document_lines(document_id);
CREATE INDEX idx_external_document_lines_item    ON external_document_lines(org_id, external_item_id);
CREATE INDEX idx_external_document_lines_product ON external_document_lines(org_id, product_id);

-- ── 5. RLS — admin-only, matching contacts ────────────
--
-- These tables expose customer names, prices and sales volumes, so they get the
-- same stricter-than-org-scoped treatment as contacts: workers get zero rows.
-- The sync itself runs as the service role in an edge function and bypasses RLS
-- entirely — these policies govern humans in the admin UI.

ALTER TABLE integration_connections  ENABLE ROW LEVEL SECURITY;
ALTER TABLE external_entity_map      ENABLE ROW LEVEL SECURITY;
ALTER TABLE external_documents       ENABLE ROW LEVEL SECURITY;
ALTER TABLE external_document_lines  ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins manage integration_connections in their org" ON integration_connections
  FOR ALL TO authenticated
  USING (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

CREATE POLICY "Admins manage external_entity_map in their org" ON external_entity_map
  FOR ALL TO authenticated
  USING (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

CREATE POLICY "Admins manage external_documents in their org" ON external_documents
  FOR ALL TO authenticated
  USING (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

CREATE POLICY "Admins manage external_document_lines in their org" ON external_document_lines
  FOR ALL TO authenticated
  USING (is_org_admin(org_id))
  WITH CHECK (is_org_admin(org_id));

-- RLS decides WHICH rows, GRANT decides IF the role may touch the table at all.
GRANT SELECT, INSERT, UPDATE, DELETE
  ON integration_connections, external_entity_map, external_documents, external_document_lines
  TO authenticated;
GRANT USAGE, SELECT
  ON SEQUENCE integration_connections_id_seq,
              external_entity_map_id_seq,
              external_documents_id_seq,
              external_document_lines_id_seq
  TO authenticated;
