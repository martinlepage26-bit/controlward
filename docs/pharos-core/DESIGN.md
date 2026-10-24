# PHAROS shared core: design (slice 1)

Status: draft, docs only. Author: Water. Scaffold: Fire, on this branch. Verify: Earth. Review: Argus before any merge.
Operator: Martin Lepage. Nothing in this PR is deployed, and no migration is applied anywhere.

## 0. Scope of this PR

The first PR is ONE vertical slice:

> one contact record → one approval request → Martin approves or refuses → exactly one audit entry.

- It sits behind a thin adapter that is OFF by default. ControlWard and Project Control behave exactly as on `main`.
- Migrations only add tables, triggers and indexes: 0 drops, 0 renames, 0 column changes on existing tables.
- No Kairos or EMERAULD file changes, no deploy, no secret rotation, no new repo.

## 1. Target architecture (later slices, short)

| Part | Slice | Summary |
|---|---|---|
| People and companies record | 1 (contact only); merge/dedupe later | One record per person/company, field-level provenance, Loi 25 consent basis. Later: two-source merge where evidence never crosses domains (ControlWard LIVE-R6 rule). |
| Approval gate | 1 | Nothing goes out without Martin's explicit OK, per action, bound to a payload hash. Slice 1 covers one action kind: `contact.outreach`. Later: email send, post, delete, spend, deploy. |
| Audit trail | 1 | Append-only, hash-chained, rejected UPDATE/DELETE at the DB level. |
| Connection registry | later | References only (provider, account id, scopes, status, `secret_ref` → env var / Keychain / secret manager name). Never a secret value in code, rows, logs or repo. Not in this PR. |

Non-goals for slice 1: sending anything, dedupe/merge, registry, migrating existing data, any UI beyond what the adapter needs, any network listener other than loopback.

## 2. What exists today (inspected 2026-10-24)

**ControlWard** (`martinlepage26-bit/controlward`, main `dc49e7b`): Swift macOS app under `native-crm/Sources/FollowUpOSNative/` plus a TypeScript Cloudflare Worker `pharos-api/` (D1, vitest). Relevant models:
- Prospects/contacts: `ProspectLeads.swift`, `ProspectResearch.swift`, `LeadDefinition.swift` (`AddressProvenance`: address and route evidence must be on the business's own domain; `consent` incl. `conspicuousPublication(url)` must be on that domain), `Resources/config/icp.json`.
- Audit: `CWAudit.swift`, the `CW-AUDIT v1` single-line format (ts, surface, action, register, target, source, result, receipt), file sink, append-only by convention only (no hash chain, no DB enforcement).
- Approvals/drafts: mail actions (`MailActionRunner.swift`, `Outreach.swift`); approval is a UI step, not a payload-bound record.
- Project Control link: `ProjectControlWrites.swift`, `ProjectModuleBridge.swift` call `window.controlWard.capture` on the Project Control page over a register URL, with loopback checks.
- Connections: no registry; per-integration config.

**Project Control**:
- A GitHub repo exists: `martinlepage26-bit/project-control` (private, JavaScript, last push 2026-10-21). Air reported it is not a git repo; that conflicts with what GitHub shows. Contents not inspected in this PR — **unverified** whether it is the live code.
- Box copies: `/workspace/pc-src` (README + `worker/src/index.js`, `wrangler.toml`), `/workspace/pc-test/worker/schema.sql`, `/workspace/project-control.html`, `/workspace/project-control-reorg/live-snapshot-2026-10-06.json`.
- Live data: a Cloudflare D1 database. The README names `project-control` id `e1e9fa25-…` on the me.com Cloudflare account; the Oct 6 snapshot says it was read from D1 `959e5bdb` on the PHAROS account. **Which one is live today is unverified** (Martin to confirm, Q2).
- Schema (from `schema.sql`): `projects`, `incidents`, `notes`, `events` (seq, at, connection, provider, op, entity, entity_id, field, old/new value), `connections` (label, provider, role, `token_sha256`, state), `settings`, `baselines`. Its `events` table is append-by-code only; no DB-level guard.

## 3. Language and location decision

The core must be callable from a Swift app and from a web page (Project Control HTML + Worker). A Swift-only package fails the second; a Worker-only core forces ControlWard online.

**Recommended:** `pharos-core/` at the root of the controlward repo containing
1. `schema/` — plain SQLite DDL migrations (the contract, language-neutral; also valid on D1, which is SQLite).
2. `service/` — a small TypeScript service (Node 22, `node:sqlite` or better-sqlite3) exposing the gate over HTTP on `127.0.0.1` only, with vitest tests. TypeScript matches `pharos-api/` and Project Control, so the CI toolchain already exists.
3. `adapters/swift/` — a thin Swift client (`PharosCoreAdapter`) ControlWard calls; disabled by default.

Why: one schema both sides share; loopback keeps data local (Loi 25) and matches the existing loopback rules in `ProjectModuleBridge`; the web page can call `http://127.0.0.1:<port>` without a cloud deploy.

Alternatives:
- Swift package `PharosCore` in controlward: simplest for ControlWard, unusable from Project Control. Rejected.
- Logic in the D1 Worker (`pharos-api` or Project Control's Worker): reachable from both, but needs a deploy and puts contacts in the cloud. Later option, not slice 1.
- New repo `pharos-core`: cleanest boundary, but needs Martin's yes (Q1). Moving later is a `git subtree split`.

## 4. Slice 1 spec

### 4.1 Contact schema (`pharos-core/schema/0001_contact.sql`)

```sql
CREATE TABLE IF NOT EXISTS pc_contact (
  id            TEXT PRIMARY KEY,               -- ulid
  kind          TEXT NOT NULL CHECK (kind IN ('person','company')),
  display_name  TEXT NOT NULL,
  email         TEXT,
  business_domain TEXT,                         -- own domain; evidence must be on it
  consent_basis TEXT NOT NULL CHECK (consent_basis IN
                 ('none','express','implied_business_relationship','conspicuous_publication')),
  consent_evidence_url TEXT,                    -- required when conspicuous_publication; host must equal business_domain
  consent_recorded_at TEXT,
  created_at    TEXT NOT NULL,
  CHECK (consent_basis <> 'conspicuous_publication' OR consent_evidence_url IS NOT NULL)
);
CREATE TABLE IF NOT EXISTS pc_contact_field_source (   -- field-level provenance
  contact_id TEXT NOT NULL REFERENCES pc_contact(id),
  field      TEXT NOT NULL,
  source     TEXT NOT NULL,       -- e.g. controlward:prospect, project-control:note, manual
  source_url TEXT,
  fetched_at TEXT NOT NULL,
  PRIMARY KEY (contact_id, field, source)
);
```
The host-equals-domain rule (LeadDefinition parity) is enforced in the service and tested; SQLite cannot parse URLs.

### 4.2 Approval request (`0002_approval.sql`)

```sql
CREATE TABLE IF NOT EXISTS pc_approval (
  id            TEXT PRIMARY KEY,
  action        TEXT NOT NULL,                  -- slice 1: 'contact.outreach'
  contact_id    TEXT NOT NULL REFERENCES pc_contact(id),
  payload_json  TEXT NOT NULL,                  -- canonical JSON (sorted keys, UTF-8, no whitespace)
  payload_hash  TEXT NOT NULL,                  -- sha256 hex of payload_json
  requested_by  TEXT NOT NULL,                  -- agent or app id
  state         TEXT NOT NULL DEFAULT 'pending'
                CHECK (state IN ('pending','approved','refused','expired','consumed')),
  decided_by    TEXT,                           -- must be 'human:martin' when set
  decided_at    TEXT,
  expires_at    TEXT NOT NULL,                  -- default requested + 24h
  consumed_at   TEXT,
  created_at    TEXT NOT NULL,
  CHECK (decided_by IS NULL OR decided_by = 'human:martin')
);
```

States: `pending → approved → consumed`; `pending → refused`; `pending|approved → expired` (at/after `expires_at`). All other transitions are refused. Terminal: refused, expired, consumed.

API (loopback HTTP, JSON; same functions in-process for tests):

| Call | Who | Effect |
|---|---|---|
| `POST /approvals` {action, contact_id, payload} | agent/app | creates `pending`; never anything else |
| `POST /approvals/:id/approve` {payload_hash} | Martin only | `approved` if hash matches stored hash and not expired |
| `POST /approvals/:id/refuse` | Martin only | `refused` |
| `POST /approvals/:id/consume` {payload} | executor | succeeds once, only if `approved`, not expired, and sha256(canonical(payload)) == payload_hash; else refused |
| `GET /approvals/:id` | any local | read |

Martin-only: approve/refuse require a human-presence token minted by the local UI after a user gesture (ControlWard: macOS LocalAuthentication prompt; web page: owner session). Agent credentials (MCP connection tokens, `requested_by` agent ids) are refused with `refused:not-human`. Any edit to the payload changes the hash, so consume fails and a new request is needed. Expiry is checked on every call (lazy) — no background job in slice 1.

### 4.3 Audit table (`0003_audit.sql`)

```sql
CREATE TABLE IF NOT EXISTS pc_audit (
  seq          INTEGER PRIMARY KEY AUTOINCREMENT,
  ts           TEXT NOT NULL,          -- ISO8601 UTC, ms
  actor        TEXT NOT NULL,          -- human:martin | agent:<id> | app:controlward
  action       TEXT NOT NULL,          -- approval.request|approval.approve|approval.refuse|approval.consume|approval.expire|gate.refuse
  subject      TEXT NOT NULL,          -- approval id
  payload_hash TEXT NOT NULL,
  result       TEXT NOT NULL,          -- ok | refused:<code>
  prev_hash    TEXT NOT NULL,          -- 64 zeros for seq 1
  hash         TEXT NOT NULL           -- sha256(prev_hash|seq|ts|actor|action|subject|payload_hash|result)
);
CREATE TRIGGER IF NOT EXISTS pc_audit_no_update BEFORE UPDATE ON pc_audit
  BEGIN SELECT RAISE(ABORT, 'pc_audit is append-only'); END;
CREATE TRIGGER IF NOT EXISTS pc_audit_no_delete BEFORE DELETE ON pc_audit
  BEGIN SELECT RAISE(ABORT, 'pc_audit is append-only'); END;
```
No PII, no payload bodies: only the hash. Verify: walk by `seq`, recompute each `hash`, check `prev_hash` equals the previous row's `hash`; first break → report seq. `pharos-core verify-audit` CLI exits non-zero on break. A `CW-AUDIT v1` line can be emitted alongside for ControlWard's existing log (mapping: surface=`pharos-core`, target=subject, result=result, receipt=hash[0..12]).

"Exactly one audit entry" for the slice means: the decision (approve or refuse) writes exactly one `pc_audit` row, in the same transaction as the state change. Request and consume rows are separate events and are counted separately in tests.

### 4.4 Adapter (off by default)

```
interface PharosCoreAdapter {
  enabled: boolean
  requestApproval(contact, action, payload) -> {id, state:'pending'} | {disabled:true}
  status(id) -> state
  consume(id, payload) -> ok | refused:<code>
}
```
- Flag `PHAROS_CORE_ENABLED` (env) / `pharosCoreEnabled` (ControlWard UserDefaults), default false. When false the adapter is a no-op returning `{disabled:true}` and no code path in ControlWard or Project Control changes.
- Swift: `adapters/swift/PharosCoreAdapter.swift` + `NoopPharosCoreAdapter` as the default. Slice 1 does not wire it into any existing call site.

### 4.5 Migrations

`pharos-core/schema/000N_*.sql`, `CREATE … IF NOT EXISTS` only, new `pc_` prefix so nothing collides with ControlWard or Project Control tables. A CI check greps migrations for `DROP|ALTER TABLE .* RENAME|ALTER TABLE .* DROP` and fails on any hit. Rollback = stop using the file (`pharos-core.sqlite`, separate DB); no data in existing stores is touched.

## 5. Migration of existing data (later slice, plan only)

1. Read-only export: ControlWard prospects (JSON), Project Control D1 `projects`/`notes` (via `wrangler d1 export`, read-only).
2. Mapping tables `pc_import_map(source, source_id, contact_id)`; dry run writes to a scratch DB and prints counts + rejects (e.g. consent evidence off-domain).
3. Martin reviews the dry run, then a real import into `pharos-core.sqlite`. Sources stay authoritative until Martin switches; rollback = delete the new DB file. No destructive step on sources.

## 6. Scaffold plan for Fire (red first)

```
pharos-core/
  schema/0001_contact.sql 0002_approval.sql 0003_audit.sql
  service/src/{canonical.ts,gate.ts,audit.ts,contact.ts,adapter.ts,server.ts}
  service/test/{gate.test.ts,audit.test.ts,slice.test.ts,adapter.test.ts,migrations.test.ts}
  adapters/swift/PharosCoreAdapter.swift (+ test in ControlWard test target, flag-off only)
  scripts/check-untouched.sh   # fails if diff touches kairos/ or emerauld paths
```
Commit order: tests first (CI red with named failures), then implementation (green). Add one CI job `pharos-core` that runs `vitest --reporter=verbose` so the log names each test and the counts. Existing jobs unchanged.

## 7. Acceptance criteria (Earth)

Each item has a test that fails first, and the CI log names the tests with counts.

1. **Gate refuses without Martin's OK, and the refusal is audited.** `gate.test.ts`: consume on pending → `refused:not-approved`; approve by an agent id → `refused:not-human`; consume with edited payload → `refused:hash-mismatch`; consume after expiry and second consume → refused. Each refusal writes one `gate.refuse` audit row.
2. **Audit rejects UPDATE and DELETE at the DB level.** `audit.test.ts`: raw SQL `UPDATE pc_audit …` and `DELETE FROM pc_audit …` both throw `pc_audit is append-only`; chain verify passes, and a tampered copy (triggers dropped in a scratch DB) fails verify at the right seq.
3. **Happy path.** `slice.test.ts`: one contact → one request → Martin approves → exactly one decision audit row (and the refuse variant: exactly one).
4. **Adapter off by default; ControlWard suite unchanged.** `adapter.test.ts`: default adapter is disabled and no-ops. ControlWard's existing Swift and pharos-api counts on this branch equal those on `main` (`dc49e7b`), quoted from CI logs.
5. **Migrations additive only.** `migrations.test.ts`: no DROP/RENAME/column ALTER; applying all migrations twice is idempotent.
6. **0 Kairos or EMERAULD files changed.** `check-untouched.sh` on `git diff main...HEAD --name-only` → 0 matches.
7. No new repo created without Martin's yes (process check by Earth/Argus).

## 8. Open questions for Martin

- Q1. Location: `pharos-core/` inside controlward (recommended) or a new `pharos-core` repo (needs your yes)?
- Q2. Which Project Control D1 is live: `e1e9fa25…` (me.com account) or `959e5bdb` (PHAROS account)? And is `martinlepage26-bit/project-control` the current source?
- Q3. Human-presence proof for approve/refuse: macOS LocalAuthentication (Touch ID) in ControlWard is proposed. OK, or something else?
- Q4. Default approval expiry: 24 h?
- Q5. Consent bases: are the four values in 4.1 the ones you want under Loi 25 / CASL?
