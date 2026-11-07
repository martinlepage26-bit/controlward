# Read-only import durability and current KAIROS acceptance

This work concerns ControlWard's local import transaction and read-only KAIROS
client. The KAIROS and GAP repositories were inspected without changing them.
Production accounts, Keychain contents, notifications and outreach are outside
these checks.

## Demonstrated failure and repair

Two new cases failed against the original ControlWard implementation:

- GAP returned a synced job while the workspace folder was replaced by a file.
- KAIROS returned a failed job but left unsaved imported data or health in the
  visible workspace.

Both importers now apply data, job, activity and health through one
`commitWorkspace` transaction. The candidate is published after the complete
write succeeds. A failed save retains the prior visible and durable workspace,
surfaces the error, and allows retry after storage is restored. A failed read
can save a failed-job diagnostic when storage is available. GAP refuses imports
while workspace recovery is blocked.

The regression cases exercise new and existing leads/signals, upstream updates,
GAP retirement, owner decisions, actual blocked writes, retry and exact reload.
The full native suite passed after the repair: GAP13/13 and KAIROS5/5, along with
the other native suites. The original red and repaired green outputs are
retained in the private completion evidence.

## Actual KAIROS Worker and disposable D1

`bin/test-connected-kairos` runs the actual KAIROS source at
[`b37e1f792b0ca3f11a760779d0eb5b0047f8ec35`](https://github.com/martinlepage26-bit/kairos/tree/b37e1f792b0ca3f11a760779d0eb5b0047f8ec35)
with its committed migrations and pinned Wrangler4.85.0. It uses an explicit
local configuration on127.0.0.1:8883, temporary D1/KV/R2, generated disposable
keys, revoked synthetic channels and no production bindings or cron triggers.
The native client uses `URLSessionTransport`, not an HTTP fake.

The run passed19 assertions over8 real GET requests:

- Unknown key returns401; the current service's operator key returns403.
- Customer-account verification and inbox reads succeed.
- Two lead-intent entries import; an ignored lead and a non-lead entry are
  skipped. A separate account's lead is excluded by the real service.
- Answered status, IDs, Unicode message text and timestamps map correctly.
- Replay creates nothing; a blocked local save publishes no phantom data,
  success job or health result; retry preserves IDs and reload is exact.
- A later inbound message written to the actual D1 database imports once while
  retaining the owner's quote-sent status and notes.
- Client requests use only GET `/v1/me` and GET `/v1/inbox`. No test key is
  saved in the workspace or diagnostics.

An independent D1 query retained5 fixture conversations and found0 outbound
messages,0 reply drafts,0 posts and0 jobs. The harness verifies that both native
connected phases actually ran before accepting their results. It terminates the
local service and removes its temporary database; the private receipt records
verified cleanup.

These are19 assertions, not19 network requests. The service can update API-key
last-use metadata during a GET; client read-only behavior does not mean that the
server performs no internal bookkeeping.

## Reproduce

Use a clean KAIROS checkout at the pinned commit, with no local `.env` or
`.dev.vars` files (committed `.example` templates are allowed). Install its
locked dependencies with `npm ci --ignore-scripts --no-audit --no-fund`, then run:

```sh
CONTROLWARD_KAIROS_SOURCE=/absolute/path/to/clean/kairos \
  ./bin/test-connected-kairos
```

The script refuses another source commit, a dirty source tree, an unexpected
Wrangler version or an occupied test port. An optional
`CONTROLWARD_KAIROS_REPORT` path receives private proof JSON after cleanup.
The macOS CI job checks out that exact service commit and runs this acceptance
alongside native and real PHAROS acceptance.

## Boundaries and remaining work

The current KAIROS endpoint returns up to200 prioritized conversations. It
accepts customer-account API keys; operator inbox access requires KAIROS's
interactive sign-in. This acceptance does not bypass that restriction or prove
access to the owner's operator inbox. ControlWard does not import browser
sessions.

GAP source was refreshed to
[`c5e24d5a29e7499ab30f8bfc49cc89428fd5acfe`](https://github.com/martinlepage26-bit/GAP/tree/c5e24d5a29e7499ab30f8bfc49cc89428fd5acfe).
Its actual PostgreSQL/PostgREST acceptance is still pending. Configured owner
destinations and native Gmail OAuth/mailbox actions remain separate acceptance
dependencies. The working Gmail browser composer at217 is unchanged. The
current installed build, source, archive and UI receipt are recorded in the
[current completion report](https://pharos-ai.ca/artifacts/controlward/automatic-prospect-research).
