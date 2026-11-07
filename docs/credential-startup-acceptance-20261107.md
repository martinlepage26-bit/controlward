# Credential access at startup

The earlier installed233 normal launch timed out while macOS SecurityAgent was
active. The exact blocking call was not identified. Source inspection found that
connector/mail constructors queried Keychain presence synchronously without
forbidding authentication, and automatic PHAROS/mail refreshes could read secret
data with the same interactive behavior as an explicit action.

The implementation separates these operations:

- Constructors use only memory hints and return without waiting for Keychain.
  Synchronous lookups run on background dispatch workers, including explicit
  key reads. Pending checks have a visible Checking access state. Per-target
  revisions discard late probes after a credential replacement/removal, and
  changed endpoint/key pairs cannot reuse a pending read.
- Presence probes and automatic data reads use a per-request `LAContext` with
  `interactionNotAllowed = true`. Denied access remains denied.
- Only an item-not-found response establishes missing credentials. Other probe
  failures produce an access-needed state. An older successful health check
  cannot hide that state.
- View rendering uses cached availability. It does not repeatedly query Keychain.
- Automatic work pauses on denied access, retaining the stored Auto-Pilot choice
  and sign-ins. A readable attribute response is insufficient to authorize a
  background secret read.
- Explicit **Verify**, **Check access** and **Refresh** retain normal macOS
  authentication. The owner handles any protected dialog locally.

Service/account identities, credential writes/deletes and ACLs are unchanged.
The agent made no permission grant and inspected no owner Keychain contents.
This is a failure-handling change, not an authentication bypass.

Apple documents the [authentication-context query key](https://developer.apple.com/documentation/security/ksecuseauthenticationcontext)
and [noninteractive context property](https://developer.apple.com/documentation/localauthentication/lacontext/interactionnotallowed).
Its [lookup performance guidance](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:))
also requires keeping this blocking call away from the main thread.

## Verification scope

Seven injected/memory-only cases cover: query/status policy; denied startup with
unchanged workspace/Auto-Pilot; successful attributes followed by denied automatic
PHAROS data access and explicit retry; and the actual mail periodic-start task
with denied data access followed by an explicit single-account retry; controlled
delays proving main-actor progress and stale-probe rejection; and a delayed
manual read whose endpoint/key changes before release, with zero outbound
requests; and Stop/Disconnect during pending data reads, with zero later requests
or restarted Auto-Pilot. Mutation races use a wholly in-memory store, including write/delete.
Synthetic credentials and in-process HTTP fakes are used; no real Keychain
round trip is enabled. A complete Mac application build remains a release gate.

The focused entry is `bin/test-native-app --credential-access`. Local verification
also compiles the same complete native source/test list with Swift6 whole-module
compilation, then executes the unchanged runner. The full canonical script remains
the CI gate. Earlier diagnostic/test-harness failures are not counted as passes.
The [Twenty approval regressions](twenty-push-approval-20261107.md) add two more
cases to this entry, covering record edits while credential or HTTP work is pending.

The [current release receipt](https://pharos-ai.ca/artifacts/controlward/automatic-prospect-research)
records the exact installed source, archive, CI and running-app acceptance. Fake
status tests do not establish a production-account connection or successful
credential authentication. Fresh live KAIROS context and other provider journeys
retain their separate acceptance requirements. The full product objective is open.
