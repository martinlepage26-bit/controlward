# PHAROS Contextward API

Cloudflare Worker edge contract for the native Contextward workspace.

## Routes

- `GET /v1/health`
- `GET /v1/auth/check` (Contextward key)
- `POST /v1/exchange/push` (Contextward key)
- `POST /v1/leads/push` (LeadGen key only): `leadgen.push.v1` body, up to 100 leads,
  each `{source_id, event}` with a `leadgen.event.v1` event. Idempotent per
  `source_id` + content hash; only minimised fields are stored.
- `GET /v1/leads?since=<cursor>&limit=<n>` (Contextward key only): unacked leads
  after the cursor, `contextward.lead-inbox.v1`, with `cursor` and `has_more`.
- `POST /v1/leads/ack` (Contextward key only): `{acks:[{source_id, seq}]}`. Acks
  the exact version pulled and clears its payload.
- Cron `17 3 * * *`: deletes rows acked more than 30 days ago and any row older
  than 90 days.

Keys are Worker secrets: `PHAROS_API_KEY` (Contextward) and `LEADGEN_PUSH_KEY`
(the LeadGen OS exporter on CT920). Neither key can use the other's routes.

`POST /v1/exchange/push` requires `Authorization: Bearer $PHAROS_API_KEY`, an
`Idempotency-Key` header, and a `contextward.exchange.v1` JSON body. The
When a D1 binding is provisioned, the packet persists the payload and enforces
idempotency. Without that binding it returns `persisted: false` and never
pretends a receipt means durable storage.

The included migration creates the receipt table. Creating the Cloudflare D1
database, setting its `database_id`, adding the `DB` binding, and deploying
still require owner-controlled credentials and authorization.

## Local validation

```bash
npx vitest run --config pharos-api/vitest.config.ts
npx wrangler types --config pharos-api/wrangler.jsonc
npx wrangler deploy --config pharos-api/wrangler.jsonc --dry-run
```

Deployment is not performed by this packet.
