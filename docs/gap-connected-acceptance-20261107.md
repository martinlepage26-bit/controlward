# Native GAP connector against PostgreSQL and PostgREST

The native connector passed26 assertions over14 GET requests against actual
PostgreSQL/pgvector and PostgREST16.5. This is controlled local acceptance, not
verification of the owner's configured Supabase project.

The additional official Supabase Envoy gateway run now passes35 native assertions
over19 native requests: the original26/14 direct database/API checks plus9/5
through the gateway. Four explicit controls (three gateway requests and one direct PostgREST request)
are separate. Shipping app source is unchanged from build224.

## Source and runtime

- GAP source: `martinlepage26-bit/GAP` at
  `c5e24d5a29e7499ab30f8bfc49cc89428fd5acfe`, clean and unchanged.
- All17 committed SQL migrations were applied in order, including the write
  revocations and private-corpus policies.
- PostgreSQL image:
  `pgvector/pgvector@sha256:7d0a41464797aeb9862dfdc0bbf1526b82cfd324cdd8036df19e3545f4a9ccb8`.
- PostgREST image:
  `postgrest/postgrest@sha256:1347d7552b88f17832912c06afbf7c43209af6eeeb60834b04aae12c9bd9d5cc`.

The harness creates a dedicated Docker network. The database has no published
port; PostgREST is published only on127.0.0.1:8885. A loopback gateway on8884
rewrites `/rest/v1/gap_clusters` to PostgREST's `/gap_clusters`, forwards the
query and auth headers, and relays the real response. It does not generate
cluster responses or emulate the query engine. The native client uses
`URLSessionTransport` and is restricted to that GET route.

Roles and initial default grants model the Supabase schema bootstrap before
the repository's migrations revoke access. Generated passwords, JWT signing
secret and short-lived anon JWT live only in owner-private temporary files.
The test independently confirms that anon can read gap clusters, cannot write
them, and cannot read raw corpus documents.

## Verified behavior

The three native phases pass12,9 and5 assertions respectively:

1. An invalid JWT gets401 from real PostgREST. Valid native verification and
   import succeed. Numeric keyset pagination reads all501 active clusters,
   excludes a retired cluster, decodes the actual one-to-one score embedding,
   retains a cluster with no scores, and preserves the Unicode label and score
   components. Replay preserves every local UUID. Owner routing is saved.
2. SQL changes one label/score, retires one cluster and adds one. An actual
   blocked workspace write publishes no new, changed or retired record and
   retains the old durable bytes and failure display. Retry saves exactly one
   new record, one update and one retirement, retaining owner decisions and
   existing local identities. Retired records remain available for audit but
   leave active exchange.
3. SQL reactivates the retired cluster. Native import restores the same local
   identity and owner workflow without duplication.

Every phase verifies exact workspace reload, a second numeric pagination
request, and absence of the generated JWT from persisted records/diagnostics.
The gateway independently counts the same14 GET requests. The final SQL audit
finds503 clusters,502 active clusters,500 score rows,0 raw documents and0 jobs,
matching only the harness's explicit fixture changes. The native connector
performs no backend write. Container/network/temp-file cleanup is verified in
the private proof receipt.

## Reproduce

Use Docker, the project's Node and a Mac with the native Swift prerequisites.
Pull the two exact image digests above, then use a clean GAP checkout at the
pinned commit without local environment files:

```sh
CONTROLWARD_GAP_SOURCE=/absolute/path/to/clean/GAP \
  ./bin/test-connected-gaps
```

`CONTROLWARD_GAP_REPORT=/private/path/proof.json` optionally retains a0600
receipt after cleanup. The script refuses a different/dirty GAP checkout,
local environment files, missing pinned images or occupied test ports. It
removes only the resources carrying its generated fixture label. Credentials
are not printed. The existing Colima/Docker runtime is not stopped by the
harness, because it may serve other work.

## Limits

This verifies the native read/import workflow against GAP's actual migrated
schema, database privileges and PostgREST JWT/query semantics. It does not run
GAP's extraction/embedding pipeline or verify its dashboard. Legacy Kong and
Supabase's managed platform are not tested. The owner's saved hostname
and account remain external dependencies. No production database, owner key,
provider activation, outreach or notification delivery is involved.

## Official Supabase Envoy gateway

Supabase's current self-hosted default is Envoy, rather than Kong. The additional
acceptance uses the unmodified four gateway configuration/entrypoint files from
`supabase/supabase` at `dc73b346c1f37eaae9e529fae81a4307b78fefe6` and the image
specified there, pinned as:

`envoyproxy/envoy@sha256:1fde8efee875e4e4f6a39a90fe49d9338e1caacce5762034ef9fb4bbb9ad6aed`.

The harness checks the exact Git blob hashes before using those files:

| File | Git blob |
|---|---|
| envoy.yaml | def443b68817921d98180b58d558006a2f86233f |
| cds.yaml | a2bb565ae8360ef1388e7ad072850e6bb09c1eed |
| lds.template.yaml | d5648c8287e62cfaddce37cbeb17370020172a7b |
| docker-entrypoint.sh | 2c67584a30e151879e11b21939b9f1ed9857a38f |

Fresh opaque publishable/secret keys, HS256 legacy keys and ES256 internal JWTs
enable the official translation path. The EC private key stays in process memory;
PostgREST receives only the public EC JWK and the disposable legacy symmetric key.
The existing three direct phases run first. A fourth phase forwards native
requests through the official Envoy listener and its unmodified authentication,
translation and routing filters to the same real PostgREST/database:

- Unknown publishable key gets401.
- Legacy anon JWT still works.
- Opaque publishable key verifies and reimports all502 records without changes.
- The native client sends the opaque key only as `apikey`, with no Bearer value;
  the gateway supplies an ES256 anon JWT, verified by actual PostgREST.
- Native `sb_secret_` refusal occurs before any gateway request. This is a format
  guard, not a claim that arbitrary elevated legacy JWTs were tested.
- Exact reload, credential absence and second-page behavior remain verified.

Three direct gateway controls verify401 without an API key,403 for the OpenAPI
root with a public key, and401 for an invalid ES256 signature carried alongside
a valid publishable key. A fourth control reaches PostgREST directly without a
JWT and is refused. A fixture-only pre-request function requires an explicit
Bearer header and verified anon claims with expiry on the gap route. Its root
health probe remains usable. This prevents anonymous-role fallback from falsely
proving JWT translation; the function does not alter the committed GAP policies
or generate a response. Readiness probes are not included in native request counts. The final database audit remains503 clusters,502 active,
500 score rows,0 corpus documents and0 jobs. Cleanup includes the Envoy container.

To reproduce, obtain the four files from the exact Supabase commit above and pull
the exact Envoy digest, in addition to the earlier prerequisites:

```sh
CONTROLWARD_GAP_SOURCE=/absolute/path/to/clean/GAP \
CONTROLWARD_SUPABASE_GATEWAY_SOURCE=/absolute/path/to/docker/volumes/api/envoy \
  ./bin/test-connected-gaps
```

The optional gateway phase uses loopback port8886. The fixture uses only the REST
route; Auth, Storage, Realtime, Studio and the other Supabase services are not
started or claimed as verified.

[Supabase Envoy architecture](https://supabase.com/docs/guides/self-hosting/self-hosted-envoy)
and [key translation](https://supabase.com/docs/guides/self-hosting/self-hosted-auth-keys)
describe the contract tested here. Self-hosted acceptance does not establish
the owner's managed Supabase project or credentials.

Runtime references:
[PostgREST installation](https://docs.postgrest.org/en/stable/explanations/install.html),
[PostgREST JWT roles](https://docs.postgrest.org/en/stable/references/auth.html),
[pgvector Docker images](https://github.com/pgvector/pgvector#docker).
