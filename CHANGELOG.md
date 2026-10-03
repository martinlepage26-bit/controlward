# Changelog

All notable changes to this application are documented in this file.

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
