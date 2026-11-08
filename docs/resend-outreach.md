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

The existing `Resources/config/icp.json` privacy gate remains closed. It permits
sends only to the configured Martin addresses until Martin rules on the privacy
impact assessment. Implementing Resend does not change that gate. No new prospect
send or diagnostic message is authorized by the standing sender preference.

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
