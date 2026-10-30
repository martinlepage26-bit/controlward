# ControlWard Chrome Companion (source)

This Manifest V3 extension implements a focused, local lead-capture workflow: explicitly capture the active page or a selected text/link; edit the business name, website, municipality hint and configured segment; authorize ControlWard to fetch the selected public business website; review the result from ControlWard’s existing lead pipeline and RBQ checks; inspect evidence and possible duplicates; then separately confirm a save or an explicit update/skip decision.

It is TypeScript source plus generated scripts in `dist/`. It does not call the PHAROS Worker or a hosted API, embed a Worker credential, create outreach, send messages, monitor browsing history, or install itself. The Worker’s currently documented routes do not include browser capture/create-lead, so the integration is a source-only Chrome Native Messaging host added under `native-crm/ChromeBridge/`.

## Build and checks

```bash
cd chrome-extension
npm ci
npm test
```

`npm test` compiles TypeScript strictly and runs structural checks for the Manifest V3 permissions, lack of broad host permissions/content scripts, CSP, explicit capture paths, English/French controls, generated scripts, and absence of Worker credentials. The generated `dist/` files are included so the extension can be loaded without running TypeScript first.

## Load the unpacked extension

1. Run the build/check commands above.
2. In Chrome, open `chrome://extensions`, enable **Developer mode**, and choose **Load unpacked**.
3. Select this `chrome-extension` directory. Copy the extension ID shown on its details card.
4. In the full source checkout root, run the native host installer with that exact ID:

   ```bash
   native-crm/ChromeBridge/install-chrome-native-host.sh <32-character-extension-id>
   ```

   This user-run script builds the Native Messaging executable, installs it under `~/Library/Application Support/ControlWard/ChromeBridge`, and registers a host manifest under Chrome’s `NativeMessagingHosts` directory with an `allowed_origins` entry for that one extension ID. It validates that the configured app container exists. **It does not build, install, replace, launch, or update `ControlWard.app`.** The script is supplied but was not run as part of this delivery.

5. Restart Chrome after registration. Open the extension popup, open the side panel, and pair it once with the host. Pairing stores a random token in extension `storage.local` and only its SHA-256 hash in the app-container Leads folder. The token is not synchronized and is never placed in the extension package.
6. Capture from a business page or right-click selected text/a link. Review all editable input. A municipality is explicitly an unverified hint and is not passed into the canonical location or RBQ matching rules. The native app’s configured rules and licensed data remain authoritative.
7. Review the separate ControlWard verdict, reasons, source URLs/excerpts, fetch time, and duplicate. Check the authorization box and confirm the exact create/update/skip operation in the additional confirmation prompt before a register write.

To remove only the bridge registration and helper files, run `native-crm/ChromeBridge/uninstall-chrome-native-host.sh`. It intentionally leaves the Leads data and pairing state untouched. If the extension token is lost, close Chrome, remove only `chrome-pairing.json` from the app-container Leads folder shown below, reload the extension, and pair again; do not delete the Leads folder or `prospects.json`.

## Verified data location

The app’s packaged `CFBundleIdentifier` is `com.pharos.contextward`, and its entitlements enable App Sandbox. `LeadPipelineEnvironment.defaultRoot()` resolves Application Support within that sandbox when called by the app. The local Chrome host wrapper explicitly sets `CONTROLWARD_LEADS_DIR` to the same configured container location:

```text
~/Library/Containers/com.pharos.contextward/Data/Library/Application Support/ControlWard/leads
```

The macOS container directory and `Data/Library/Application Support` were present during a read-only check. The `ControlWard` and `leads` subdirectories were **absent** at that time; they were not created. Pairing or app use will create the folder with owner-only permissions. No prospect file was read or modified. This path is also documented by the app’s lead-proof tooling, which uses `bin/prove-lead-pipeline --verify-app <path>`.

## Architecture and safeguards

- Chrome permissions are limited to `activeTab`, `scripting`, `storage`, `sidePanel`, `contextMenus`, and `nativeMessaging`; there is no `host_permissions` and no always-on content script.
- Page extraction runs only on an explicit button click. Context-menu selection/link data is staged as untrusted text for user review. No page text is interpreted as instructions.
- The native host validates framed JSON size, protocol version, exact allowed keys, field bounds, operation schemas, extension ID, and paired token. Chrome’s native-host manifest is restricted to the loaded extension’s exact origin.
- The host reuses `ProspectSearchRun`, `GuardedLeadTransport`, `SiteExtractor`, `LeadDefinition`, `RBQOpenData`, and the current bundled ICP configuration. Missing or ambiguous reference data follows existing fail-closed logic. A typed municipality hint is intentionally excluded from location and RBQ matching.
- The capture is staged in memory for review; qualification does not save. Save requires an exact operation decision plus a separate user confirmation. Before a disk transaction, duplicate identity is checked again. An unapproved or changed duplicate fails without merging.
- Prospect updates use the existing local JSON register with process/thread serialization and atomic, mode-600 writes under a mode-700 directory. The bridge does not alter Worker provenance policy or write to production/remote records.

## Scope and unverified items

This is one complete single-business vertical slice. It does not yet include multi-candidate batch save, lead filtering/tag workflows, or a live Chrome screenshot/demo. Native ControlWard qualification reasons and some native error text remain in their existing English wording, while the extension’s main controls support English and French. Chrome installation/registration, live page extraction through Chrome, the signed app’s real launch environment, live website fetches, and app UI refresh after a bridge save were deliberately not run or are unverified. See `CHROME-EXTENSION-TEST-REPORT.md` in the repository root.
