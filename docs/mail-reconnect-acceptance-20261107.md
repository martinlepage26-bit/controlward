# Native Gmail reconnect acceptance — 7 November 2026

An existing native Gmail token could remain after a refresh failed with
`invalid_grant` or after older read-only permissions blocked an action. The
account row then offered only Refresh and Disconnect, even though its error
asked for Connect. Renewing it required first deleting the previous sign-in.

The account row now offers Reconnect beside Refresh and Disconnect whenever a
token exists. It uses the same explicit owner-driven Google authorization and
mailbox identity check as initial Connect. The scope set is unchanged. Error
and permission messages now name Reconnect in Mail accounts. Chrome and Gmail+
sessions remain separate from this native connection.

## Automated Mac checks

`bin/test-native-app` passes, including17/17 mail-intake cases. The new
controller case starts with an existing synthetic token and a second account:

- Refresh HTTP400 requests reauthorization while preserving the old token.
- Cancelling authorization makes no HTTP request and keeps that token.
- A rejected token exchange keeps it.
- A successful exchange for the wrong mailbox saves neither that mailbox nor a
  replacement for the selected account. CRM bytes remain exact.
- A matching mailbox replaces only the selected token and refreshes metadata;
  the second account and the unchanged CRM file remain exact.

These checks use in-memory tokens, dedicated temporary defaults/storage and fake
Google responses. The existing sign-in implementation already saves only after
profile validation; this change exposes that route for an existing account.
They do not prove a live account has connected.

## Runtime and release evidence

The actual `MailAccountsSection` was compiled into a separate Mac UI fixture
with memory-only tokens, fake Google HTTP400 responses, the real theme and a
temporary review store. Its original view from7db3e15 showed Refresh and
Disconnect but no Reconnect. The edited view shows Refresh, Reconnect and
Disconnect for that same expired synthetic account, and Connect for the second
account without a token. Another Refresh preserves the reconnect route.
Disconnect removes only the synthetic token and changes that row and its aliases
to Not connected / Connect. No Google authorization was started from the fixture.

This is component runtime evidence. The complete application's package, strict
signature, clean source stamp and isolated review checks are recorded separately
in the current release receipt. Existing build224 is retained until that
replacement passes its release gate.

Native ControlWard Gmail OAuth, real mailbox actions and delivery remain
unverified until the owner completes the app’s own Connect/Reconnect flow. No
owner Keychain inspection, new permission grant or outreach was performed.
Notification delivery remains deferred by Martin.
