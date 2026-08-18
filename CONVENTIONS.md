# Conventions

Rules this codebase holds itself to. Every one exists because it was violated in
the v1 ERP (`DanielSenteu/flagship`, tag `v1-full-erp`) and cost real debugging.
The incident is kept beside each rule, because rules without their scar are the
first thing dropped under deadline.

## Database

**1. Every table declares its grants explicitly — for `authenticated` AND `service_role`.**

RLS decides *which rows*; GRANT decides *whether the role may touch the table at
all*. Never rely on Supabase's default privileges.

> v1: 26 tables had no privileges for `authenticated` and all 37 had none for
> `service_role` on a fresh database. Production worked only because it predated
> a Supabase image change. Any new project — staging, a new client, or a
> disaster-recovery restore — came up with the entire app returning "permission
> denied", and every edge function broken. Found only by running the SQL tests
> against a database built from scratch.

Table checklist: `ENABLE ROW LEVEL SECURITY` + at least one policy + `GRANT
SELECT, INSERT, UPDATE, DELETE` + `GRANT USAGE, SELECT ON SEQUENCE`.

**2. A CHECK constraint's allowed values live next to the code that writes them.**

When you add a new kind of thing, add it to the constraint in the same migration.

> v1: `post_manual_stock_adjustment` wrote `movement_type = 'manual_addition'`,
> which the constraint had never allowed. Every operator override failed from
> the day it shipped until someone tested it two days later. The fix was not to
> widen the constraint — the correct types already existed, and inventing new
> ones would have hidden the events from every report that groups by type.

**3. Ledgers are append-only. Corrections are reversing entries, never edits or deletes.**

> Applies to stock movements and anything financial. When a mirrored document is
> voided upstream, post the opposite movement; do not delete the original.

**4. Anything retryable proves: run twice = run once.**

Imports, syncs, webhooks, confirmations. Enforce it with a database constraint
where possible, so a buggy caller hits an error rather than inventing data.

**5. Guarded posting.** Optional subsystems degrade silently: if the GL accounts
aren't set up, the business action still succeeds and posting skips. Costing
comes from the stock ledger, not the GL — so a factory customer needs no chart
of accounts at all.

## Time

**6. Kenya time is a decision, never a default.**

Machines run in Nairobi (UTC+3); servers think in UTC. Any "today", day boundary
or month bucket goes through the EAT helpers in `packages/shared`. Never
`new Date().getHours()`.

> v1: `localMidnightISO` used the server's local midnight. At 22:00 UTC it was
> already tomorrow in Kenya, so a shift's output landed on the wrong day.

## Integrations

**7. The spine is generic; the adapter is not.**

Storage, mapping and review know nothing about any vendor. One adapter per
provider owns its auth, pagination and field names. A second provider must cost
one file and zero migrations.

**8. Never build a configurable field-mapping layer.** Mapping semantics belong
in adapter code — in git, tested, reviewable. Config in the database is
credentials, cursors and toggles; never meaning.

**9. Store the raw payload. Normalise beside it, never instead of it.**

If extraction was wrong, re-derive from what you already hold rather than
re-fetching from a vendor whose record may have changed.

**10. Verify external API behaviour; never assume it.**

> v1: Zoho's `last_modified_time` is an exact match, not "since", and
> `last_modified_time_start` is silently ignored — a 2027 cutoff still returned
> a full page. Both would have looked like working incremental sync while
> quietly re-importing everything. Sorting by `last_modified_time` does work.
> Every one of those was established by calling the API, not by reading docs.

**11. Map on stable external IDs, not display text.** Names get renamed upstream.

## Code

**12. Never swallow an error to produce a friendlier message.**

> v1: the sync function ignored the error from its connection lookup, so a
> permissions failure and a missing config row were indistinguishable. It sent
> us hunting a config problem that didn't exist.

**13. Browser-called edge functions handle CORS** — preflight `OPTIONS` plus
headers on every response. Without it the browser reports only "Failed to send a
request", which names nothing.

**14. Sentinel and error values are filtered at the edge, never stored.**

Vendor sentinels (`-1`, `65535`, `4294967295`) *and* protocol error values.

> v1: OPC UA `BadNodeIdUnknown` was stored as the measurement `2150891520`. Any
> parameter a machine doesn't expose poisons the data with 2.15 billion.

## Testing

**15. CI runs the SQL tests too.**

> v1: six pgTAP suites existed and none ran in CI. Three were silently broken —
> including one that had been failing since the day it was written.

**16. Every integration test seeds two orgs** and asserts A can neither read nor
write B's rows. Multi-tenant safety is a test, not a hope.

**17. Test the boundary, not the middle.** 22:00 UTC, the cutover date itself,
the invoice with one unmapped line out of two.
