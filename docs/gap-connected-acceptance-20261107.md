# Native GAP connector against PostgreSQL and PostgREST

The native connector passed26 assertions over14 GET requests against actual
PostgreSQL/pgvector and PostgREST16.5. This is controlled local acceptance, not
verification of the owner's configured Supabase project.

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
GAP's extraction/embedding pipeline or verify its dashboard. It does not test
Supabase's Kong gateway or the new `sb_publishable_` API-key translation; that
native header behavior retains fixture coverage. The owner's saved hostname
and account remain external dependencies. No production database, owner key,
provider activation, outreach or notification delivery is involved.

Runtime references:
[PostgREST installation](https://docs.postgrest.org/en/stable/explanations/install.html),
[PostgREST JWT roles](https://docs.postgrest.org/en/stable/references/auth.html),
[pgvector Docker images](https://github.com/pgvector/pgvector#docker).
