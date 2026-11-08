# Using ControlWard for daily prospect and follow-up work

If a record cannot be saved, its editor stays open with an error. Keep the form open, restore access to the workspace folder or free disk space, then try Save again. The displayed draft has not been committed until Save succeeds; quitting or cancelling can discard it.

Start in **Pipeline**. Import an existing lead CSV, add a lead by hand, or use **Find prospects** to review public business listings. For configured evidence-backed research, use **Pipeline → Leads** and add only Ready records to Pipeline for review. Operations → Import LeadGen accepts exported event files. A listing or imported score is a research lead; it does not establish buying intent.

If a connection says **Access needed**, use its **Verify** or **Check access**
action and handle any macOS dialog locally. Automatic refreshes pause until the
credential is accessible; the saved sign-in and Auto-Pilot choice are retained.
Credential checks and reads use a30-second application-wait deadline. If the
wait expires, the app releases its busy controls and retains your saved
connection. A synchronous macOS lookup may still be running; another lookup for
that item is refused until it returns. Handle any local access prompt before
retrying. You can continue local CRM work. See the
[deadline behavior and test scope](credential-wait-acceptance-20261108.md).

Changing a connection or stopping automatic intake prevents a pending read from
importing into the replacement connection. A PHAROS snapshot edited during
credential access needs a fresh preview. A write already issued to a provider
retains its observed outcome; stopping does not undo it.

**Find prospects** researches the selected businesses' websites for public contact routes, named people and explicit AI-use evidence. Expand **Research websites from a search or agent** to give it business websites from another discovery source; ControlWard obtains the evidence itself. Sources, timestamps and unknowns are retained when the search sheet or app closes. Use **Add researched lead** to save a finding and any eligible 99 CAD Quick Scan draft into Pipeline for review. Published business contact details are not proof of a person's private inbox or mailbox deliverability. Map coverage can be sparse; a missing result does not establish that no suitable business exists.

The desktop's evidence search stops after 90 seconds and offers **Cancel search**. Completed research records are kept. Public providers can return sparse results or fail; inspect the recorded source/refusal evidence and qualify a business before treating it as a sales opportunity.

Discovery's **KAIROS targeting and enquiries** panel reads the saved audience,
positioning, content-performance context and inbox availability. Use **Review
enquiry links** to confirm an enquiry's researched business. Suggestions require
review, and manual links require a reason. **Review fit** records your explained
offer-fit decision. Fit, recorded interest and website-published contactability
stay separate; content metrics never establish buyer intent. Paused collection
and an empty inbox leave interest unknown. See the [matching and evidence rules](kairos-discovery.md).

Open a lead and check its name, source evidence, contact details, service or ask, and next follow-up date. Enter a value only when you have one. Choose **Review conversion…** (or **Review links…** for a converted lead), check the proposed company, contact, opportunity and follow-up task, then confirm. A business without a named person creates no invented contact. A second conversion reuses its links.

Choose **Write follow-up message**, or continue the retained message. Read the recorded facts and unknowns. Apple Intelligence may rephrase a grounded draft; unsupported additions fall back to recorded facts. **Save & close** retains unsent text separately from sent history. **Copy** places it on the macOS clipboard.

Lead outreach uses **Review & send via Resend**, from **ml@pharos-ai.ca**. Review the exact recipient, subject and complete body. Cancelling has no provider effect. External recipients start disabled. In **Settings → Outreach through Resend → Review recipient policy…**, the owner can review the scope and record a privacy-assessment ruling with its reference. That decision applies to all otherwise eligible native recipients in this workspace; every message still needs separate confirmation. **Restrict to owner addresses…** cancels existing message previews, including a confirmation waiting for credential access. CRM restore/reset or a changed policy needs a fresh review. An eligible draft or saved key does not prove approval or acceptance. Only a successful provider receipt adds sent history and updates the linked next action; acceptance, delivery, replies and payment remain separate. There is no Gmail/default-mail fallback or manual “Mark as sent” action in this lead flow. See [reviewed Resend outreach](resend-outreach.md).

Version 4 website research records the requested page. Changed pages, older parser versions, incomplete findings, findings at least an hour old and a new local day require a fresh fetch before cache reuse. A saved older-parser cold-outreach draft shows a recheck reason. A newer negative recheck governs the draft without erasing its text, history, relationships or dates. Contactability withholds partial phone links and the North American fictional-number range while retaining original evidence. Published routes still do not prove subscriber ownership or reachability. See [contact quality and freshness](discovery-contact-freshness-20261108.md).

Use **Tasks** or the lead's next follow-up date to maintain the next action. The converted lead and its follow-up task share the date. Operations → **Schedule reminders** requests notification permission explicitly and reports the result. Until macOS authorization and delivery are confirmed, use the visible Pipeline due list and Tasks list; they work without notifications.

Record Won or Lost when the outcome is known. ControlWard updates the linked opportunity and closes that lead's follow-up task. Pipeline totals count the entered value once and list unvalued records separately. Won value records an outcome you enter; it is not a payment receipt or revenue generated by the application.

Use **Notes** for relationship context and **Email → Local review inbox** for metadata review. Exact sender addresses can suggest existing leads, including several choices for a shared route; review and save the association yourself. **Use lead next action** reuses the lead's existing task, including when several messages belong to that lead. Completion and deletion receipts are retained. An unlinked message keeps its separate one-task receipt. **Open lead and draft** opens the associated CRM record. A sender match does not authenticate identity or prove a buying enquiry. Known-lead Reply, Reply all and Forward direct you to the reviewed Resend flow; ordinary personal-mail actions retain their connector. Synthetic/imported mail without a connected provider cannot perform mailbox actions. **Operations → Lantern audits** keeps separate French and English assessments; **Saved views** is in the profile menu at the top right.

In Contacts, Companies, Opportunities, Tasks and Notes, select a row and press Return or Space to edit it, or use its labelled edit action. Existing record editors offer a confirmed local delete. Related records and their own text stay; links to the deleted record are cleared. Deleting a lead's next-action task clears that lead's follow-up date. Each deletion first saves a private recovery backup. Settings → **Show deletion backups** locates these files; **Review a backup to restore** recovers the workspace. Historical task and capture receipts remain, so a repeated import does not recreate work you deleted. Deletion does not remove an upstream record.

Before significant changes, use Settings → **Save local backup**. It includes saved leads and unreviewed website research, source evidence, exact drafts and exclusions. Restore previews these counts and saves a rollback copy first. Older backups without unreviewed research keep the current findings. Restoring or resetting rotates the research generation, so old pending agent requests are cancelled without visiting websites; submit a fresh batch afterward. Wait for or cancel active research before restoring. A damaged research or exclusion file is retained and blocks a misleading complete backup. The backup excludes Keychain credentials, WebKit module storage and external registers. Export Project Control separately through its Tools menu. Project capture previews the destination and creates an unassigned inbox item; project decisions remain in that register.

Backups with repeated record IDs are refused as a whole, including audit transcripts and lead history; the error names the collection. A refused restore changes no records or recovery files. Export validates its snapshot before replacing an existing backup. Use the original source or a different valid backup after correcting the identified records; the app does not silently merge or discard ambiguous identities. See [backup validation acceptance](backup-validation-acceptance-20261107.md).

For a walkthrough with synthetic fixtures, run `bin/preview-controlward`. To review the actual release app, run `bin/review-controlward /path/to/ControlWard.app`. It prints a review UUID; pass that UUID as the second argument to reopen the same review. This mode has a separate sandbox workspace, ephemeral embedded modules, no saved account access or connector traffic, and no notification scheduling. Public prospect search and local CRM work remain available. The helper refuses older builds that do not support this mode. Opening the app normally uses the established workspace and configured accounts.

The app imports its legacy website-research cache once into the native workspace, preserving the original and a private pre-migration copy. If a workspace write fails during research, completed findings are retained in a private recovery file when that directory remains writable. Reopen after repairing storage or use **Refresh findings** to retry recovery. Recovery never sends messages or promotes a lead by itself. Use the research client bundled with the current app; protocol version2 binds requests to the current workspace generation.

Lantern refreshes preserve reviewed audit identity, CRM links, findings and remediation. Scores and transcript exports replace earlier imported values rather than accumulate on replay. An unfilled canonical template imports no scores. Invalid rows or failed storage leave that file unapplied; Operations keeps the named error visible until you dismiss it. See the [input and recovery contract](lantern-import-contract.md) for accepted values and multi-file behavior.

Lantern combines rows using each row's sample count; canonical transcript rows each count once. Fractional scores are retained. A missing language, zero samples or incomplete assessment shows **Unscored**, stays out of the average gap and creates no gap-remediation task. In the audit editor, review all five dimensions and source weights before marking an assessment complete. Old multi-row imports without saved weights need reimporting or review. Before downgrading to an older integer-only build, restore a backup made for that build: keeping the older app alone does not roll back fractional data.

A converted lead exports to Twenty through its linked opportunity, so it represents one deal. If the lead was pushed before conversion, the existing remote deal is reused. After an interrupted push, review a fresh preview and retry: pending creations resume their saved record identities. The app stops if it cannot save progress. Several local opportunities competing for one prior remote deal block the push for relationship review. Already separate remote duplicates are retained; ControlWard never deletes them automatically. The adapter does not map native Lost to a remote stage; review that outcome in Twenty.

Integration Center labels LeadGen imports and Lantern audits **Local**. Imported records do not activate a provider connection. PHAROS, Twenty, GAP and KAIROS display their own setup, verification or error status; use the PHAROS status for the live lead inbox.

KAIROS imports require the customer-account API key issued by KAIROS. A Resend
sending key, even one named KAIROS, does not authenticate this inbox connector.
Resend sending keys are for email delivery and can be restricted to a sending
domain; they are not interchangeable with the KAIROS customer API credential.
Its current service refuses
operator API keys on inbox routes; the operator's browser sign-in is separate.
An import reads lead-intent entries from up to200 prioritized conversations.
GAP, KAIROS and each PHAROS lead-inbox page publish imported records only after the complete local save
succeeds. If storage is blocked, restore access to the workspace folder and
retry. Owner decisions and existing records remain intact.
The connector panel keeps the latest failed attempt visible while the app is open,
even when storage could not save its diagnostic. A successful retry replaces it.

PHAROS acknowledges an inbox page only after saving its records and source epoch.
A blocked save leaves new leads, retractions and cursor changes unapplied. Repair
storage and choose **Pull now** to retry. If an acknowledgement fails after the
page was saved, those durable records stay; a retry deduplicates them. Progress
from earlier saved pages is retained if a later page fails.

KAIROS incoming text appears in **Latest incoming message**, with its channel
and source timestamp. Use **Write follow-up message** to start an outgoing draft.
Incoming updates retain the saved reply, sent history and owner-entered service.
On older mixed records, the editor prepares a repaired copy; Cancel leaves the
file unchanged, while Save retains the separate source fields.

## Connect the native Gmail inbox

In **Integrations → Mail accounts**, choose **Connect** beside the matching Gmail address and complete Google’s consent yourself. A Chrome or Gmail+ sign-in is separate. If a previous native sign-in expired or has older read-only permissions, choose **Reconnect** directly; you do not need to disconnect first. Cancelling or failing sign-in preserves the previous token. A wrong-account sign-in is refused before replacing it. Refresh checks the mailbox; browser draft handoff alone does not establish native sync.
