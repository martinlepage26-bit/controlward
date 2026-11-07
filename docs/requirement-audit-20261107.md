# Historical209 requirement audit and connected acceptance — 2026-11-07

> Historical checkpoint: build228 is now installed. Use the [current25-row ledger](completion-ledger-20261106.md) and [published release receipt](https://pharos-ai.ca/artifacts/controlward/automatic-prospect-research) for current results. The209 observations below remain evidence for their stated scope; their then-unverified paths are not a current status inventory.

At this checkpoint, build209 remained installed at reviewed app source `4c74c87ab186875548d60a34df84f84b72ffb436`, merged as `9a266f848a39002e724402187d1f3ace9ec75d32`. This pass changes the acceptance harness and guidance; no shipping app source changed. [The25-row ledger](completion-ledger-20261106.md) replaces its stale198/192 checkpoint with current evidence and explicit remaining acceptance. The full hosted task remains in progress.

## Additional installed-app journeys

All UI work used `/Applications/ControlWard.app`, explicitly launched with `bin/review-controlward`; account connections and notifications were off. Processes were checked before binding the UI, and a fresh binding was used after each restart.

- **Copy:** opened the retained public99CAD Quick Scan draft, clicked the actual Copy button, then pasted using Cmd+V into an empty scratch note. All891 UTF16 units matched after newline normalization. Cancelled the note and lead editor; public workspace bytes were unchanged. No mail application was opened.
- **Signals:** in a separate synthetic review, default filtering hid retired evidence; Include retired showed its audit label. Search and the toggle combined correctly. The retired row's project-capture action was disabled. Manual automation qualified only the active high-intent signal. A second run reported no new actions and changed no workspace bytes. Restart retained active Qualified/retired Captured states.
- **LeadGen file:** the real file chooser imported one synthetic JSON event. Reimport reported zero imported/one already recorded, with byte-identical workspace storage. Restart retained exactly one imported lead and its signal; the two pre-existing synthetic signals were unchanged.

The record-action source files (`RecordDeletion.swift`, `DirectoryView.swift`, `EntityEditors.swift`) were compared between the202 acceptance source and209 and are unchanged. Later AppStore changes concern imports/scoring; current save/deletion regressions cover the store. Earlier actual CRUD, CSV, cadence/outcome, account-intelligence, saved-view, activity and security journeys remain separately identified by build in the ledger.

## Current real Project Control backend

Cloned current `martinlepage26-bit/project-control` at `7648722bd87d772d7bb9449d17825836178509ac`, installed its locked Worker dependencies, and ran:

```bash
bin/test-connected-workspace /path/to/project-control
```

The native WebKit runner now explicitly uses `-swift-version 6`, matching the app. The run passes **13 total assertions:8 base WebKit checks and5 connected Worker/D1 checks**. This corrects the earlier ledger's overstatement of13 network checks in addition to8 base checks.

Connected assertions verify the exact snapshot/register, initial-versus-duplicate capture receipt, destination identity, changed-register refusal and a single persisted unassigned inbox item with exact quote/HTML-sensitive source text. This uses the actual bundled dashboard, real HTTP and disposable local D1, with no transport shim. The bundled dashboard remains pinned at `5cfbaf5d644f0f157715e74ecbe041605e586d59`; it is compatible with this current backend. Production register credentials and writes are outside this check.

## Native PHAROS against its real Worker/D1

```bash
bin/test-connected-pharos
```

The new opt-in runner uses only127.0.0.1:8881, a generated temporary configuration, test-only keys and disposable local D1. It removes Cloudflare credential overrides from its child environment and invokes only local Wrangler commands. The native executable uses the actual AppStore/PharosClient, URLSession transport and an in-memory secret store with a temporary native workspace. It opens no owner store, uses no Keychain and schedules no OS notifications. Child processes and temporary state are cleaned on completion.

Twelve native checks pass: wrong-key401; authenticated health/status; unconfirmed exchange refusal; duplicate confirmed exchange; changed exchange; real storage-failure/no-ack; saved linked lead and scores; real ack; reload/replay and cursor persistence; retraction removes the imported lead/signal; tombstone ack; no test API key in workspace. An independent D1 query then confirms **2 exchange snapshots,0 pending items,1 acknowledged tombstone with no payload**. This gate is added to the macOS CI job. The ordinary native suite still runs with no mode argument.

This establishes controlled native-to-real-backend behavior. It does not establish access to Martin's production inbox, successful deployment or operation with a production credential.

## Owner-file and execution boundaries

The exact normal owner file set and all15 content hashes match the original baseline. Fourteen files were already0600; one legacy enrichment report was0644 under a0700 parent. Only that regular file's permission was tightened to0600, preserving bytes, uid/gid and mtime; a private reversible metadata receipt was retained. All15 files are now0600 under0700 roots. The normal app was not launched in this audit. Existing owner Auto-Pilot preference was not changed.

The earlier205 stale-handle startup migration is retained as an incident: the exact pre-migration workspace and full file set were restored, with both versions preserved privately. Background connector/OS activity during that startup was not independently verified. This audit does not erase that limit.

## Remaining configured acceptance

Existing destinations were inferred from saved non-secret endpoints and matching published Worker configuration. Public PHAROS health returned200 with production D1; Project Control health returned200/version2.0.0. PHAROS and KAIROS authenticated paths returned401 without credentials. The saved local Twenty service was unavailable and the saved GAP hostname did not resolve from this Mac. No replacement GAP destination was invented.

The14-case native integration suite uses fakes for PHAROS and Twenty. Separate TypeScript SDK CI reaches a real Twenty test instance; that is not native TwentyClient network acceptance. Current GAP/KAIROS imports and Gmail OAuth/mailbox actions remain unverified against configured accounts. The hosted Email Aggregator remains labelled a prototype. Default-mail-client launch is also untested; its policy gate and actual clipboard path are verified.

Notification delivery/cancellation remains expressly deferred by Martin. Build209 is ad-hoc signed, not notarized. No outreach, account activation, production write/deploy, external migration or generated revenue is claimed. The full task remains open for these applicable configured journeys; fixture checks and public health do not close them.

## Reproducible checks for this change

- `bin/test-connected-pharos`:12/12 native checks and independent D1 state passed.
- `bin/test-connected-workspace /path/to/project-control`:13/13 total assertions passed in Swift6 mode.
- `bin/test-native-app`: full ordinary native suite passed, including all existing connector/workflow cases,11 build-stamp cases and6 agent-client cases.
- `bin/check-native-source-lists`, shell/Node parse checks, workflow secrets guard with4 guard tests and `git diff --check`: passed.

Private evidence includes hashes, review IDs and log receipts; no owner CRM content or credential was committed. Public report: [ControlWard research and acceptance](https://pharos-ai.ca/artifacts/controlward/automatic-prospect-research).
