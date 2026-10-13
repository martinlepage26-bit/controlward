# Changelog

All notable changes to this application are documented in this file.

## Unreleased

- Self-hosted CI now waits for a GitHub-hosted secrets preflight. The guard
  rejects whole-context, wildcard and mixed-case secret access, allowing only
  explicit `secrets.GITHUB_TOKEN` references.
- Kairos answered-only updates now mark new leads as contacted even when the
  inbound message timestamp is unchanged; local workflow states are preserved.
- Windows-1252 imports accept every defined C1 character, including Š, š, Ž,
  ž and Ÿ. Undefined bytes remain rejected; use UTF-8 for legacy files whose
  encoding is ambiguous.
- Fixed CSV import for Excel and Windows exports: CRLF and CR line endings now
  split rows instead of collapsing the file into one row.
- CSV import detects semicolon (French-locale Excel) and tab delimiters, and
  honours an Excel `sep=` first line.
- CSV import accepts UTF-16 (with or without a byte-order mark) and
  Windows-1252 files and drops a leading byte-order mark, which previously
  broke Lantern header matching. Likely mixed/corrupt UTF-8 and files with
  undefined Windows-1252 bytes are rejected instead of importing garbled accents.
- Delimiter detection samples the first rows and ignores leading blank lines.
- Quote amounts parse English and French formats (`$2,500.00`, `2 500,00 $`).
  A lone `.` is always a decimal point; a lone `,` groups thousands only in
  the `2,500` shape.
- French lead headers (`Nom`, `Prénom`, `Courriel`, `Soumission`, …) map
  without regard to accents; `Prénom` + `Nom` combine into the full name.
- Imports that find nothing now say so instead of failing silently.

## 0.1.0 - 2026-09-26

- Shipped the native Contextward macOS workspace (Developer ID signed when a
  signing identity is available, ad-hoc otherwise).
- Added guarded PHAROS and Twenty connectors with Keychain-backed credentials.
- Added the PHAROS lead inbox with pagination, acknowledgement, retractions,
  persisted cursors, and automatic polling.
- Added read-only Gap Analysis ingestion with keyset pagination, retirement,
  and reactivation.
- Added preview-bound Twenty pushes and corrupt-workspace write protection.
- Added the Cloudflare Worker/D1 backend, retention cron, production validation,
  and reproducible native release packaging.

## 0.1.0

- Initial application scaffolded with [`create-twenty-app`](https://www.npmjs.com/package/create-twenty-app)
