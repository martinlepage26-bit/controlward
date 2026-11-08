# Bounded credential waits and current-connection checks

## Demonstrated failure

The installed256 KAIROS import remained busy while a background worker was inside
`CredentialIO.read` / `SecItemCopyMatching`. The main interface remained usable.
Moving that blocking lookup away from the main thread did not give its Swift
caller a deadline or cancellation result. The original implementation also
accepted a late credential result after its waiter was cancelled; the new
controlled regression fails against that original behavior.

## Application behavior

- Credential presence probes and data-read callers wait at most30 seconds by
  default. Cancellation settles the waiter independently of a blocked OS call.
  Settlement is exactly once; a late value or error is discarded.
- This does **not** terminate a synchronous macOS lookup. While that lookup is
  still held, the app refuses another lookup for the same service/account rather
  than accumulating workers or repeated prompts. Only item identities are
  tracked; no secret or result is cached by this gate.
- Expired access checks show Access needed. Saved connections, sign-ins,
  Auto-Pilot preferences and owner records are retained. Local CRM work remains
  available. An owner can handle a macOS prompt locally and retry the current
  connection. The deadline neither grants access nor establishes missing keys.
- PHAROS rechecks the approved CRM snapshot after credential access and before
  its push. A changed snapshot needs a new preview and confirmation.
- KAIROS imports, KAIROS Discovery context, paginated GAP reads and PHAROS lead
  pulls check that their connection/workspace still matches after awaited work.
  An old result cannot import records, retire current GAP signals, or mark a
  replacement connection verified. Stop is checked before committing automatic
  PHAROS intake and before acknowledging its page.
- A saved page remains saved if acknowledgement was already issued. Its late
  response cannot advance a replacement connection's cursor. Likewise, an
  already-issued PHAROS or Twenty write retains its observed provider outcome;
  cancellation does not pretend to undo it. A previous-connection outcome is
  labelled and does not verify the new connection.
- Workspace import now has the same running-integration/research exclusion as
  reset and restore. Read-only import status says Reading instead of Sending.

Credential service/account names, authentication policy, writes/deletes and ACLs
are unchanged. Tests use synthetic credentials and in-process transports; they
do not inspect or change owner Keychain contents or send a real message.

## Verification

`bin/test-native-app --credential-access` passes23/23 credential cases and18/18
Resend cases. The complete native suite passes, including the existing
PHAROS/KAIROS/GAP durability, stop, retry and CRM tests. The focused cases cover
early cancellation, cancellation before dispatch, late success/error, startup
probe deadlines, API/mail/Resend deadlines, duplicate held lookups, snapshot
edits, connection replacement during reads/pages/acks, Stop during a page and
the real outcome of an already-issued write. Controlled held operations have a
separate safety release; deadline assertions complete before that release.

The original cancellation regression fails against the earlier implementation.
In an isolated worktree, removing the lookup gate, snapshot recheck and
connection/Stop checks causes8/23 credential cases to fail. Both red logs are
retained in the release evidence. Full SwiftUI compilation, packaging,
signature/archive equality, hosted CI and installed-app checks are separate
release gates. The [current release receipt](https://pharos-ai.ca/artifacts/controlward/automatic-prospect-research)
records their exact result and source rather than implying them from these tests.

Apple documents that [SecItemCopyMatching blocks its calling thread](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:)).
The [task cancellation handler contract](https://developer.apple.com/documentation/swift/withtaskcancellationhandler(operation:oncancel:isolation:))
requires concurrent-safe handling, including cancellation before the operation
starts. The [checked continuation contract](https://developer.apple.com/documentation/swift/checkedcontinuation)
requires one settlement. These changes bound the application waiter; successful
live authentication remains dependent on macOS and the configured account.

## Remaining acceptance

No nonempty live KAIROS enquiry, strategy, newly collected conversation or
production prospect send is established by these injected tests. Notification
delivery remains owner-deferred. The full ControlWard product objective remains
open; the current25-requirement ledger and release receipt retain those limits.
