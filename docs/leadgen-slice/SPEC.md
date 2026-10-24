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
6. D1: INSERT only, one row per DB, both marked as waiting on Martin, each read back after the write. A test shows UPDATE/DELETE are refused. No schema changes: the row goes into the existing `projects` table unless Martin says otherwise. Tests also cover: row count +1 exactly, and a before/after checksum showing existing rows unchanged. (Superseded in part by decisions (a) to (f) below: the row goes into a new `leads` table.)
7. Every test fails before the code is written, CI ends green, and nothing deploys.

## Earth's checks

- Fit: the reason quotes body text, never only "privacy" or a footer link (LIVE-R4); all evidence sits on the prospect's own domain (LIVE-R6).
- Draft: recorded consent basis and CASL unsubscribe footer; saved as a draft only; 0 calls to send, read, or delete mail.
- D1: both databases see the one migration, INSERT into `leads`, and read-only SELECT only; `leads` count +1 exactly in each; a before/after checksum shows every existing row and table schema unchanged.
- Sources: only public sites on an allowlist; no Maps or data-broker hosts.
- Evidence: each item has a test that fails first, a CI log naming it with counts, and logs from the one live run after Martin's OK.

## Decisions that replace parts of point 6 (from Jade, Martin told her to infer)

- (a) The lead row goes into a NEW `leads` table, created by the additive migration `docs/leadgen-slice/migrations/0001_create_leads.sql` (exactly one `CREATE TABLE IF NOT EXISTS leads` statement), run in both D1s. NO row is written to `projects`, and there is no ALTER, DROP, or UPDATE on any existing table. The migration is applied only during the live run after Martin's OK, never before.
- (b) "Never a candidate" is resolved: a candidate is a Project Control candidate record of the kind Martin's paused intake routine used to create. The D1 guard refuses any candidate record, status, or kind, any write to a table whose name contains "candidate", and any write to `projects`. The Gmail draft itself is allowed.
- (c) LIVE-R4: "privacy" or a footer link alone never counts as fit evidence. LIVE-R5: the draft carries a recorded consent basis plus the CASL unsubscribe footer.
- (d) The live run logs, before and after, in both D1s: the row count, a row checksum, and a schema checksum (`sqlite_master.sql`) of every existing table, plus the `projects` row count, which must be unchanged. The only allowed difference is the new `leads` table. Any other difference fails the run.
- (e) If either D1 already has a `leads` table, the run STOPS before any insert and reports it so Martin can be asked.
- (f) Martin's live-run OK must name the new `leads` table in both DBs (`e1e9fa25` and `959e5bdb`).

## Tests (fakes only, each written to fail first)

LG1 dry-run default; LG1 live needs flag and OK; LG2 allowlist; LG2 Maps and broker hosts; LG2 robots.txt and fetch log; LG3 exactly one prospect; LG4 body quote on own domain (LIVE-R6); LG4 footer or privacy-only refused (LIVE-R4); LG4 off-domain refused; LG5 createDraft only, 0 send/read/delete; LG5 consent basis, CASL footer, signature, no dashes (LIVE-R5); LG6 one INSERT into leads per DB, 0 projects writes; LG6 checksum and count logging; LG6 changed row or schema fails; LG6 existing leads table stops the run; LG6 UPDATE/DELETE/DROP/ALTER/other refused; LG6 never a candidate; LG6 migration scan (one CREATE, 0 ALTER/DROP/UPDATE).

## D1 read-only inspection (2026-10-24, SELECT and PRAGMA only, rows_written 0)

Neither database has a `leads` table or any table whose name contains "candidate".

- `e1e9fa25` project-control (me.com): tables `_cf_KV, projects, incidents, notes, events, sqlite_sequence, connections, settings, baselines`. `projects` has 104 rows and 19 columns (id, title, outcome, domain, status DEFAULT 'Candidate', next_action, deadline, review, blocked, link, deferrals, exposure, origin_type, origin_connection, origin_note, rev, created, updated, expires_at).
- `959e5bdb` project-control (PHAROS): tables `_cf_KV, d1_migrations, sqlite_sequence, projects, incidents, notes, events, connections, settings, baselines, submission_rounds, items`. `projects` has 216 rows and the same 19 columns plus parent_id, level, portfolio, node_kind, domain_tags, review_flag, review_note, workspace, source_ref.

## Open questions

- Q1 resolved, see decision (b).
- Q2 resolved: the live runner is wired as the CLI subcommand `FollowUpOSNative leadgen` (`LeadgenLive.swift`, `LeadgenEntry.swift`). It is dry-run by default: it prints the plan and makes no fetch, Gmail, or D1 call. `--live` also needs `--confirm "leads in e1e9fa25 and leads in 959e5bdb"`, and the run refuses anything else. Live order: read-only schema check of both DBs (STOP if `leads` exists); then, per DB, checksum (rows plus `sqlite_master.sql`) and `projects` count before, apply 0001, INSERT one row, read back, checksum and counts after; then the one Gmail create-draft on ml@pharos-ai.ca; every step goes to `~/Library/Logs/ControlWard/leadgen/leadgen-run-<time>.log`. The row's `draft_ref` is the draft's locally generated Message-ID, so no UPDATE is needed after the draft exists. Credentials are resolved at run time from env or Keychain references named in the local config, never from code. There is no UI button in this slice.
- Q3 resolved: the CASL footer address comes only from the uncommitted local config `~/Library/Application Support/ControlWard/leadgen.local.json` (`leadgen.local.json` is in `.gitignore`; `docs/leadgen-slice/leadgen.local.example.json` is the committed template with placeholders). The draft refuses to build without an address. A denylist in code holds only one street name, Saint-Hubert (that address belongs to another business), and it matches every spelling.

## Tests added for Q2 and Q3 (failing first)

LG1 a vague `--confirm` is not live; LG7 CLI dry-run prints the plan and touches nothing; LG7 `--live` without the exact confirmation refuses before any adapter is built; LG7 live step order, with the Gmail draft last; LG7 run log file under the log directory; LG8 the draft refuses to build without the address config; LG8 a Saint-Hubert footer address is refused; LG8 the repo holds only the placeholder example and ignores the local config.

## Runbook: the one live run (only after Martin's OK names the `leads` table in both DBs)

1. On the Mac, at the PR head: `swift build --package-path native-crm`.
2. Edit `~/Library/Application Support/ControlWard/leadgen.local.json` (mode 600): keep `postalAddress`, then add the one `prospect` (organization, own-domain site, published contact email), `paths`, `consent` (basis, the URL where the address is published, time recorded), and `credentials` (the two Cloudflare account IDs plus env or Keychain reference names for the two D1 tokens and the Gmail compose token). Store the secrets in Keychain (`security add-generic-password -s <service> -a leadgen -w`), not in the file.
3. Dry-run: `native-crm/.build/debug/FollowUpOSNative leadgen`. Check that the prospect, pages, address `set`, and consent `set` lines are right.
4. Live, once: `native-crm/.build/debug/FollowUpOSNative leadgen --live --confirm "leads in e1e9fa25 and leads in 959e5bdb"`.
5. Check the printed result: `leads 0 -> 1` and `existing tables unchanged` for each DB, plus the draft ID. Open the run log path it prints: the before/after checksums of every table and the `projects` counts must match.
6. If it prints `stopped before any insert: a leads table already exists`, or any other stop, do nothing more and report the log.
7. Martin reads the draft in ml@pharos-ai.ca and sends or discards it himself. The runner never sends.

## Hard limits

No live Gmail or D1 calls except the read-only schema inspection above. All tests use fakes. No sending, inbox reading, deleting, bulk, or deploy. Credentials come from env or Keychain only.
