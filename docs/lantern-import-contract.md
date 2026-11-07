# Lantern import and recovery contract

Lantern CSV and XLSX imports validate a complete file before changing the native workspace. A successful workspace commit publishes the imported audits and their activity together. An unreadable file, invalid row, ambiguous audit identity or failed write throws an error and leaves that file's records unapplied. Operations retains import errors in an alert until dismissed; when several files are selected, errors identify the failed files and clarify that other files may have imported.

## Supported input

- Flat CSV/XLSX rows use `audit`, `client`, `language`, score columns and `sample_size`/`samples`. Language is FR or EN, case insensitive. Supplied scores must be finite numbers from0 to100; fractional values are retained without rounding. Sample counts must be non-negative whole values; overflowing totals are refused. Existing partial score-column exports remain supported.
- Canonical workbooks use their English and French transcript worksheets. Numeric0–5 scores convert to the native0–100 scale. Invalid, non-finite or partially filled scores are refused. A template row containing only its prefilled transcript ID is not scored evidence and is ignored; an entirely unfilled template imports no audit.
- Canonical transcript IDs, workflow, date, taxonomy codes and quoted excerpts are retained with the language and source filename. Import does not contact a provider or send a message.

## Refreshing an audit

The audit name identifies a local refresh. If more than one saved audit has that exact name, resolve the duplicate names before importing; the importer never chooses one or deletes them all. An unambiguous refresh retains the audit ID, creation date, CRM links, owner findings, remediation and reviewed methodology. Imported scores, sample counts and transcripts replace the previous export rather than accumulate duplicates. Identical transcript IDs remain stable on replay. A blank incoming client name preserves the saved client label.

## Language rollups and unknown assessments

CSV language scores are sample-weighted means of every positive-weight source row. Each canonical transcript has weight1. Zero-sample rows remain in the evidence register but do not change the aggregate. Per-row counts and score-field completeness are saved with the raw transcript scores. For example, French20 ×1 and100 ×3 produce80; compared with English60, the gap is20. Source row order does not change the result.

A gap requires complete, valid French and English assessments and positive sample counts for both. Missing languages, missing score columns and explicit owner withholding decisions remain **Unscored**. They are excluded from the average and do not create gap-remediation tasks. A genuine measured zero with positive samples is still a valid score. The audit editor exposes each language's completion decision and explains an unavailable comparison. New manual assessments start incomplete.

An explicit owner decision to withhold a comparison survives source refresh. Reimport replaces source-owned score values and rebinds positive approval to the refreshed evidence; owner links, findings and remediation remain. Legacy integer scores still decode. A legacy multi-row record without its row weights is retained but needs reimport or explicit review before comparison; its former last-row aggregate is not silently endorsed.

Scores now retain fractional precision in native JSON. Older integer-only builds do not support these new fractional assessments. Before using an older application, restore a backup made for that version; retaining the old app alone does not roll back the data. Current builds read the earlier integer backups.

## Acceptance

The native CSV/import suite includes real directory-blocker failures and retry/reload checks for both CSV and workbook inputs, reviewed-context replay, ambiguous identities, whole-file validation, canonical score/evidence retention, invalid canonical scores and unfilled templates. These fixtures are created by the tests; the suite does not read an owner's Downloads workbook. Final running-app, packaging and installed-source evidence is maintained with the [full product ledger](completion-ledger-20261106.md) and the published ControlWard report.
