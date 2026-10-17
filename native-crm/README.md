# ControlWard for macOS

This is the native, persistent macOS workspace for ControlWard, the PHAROS
relationship and operations system. It uses SwiftUI/AppKit, stores its JSON data in
an owner-only folder (see Data location), and does not start Docker, a browser, or a
localhost server.

The workspace now includes separate Contacts, Companies, Opportunities, Tasks,
Notes, LeadGen Signals, Lantern bilingual audits, local automation rules, and an
activity register. Records can be related by UUID and edited from dedicated
native directory views. LeadGen JSON, flat Lantern CSV exports, and the canonical
Lantern XLSX workbook layout can be imported with source-file provenance, retaining
transcript-level language scores, taxonomy codes, and quoted notes. This is a local single-user workspace, not yet a
multi-user sync service or the full Twenty server platform.
Kairos can be connected as a read-only source: a user-triggered import copies
only lead-intent conversations into local leads, deduplicated by conversation id.
The Kairos API key is stored in macOS Keychain; Contextward never sends replies
or publishing actions back to Kairos.
Due follow-ups can also be scheduled as explicit native macOS notifications;
the app does not send outbound messages automatically.
The default Overview combines CRM, LeadGen, Lantern, Pharos findings, automation,
and sync-queue state in one command-center view.
Configured adapter endpoints expose a read-only HTTP preflight; the preflight
does not transmit workspace data or provider credentials.
Staged outbox packages include deterministic sync manifests with entity counts
and idempotency keys for downstream adapters.

The companion `pharos-api` directory contains the PHAROS-owned edge endpoint
contract for health checks and authenticated exchange intake. The Worker is
deployed to the configured Cloudflare account with D1 receipt persistence;
provider credentials remain outside the native workspace.

## Build and test

```bash
./bin/test-native-app
CONTEXTWARD_SIGN_IDENTITY=- ./bin/build-native-app
```

The locally signed bundle is created at:

```text
native-crm/dist/ControlWard.app
```

The bundle intentionally remains in this workspace to comply with the managed
Mac host boundary. `bin/build-native-app` uses the installed Developer ID
Application identity when available and otherwise falls back to an ad-hoc local
signature. Both paths enable the hardened runtime and App Sandbox
(`Resources/Contextward.entitlements`: sandbox, user-selected read-write files,
and outbound network access). An explicit `CONTEXTWARD_SIGN_IDENTITY=-` build signs locally without inspecting
Keychain identities. Notarization is a separate distribution step and is not
claimed here.

Create a versioned, checksum-bearing ZIP without modifying workspace data:

```bash
CONTEXTWARD_SIGN_IDENTITY=- ./bin/package-native-app
```

Release artifacts are written below `native-crm/release/`, which is excluded
from Git. The packaging command re-runs the complete native test/build/signature
gate before producing the archive and SHA-256 file.

## Data location

The app stores `workspace.json` in `Application Support/Contextward/`. Because
the app is sandboxed, macOS resolves that inside its container:

```text
~/Library/Containers/com.pharos.contextward/Data/Library/Application Support/Contextward/
```

The folder is mode 700 and every file in it (workspace, reset backups, sync
outbox) is mode 600. Outbox packages are deleted once synced or discarded.
`Reset all data` writes `workspace-backup-<timestamp>.json` there first.
`FOLLOWUPOS_DATA_DIR` overrides the folder in Debug builds only.

### Migrating from `native-crm/data/workspace.json`

Earlier builds kept data in `native-crm/data/`. Migrate it once, either way:

- `./bin/migrate-native-data` after opening and quitting the app once (so the
  container exists), or
- Settings, then `Import legacy workspace.json…`, and select the old file.

Both copy the file, verify the copy by SHA-256, set the original to mode 600,
and keep it as a backup. Neither overwrites an existing workspace or deletes
the original.

## Import limits

Every import (CSV, XLSX, LeadGen JSON, exchange JSON) is capped at 20 MB and
10,000 records; an XLSX entry may inflate to at most 50 MB. XLSX files are read
in-process (no `unzip` subprocess). CSV headers must match exact names or known
alternatives. LeadGen JSON must match the `leadgen.event.v1` schema; events
without `schema_version` are treated as v1.

CSV text accepts UTF-8, UTF-16 and Windows-1252, including the defined extended
letters and punctuation. Undefined Windows-1252 bytes and likely mixed/corrupt
UTF-8 are rejected. Legacy encodings can share valid byte sequences; export Mac
Roman or other legacy files as CSV UTF-8 to avoid ambiguous character decoding.

## Unified desktop

See [ControlWard workflows](../docs/controlward.md) for Projects, Email Aggregator,
mail metadata imports, cross-section links, reviewed capture and backup/restore.
The release bundles Project Control resources from a pinned commit;
`./bin/vendor-project-control --check` verifies every allowed file hash.
`./bin/test-workspace-modules` exercises real WebKit rendering and isolation.
