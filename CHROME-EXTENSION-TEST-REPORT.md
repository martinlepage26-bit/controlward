# ControlWard Chrome Integration — Native Review

**Reviewed branch:** `manus/chrome-native-messaging`
**Exact HEAD commit:** `dc49e7b6deec7a2cb8e7ec2151387cd0704c9e05`
**Review basis:** the uncommitted working-tree diff on that branch compared with the exact HEAD above. No implementation code was changed in this review; only this report was reorganized.

## Destination clarification

The proposed bridge writes **Prospect Leads** through `LeadPipelineEnvironment.storeURL` to `ControlWard/leads/prospects.json`, which stores `[ProspectRecord]` and is read by `ProspectLeadsView`.

That is separate from CRM workspace leads: `StorageLocation.workspaceFile` is `Contextward/workspace.json`, and `AppStore` loads `Workspace.leads` as CRM `Lead` values. The reviewed bridge does not convert or import a prospect into that workspace. If the intended destination is the CRM Leads board, that is a separate requirement and needs an explicitly reviewed conversion/import flow.

## Changes present in the reviewed branch

These are implementation changes observed in the branch diff, not a claim that the complete running-app workflow has been accepted:

- The bridge adds `snapshot()` and a read-modify-write `transaction()` that reloads from disk under a lock. `ProspectIngest` uses that transaction, and the native bridge rechecks the reviewed duplicate decision before saving.
- For the bridge save path, `ProspectIngest` now returns a storage error and the host checks it before returning a saved result. The host also performs strict message validation, explicit pairing, bounded staging, and requires a separate save confirmation.
- The capture path validates segment IDs against the host’s bundled ICP configuration and uses the existing guarded fetch, site extraction, qualification, and RBQ code. A user-entered municipality hint is discarded for qualification/RBQ. The saved record is marked `.externalSearch` with `fetcher = "chrome-extension"`; fetched-page evidence and timestamps are retained. The bridge adds no Worker request.

### Pre-existing behavior, not a new branch fix

The base commit already used `Data.write(..., options: .atomic)` in `ProspectLeadsStore.replace`, and the existing `SecureFiles.writePrivate` helper also performed atomic writes with private permissions. Atomic replacement prevents torn-file writes; it does not by itself serialize concurrent read-modify-write operations or surface swallowed errors. The base `replace()` used `try?` for encoding, directory creation, and writing. The branch adds transaction/locking behavior; it did not introduce atomic writes.

## Remaining gaps in the reviewed diff

1. **Lost updates between writers — partially addressed.** The new transaction path is an improvement, but serialization is not established for every writer. `NSLock` is per store instance, while POSIX record locks are process-associated; distinct store instances in the same process are not shown to mutually exclude one another. `replace()` remains outside the transaction path. An already-installed app would not automatically gain the new lock behavior, and the installer does not verify or update that app. The added store regression is sequential through one store instance, not a concurrent-writer test.

2. **Silent load/save failures — partially addressed.** The host save checks transaction errors, but `ProspectLeadsStore.init` still uses `try?`, so unreadable or malformed `prospects.json` can appear as an empty in-memory store. `replace()` still swallows errors. The native app’s `LeadPipelineEnvironment.searchAndIngest` discards the ingest result, and its summary is based on search reports rather than confirmed persisted records. Thus the bridge path has stronger error reporting than the existing app load/search paths.

3. **UI refresh after an external save — not addressed.** `ProspectLeadsView` loads records into `@State` on its initial `.task` and reloads after its own search. The diff adds no file watcher, app-level refresh signal, or return-to-view reload. An already-open Prospect Leads screen can remain stale after a separate host process writes the JSON file.

4. **Trusted qualification inputs/provenance — partially addressed.** Segment, guarded website fetch, municipality exclusion, and external-search provenance are handled as described above. However, `businessName` remains user-editable and is passed directly as `LeadCandidate.name`, then used as the prospect organisation and research name. The reviewed path does not independently confirm that identity against the fetched first-party site; the name also influences qualification/conflict text and identity generation. The current-tab `sourceURL` is audit context, while the host separately fetches `websiteURL`; those origins need to remain distinct and mismatches require verification/review.

5. **App/host version compatibility — not addressed.** The host reports static `hostVersion = "1.0.0"` and protocol version `1`, and packages its own SwiftPM resources. The app source declares version 1.1.1/build 103, but the installer checks only that the sandbox container exists. There is no handshake for installed app version, rules/config identity, or prospect-store schema. The installed app’s actual version was not inspected; a separately built host may therefore run beside an app with different rules or writer behavior without a compatibility gate.

## Tests not run and validation status

- **Chrome extension validation: NOT RUN.** The extension was not loaded or exercised in Chrome. A previously reported TypeScript/structural script pass is static artifact checking only, not extension validation.
- **End-to-end acceptance: NOT RUN.** No complete extension → native host → saved Prospect Leads → refreshed running-app workflow was exercised.
- **Concurrency regression tests: NOT RUN.** Required cases include concurrent transactions through two store instances in one process, simultaneous separate processes, and a bridge write racing an app-version writer. Assert no lost records, valid JSON, and correct duplicate rechecks.
- **Failure/refresh/trust/compatibility regression tests: NOT RUN.** Required cases include malformed/unreadable storage and failed writes surfaced to UI without overwrite; external save updating an already-open view; mismatched business name/site and municipality-hint non-influence; provenance preservation and Worker-policy refusal; and mismatched app/host/config/schema versions failing closed.
- **Previously reported native tests:** 61/61 lead-pipeline tests passed, including sequential transaction/duplicate approval. That does not cover the cases above. The aggregate `bin/test-native-app` command exited 133 because two PHAROS API Vitest checks did not run (missing Worker test dependencies), leaving the aggregate tally at 54/56.
- **Previously reported native protocol smoke:** passed against an emitted executable using temporary pairing data, but did not test app-store interoperability, Chrome launch, or UI refresh. SwiftPM did not achieve a clean build-script exit under the local cache policy.
- **App/host compatibility acceptance: NOT RUN.** No installed app was launched or version-checked. `ControlWard/leads` was absent in the previous read-only container inspection; this review did not create it or inspect prospect records.

Passing CI or individual unit/protocol checks does not establish that the complete running-app workflow works. The remaining items above are gaps in the exact reviewed diff; re-review any later final branch/head and diff before deciding which remain open or authorizing fixes or integration testing.
