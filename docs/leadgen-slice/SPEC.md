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
- Q2 resolved: the live runner is wired as the CLI subcommand `FollowUpOSNative leadgen` (`LeadgenLive.swift`, `LeadgenEntry.swift`). It is dry-run by default: it prints the plan and makes no Gmail or D1 call. With `directoryURL` empty it also makes no fetch and prints `directory not configured` and `prospect: not configured`. With a directory URL it fetches that page and the one clinic's own site. `--live` also needs `--confirm "leads in e1e9fa25 and leads in 959e5bdb"`, and the run refuses anything else, including a missing directory URL. Live order: read-only schema check of both DBs (STOP if `leads` exists); then the one Gmail create-draft on ml@pharos-ai.ca; then, per DB, checksum (rows plus `sqlite_master.sql`) and `projects` count before, apply 0001, INSERT one row, read back, checksum and counts after. The row's `draft_ref` is the id returned by create-draft. If a row insert fails, the unsent draft stays and the log names that id and which database failed. No row is written when the draft is not created. Every step goes to `~/Library/Logs/ControlWard/leadgen/leadgen-run-<time>.log`. Credentials are resolved at run time from env or Keychain references named in the local config, never from code. There is no UI button in this slice.
- Q3 resolved: the CASL footer address comes only from the uncommitted local config `~/Library/Application Support/ControlWard/leadgen.local.json` (`leadgen.local.json` is in `.gitignore`; `docs/leadgen-slice/leadgen.local.example.json` is the committed template with placeholders). The draft refuses to build without an address. A denylist in code holds only one street name, Saint-Hubert (that address belongs to another business), and it matches every spelling.

## Tests added for Q2 and Q3 (failing first)

LG1 a vague `--confirm` is not live; LG7 CLI dry-run prints the plan and touches nothing; LG7 `--live` without the exact confirmation refuses before any adapter is built; LG7 live step order, with the Gmail draft last; LG7 run log file under the log directory; LG8 the draft refuses to build without the address config; LG8 a Saint-Hubert footer address is refused; LG8 the repo holds only the placeholder example and ignores the local config.

## Runbook: the one live run (only after Martin's OK names the `leads` table in both DBs)

1. On the Mac, at the PR head: `swift build --package-path native-crm`.
2. Edit `~/Library/Application Support/ControlWard/leadgen.local.json` (mode 600). Set `directoryURL` to `https://dpq.quebec/repertoire-des-membres/` (the example already names that page; pending Water's spec confirmation). Keep `postalAddress`, `paths`, `consent` (basis only; the source and the recorded time come from the fetched own-domain page), and `credentials` (the two Cloudflare account IDs, env or Keychain names for the two write tokens, the two read-only snapshot tokens, and the Gmail compose token). A `prospect` block in the file is not the discovery source. Store the secrets in Keychain (`security add-generic-password -s <service> -a leadgen -w`), not in the file.
3. Dry-run: `native-crm/.build/debug/FollowUpOSNative leadgen`. An empty `directoryURL` prints `directory not configured` and `prospect: not configured` and fetches nothing. With a URL, check the directory line, the one clinic, the fit quote, the recipient, and the consent source. The same directory URL is written to the run log. Nothing is written or drafted.
4. Live, once: `native-crm/.build/debug/FollowUpOSNative leadgen --live --confirm "leads in e1e9fa25 and leads in 959e5bdb"`.
5. Check the printed result: `leads 0 -> 1` and `existing tables unchanged` for each DB, plus the draft ID. Open the run log path it prints: the before/after checksums of every table and the `projects` counts must match.
6. If it prints `stopped before any insert: a leads table already exists`, or any other stop, do nothing more and report the log.
7. Martin reads the draft in ml@pharos-ai.ca and sends or discards it himself. The runner never sends.

## Discovery (directory page)

Argus chose `https://dpq.quebec/repertoire-des-membres/` (one static HTML page; robots.txt allows it). Pending Water's spec confirmation. The installations file was not approved as a source because it has no website or email column, so it is not wired in.

An empty `directoryURL` in a local file is still `directory not configured`: the dry run prints that and `prospect: not configured` and does not fetch. It does not treat a hand-supplied clinic URL as the prospect. The example config names the DPQ page. Its host must be exactly `dpq.quebec`. A redirect to any other host, including `dentistesproprietaires.quebec`, fails closed. The run fetches that page once per run, robots.txt first, with User-Agent `PHAROS AI ControlWard (+https://pharos-ai.ca; ml@pharos-ai.ca)`. It does not bulk-fetch. A fiche yields the clinic name, the dentist name, and the link to the clinic's own website. Google Maps, search, and aggregator links are ignored and never followed. A fiche with no own-site link is skipped. The address comes only from the clinic's own website, where it is conspicuously published. A role address (info@, contact@, reception@, and the other role locals) is preferred over a personal one. No-solicitation wording (`no solicitation`, `pas de sollicitation`, `aucune sollicitation`), or no published address, refuses the entry. An address is never guessed or constructed. The lead row stores the clinic name, the dentist name, the role email, and two source records: the DPQ page URL with its fetch time, and the clinic page URL where the email was found with its fetch time. The fit quote and the consent source stay on the clinic page. The draft is about that clinic's AI governance and Loi 25 obligations for health data. The public page links more than one clinic's own site, so a run of the configured URL fails closed with `notExactlyOneProspect` and does not fetch those sites. `consent.recordedAt` is the fetch time of the evidence page, and the lead row stores that clinic URL and time. An empty fetch time refuses the draft. There is no fallback to a quote without a time, and the config `recordedAt` is not kept in its place. A refused candidate is named in the run log and writes no row, including no suppressed row, and the run never sends an UPDATE. The run writes exactly one lead row per database, or none. Google Maps, data brokers and search-engine pages are not sources. M2 and M3 apply to every fetch. On macOS the connection goes to the admitted IP with Network.framework, and the TLS server name is the original hostname. The certificate is evaluated against that name with the system trust store. An IPv6 target is written as a bracketed literal.

Before any draft, the run reads `LEADGEN_SUPPRESSION`. A missing, empty, unreadable, or unparseable file means no draft. Stored addresses are trimmed and lowercased the same way as candidates. A domain entry covers that host and its subdomains. A suppressed address or domain writes no draft and no row, and the log says why. TODO: Martin purges a rejected or unsubscribed lead. Purging a lead row is a Project Control data delete, which this slice does not send. The run logs `suppressed:` and writes no row, including no suppressed row. The footer is the full line from local config, NFC-normalized and compared to the pinned sha256 (`LeadgenDraftComposer.footerLineSHA256`). A mismatch refuses the draft and is logged. The plaintext line is not stored in the repo. The draft carries a List-Unsubscribe header. Snapshot SELECTs use the read-only token named in config (`LEADGEN_CF_TOKEN_MECOM_READ`, `LEADGEN_CF_TOKEN_PHAROS_READ`). Startup calls `/user/tokens/verify` and fails closed unless the returned id equals the saved id, status is `active`, and the gitignored policy lists only D1 Read on the two account ids. That file holds the token id and the permission list, never the token value. This is a declared-and-captured proof, not live policy introspection (`docs/leadgen-slice/d1-read-token-policy.md`).

## Running one suite

`bin/test-portable` and `bin/test-native-app` print `git rev-parse HEAD` before anything else. With no arguments they run every suite. One suite at that same SHA:

```
./bin/test-portable LeadgenSliceTests
./bin/test-native-app LeadgenSliceTests
```

The portable names are `MailActionOutcomeTests`, `LeadPipelineTests`, `LeadPipelinePlantedReds`, `MailControlTests`, `ProjectControlTests`, `MailControlPlantedReds`, and `LeadgenSliceTests`. The Mac runner accepts those plus the other smoke suites (`SecurityTests`, `IntegrationTests`, and the rest of the types in `NativeSmokeTests`).

## Hard limits

No live Gmail or D1 calls except the read-only schema inspection above. All tests use fakes. No sending, inbox reading, deleting, bulk, or deploy. Credentials come from env or Keychain only.
