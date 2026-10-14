# ContextWard product promises — pre-implementation gaps

Inspected 2026-10-14 at baseline `9b63dbb`. This file was written before implementation changes. The requested checkout was clean but behind the released commit; work continues on `feat/product-promises-20261014`, preserving `main` and other worktrees. Baseline native regression tests pass (101 named checks plus smoke); that is not running-app proof. No promise is marked working based on inspection alone.

| # | Promise | Status | Evidence and gap |
|---|---|---|---|
| 1 | Contacts, companies, notes, relationship history | incomplete | Models.swift 338–408, EntityEditors.swift 28–55, DirectoryView.swift 55–97: CRUD persists but contact/lead/company links are not exposed and context/history is fragmented. |
| 2 | Opportunities with explicit pipeline stages | incomplete | Models.swift 361–378 defines stages; PipelineView.swift shows leads, opportunities remain a flat directory. No lead-to-opportunity flow. |
| 3 | Tasks and timed local reminders | incomplete | EntityEditors.swift 125–148 has date only. AppStore.swift 1072–1092 sends immediate notifications for already-due leads, ignores delivery errors; tasks never schedule. |
| 4 | Active discovery, evidence, dedup, visible priority formula | absent | PipelineView.swift only imports or manually adds leads. AppStore.swift 422 imports an upstream inbox. No native search or discovery UI/client. |
| 5 | Capture/import and evidence-based prioritization | incomplete | AppStore.swift 1095–1173: CSV/LeadGen JSON duplicate records; CSV provenance and scoring explanation absent. Signal score/evidence not visible with lead. |
| 6 | Linked Lantern FR/EN evidence and imports | incomplete | AppStore.swift 1196–1231: aggregates use final row, XLSX normalization drops evidence fields; audit has free-text client but no relationship IDs. |
| 7 | Full KAIROS linkage inventory/repair/optional status | incomplete | Optional GET connector and import exist; supplied priority is discarded. Live state unverified. Inventory below. |
| 8 | PHAROS, Gap, Twenty, KAIROS statuses/failures | incomplete | IntegrationCenterView.swift/AppStore.swift/Integrations.swift provide connectors, but PHAROS push lacks preview/confirmation; lead pull auto-ack writes; arbitrary upstream error text can enter UI/storage. Live state unverified. |
| 9 | Bounded default-off Auto-Pilot | absent | No Auto-Pilot switch. Models.swift 101,130 defaults automatic pulling on; launch/5-minute pull includes remote acknowledgment. |
| 10 | Credentials in secure storage, never logs/UI/exports/errors | incomplete | Keychain store and endpoint scrubbing exist. Integrations.swift 159/249 and generic catches can echo raw server/transport details. Need adversarial secret-echo tests. |

Paths above are under `native-crm/Sources/FollowUpOSNative/` unless stated.

## KAIROS inventory at baseline

| Function/config/data path | File/component | Sends / receives | Evidence/status | Required offline? |
|---|---|---|---|---|
| SyncTarget.kairos, keyed; generic key UI | Models.swift 161–173; SettingsView.swift 59–76 | Keychain target `com.pharos.contextward.kairos`; no key in workspace | Implemented; storage tests pass, live unverified | No |
| endpoint/setEndpoint/kairosClient/verifyConnector | AppStore.swift 81–98,193,213 | `connectorEndpoints["kairos"]`, `connectorHealth["kairos"]`; default `https://kairos.govern-ai.ca` | Implemented; live unverified | No |
| KairosConversation/Inbox/Client init/request/send/verify/pullInbox | Integrations.swift 195–277 | Bearer-authenticated GET `/v1/me`, GET `/v1/inbox?includeAnswered=true&limit=200`; receives ID, author, intent, priority, status, time, platform, message; 2 MiB response cap | Implemented; live unverified | No |
| importKairosLeads/applyKairosLead | AppStore.swift 332–410 | Local `kairos:<id>`, sourceUpdatedAt, lastMessage/status; syncJobs `kairos.inbox.v1`; priority dropped | Four import-update regressions pass; no live proof | No |
| Integration selector/status/verify/import | IntegrationCenterView.swift 9,15,52,98–113,246 | Manual read/import controls | Inspection only | No |
| Intake source/origin/interest route | pharos-api/src/intake.ts 15,30,86–212; index.ts 9–10; migrations/0004_intake_leads.sql | Separate optional POST `/v1/intake`, `INTAKE_KEY`/allowed origin; name/email/company/interest/source/note; kairos interest → project `r0epsco9`; intake_leads/lead_inbox; optional Project Control binding/token | Existing edge route; no native dependency or live write tested | No |
| Tests/docs | KairosTests.swift; bin/test-native-app; NativeSmokeTests.swift; intake.test.ts; README.md; native-crm/README.md; CHANGELOG.md | Test fixtures and connector documentation | Native baseline passes; documentation not runtime proof | No |

## Discovery inventory and intended implementation

Existing sources: manual entry, CSV, LeadGen JSON, PHAROS inbox, KAIROS inbox, Gap Analysis signals. None actively searches for prospects. Inbox priority is supplied composite or `(fit+intent)/2`; local high-intent qualification needs fit ≥70 and intent ≥70. Inbox dedup uses source ID, email, then phone without conflicting email. CSV/JSON currently do not deduplicate.

Add user-triggered public business discovery through OpenStreetMap Overpass using named categories, selectable city coordinates/custom coordinates, bounded radius and ≤50 results. A read-only endpoint probe already returned real Montréal businesses; app verification is still required. Retain OSM identity, public contact fields, address, source URL, query, capture time and attribution. Dedup by OSM identity, with cautious matching that preserves distinct locations. Visible research-priority formula: category/location match 50 + website 20 + phone 15 + email 15. Buyer intent remains unknown; ≥65 means ready for human review only.

## Verification contract

Build an isolated native acceptance app and preserve the user's existing workspace/bundle. Verify promises 1–6 and 9 through native UI, including actual public discovery and notification delivery. Relaunch and recover relationship links, notes, audit evidence, opportunity stage, score and next action. Verify credentials-configured integrations by safe live reads; otherwise label live unverified and exercise failure states. External writes require visible preview plus explicit confirmation. No automatic outreach. Record each method separately; do not substitute tests for running-app acceptance.
