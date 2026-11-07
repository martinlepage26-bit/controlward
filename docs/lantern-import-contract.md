# Lantern import and recovery contract

Lantern CSV and XLSX imports validate a complete file before changing the native workspace. A successful workspace commit publishes the imported audits and their activity together. An unreadable file, invalid row, ambiguous audit identity or failed write throws an error and leaves that file's records unapplied. Operations retains import errors in an alert until dismissed; when several files are selected, errors identify the failed files and clarify that other files may have imported.

## Supported input

- Flat CSV/XLSX rows use `audit`, `client`, `language`, score columns and `sample_size`/`samples`. Language is FR or EN, case insensitive. Supplied scores must be whole values from0 to100; equivalent spreadsheet numbers such as80.0 are accepted. Sample counts must be non-negative whole values; overflowing totals are refused. Existing partial score-column exports remain supported.
- Canonical workbooks use their English and French transcript worksheets. Numeric0–5 scores convert to the native0–100 scale. Invalid, non-finite or partially filled scores are refused. A template row containing only its prefilled transcript ID is not scored evidence and is ignored; an entirely unfilled template imports no audit.
- Canonical transcript IDs, workflow, date, taxonomy codes and quoted excerpts are retained with the language and source filename. Import does not contact a provider or send a message.

## Refreshing an audit

The audit name identifies a local refresh. If more than one saved audit has that exact name, resolve the duplicate names before importing; the importer never chooses one or deletes them all. An unambiguous refresh retains the audit ID, creation date, CRM links, owner findings, remediation and reviewed methodology. Imported scores, sample counts and transcripts replace the previous export rather than accumulate duplicates. Identical transcript IDs remain stable on replay. A blank incoming client name preserves the saved client label.

## Acceptance

The native CSV/import suite includes real directory-blocker failures and retry/reload checks for both CSV and workbook inputs, reviewed-context replay, ambiguous identities, whole-file validation, canonical score/evidence retention, invalid canonical scores and unfilled templates. These fixtures are created by the tests; the suite does not read an owner's Downloads workbook. Final running-app, packaging and installed-source evidence is maintained with the [full product ledger](completion-ledger-20261106.md) and the published ControlWard report.
