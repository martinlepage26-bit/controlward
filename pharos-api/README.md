# PHAROS Contextward API

Cloudflare Worker edge contract for the native Contextward workspace.

## Routes

- `GET /v1/health`
- `GET /v1/auth/check` (Contextward key)
- `POST /v1/exchange/push` (Contextward key)
- `POST /v1/leads/push` (LeadGen key only): `leadgen.push.v1` body, up to 100 leads,
  each `{source_id, event}` with a `leadgen.event.v1` event. Idempotent per
  `source_id` + content hash; only minimised fields are stored. An optional
  `retract: [source_id]` (up to 100) turns leads LeadGen withdrew (deletion,
  consent withdrawn, disqualified) into PII-free tombstones.
- `GET /v1/leads?since=<cursor>&limit=<n>` (Contextward key only): unacked leads
  after the cursor, `contextward.lead-inbox.v1`, with `epoch`, `cursor` and
  `has_more`. Tombstones arrive as `{source_id, seq, retracted: true}`. A new
  `epoch` means the inbox was recreated and the client resets its cursor.
- `POST /v1/leads/ack` (Contextward key only): `{acks:[{source_id, seq}]}`. Acks
  the exact version pulled and clears its payload.
- Cron `17 3 * * *`: deletes lead rows acked more than 30 days ago (unacked
  leads stay until pulled) and exchange snapshots older than 30 days.

Keys are Worker secrets: `PHAROS_API_KEY` (Contextward) and `LEADGEN_PUSH_KEY`
(the LeadGen OS exporter on CT920). Neither key can use the other's routes.

`POST /v1/exchange/push` requires `Authorization: Bearer $PHAROS_API_KEY`, an
`Idempotency-Key` header, and a `contextward.exchange.v1` JSON body. The
When a D1 binding is provisioned, the packet persists the payload and enforces
idempotency. Without that binding it returns `persisted: false` and never
pretends a receipt means durable storage.

The included migrations create the receipt and lead-inbox tables. The production
Worker is `pharos-contextward-api`, backed by the configured
`pharos-contextward` D1 database and scheduled at `17 3 * * *`.

## Local validation

```bash
yarn test:worker
yarn check:worker
```

Production deployment is deliberately separate from validation:

```bash
npx wrangler d1 migrations list pharos-contextward --remote --config pharos-api/wrangler.jsonc
npx wrangler deploy --config pharos-api/wrangler.jsonc
curl --fail --silent --show-error https://pharos-contextward-api.ml-c38.workers.dev/v1/health
```

The remote health response must report `environment: "production"` and
`storage: "d1"`. Never place either Worker secret in source, command arguments,
logs, or GitHub workflow files.
