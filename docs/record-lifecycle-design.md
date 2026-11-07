# Complete native record actions

The full ControlWard acceptance audit found that storage supported deleting contacts, companies, opportunities, tasks and notes, but their editors exposed no deletion action. The directory also had no selectable keyboard-open path. This work closes that documented CRM lifecycle gap; it does not change provider authority.

## Contract

- Existing entity editors expose a labelled delete control and an explicit confirmation. New forms show required-field errors rather than silently ignoring Save. Notes can select their opportunity as well as contact/company.
- Directories retain a selected record and open it with Return or Space. Edit and project controls remain separate accessible children.
- Deletion validates the current identity, saves a complete private version2 recovery backup, applies local link changes, and publishes only after the workspace commit succeeds. A failed backup or commit leaves the record and its relationships unchanged. Recovery copies never overwrite one another.
- A contact/company deletion clears its live links across native records and mail metadata. An opportunity deletion clears task/note links. Related records, their own text and source evidence remain.
- Deleting the lead's next-action task clears its date and link, so neither automation nor reminder fallback recreates it. The last legacy next-action task follows the same rule. Deleting an ordinary associated task leaves a different next action alone.
- Lead deletion closes its next-action task, clears live lead links and retains upstream dismissal identity. No upstream record is deleted.
- Historical capture, GTM and remediation task receipts remain. Deleted-task labels must say that work was deleted rather than imply an active task. Current-destination Twenty identities are retained for compatible recovery; no remote delete or write occurs.
- Settings exposes the private deletion-backup folder and its normal reviewed restore path. Restore continues to preserve endpoints, merge exclusions, reset automation and rotate the research generation. No new persisted workspace schema is introduced.

## Evidence required

The new11-case native suite exercises link cleanup, non-cascading content retention, canonical/legacy task reminders, no automatic recreation, upstream dismissal, private complete backup/restore, stale identities, real backup failure, real workspace-commit failure and retry. The full native suite and app debug build pass at the implementation checkpoint.

Before release, verify the actual directory keyboard/edit controls, blank validation, five delete confirmations, cancellation, associated records, task date/reminder state, note/opportunity relation, normal recovery UI and restart using synthetic review data. Packaging, exact-head CI, installed-source identity and unchanged owner files remain release gates. This does not replace the full product ledger or require provider credentials, outreach or notification permission changes.

Actual packaged acceptance is now recorded in [record-actions-acceptance-20261107.md](record-actions-acceptance-20261107.md): all five entity deletes/restores, private backups, keyboard editing, validation, CSV conversion, exact relationships and restart passed at202. Installed release identity is reported separately after the release gate.
