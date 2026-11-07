# Native record actions — Mac acceptance, November 7, 2026 UTC

The full product audit found that contact, company, opportunity, task and note editors had no delete action, and directory records had no keyboard-open path. The implementation is described in [record-lifecycle-design.md](record-lifecycle-design.md). This acceptance uses synthetic data in an isolated release-review workspace; no owner mailbox, connector or notification permission was used.

## Reviewed build

- Source `f17ffb209c50b09273c0d4856eb3f41b77c5a88b`, packaged build202, ad-hoc signed and not notarized.
- Archive SHA256 `379d41e0c17a88195de00ced4fbff15d852af4d0034c38986dff4017fb597f0c`.
- [CI42319112636](https://github.com/martinlepage26-bit/controlward/actions/runs/42319112636) and [macOS packaging42319112392](https://github.com/martinlepage26-bit/controlward/actions/runs/42319112392) passed for that exact source.
- Full native suite, new11 record-deletion cases, full SwiftUI debug build, WebKit8 assertions, release packaging, strict signature and extracted-ZIP checks passed.

## Actual application checks

Review `1E2E5F09-3392-4F3C-AC87-B114F680ECE6` was created through onboarding. A blank company name produced a visible validation error. Company and contact creation/editing worked, with Return and Space opening directory editors. Cancelling the company-delete confirmation retained the record and created no recovery copy.

CSV import created one synthetic lead, skipped one nameless row, and repeated import created nothing. Conversion reused the existing company and created the linked named contact,1200CAD opportunity and next-action task. Pipeline remained1200CAD after conversion. Direct opportunity/task edits persisted. Editing an opportunity without touching its displayed close-date control did not invent a stored close date. A note was created, edited and saved with contact, company and opportunity links; its persisted IDs were checked.

The resulting graph contained1 lead,2 contacts,1 company,1 opportunity,1 task and1 note. Each of the five entity types was then deleted through its editor and explicit confirmation. The persisted graph was compared after deletion and after the normal Settings → Review a backup to restore flow:

| Delete | Actual result before restore |
|---|---|
| Note | Only the selected note was removed; other records remained exact |
| Canonical task | Only the task was removed; its lead's next-action task ID and date cleared |
| Opportunity | Task/note opportunity links cleared; lead values/status and other records remained |
| Company | Live company links cleared; both contacts and related records/text remained |
| Linked contact | Live contact links cleared; the unrelated contact and related records/text remained |

All five actions saved distinct complete version2 recovery copies, mode0600 in a0700 folder, before deletion. Each backup contained the original six collections. Settings showed a restore preview, saved a rollback copy, and restored the exact compared record graph. Research generation changed on restore. After the final restore, quit/reopen retained all six collections exactly. The15 normal owner file hashes remained unchanged.

## Scope

These checks establish the native record-action repair. Reminder delivery/cancellation at the operating-system level remains deferred by Martin; the task/date state and model cancellation contract were checked. Historical receipts and upstream records are retained. No outreach, provider activation, production register change, deployment, migration or revenue is claimed. The [full product ledger](completion-ledger-20261106.md) remains active beyond this repair.
