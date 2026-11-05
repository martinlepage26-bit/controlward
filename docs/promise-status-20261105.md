# ControlWard promise status — 2026-11-05

Later Mac work and newly reproduced defects are tracked in [fulfillment progress](fulfillment-progress-20261105.md).
The Linux-only results below remain the record of the cloud session; they do not override later Mac evidence.

This document replaces the status claims in the 2026-10-14 reports (`FINAL-STATUS.md`, `GAP-AUDIT-20261014.md`,
`docs/product-promises-gap-20261014.md`). Those files are kept as history. Several of their gaps are now closed in
code: Auto-Pilot is a Settings toggle that defaults to off, task and contact editors have relationship pickers,
task reminders are scheduled when a task is added or saved and again at launch, and PHAROS push requires a preview
fingerprint. Those claims were checked by reading the code only and have not been re-tested here.

Branch `claude/epic-ramanujan-c3t11l`, base `2d7a734`. Environment: a Linux cloud container with Swift 6.1 (Docker
image `swift:6.1-noble`) and Node 22. The repository pins Node 24.5; the JavaScript suites passed on 22 anyway.
**Not available: macOS, Xcode, SwiftUI/AppKit, the Keychain, UserNotifications, a GUI, owner credentials.** All
records used were synthetic. No mail was sent, no mailbox was changed, nothing was deployed, and no production
service or migration was touched.

## Correction (second pass, same day)

The first pass relocated `TwentyObject`/`TwentyLink` with a script that sliced the file at stale offsets.
That left `Integrations.swift` with a truncated `TwentyObject` and a broken `TwentyClient` doc comment,
so the Mac build would not compile. The first pass ran `swiftc -parse` only on the files it meant to edit,
so the damage went unnoticed. It also left `bin/test-workspace-modules` without `LeadWorkflow.swift` and
the lead pipeline sources that AppStore now needs. Both are fixed in `7a7d6a9`. Every Swift file (92) is now
parse-checked, and `bin/check-native-source-lists` fails if the two Mac test scripts' source lists drift apart.

## Status vocabulary

- **verified**: a test that exercises the behavior ran and passed in this session.
- **partial**: the logic was tested here, but the app, UI or relaunch path runs only on the Mac. Or Mac tests exist
  for it but were not run in this session.
- **blocked**: needs the owner's Mac, GUI, notification permission or credentials.
- **unavailable**: not implemented.

A compile, a parse check or reading the code never counts as **verified**.

## Commands run (this session)

| Command | Result |
| --- | --- |
| `bin/test-portable` (Swift 6.1 container; `CW_PHAROS_PLANTED_REDS` set from the vitest JSON report) | PASSED. Lead pipeline 90/90; slice 3 planted reds 74/74; mail control 9/9; Project Control writes 4/4; mail outcome 3/3; slice 1/2/4 reds 7/5/3 |
| `bin/test-crm-core` (new, same container) | PASSED, 23/23 (second pass). Also passes with the process time zone set to UTC+14 and UTC−11 |
| `bin/check-native-source-lists` (new, bash) | consistent. Fails on the pre-fix `test-workspace-modules` list (planted red) |
| `swiftc -parse` on every `.swift` file (92: Sources, Tests, LinuxShims, WebKitTests) | 0 errors. Syntax only |
| `yarn test:worker` | 60/60 |
| `yarn test:unit` | 1/1 |
| `yarn lint` / `yarn typecheck` | 0 warnings, 0 errors / exit 0 |
| `swiftc -parse` on edited SwiftUI/AppKit files | Syntax only. They cannot be type-checked here |
| AppStore additions type-checked against a stand-in class with the same members | Clean under Swift 6. This is not the real AppStore |
| `zsh bin/test-native-app` (Swift 6.1 Linux container, zsh installed) | exit 1: `AppStore.swift:1:8: error: no such module 'AppKit'`. Platform limit; **pending Mac verification** |
| `zsh bin/test-workspace-modules` (same) | exit 1: same `no such module 'AppKit'`. **Pending Mac verification** |
| `bin/build-native-app` | Not run (needs macOS) |

The first baseline `bin/test-portable` run failed only because `node_modules` was missing: Argus reds 9 and 10 read
RED-NOT-RUN. After `yarn install --immutable` and passing the vitest report into the container, the suite passed.

Planted-red check of the new suite: reintroducing the `nil == nil` context match and the double count made 2 of
the 18 cases fail. The source was then restored.

## Lead → follow-up workflow

| Step | Status | Evidence here | Still unverified |
| --- | --- | --- | --- |
| 1. Find or import a lead | partial | Prospect search pipeline 90/90 (fake transport, synthetic). New: a Ready prospect enters Pipeline once, and held, dropped and to-fix records are refused with nothing written (`CRMWorkflowTests`). Worker lead push/pull 60/60 | Live search; the CSV/LeadGen/Lantern import suite `CSVImportTests` (Mac); OSM discovery (`DiscoveryTests`, Mac); KAIROS (`KairosTests`, Mac) |
| 2. Source, evidence, dedup, explainable score | partial | Evidence lines with the source ID and "buyer intent unknown". Itemised record-completeness score that disclaims intent. Dedup by source ID and email on promotion; by name/legal form, email and phone on conversion (phone with a conflicting email stays separate). Pipeline dedup rules covered by the 90 pipeline tests | SwiftUI rendering of the evidence block |
| 3. Convert to linked contact, company, opportunity | partial | Preview, then confirm; fill-only; idempotent; a stale preview or a blocker writes nothing; a company-only listing creates no person; no value is invented (6 cases) | SwiftUI confirmation dialog (parse-only). AppStore `convertLead` type-checked against a stand-in only. Mac smoke check added, not run |
| 4. Stage, notes, owner-entered value, next action | partial | Stage from lead status; value only from the owner-entered quote; follow-up task is the next action and moves when a follow-up is logged; won/lost mirrors both ways | Editor UI |
| 5. Reminder and grounded draft | partial / pending Mac | Reminder at 9 AM on the due day in the reminder's calendar, even when that calendar's time zone differs from the process's (fixed in the second pass); explicit instant first; none when the task is done or past. A rescheduled lead moves its task; a rescheduled task moves the lead; a won or lost lead, or its opportunity, closes the task. Local draft: only recorded facts. A hand-entered lead with no inbound record is never thanked for getting in touch, and its subject is "Introduction". On-device (AI) draft: the model gets facts, unknowns and the grounded draft, never internal notes. Output that implies unrecorded contact, a conversation, a quote, a number or a placeholder falls back to the grounded draft, with the reason shown (3 cases + planted reds) | Notification delivery and cancellation (**pending Mac**: needs the Mac and notification permission). The real FoundationModels call (macOS 26 only) is unverified; only its prompt and the output guard are tested |
| 6. Owner review before sending or external writes | verified (gates) / partial (app) | Mail: unconfirmed reply/trash refused with 0 requests; DELETE refused before the network; allowlist; audit lines (portable 9/9 + reds 7/3). Project Control capture refusals with 0 POSTs (4/4 + reds 5/5). Lead draft "Email" only opens the owner's mail app; ControlWard sends nothing (code) | PHAROS push fingerprint and Twenty preview (`IntegrationTests`, Mac). In-app confirmation dialogs |
| 7. Persistence after relaunch | partial / blocked | `workspace.json` round trip with AppStore's encoder options and the `PersistentWorkspace` decoder. Links, value, stage, next action, note link and evidence survive. A pre-change workspace still loads | AppStore reload smoke check added to `NativeSmokeTests` (Mac, not run). Quit-and-reopen in the running app (**blocked**) |

Outcomes: the Pipeline totals ($ won, $ still open, close rate) count only owner-entered values. A converted lead is
counted once, through its opportunity. Before this change it was counted twice, so a $5,000 quote showed as
$10,000 open. Records without a value are counted, never estimated. There is no forecast, probability or
score-based revenue anywhere in these totals. `AccountScoring` already labels its fit "not a conversion probability".

## Product contract

| Promise | Status | Evidence | Gap / owner step |
| --- | --- | --- | --- |
| CRM records and relationships | partial | Conversion and relaunch cases (Linux). The unlinked-context bug is fixed and has a regression test | Mac `NativeSmokeTests` relationship reloads not run |
| Pipeline (stages, due, values) | partial | Outcome totals; stage mapping | Pipeline UI |
| Tasks and reminders | partial / pending Mac | Reminder timing; the follow-up task and the lead's next follow-up stay the same date in both directions; a closed deal closes its follow-up task; automation no longer adds a second task for a converted lead (AppStore, inspection) | Delivery and cancellation need the Mac |
| Notes and activity | partial | Conversion and promotion write activity events; note links survive the round trip | Activity view (Mac) |
| LeadGen evidence | partial | Worker: push provenance, retract and test marking (60/60, incl. Argus reds 9–10); prospect evidence carried into the CRM | Native inbox pull (`LeadInboxTests`, Mac) |
| Lantern audits | partial | Unchanged code. Lead context now lists only linked audits | `CSVImportTests` (Mac) |
| Saved views | partial | Unchanged code | Mac only |
| Backups and restore | partial | Unchanged code. New fields are plain workspace data, so backups include them | `ControlWardTests` restore confirmation and rollback (Mac) |
| Connector status and errors | partial | `ConnectorStatus.resolve` shows Active only when a recorded health check passed (inspection) | `IntegrationTests`/`SecurityTests` (Mac). No live connector verified |
| Project Control review and capture | verified (write gate) | PC writes 4/4; slice 2 reds 5/5 | WebKit bridge `test-workspace-modules` (Mac). PC stays the authority for project decisions |
| Mail review | verified (action gate) | Mail control 9/9; slice 1/4 reds | Live Gmail unverified (no credentials, by instruction) |
| Supported connector flows | partial | Worker routes 60/60 against a local test D1 | Production Worker, PHAROS, KAIROS, GAP and Twenty not contacted |

Boundaries left as documented: GAP stays read-only, the hosted Email Aggregator stays labelled a prototype, the
Twenty extension stays parked, credentials stay in the Keychain, and Project Control stays authoritative.

## Owner-side acceptance (needs the Mac)

Use a throwaway data folder. `FOLLOWUPOS_DATA_DIR` overrides the folder in Debug builds only; otherwise use
`./bin/preview-controlward`.

1. `./bin/test-native-app` and `./bin/test-workspace-modules`: expect `CRM workflow tests: 23/23 passed`, the
   conversion relaunch smoke check, and the WebKit module tests to pass. This is the first real type check of
   `AppStore.swift`, `Integrations.swift` and the edited SwiftUI files: `LeadEditorView`, `ProspectLeadsView`
   and `PipelineView`.
2. `CONTEXTWARD_SIGN_IDENTITY=- ./bin/build-native-app`, then open the app.
3. Pipeline → Leads: run a search, then choose **Add to pipeline for review** on one Ready row. Held rows have no
   button.
4. Open the new lead and check **Source and evidence** and the completeness line. Set a next follow-up date, then
   choose **Review conversion…**. Read the preview, then choose **Convert**.
5. Check that Companies, Contacts, Opportunities and Tasks each show one linked record. Check that `$ still open` did
   not double.
6. Write a follow-up message. Check the **Grounded in** and **Not stated** lines, then choose **Email**. Mail.app
   opens a draft; do not send it. Choose **Mark as sent** and check that the follow-up task's date moves.
7. Grant notifications. Check that a pending reminder exists (or wait for it to fire) at 9 AM on the due date.
   Change the lead's next follow-up date and save; the task's date and the reminder should move. Then mark the lead
   **Won**; the follow-up task should show Done, and no reminder should remain.
   With Apple Intelligence on (macOS 26), regenerate a draft for a hand-entered lead. It must not thank them for
   getting in touch. If the model adds anything that is not recorded, the editor shows the grounded draft and the
   reason.
8. Quit with Cmd+Q, reopen, and repeat step 5.
9. Settings: export a backup, restore it, and check that the links and the follow-up task are still present.
10. Optional CI: run the `build-macos-app` workflow on this branch with `workflow_dispatch`. It tests, packages and
   uploads an unsigned ZIP artifact. It was not triggered from this session.
