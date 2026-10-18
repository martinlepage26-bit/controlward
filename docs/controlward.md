# ControlWard workflows and boundaries

ControlWard uses ContextWard as its native desktop home. Project Control and
Email Aggregator are available inside the same app. This integration adds
working review paths across all 16 top-level sections while keeping each
system's records and authority explicit.

| Section | Available additions |
| --- | --- |
| Overview | Search across local records, due tasks with completion actions, review queues and compact activity/context |
| Projects | Full bundled Project Control dashboard, persistent module state, native JSON import/export, explicit intake bridge |
| Email | Hosted Email Aggregator plus a local metadata review inbox, search, review state, contact/company links and deduplicated tasks |
| Activity | Filter/search local activity, export visible events and inspect confirmed project capture receipts |
| Pipeline | Due-only filtering, keyboard-openable leads, project links and readable scrolling opportunity stages |
| Operations | Search signals, include retired evidence explicitly, and link/capture active signals for project review |
| Account intelligence | Search accounts, filter eligible segments and export visible rules-based assessments |
| Integrations | Module connection status, direct navigation, capture receipt counts and existing preview-bound connectors |
| Contacts | Shared search/sort, dedicated editor and project links/capture |
| Companies | Shared search/sort, dedicated editor and project links/capture |
| Opportunities | Open/completed/overdue filters, sorting, editor and project links/capture |
| Tasks | Open/completed/overdue filters, completion/reopening and project links/capture |
| Notes | Shared search/sort, editor and project links/capture |
| Saved views | Search terms, result counts and navigation into actual filtered directories |
| Security | Filter resolved/high-severity findings and create one review task per finding |
| Settings | Private backup export, reviewed restore with rollback, and existing connector/local automation settings |

## Project record links and capture

Connect a register in Projects → Sync using the existing owner workflow. The
native bridge reads a narrow projection of project identity, title, status and
workspace; it never reads the owner token or connection list.

A local link includes the register URL and opaque project ID, so the same project
ID in another register is not interchangeable. Linking does not update the project.
Capture shows the destination, source identity, editable summary/link and selected
metadata. A changed register invalidates the preview. It creates an unassigned
inbox item; assignments, deadlines, status and decisions remain owner actions.
Retries use a stable source identity and retain the existing item on HTTP 409.
If a request loses its response, reconnect the original register and retry the
same record. A local receipt is written only after a confirmed response.

## Email Aggregator

The hosted module points to <https://email-aggregator-ext-ol5f.bolt.host/>. The
inspected source is `martinlepageai-ux/email-aggregator` at
`0c1b72c213c3f02164c2d508d7befc2f35f24e68`. Its current sign-in screen labels it a
prototype; provider OAuth/mailbox synchronization is not implemented in the
inspected source. ControlWard's own live Gmail metadata intake is native (see
`native-crm/README.md`, Live mail intake) and does not use this hosted app. No credentials or provider mailbox contents were used in QA.

The local inbox imports `controlward.mail.v1` JSON or the existing Project Control
synthetic Email Aggregator fixture. Unknown fields such as body text and tokens
are never decoded or persisted. Source/account IDs deduplicate imports, while
review decisions and local links survive a refresh. A task action keeps one task
per message, including after completion; a deleted task receipt is not silently
revived. Synthetic mail capture is restricted to loopback test registers.

Example (synthetic data only):

```json
{
  "schema_version": "controlward.mail.v1",
  "messages": [{
    "source_id": "fixture-message-1",
    "subject": "Review the project brief",
    "sender": "camille@example.test",
    "recipient": "owner@example.test",
    "received_at": "2026-10-17T09:00:00Z",
    "provider": "synthetic",
    "account_id": "fixture-account",
    "synthetic": true
  }]
}
```

## GAP reconciliation

The local pipeline package matches all 64 tracked files in
`martinlepage26-bit/GAP` at `f875514a9923465d0b65bd3ea8de04d7e8c3af34`.
GAP remains a read-only source through the existing paginated active-cluster
import. The owner chooses what becomes project work.

Before applying migrations, run [gap-schema-preflight.sql](gap-schema-preflight.sql)
in a read-only transaction with schema-owner visibility. It classifies the
schema family and inspects the claim-function ambiguity fix without invoking
queue claims. This is not a complete migration compatibility certificate.

- `gap_pipeline`: upstream uses `gap_scores.gap_cluster_id` and pipeline tables.
  The worker-support migration supplies extraction item indices, embeddings,
  assessments and qualified claim-function bodies.
- `contextward_minimal`: the older optional fallback uses `gap_scores.cluster_id`.
  It is a different schema family; do not overlay the full pipeline blindly.
- `empty_or_unrelated` or `mixed_or_incomplete`: inspect the intended project and
  migration history before applying anything.

No production Supabase project, endpoint, credentials or migration application
was verified in this work. Tests use in-memory PGlite and synthetic inputs.

## Data and recovery

The release retains `com.pharos.contextward`, the Contextward data directory and
existing credential service identifiers. It neither copies owner credentials
nor migrates personal files. Project Control and Email Aggregator use separate
persistent WebKit stores, separate again from the native CRM connector keys.
The project bundle is a pinned file copy, not a pointer to a mutable checkout.

Settings backups contain the native workspace, imported metadata, project links
and receipts. **They do not back up WebKit storage, Project Control's D1 register,
Email Aggregator's hosted data or Keychain credentials.** Export Project Control
separately using its Tools menu.

Restore validates the envelope and identities, writes an owner-only rollback
backup, and commits atomically. Current connector destinations stay in place;
current Twenty identities survive only for records still present. Imported
remote identities, queued writes and prior health results are discarded;
automation and pull state are disabled/reset. Restore never redirects existing
credentials to a backup-supplied endpoint.

## Build, test and review

```bash
./bin/vendor-project-control --check
./bin/test-native-app
./bin/test-workspace-modules
# Optional real WebKit-to-Worker check; requires npm ci in that Worker checkout:
./bin/test-connected-workspace /path/to/project-control
./bin/preview-controlward
CONTEXTWARD_SIGN_IDENTITY=- ./bin/package-native-app
```

Preview is a separate temporary app with synthetic records, in-memory secrets
and nonpersistent WebKit stores. The release contains no preview fixture.
The explicit local signature avoids Keychain identity inspection; the resulting
ZIP is not notarized. The packaging command verifies the archive after extraction.

To update the bundled dashboard, first commit its source changes, then run
`./bin/vendor-project-control /path/to/project-control`. Review the manifest and
rerun the gates. Allowed assets and hashes are in
`native-crm/Sources/FollowUpOSNative/Resources/ProjectControl/source.json`.

Visual direction and the Impeccable → Diamond Eyes handoff are recorded in
[design-refinement.md](design-refinement.md), [PRODUCT.md](../PRODUCT.md) and
[DESIGN.md](../DESIGN.md). Native light-mode layout and focused color-pair checks
were reviewed; full localization and formal accessibility certification remain
outside this release.
