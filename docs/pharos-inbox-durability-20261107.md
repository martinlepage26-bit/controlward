# PHAROS inbox page durability

Two regressions failed against the222 model code: a blocked save published an
unsaved lead/signal/epoch/job, and a blocked retraction visibly removed records
or changed the cursor/job despite leaving the upstream item unacknowledged.
The old no-ack check alone did not establish local publication safety.

Each inbox page now applies to a candidate workspace. Its records and source
epoch are written before publication and acknowledgement. A failed page leaves
the previous visible and durable workspace intact. An acknowledgement failure
retains the already saved records and the previous cursor; replay deduplicates
them. Successful acknowledgement is followed by a durable cursor commit. A
later failed page retains earlier committed progress. Recovery-blocked
workspaces refuse the operation.

Jobs and activity use durable commits too. If storage cannot save the failure
diagnostic, the connector panel retains the latest failed attempt outside the
workspace, replacing it on successful retry. Only committed operations count
as progress kept.

## Evidence

- Native inbox suite17/17 passes, including both blocked-write regressions,
  retry/reload, paging, failed acknowledgement, source-epoch reset, deduplication,
  retraction, dismissal and counts-only diagnostics. A101-record case fails the cursor save after the first100 records were acknowledged, then verifies exact durable progress and retry of the final record.
- `bin/test-connected-pharos` passes14 native assertions against the actual
  repository Worker and disposable local D1. The new assertions check that a
  failed read/save exposes no phantom record or metadata, and that a blocked
  real tombstone retains the visible record, original durable bytes and the
  upstream pending item until retry.
- Independent D1 inspection finds2 exchange snapshots,0 pending items and1
  acknowledged tombstone with no retained payload. The test service and its
  temporary data are removed after the run.
- GAP's actual migrated PostgreSQL/PostgREST acceptance is recorded
  [separately](gap-connected-acceptance-20261107.md). It covers26 assertions
  over14GETs and does not establish Supabase gateway or owner-account access.

Reproduce on a Mac with the project's locked JavaScript dependencies:

```sh
./bin/test-native-app
./bin/test-connected-pharos
```

The PHAROS origin audit required no code change: the current Worker push
contract accepts only an `inbound_form` provenance with a named form source or
an explicitly marked test record. General prospect pushes are refused. Local
LeadGen file imports use the separate `leadgen-file:` prefix, treated as
manual/file input when grounding a draft. These source checks do not establish
buying intent or validate arbitrary historical inbox data.

Configured owner destinations, native Gmail OAuth/mailbox actions and
notification delivery retain their existing acceptance boundaries. No owner
credential, outreach or production change was used for these checks.
