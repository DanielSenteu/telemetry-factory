-- Migration 52: Integrations RPCs — ingestion, mapping, and the demand views.
--
-- Schema shipped in 51; behaviour lives here (same split as contacts 39/40).
--
-- DIVISION OF LABOUR, restated because it is the whole architecture: the ADAPTER
-- (an edge function, one per provider) knows Zoho's field names, OAuth and
-- pagination. It hands this RPC a NORMALISED document. Nothing below knows what
-- a "zoho" is — it speaks external_id / quantity / unit_price. That is why the
-- second provider costs one edge function and zero migrations.

-- ── 1. ingest_external_document ───────────────────────
--
-- Called by the sync adapter (service role). Idempotent in the strong sense:
-- re-running a full 24k backfill re-lands every document, but a document whose
-- external_modified_at has not advanced is a cheap no-op — no line churn, no
-- state change, no stock movement.
--
--   p_doc   = { external_id, external_number, doc_date, external_modified_at,
--               customer_external_id, total, balance, external_status, payload }
--   p_lines = [ { line_index, external_line_id, external_item_id, description,
--                 quantity, unit_price, line_total }, ... ]

CREATE OR REPLACE FUNCTION ingest_external_document(
  p_org_id        INTEGER,
  p_connection_id INTEGER,
  p_source_system TEXT,
  p_doc           JSONB,
  p_lines         JSONB
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
  v_doc_id   BIGINT;
  v_doc_date DATE;
  v_line     JSONB;
BEGIN
  v_doc_date := NULLIF(p_doc->>'doc_date', '')::DATE;

  INSERT INTO external_documents (
    org_id, connection_id, source_system, doc_type, external_id, external_number,
    doc_date, external_modified_at, payload, customer_external_id,
    total, balance, external_status
  )
  VALUES (
    p_org_id, p_connection_id, p_source_system, 'sales_invoice',
    p_doc->>'external_id',
    p_doc->>'external_number',
    v_doc_date,
    NULLIF(p_doc->>'external_modified_at', '')::TIMESTAMPTZ,
    COALESCE(p_doc->'payload', '{}'::JSONB),
    p_doc->>'customer_external_id',
    NULLIF(p_doc->>'total', '')::NUMERIC,
    NULLIF(p_doc->>'balance', '')::NUMERIC,
    p_doc->>'external_status'
  )
  ON CONFLICT (org_id, source_system, doc_type, external_id) DO UPDATE SET
    external_number      = EXCLUDED.external_number,
    doc_date             = EXCLUDED.doc_date,
    external_modified_at = EXCLUDED.external_modified_at,
    payload              = EXCLUDED.payload,
    customer_external_id = EXCLUDED.customer_external_id,
    total                = EXCLUDED.total,
    balance              = EXCLUDED.balance,
    external_status      = EXCLUDED.external_status,
    fetched_at           = now()
  -- Only when the source actually moved on. Unchanged documents fall through to
  -- the SELECT below and cost nothing.
  WHERE external_documents.external_modified_at IS NULL
     OR EXCLUDED.external_modified_at IS NULL
     OR EXCLUDED.external_modified_at > external_documents.external_modified_at
  RETURNING id INTO v_doc_id;

  IF v_doc_id IS NULL THEN
    SELECT id INTO v_doc_id
      FROM external_documents
     WHERE org_id = p_org_id AND source_system = p_source_system
       AND doc_type = 'sales_invoice' AND external_id = p_doc->>'external_id';
    RETURN v_doc_id;                      -- nothing changed; leave lines and state alone
  END IF;

  -- Lines are replaced wholesale: this is a mirror of a document that may have
  -- been edited upstream, so "what it says now" is the only truth we keep.
  DELETE FROM external_document_lines WHERE document_id = v_doc_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(COALESCE(p_lines, '[]'::JSONB))
  LOOP
    INSERT INTO external_document_lines (
      org_id, document_id, line_index, external_line_id, external_item_id,
      description, quantity, unit_price, line_total, product_id
    )
    VALUES (
      p_org_id, v_doc_id,
      COALESCE(NULLIF(v_line->>'line_index', '')::INTEGER, 0),
      v_line->>'external_line_id',
      v_line->>'external_item_id',
      v_line->>'description',
      COALESCE(NULLIF(v_line->>'quantity', '')::NUMERIC, 0),
      NULLIF(v_line->>'unit_price', '')::NUMERIC,
      NULLIF(v_line->>'line_total', '')::NUMERIC,
      (SELECT m.product_id FROM external_entity_map m
        WHERE m.org_id = p_org_id AND m.source_system = p_source_system
          AND m.entity_type = 'product' AND m.external_id = v_line->>'external_item_id')
    );
  END LOOP;

  PERFORM reprocess_external_document(p_org_id, v_doc_id);
  RETURN v_doc_id;
END;
$$;

-- ── 2. reprocess_external_document ────────────────────
--
-- Decides a document's fate from lines that are already stored — no payload
-- parsing, so it is safe to re-run after a mapping lands. Split out from
-- ingestion precisely so mapping can reuse it.
--
-- The cutover rule: documents dated before stock_cutover_date (or any document
-- when it is NULL) are records_only — they still count as demand history, they
-- simply never move stock. Deducting three years of sales from today's shelf
-- would drive every product deeply negative.
--
-- Partial mappings do NOT post partial stock: one unmapped line puts the whole
-- document in needs_mapping. Half-deducting an invoice is worse than not
-- deducting it, because it looks like it worked.

CREATE OR REPLACE FUNCTION reprocess_external_document(
  p_org_id      INTEGER,
  p_document_id BIGINT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_doc_date DATE;
  v_conn     INTEGER;
  v_status   TEXT;
  v_cutover  DATE;
  v_unmapped INTEGER;
  v_mapped   INTEGER;
  v_state    TEXT;
BEGIN
  SELECT doc_date, connection_id, external_status
    INTO v_doc_date, v_conn, v_status
    FROM external_documents WHERE id = p_document_id AND org_id = p_org_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT stock_cutover_date INTO v_cutover
    FROM integration_connections WHERE id = v_conn;

  SELECT COUNT(*) FILTER (WHERE product_id IS NULL AND COALESCE(external_item_id, '') <> ''),
         COUNT(*) FILTER (WHERE product_id IS NOT NULL)
    INTO v_unmapped, v_mapped
    FROM external_document_lines
   WHERE document_id = p_document_id;

  -- 'void' and 'draft' are near-universal document states rather than one
  -- vendor's vocabulary, so the spine is allowed to know them. A cancelled
  -- invoice never left the building and must not deduct stock — and because a
  -- document can be voided AFTER we stocked it, this is also the path that must
  -- reverse. Reversal is handled by the guard below rather than by deleting the
  -- original movement: the stock ledger stays append-only.
  IF COALESCE(v_status, '') IN ('void', 'draft') THEN
    INSERT INTO stock_movements
      (org_id, product_id, quantity, movement_type, unit_cost, source_type, source_id, note)
    SELECT sm.org_id, sm.product_id, -sm.quantity, 'adjustment', sm.unit_cost,
           'external_document_void', p_document_id::INTEGER,
           'reversal: source document voided upstream'
      FROM stock_movements sm
     WHERE sm.org_id = p_org_id
       AND sm.source_type = 'external_document'
       AND sm.source_id = p_document_id::INTEGER
       AND NOT EXISTS (
         SELECT 1 FROM stock_movements r
          WHERE r.org_id = p_org_id
            AND r.source_type = 'external_document_void'
            AND r.source_id = p_document_id::INTEGER
       );

    UPDATE external_documents
       SET import_state = 'records_only', import_error = NULL
     WHERE id = p_document_id AND org_id = p_org_id;
    RETURN 'records_only';
  END IF;

  IF v_cutover IS NULL OR v_doc_date IS NULL OR v_doc_date < v_cutover THEN
    v_state := 'records_only';
  ELSIF v_unmapped > 0 THEN
    v_state := 'needs_mapping';
  ELSIF v_mapped > 0 THEN
    -- Guarded by existence rather than by state, so a retry after a crash
    -- between INSERT and UPDATE still cannot double-deduct.
    IF NOT EXISTS (
      SELECT 1 FROM stock_movements
       WHERE org_id = p_org_id
         AND source_type = 'external_document'
         AND source_id = p_document_id::INTEGER
    ) THEN
      INSERT INTO stock_movements
        (org_id, product_id, quantity, movement_type, unit_cost, source_type, source_id, note)
      SELECT p_org_id, l.product_id, -l.quantity, 'sale',
             COALESCE(ps.avg_unit_cost, 0), 'external_document', p_document_id::INTEGER,
             d.source_system || ' ' || COALESCE(d.external_number, d.external_id)
        FROM external_document_lines l
        JOIN external_documents d      ON d.id = l.document_id
        LEFT JOIN product_stock ps     ON ps.product_id = l.product_id
       WHERE l.document_id = p_document_id
         AND l.product_id IS NOT NULL
         AND l.quantity <> 0;
    END IF;
    v_state := 'stocked';
  ELSE
    v_state := 'records_only';               -- nothing sellable we track; still demand history
  END IF;

  UPDATE external_documents
     SET import_state = v_state, import_error = NULL
   WHERE id = p_document_id AND org_id = p_org_id;

  RETURN v_state;
END;
$$;

-- ── 3. map_external_entity ────────────────────────────
--
-- The 287-item, 176-contact human-judgement step. Runs as the CALLER so RLS
-- (admin-only) governs it; a worker cannot map anything.
--
-- Mapping is retroactive by design: it back-fills every line ever seen carrying
-- that external id, then re-evaluates the documents it just unblocked. In
-- practice that re-evaluation loop is small — only post-cutover documents can
-- leave records_only — which is why it is safe to do inline.

CREATE OR REPLACE FUNCTION map_external_entity(
  p_org_id        INTEGER,
  p_source_system TEXT,
  p_entity_type   TEXT,
  p_external_id   TEXT,
  p_label         TEXT    DEFAULT NULL,
  p_contact_id    INTEGER DEFAULT NULL,
  p_product_id    INTEGER DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_map_id INTEGER;
  v_doc    BIGINT;
BEGIN
  IF NOT is_org_admin(p_org_id) THEN
    RAISE EXCEPTION 'Only org admins can map external entities';
  END IF;

  -- Validate the target belongs to this org — a mapping is a cross-system join,
  -- and a mis-scoped one would leak another org's product into our stock ledger.
  IF p_entity_type = 'product' THEN
    PERFORM 1 FROM products WHERE id = p_product_id AND org_id = p_org_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Product % not in org %', p_product_id, p_org_id; END IF;
  ELSIF p_entity_type = 'contact' THEN
    PERFORM 1 FROM contacts WHERE id = p_contact_id AND org_id = p_org_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Contact % not in org %', p_contact_id, p_org_id; END IF;
  ELSE
    RAISE EXCEPTION 'Unknown entity_type %', p_entity_type;
  END IF;

  INSERT INTO external_entity_map
    (org_id, source_system, entity_type, external_id, external_label, contact_id, product_id)
  VALUES
    (p_org_id, p_source_system, p_entity_type, p_external_id, p_label, p_contact_id, p_product_id)
  ON CONFLICT (org_id, source_system, entity_type, external_id) DO UPDATE SET
    contact_id     = EXCLUDED.contact_id,
    product_id     = EXCLUDED.product_id,
    external_label = COALESCE(EXCLUDED.external_label, external_entity_map.external_label),
    mapped_by      = auth.uid(),
    mapped_at      = now()
  RETURNING id INTO v_map_id;

  IF p_entity_type = 'product' THEN
    UPDATE external_document_lines l
       SET product_id = p_product_id
      FROM external_documents d
     WHERE l.document_id = d.id
       AND l.org_id = p_org_id
       AND d.source_system = p_source_system
       AND l.external_item_id = p_external_id
       AND l.product_id IS DISTINCT FROM p_product_id;

    FOR v_doc IN
      SELECT DISTINCT d.id FROM external_documents d
       WHERE d.org_id = p_org_id
         AND d.source_system = p_source_system
         AND d.import_state IN ('needs_mapping', 'pending')
    LOOP
      PERFORM reprocess_external_document(p_org_id, v_doc);
    END LOOP;
  END IF;

  RETURN v_map_id;
END;
$$;

-- ── 4. The views the whole integration exists to produce ─

-- What still needs a human decision, ordered by how much it matters. Mapping the
-- top seller first is worth more than mapping alphabetically.
CREATE VIEW external_unmapped_items WITH (security_invoker = true) AS
SELECT
  l.org_id,
  d.source_system,
  l.external_item_id,
  MAX(l.description)          AS description,
  COUNT(DISTINCT d.id)        AS document_count,
  SUM(l.quantity)             AS total_quantity,
  MAX(d.doc_date)             AS last_sold_on
FROM external_document_lines l
JOIN external_documents d ON d.id = l.document_id
WHERE l.product_id IS NULL
  AND COALESCE(l.external_item_id, '') <> ''
GROUP BY l.org_id, d.source_system, l.external_item_id;

-- The demand signal: what sold, how much, when. Mapped and unmapped alike — an
-- unmapped item still tells you it moves 400 units a month before anyone decides
-- what it is on our side.
CREATE VIEW external_demand_monthly WITH (security_invoker = true) AS
SELECT
  l.org_id,
  d.source_system,
  DATE_TRUNC('month', d.doc_date)::DATE AS month,
  l.product_id,
  l.external_item_id,
  MAX(l.description)     AS description,
  SUM(l.quantity)        AS quantity_sold,
  SUM(l.line_total)      AS revenue,
  COUNT(DISTINCT d.id)   AS document_count
FROM external_document_lines l
JOIN external_documents d ON d.id = l.document_id
WHERE d.doc_date IS NOT NULL
GROUP BY l.org_id, d.source_system, DATE_TRUNC('month', d.doc_date), l.product_id, l.external_item_id;

GRANT SELECT ON external_unmapped_items, external_demand_monthly TO authenticated;
