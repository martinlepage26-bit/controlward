# Owner recipient-policy decision

The native Settings view previously explained a closed privacy gate whose only
configuration was a bundled JSON file. There was no product workflow for the
owner to record the ruling that the gate requested. The new controls retain
the closed packaged default and let the owner review and record a decision in
Settings, without a source edit or another release.

The scope is all otherwise eligible external recipients in this native
workspace. It does not approve one message, schedule a campaign, activate
collectors or authenticate a contact. The review sheet distinguishes general
message checks from the additional source/freshness requirements for researched
cold outreach. Sender and reply-to remain `ml@pharos-ai.ca`; Resend credentials,
message previews, provider requests, acceptance receipts and follow-up bookkeeping
use their existing paths.

## Persistence and approval boundaries

- A review requires an assessment title/reference and explicit confirmation of
  the external-recipient scope. Cancel writes no policy or CRM data.
- The non-secret decision is atomic mode600 local configuration beside the
  workspace. It is not included in native CRM backups. It contains a unique
  decision identity, timestamp, scope/configuration fingerprint and workspace
  path/generation binding.
- Missing decisions retain the packaged default. Unreadable, unsupported,
  copied, mismatched or stale decisions disable external recipients. Restoring
  or resetting CRM data changes its generation and requires a new review.
- Reopening normally retains a matching decision. The sender rereads it at
  review and each send validation; another instance's restriction invalidates
  a cached preview. Reapproval does not revive an older message confirmation.
- Revocation during credential access prevents the later provider request.
  Requests already issued retain their actual outcomes and receipt recovery.
- A failed save pauses external sending in the current session, invalidates
  previews, and requires an explicit successful retry. The UI states the
  restart limitation when the earlier on-disk decision could remain valid.

The file is protected by the same local filesystem ownership assumption as the
single-user CRM. It is not a cryptographic identity attestation. No owner ruling
or legally sufficient assessment is inferred from installing the application.

## Verification scope

The focused native Resend suite covers the default closed policy, explicit
confirmation/reference, private persistence/reopen, unchanged CRM/zero HTTP,
stale review, copied/configuration-changed/invalid decisions, revocation and
reapproval, a second store's change, credential-wait revocation, actual CRM
restore/reset and failed-save/retry behavior. All provider and credential
objects in these tests are synthetic, injected and in-memory.

The current release receipt records executed counts, complete native/package
checks, mutation checks and the actual isolated native Settings witness when
performed. Tests and source inspection alone do not establish the UI witness.
The normal owner workspace must remain externally disabled unless the owner
personally records a ruling. The complete25-requirement goal and remaining
live-provider/reply dependencies remain open.
