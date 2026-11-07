# Native Twenty conversion and retry repair — 2026-11-07

This repair follows merged [PR36](https://github.com/martinlepage26-bit/controlward/pull/36), which added real PHAROS Worker/D1 acceptance. Build209 remains installed at this source checkpoint; final packaging and installed-app checks for this repair are separate release gates. The full product objective remains open.

## Reproduced problems

The native mapper exported both a converted lead and its linked opportunity. A real AppStore conversion therefore previewed **5 creations, including2 opportunities**, for one company/contact/deal/follow-up workflow. Its new regression failed on the original mapper.

Three additional failure-injection cases also failed on the original sync code:

- An unwritable workspace still sent remote writes and reported success.
- Storage becoming unavailable just after the first remote creation did not stop later writes or prevent a success result.
- A successfully created company whose HTTP response was lost was created again after reloading and retrying.

The baseline integration result was17/20 for these durability cases; conversion's earlier baseline was14/15. Logs and their hashes were retained privately. These are demonstrated failure cases, not inferred production incidents.

## Resulting behavior

A converted lead is exported through its linked opportunity, matching local CRM totals. A lead pushed before conversion transfers its existing remote deal identity to that opportunity. Separate remote duplicates created by earlier versions are retained; this repair never deletes them. Several local opportunities competing for one unresolved prior remote identity block the preview/push for relationship review.

The push now verifies local storage before any request. Each new remote record gets a UUID v4 saved as a pending identity before creation. Twenty receives that same UUID in the create body. The native client verifies that the response retained it. A lost response or failed receipt save leaves the durable pending identity available after restart; retry checks/resumes that record rather than creating another identity. Completed links clear the pending flag only after their save succeeds. A404 for a previously completed remote record reserves a fresh identity before recreation.

The optional pending field preserves decoding of older links. Its payload-hash marker also prevents older readers from treating an unfinished creation as unchanged. Preview wording includes “create or resume”; pending work still requires a fresh explicit preview and confirmation. No provider key enters the workspace or logs.

## Validation

- Full `bin/test-native-app` passed:20/20 integration cases, including conversion, prior-push identity reuse, ambiguous-link refusal, initial storage failure, post-create save failure, lost response, existing error/retry,429 and404 behavior. All other native workflows and existing planted-red tallies also passed.
- `swift build --package-path native-crm` passed, including the edited SwiftUI controls.
- `bin/test-workspace-modules` passed8/8 WebKit checks in Swift6 mode.
- **12/12 native connected checks** passed with actual URLSession HTTP against an official disposable Twenty service: wrong-key refusal, authenticated Verify, preview requirement, one converted opportunity, stale-preview refusal, four real objects and their saved identities, exact person/company/deal relationships and1234.5CAD amount, task title, unchanged replay IDs, in-place company update and identity persistence after native reload.
- An independent real REST create returned201 and preserved a supplied UUID v4 before relying on that API behavior for retry recovery.

The connected backend used official `twentycrm/twenty-app-dev` image digest `sha256:2237246b211907c75ae777ba56c423cfeef1e43692e6f29f4b738b229af582e9`, with the public seeded development identity from [Twenty's official test action](https://github.com/twentyhq/twenty/blob/main/.github/actions/spawn-twenty-app-dev-test/action.yml), action-file blob `36389d71388f3c50bf3bac5f40fb99fe57cc8638`. No owner credential was used or inspected.

It ran as a task-labelled disposable container on CT920, bound only to127.0.0.1:8882 and reached from the Mac over a dedicated loopback SSH forward. CPU/memory were bounded to2 cores/4GiB. Its ClickHouse background pool was reduced to fit that test environment; after an initial service dependency failure, the container's own initialization was retried. No host configuration or production service was changed. The container, its synthetic database and the SSH tunnel were removed after the checks; the local port was verified closed. The trusted image cache was retained.

## Reproduce the connected check

Start an official disposable seeded Twenty instance and make its port2021 available only at127.0.0.1:8882. Use the official development fixture identity in a private0600 key file; never use an owner key for this check.

```bash
bin/test-connected-twenty /private/path/disposable-twenty.key
```

The runner accepts only the fixed loopback endpoint and uses a temporary native workspace, in-memory secrets and no OS notification delivery. It creates clearly synthetic records in that disposable service; dispose of the test service afterward. The normal native app does not start Docker or require this test service.

## Remaining acceptance

These checks prove the controlled native client/service workflow and native fault recovery. They do not prove access to the owner's saved Twenty service, which was unavailable at its saved local endpoint. Production PHAROS/Project Control, Gmail OAuth/mailbox actions, current GAP/KAIROS imports and the default-mail-client handoff retain their separate acceptance requirements. Notification delivery remains owner-deferred. No outreach, deployment, external migration or generated revenue is claimed.
