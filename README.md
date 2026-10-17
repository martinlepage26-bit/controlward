# ControlWard

ControlWard combines ContextWard's native macOS CRM, the bundled Project Control
dashboard, and Email Aggregator in one desktop home. GAP remains a read-only
research source. Review mail metadata, link records to projects and capture
selected evidence into the project inbox with explicit confirmation.

See [the section-by-section guide](docs/controlward.md), [product direction](PRODUCT.md)
and [design system](DESIGN.md). The hosted email app is still a synthetic-mail
prototype; real mailbox OAuth and a production GAP connection are not included.

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
CONTEXTWARD_SIGN_IDENTITY=- ./bin/build-native-app
open native-crm/dist/ControlWard.app
```

For an isolated synthetic preview with no Keychain access or persistent browser
sessions, run `./bin/preview-controlward`. It creates a separate temporary app
and dataset. The release preserves the existing ContextWard bundle ID and data
location; it does not rename or migrate the owner's files.

Create a verified release archive with:

```bash
CONTEXTWARD_SIGN_IDENTITY=- ./bin/package-native-app
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
environment are documented in [`SETUP.md`](SETUP.md). The native app does not require Twenty, Docker or a localhost server. Embedded
modules use macOS WebKit; Email Aggregator needs network access.

## Release gates

GitHub CI validates the extension, Worker, Twenty integration, native Swift
tests, and native release compilation. Production Worker deployment is manual
and environment-gated; it requires the repository's protected
`CLOUDFLARE_API_TOKEN` secret and performs tests, a dry run, D1 migrations,
deployment, and live health verification in that order.
