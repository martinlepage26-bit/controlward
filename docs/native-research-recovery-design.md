# Native research recovery design

Status: design for implementation under the active full ControlWard goal. This is not runtime proof. Scope includes native CRM and prospect research; no provider credentials, hosted registers, mail sessions, notifications or production services change.

## Demonstrated problem

The actual build192 backup exported on November6 has only `createdAt`, `schemaVersion` and `workspace`. It contains three saved leads with their QuickScan evidence but none of the six-site research cache. Restoring a backup also has no relationship to pending agent requests. A reliable native backup must preserve the unreviewed research and must not revive old queued work.

## Decision and tradeoff

Use the existing atomic native workspace as the canonical home for native website candidates and research. This makes CRM and research backup/restore one file transaction rather than introducing a multi-file restore journal. Keep standalone portable lead-pipeline files as an explicitly separate source, and preserve the legacy research file when importing it. Continue to keep ephemeral requests, heartbeat/process IDs, provider sessions, credentials and hosted module state outside backups.

This increases the workspace's size. Enforce the existing bounded backup budget and surface capacity errors before publishing a change. Never truncate evidence or silently omit a collection. A private recovery delta may retain completed research when the main workspace cannot be written; it is included in the next complete export/recovery and must not resurrect ignored data after a deliberate restore.

## Components and contracts

1. Move only the pure `DiscoveryCandidate` and `WebsiteResearchCache` data types into a Foundation-only source included by native and portable manifests. Do not pull the HTTP/UI discovery client into Linux model compilation.
2. Extend `PersistentWorkspace` compatibly with canonical website research, a migration marker, a UUIDv4 research generation, a consumed recovery-delta fingerprint, and restored exclusion entries. Missing legacy fields decode safely.
3. `AppStore` owns the research directory and durable research mutations. A custom test workspace defaults to an adjacent isolated research directory, never the owner's live folder. Release review and acceptance previews retain dedicated roots. Check the preview branch of `LeadPipelineEnvironment.defaultRoot` explicitly; it must not read the owner's research.
4. Import the legacy `quick-scan-research.json` once, using strict size/schema checks, into the canonical workspace. Preserve original bytes and a private pre-migration workspace backup. An unreadable source stays preserved and blocks research replacement with a visible error; ordinary CRM recovery remains explicit.
5. Agent and manual discovery persist candidates/results through AppStore's commit-before-publication boundary. A write failure keeps visible findings and, when the separate research directory is writable, writes a private bounded recovery delta. On repair, recover that delta idempotently by source and evidence time, then remember its fingerprint. Do not silently promote recovered findings or send anything.
6. Native backups include canonical/unreviewed/recoverable research and the currently readable exclusions as data. Version2 reads old version1 backups. Existing native endpoints, current remote identities, queued writes, health resets and default-off automation safeguards remain.
7. Restore is blocked while native research is active. A successful restore replaces native records/research in one workspace commit, rotates the research generation, and merges exclusions conservatively with current exclusions. A legacy backup without research retains existing research with an explicit preview note. Existing exclusion files remain untouched; restored exclusions participate in every native draft/handoff check so a backup never re-enables an excluded recipient.
8. The local handoff protocol carries the workspace research generation in availability and requests. Pending/partial requests from an old generation are cancelled without a fetch after restore/reset. New requests read the new generation. Old clients/requests are refused explicitly rather than silently replayed. Never use a backup-supplied generation to revive old work.
9. Every native suppression consumer combines current readable policy with restored exclusions and remains fail-closed if the current file is damaged. Portable model entrypoints retain their file-backed contract; native wrappers supply the additional restored policy.

## Integration, failure and observability

- Workspace and research mutations stay on MainActor; no network completion publishes into a restored generation. A native active-research counter/token covers both GUI and agent paths and clears on success, cancellation or failure.
- Private exports/rollback/recovery files are mode0600 in owner-only folders. No arbitrary paths or endpoints from a backup are executed, opened, contacted or used as storage destinations.
- A failed write never publishes a changed workspace; corrupt legacy/recovery data is never overwritten. Export refuses incomplete evidence with an actionable reason instead of calling the bundle complete.
- The restore preview states native record/research counts, the presence of legacy limitations, exclusions retained and queued-work cancellation. Status/errors persist beyond a toast.
- The current implementation is single-user, bounded local JSON. No distributed service, new runtime dependency or database migration is required.

## Acceptance tests before release

- Old workspace and version1 backup load; absent/new/corrupt legacy cache; one-time migration and original-byte preservation; mode0600.
- Six candidates/results, three exact unsent drafts, source evidence, links and follow-up tasks survive export, reviewed restore and actual app restart. Unreviewed findings remain present.
- Failed main-workspace save publishes nothing, retains/reports recoverable observations, and recovers once after storage repair. Replayed recovery does not duplicate records or override newer evidence.
- Export refuses corrupt/unreadable source policy rather than asserting a complete backup. Restore retains existing exclusions, adds backed-up exclusions, and cannot weaken a damaged current policy.
- Restore/reset during active research writes nothing and explains cancellation/wait. A queued old-generation request after restore is terminally cancelled with zero HTTP requests. A new-generation request works.
- Preview/test research roots cannot equal the normal root; no owner-file additions or hash changes during acceptance.
- Full native/portable/core/WebKit/controlled Worker checks, actual Mac workflow, package/extracted signature, exact-head CI, reproducible build identity and current public evidence.

These tests are part of the full completion ledger, not a replacement for its remaining operations/account/security/provider requirements. Martin's notification deferral and the existing no-outreach/credential boundaries remain.
