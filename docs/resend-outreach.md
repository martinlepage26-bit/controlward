# Reviewed Resend outreach

ControlWard sends lead outreach only through Resend, from `ml@pharos-ai.ca`.
The existing Resend login is `martinlepage26@me.com`, team `martinlepage26`.
The root domain was observed Verified on November 7, 2026. Preserve that ownership.

In Settings, save a sending-only API key restricted to the existing `pharos-ai.ca`
domain. The owner enters it locally into the secure field; never put it in chat,
workspace JSON, exports, screenshots, logs, source, or build arguments. A saved
key is configuration, not a verified send. The application uses its existing
Keychain abstraction; previews and tests use isolated in-memory stores.

Save a lead, open its message, then choose **Review & send via Resend**. Review
From, To, Subject and the complete body. **Send this message** authorizes that one
request. Cancelling has no provider effect. Research eligibility, evidence,
unsubscribes, the current lead and the original approval are checked again after
credential access. Neither Auto-Pilot nor a scheduled reminder sends outreach.
Gmail/default-mail handoffs and manual “Mark as sent” are removed from this lead
outreach flow. Copy remains available.

The existing `Resources/config/icp.json` privacy gate remains closed by default.
In **Settings → Outreach through Resend → Review recipient policy…**, the owner
can record a privacy-assessment ruling for native Resend outreach. The sheet
states that this permits all otherwise eligible external recipients in the
current workspace, requires an assessment reference and explicit scope
confirmation, and saves nothing on Cancel. Installing the controls does not
record a ruling or enable external recipients. This records the owner's
decision; it is not a legal-compliance certificate or a decision made by the app.
The sheet includes a dated draft and primary-source links so reading it does not
require web-reader login. Filling that draft's reference does not check the
confirmation box. An existing owner assessment can be referenced instead.
No new prospect send or diagnostic message is authorized by the standing sender
preference or by recording recipient eligibility.

The decision is a private, non-secret file next to the native workspace, outside
CRM backups and imports. It is bound to that workspace's location, generation
and current packaged outreach policy. A normal reopen retains a valid decision;
restoring/resetting the CRM, copying the file to another workspace, changing the
policy, or an unreadable/unsupported decision requires another review. The
legacy pipeline/command-line policy is not opened by the native Settings ruling.

**Restrict to owner addresses…** records a new owner-only decision. Every policy
change invalidates outstanding message previews. The application rereads the
decision before message review and before sending, including after suspended
credential access, so a restriction from another instance also applies. An
already-issued request retains its actual provider result. If saving a decision
fails, external sending is blocked for that session until an explicit successful
retry. The UI explains that an earlier on-disk ruling may still apply after
restart; a failed restriction is never reported as saved.

Packaged apps resolve the base ICP configuration only from their own resource bundle and ignore
the `CONTROLWARD_CONFIG_DIR` development override. Command-line/development
configuration and the other research/proof loaders retain their existing behavior.

Before HTTP, the app atomically saves the approved request and its original
idempotency key. An accepted response must contain a Resend message UUID before
one transaction records the receipt, sent history, Contacted status and linked
next-action scheduling. Existing future dates and newer owner edits are retained.
Accepted means provider acceptance; delivery, replies and revenue are separate.
Requests use the fixed HTTPS endpoint, no redirects, no cookies/cache, and no
automatic retries. Error messages omit provider response bodies and credentials.

A timeout, ambiguous server failure or malformed success retains an unknown
outcome and does not add sent history. Check the provider first. Reviewing the
exact request again can reuse its original key inside a conservative 23-hour
window. A different message to that lead is blocked while an earlier outcome is
unknown. Expired unknown requests require provider reconciliation; the app does
not manufacture a new key. Accepted identical messages are blocked across normal
restart. Current receipts and unresolved requests survive an older CRM backup
restore; an explicit full reset still erases the workspace after its recovery
backup, including its send ledger.

If Resend accepts but local saving fails, the durable request remains and Settings
offers **Save pending Resend receipt**, which retries local bookkeeping only.
New sends, reset and restore wait for that recovery. After a crash, the persisted
request still uses its original key within the same retry window. Outside that
window, check the Resend dashboard before any further action.

Offline acceptance: `./bin/test-native-app --resend`. It uses synthetic addresses,
in-memory credentials and an injected HTTP transport. No provider is contacted.
Live acceptance requires an owner-entered key and a separately approved exact
message to an owner address. Neither is implied by passing offline tests.

API contract: [Send Email](https://resend.com/docs/api-reference/emails/send-email)
and [24-hour idempotency](https://resend.com/docs/dashboard/emails/idempotency-keys).
