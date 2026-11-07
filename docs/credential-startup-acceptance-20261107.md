# Credential access at startup

The earlier installed233 normal launch timed out while macOS SecurityAgent was
active. The exact blocking call was not identified. Source inspection found that
connector/mail constructors queried Keychain presence synchronously without
forbidding authentication, and automatic PHAROS/mail refreshes could read secret
data with the same interactive behavior as an explicit action.

The implementation separates these operations:

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

## Verification scope

Four injected Security-call cases pass: query/status policy; denied startup with
unchanged workspace/Auto-Pilot; successful attributes followed by denied automatic
PHAROS data access and explicit retry; and the actual mail periodic-start task
with denied data access followed by an explicit single-account retry. They use
synthetic credentials and in-process HTTP fakes. No real Keychain round trip is
enabled. The app also compiles completely on this Mac.

The focused entry is `bin/test-native-app --credential-access`. Local verification
also compiles the same complete native source/test list with Swift6 whole-module
compilation, then executes the unchanged runner. The full canonical script remains
the CI gate. Earlier diagnostic/test-harness failures are not counted as passes.

The [current release receipt](https://pharos-ai.ca/artifacts/controlward/automatic-prospect-research)
records the exact installed source, archive, CI and running-app acceptance. Fake
status tests do not establish a production-account connection or successful
credential authentication. Fresh live KAIROS context and other provider journeys
retain their separate acceptance requirements. The full product objective is open.
