# PHAROS lead-gen slice 1: SPEC

Status: draft, scoped by Water, built by Fire, scored by Earth, reviewed by Argus.
Nothing merges, deploys, or runs live without Martin's first-hand OK.

## Goal

ControlWard itself (Swift, `native-crm`, not an agent) finds ONE prospect from public
websites only, in ONE segment (Montréal clinics), records why it fits AI governance,
saves ONE first-email DRAFT in ml@pharos-ai.ca's Gmail, and adds ONE lead row marked
as waiting on Martin to BOTH Project Control D1 databases: `e1e9fa25` (me.com account)
and `959e5bdb` (PHAROS account).

## Water's seven points

1. Dry-run is the default. The one live run needs an explicit flag and Martin's first-hand OK.
2. Fetch only the prospect's own public website, respect robots.txt, use a host allowlist, and allow no Google Maps or data-broker hosts. Log every fetched URL.
3. Exactly one prospect in one segment; a test shows >1 is refused.
4. The fit reason cites evidence from pages on the prospect's own domain (LIVE-R6), quoting body text and never only 'privacy' or a footer link (LIVE-R4).
5. Gmail on ml@pharos-ai.ca: ONLY the create-draft action. A test proves 0 send/read/delete calls. The draft carries a recorded consent basis (Loi 25 / CASL) and a CASL unsubscribe footer. Sign as Martin Lepage, PhD, with no em dashes.
6. D1: INSERT only, one row per DB, both marked as waiting on Martin, each read back after the write. A test shows UPDATE/DELETE are refused. No schema changes: the row goes into the existing `projects` table unless Martin says otherwise. Tests also cover: row count +1 exactly, and a before/after checksum showing existing rows unchanged.
7. Every test fails before the code is written, CI ends green, and nothing deploys.

## Earth's checks

- Fit: the reason quotes body text, never only "privacy" or a footer link (LIVE-R4); all evidence sits on the prospect's own domain (LIVE-R6).
- Draft: recorded consent basis and CASL unsubscribe footer; saved as a draft only; 0 calls to send, read, or delete mail.
- D1: both databases see INSERT statements only (plus read-only SELECT for count, checksum, read-back); row count +1 exactly in each; a before/after checksum shows every existing row unchanged.
- Sources: only public sites on an allowlist; no Maps or data-broker hosts.
- Evidence: each item has a test that fails first, a CI log naming it with counts, and logs from the one live run after Martin's OK.

## D1 schema finding (read-only inspection, 2026-10-24)

Both databases have `projects`. No schema change is needed.

- `e1e9fa25` project-control (me.com): `projects(id, title, outcome, domain, status DEFAULT 'Candidate', next_action, deadline, review, blocked, link, deferrals, exposure, origin_type, origin_connection, origin_note, rev, created NOT NULL, updated NOT NULL, expires_at)`. It has NO `review_flag` or `review_note`.
- `959e5bdb` project-control (PHAROS): the same 19 columns plus `parent_id, level, portfolio, node_kind, domain_tags, review_flag, review_note, workspace, source_ref`.
- Both use status values Active, Waiting, Blocked, Completed, Abandoned, Candidate (959e5bdb also Parked). `status` DEFAULTS to `'Candidate'`.

Row written (columns common to both): `id, title, outcome, domain, status='Waiting', next_action, review='waiting on Martin', link, origin_type='controlward-leadgen', origin_note, rev=1, created, updated`. On `959e5bdb` only, also `review_flag='waiting-on-martin'`. Because the column default is `'Candidate'`, `status` is always written explicitly.

## Open questions

- Q1 (Martin): what does "never write a candidate" cover? Two readings: (a) never email the prospect, drafts only; (b) never write a candidate record. Note that `projects.status` defaults to `'Candidate'` in both DBs, so (b) may mean that status. Until Martin answers, both are enforced: no send path exists in code, and the D1 guard refuses any statement naming a table or status like `candidate` and refuses an INSERT that omits `status`.
- Q2 (Martin): confirm `projects` is the right table for a lead, rather than `items` (959e5bdb only).
- Q3: no live adapter or UI entry point is wired to the app in this slice; the live run needs a small runner using env/Keychain credentials, added only after Martin's OK.

## Hard limits

No live Gmail or D1 calls except the read-only schema inspection above. All tests use fakes. No sending, inbox reading, deleting, bulk, or deploy. Credentials come from env or Keychain only.
