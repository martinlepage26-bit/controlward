# Contextward

Contextward is a local-first macOS relationship and operations workspace for
PHAROS. It combines a native SwiftUI CRM, governed external connectors, a
Twenty app extension, and a small Cloudflare Worker/D1 edge service.

## What is operational

- Native Contacts, Companies, Opportunities, Tasks, Notes, pipeline, saved
  views, Lantern audits, LeadGen signals, automations, and activity history.
- Owner-only atomic local persistence with backups, import limits, corruption
  blocking, and Keychain-backed connector credentials.
- Authenticated PHAROS exchange pushes and lead-inbox pulling through the live
  `pharos-contextward-api` Worker and D1.
- Read-only Gap Analysis imports with pagination and lifecycle reconciliation.
- User-triggered, read-only Kairos inbox imports for conversations classified as leads. The Kairos key stays in macOS Keychain; imported handles and latest messages stay in the local workspace.
- Preview-bound Twenty pushes that create or update records and never delete.
- Hardened-runtime macOS builds, signed with the Developer ID identity when it
  is present in the keychain and ad-hoc signed otherwise, packaged as
  reproducible checksum-bearing ZIPs.
- Daily retention on the edge service: intake rows (7 days for test leads, 400
  days otherwise) and lead-inbox rows (30 days after ack).

## Mac build

```bash
./bin/test-native-app
./bin/build-native-app
open native-crm/dist/Contextward.app
```

The persistent Desktop shortcut is:

```text
~/Desktop/Contextward.app -> native-crm/dist/Contextward.app
```

Create a verified release archive with:

```bash
./bin/package-native-app
```

See [`native-crm/README.md`](native-crm/README.md) for data paths, migration,
security boundaries, imports, and native behavior.

## Worker validation

```bash
corepack yarn install --immutable
yarn test:worker
yarn check:worker
```

The live public health endpoint is:

<https://pharos-contextward-api.ml-c38.workers.dev/v1/health>

See [`pharos-api/README.md`](pharos-api/README.md) for the authenticated route
contract, retention policy, deployment procedure, and secret boundaries.

## Twenty extension

The `src/` Twenty extension is formally DESCOPED. It stays in the repository as
a parked scaffold and is not connected to the operational pipeline: nothing in
the live flow (native app, `pharos-contextward-api` Worker, lead inbox, or
Project Control intake) depends on it. The extension code is kept, not deleted,
for a possible future pickup, and extension CI remains in place as scaffold
validation only. Local setup and the persistent Lima-based development
environment are documented in [`SETUP.md`](SETUP.md). The native app does not
require Twenty, Docker, a browser, or a localhost server to run.

## Release gates

GitHub CI validates the extension, Worker, Twenty integration, native Swift
tests, and native release compilation. Production Worker deployment is manual
and environment-gated; it requires the repository's protected
`CLOUDFLARE_API_TOKEN` secret and performs tests, a dry run, D1 migrations,
deployment, and live health verification in that order.
