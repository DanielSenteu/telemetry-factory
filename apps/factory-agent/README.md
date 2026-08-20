# Factory Agent

On-prem collector for machine data. Connects to TECHMATION tmSCADA-iD201 OPC UA
gateway boxes on the factory LAN, subscribes to production parameters, filters
vendor sentinel values, computes reset-aware production deltas, and ships
readings to the cloud.

Readings hit a local disk queue (`queue/`, ndjson segments) **before** any
network attempt — the boxes have no HistoryRead, so the queue is the only thing
standing between an internet outage and permanent data loss. A shipper flushes
segments oldest-first every 10s to the `ingest-machine-readings` edge function
and deletes each segment only on ack (at-least-once delivery; the server
dedupes on `(machine_id, observed_at)`).

Design + hardware background: `docs/erp-roadmap-2026-07.md` §1 and `docs/hardware/`.

## Development (no hardware needed)

Two terminals:

```bash
pnpm simulator     # fake tmSCADA boxes on opc.tcp://127.0.0.1:26543, :26544
pnpm agent         # connects (uses config.example.json), prints JSON readings
```

The simulator misbehaves on purpose — sentinel values (machine 2's power meter),
counter resets, alarms, idle periods — because that's what the real hardware does.

Options: `pnpm simulator -- --machines 4 --cycle 5`

With `cloudUrl`/`agentToken` empty (the example config), the agent runs in
**local mode**: readings are logged but nothing touches disk or network.

## Cloud setup (once per org)

1. Apply migration 35 (`machine_integration`) — tables `factory_agents`,
   `machines`, `machine_readings`, view `machine_deltas`.
2. Deploy the ingestion function **without JWT verification** (the agent
   authenticates with its own token, not a Supabase JWT):
   `supabase functions deploy ingest-machine-readings --no-verify-jwt`
3. Mint a token as an org admin (returned exactly once, only the hash is stored):
   `SELECT create_factory_agent(<org_id>, 'factory-floor-pc');`

## Factory deployment (go-live day)

1. Copy this app to any always-on Windows/Linux PC on the factory LAN.
2. `cp config.example.json config.json`; enter each box's real endpoint
   (`opc.tcp://<box-lan-ip>:16664`), the cloud URL
   (`https://<project>.supabase.co/functions/v1/ingest-machine-readings`)
   and the org's agent token.
3. Run as a service (NSSM on Windows / systemd on Linux). Keep the PC's clock
   NTP-synced — `observed_at` comes from this machine, and the server rejects
   readings stamped more than 5 minutes in the future.

`config.json` is gitignored — it contains the org's agent token.
`queue/` is the disk buffer; it drains automatically once the network is back.

## Tests

```bash
pnpm test        # sentinel filtering, delta/reset math, disk queue, shipper
pnpm typecheck
```
