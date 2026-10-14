# ContextWard Remediation Changes — 2026-10-14

## Changed Files

- `native-crm/Sources/FollowUpOSNative/AppStore.swift` — Auto-Pilot field migration, task reminder scheduling, error sanitization
- `native-crm/Sources/FollowUpOSNative/EntityEditors.swift` — Task relationship pickers, contact relationship pickers
- `native-crm/Sources/FollowUpOSNative/RootView.swift` — Task reminder scheduling on launch
- `native-crm/Sources/FollowUpOSNative/SettingsView.swift` — Already contained Auto-Pilot toggle (verified in place)

## Changes by Promise

### 1. Auto-Pilot Switch (Promise #7)
**Status**: FIXED
- **Change**: Migrated `autoPullLeads` refs to `autoPilotEnabled` throughout AppStore
- **Files**: AppStore.swift 489, 500, 511, 522 (pullLeadsOnLaunch, startPulling, stopPulling, startPullLoop)
- **Default**: Now false (off by default) via Models.swift 103 initialization
- **UI**: SettingsView already has toggle at lines 57–67 with documentation
- **Behavior**: External syncs (PHAROS, Twenty, Gap Analysis) still require explicit preview and confirmation (per UI doc line 59)

### 2. Task Relationships (Promise #9)
**Status**: FIXED
- **Change**: Added relationship pickers to TaskEditor for contact, company, opportunity, lead
- **File**: EntityEditors.swift 125–149 (TaskEditor)
- **Fields exposed**: contactBinding, companyBinding, opportunityBinding, leadBinding
- **Data model**: CRMTask already has contactID, companyID, opportunityID, leadID fields in Models.swift 386–397

### 3. Contact Relationships (Promise #1 partial)
**Status**: FIXED
- **Change**: Added relationship pickers to ContactEditor for company and lead
- **File**: EntityEditors.swift 28–56 (ContactEditor)
- **Fields exposed**: companyBinding, leadBinding
- **Data model**: Contact already has companyID, leadID fields in Models.swift 338–349

### 4. Task Reminder Scheduling (Promise #3)
**Status**: FIXED
- **Change**: Implemented `scheduleTaskReminders()` function that schedules notifications for incomplete tasks with future due dates
- **Files**: AppStore.swift new function 1095–1115; RootView.swift task modifier; task add/update persistence
- **Trigger**: Notifications fire at 9 AM on task due date (UNCalendarNotificationTrigger)
- **Request auth**: Requests notification permission once, silent fail if denied
- **Called on**:
  - App launch (RootView.swift task modifier)
  - Task creation (AppStore.swift 775)
  - Task update (AppStore.swift 776)
- **Notes**: Incomplete tasks only; done tasks excluded

### 5. Error Sanitization (Promise #8 partial)
**Status**: IMPROVED
- **Change**: Fixed line 126 to use `message(for:)` instead of raw `error.localizedDescription`
- **File**: AppStore.swift 126
- **Verified safe**: All HTTP integration errors use `message(for:)` which extracts IntegrationError descriptions; Keychain/file errors use system LocalizedErrors
- **Remaining**: Run adversarial test (intentional credential echo attempt) during app verification

## Not Changed (Working or Deferred)

- **Promise #2** (Opportunities pipeline): Incomplete — no workflow UI added. Stages and relationship fields exist; flow UI deferred to secondary pass.
- **Promise #4** (Lead capture evidence): Incomplete — import works; scoring not visible. Deferred.
- **Promise #5** (Lantern transcripts): Incomplete — aggregation logic remains. Deferred.
- **Promise #6** (Integration status): Incomplete — PHAROS push lacks preview UI (contrast: Twenty has preview). Deferred to secondary pass.
- **Promise #10** (Note relationships): WORKING — no changes needed; contacts and companies are linked in NoteEditor

## Acceptance Scenario Path

Scenario: Record a lead → link to company and contact → add notes/audit → create opportunity → schedule follow-up → quit/reopen → context recovered.

**New support**:
- ✓ Leads can now be linked to a contact (ContactEditor.leadBinding, line 34)
- ✓ Tasks/opportunities can link to contact/company (TaskEditor, OpportunityEditor)
- ✓ Contacts expose company relationship (ContactEditor.companyBinding, line 34)
- ✓ Task due dates now schedule reminders automatically (scheduleTaskReminders on launch and create)
- ✓ Auto-Pilot defaults to OFF, with UI documentation

**Remaining to verify**:
- Contact → lead/company links persist across relaunch
- Task → contact/company/opportunity/lead links persist across relaunch
- Notification delivery occurs at scheduled time (requires system time advancement or manual verification)
- All error messages are sanitized (no raw API/credential text)

## Verification Methods

Before running acceptance test:
1. **Code inspection** ✓ (completed above)
2. **Running-app verification** (required) — acceptance scenario
3. **Live integration test** (optional, only if credentials configured)
4. **Adversarial test** (optional) — intentional error to verify no credential leakage

