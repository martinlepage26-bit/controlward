# ContextWard Acceptance Test Plan — 2026-10-14

**Scenario**: Record a lead → link to company and contact → add conversation notes and audit findings → create an opportunity → schedule next follow-up → quit and reopen → the full context and next action are recovered intact.

## Test Execution (Running App Required)

Build and launch the app on macOS 13+. Complete the following steps in order.

### Phase 1: Setup
1. Open Contextward
2. If no workspace exists, create one with business name "Test Studio" and industry "Consulting"
3. Verify **Settings** shows **Auto-Pilot: OFF** (confirm the new default)

### Phase 2: Company and Contact
4. Navigate to **Companies**, click "Add Companies"
5. Create a company:
   - Name: "Acme Builders"
   - Industry: "General Contracting"
   - Phone: "(514) 555-0100"
   - Notes: "Key client. Repeat business expected."
6. Save and navigate to **Contacts**, click "Add Contacts"
7. Create a contact:
   - First name: "Jamie"
   - Last name: "Smith"
   - Job title: "Project Manager"
   - Email: "jamie@acmebuilders.com"
   - Phone: "(514) 555-0101"
   - Company: "Acme Builders" (select from picker)
8. Save and verify contact appears in list with company shown in subtitle

### Phase 3: Lead and Notes
9. Navigate to **Pipeline**, click "Add lead"
10. Create a lead:
    - Name: "Acme Kitchen Renovation"
    - Email: "contact@acmebuilders.com"
    - Phone: "(514) 555-0100"
    - Company: "Acme Builders"
    - Service: "Kitchen renovation"
    - Quote: "5000"
11. Save. Navigate to **Notes**, click "Add Notes"
12. Create a note:
    - Title: "Discovery call"
    - Body: "Customer wants modern aesthetic. Budget is firm at $5k. Timeline: Spring 2026. Discussed material options: quartz counters, subway tile backsplash. Next: send concept sketches and material samples."
    - Contact: "Jamie Smith" (select from picker)
    - Company: "Acme Builders" (select from picker)
13. Save and verify note links to contact

### Phase 4: Opportunity and Task Scheduling
14. Navigate to **Opportunities**, click "Add Opportunities"
15. Create an opportunity:
    - Name: "Acme kitchen reno"
    - Amount: "5000"
    - Stage: "Proposal" (select from picker)
    - Contact: "Jamie Smith" (select from picker)
    - Company: "Acme Builders" (select from picker)
    - Notes: "Follow-up: awaiting material selection approval"
16. Save. Navigate to **Tasks**, click "Add Tasks"
17. Create a task:
    - Title: "Send concept sketches to Acme"
    - Status: "To Do" (select from picker)
    - Due date: 3 days from today
    - Contact: "Jamie Smith" (select from picker)
    - Company: "Acme Builders" (select from picker)
    - Opportunity: "Acme kitchen reno" (select from picker)
    - Details: "Email concept designs and material samples. Follow up by phone."
18. Save. Verify task appears in list with due date shown
19. **Notification verification (optional but recommended)**:
    - If macOS notification permissions are granted, wait for task reminder at the scheduled due date (9 AM local time)
    - Otherwise, skip this step

### Phase 5: Persistence Verification (Critical)
20. Verify the full context is visible before relaunch:
    - Lead shows company "Acme Builders"
    - Contact shows company "Acme Builders"
    - Note shows contact "Jamie Smith" and company "Acme Builders"
    - Task shows contact "Jamie Smith", company "Acme Builders", and opportunity "Acme kitchen reno"
    - Opportunity shows contact "Jamie Smith" and company "Acme Builders"
21. **Quit the app completely** (Cmd+Q)
22. **Reopen the app**
23. Verify **every link and note created in Phase 1–4 is recovered intact**:
    - Navigate to **Pipeline**: lead "Acme Kitchen Renovation" exists, shows company
    - Navigate to **Contacts**: "Jamie Smith" exists, shows company "Acme Builders"
    - Navigate to **Notes**: "Discovery call" exists, shows contact and company
    - Navigate to **Opportunities**: "Acme kitchen reno" exists, stage is "Proposal", amount is "$5000", shows contact and company
    - Navigate to **Tasks**: "Send concept sketches to Acme" exists, status is "To Do", due date is correct, shows contact, company, and opportunity

### Phase 6: Error State Verification (Security)
24. Navigate to **Settings** → **API keys**
25. Attempt to save an invalid PHAROS endpoint (e.g., "not a url") and invalid key
26. **Observe the error message**: should NOT contain raw HTTP status or full server error text
27. Correct both to valid values (or clear them)
28. Navigate to **Integration Center** and verify no integration is showing raw API error text

## Expected Results

### All Checks Pass (Scenario Success)
- ✓ Company and contact created and linked
- ✓ Contact appears in lead, note, task, and opportunity editors as selectable option
- ✓ Contact-to-company relationship persists and displays after relaunch
- ✓ Lead-to-company relationship persists and displays after relaunch
- ✓ Note-to-contact and note-to-company relationships persist after relaunch
- ✓ Task-to-contact, task-to-company, and task-to-opportunity relationships persist after relaunch
- ✓ Opportunity-to-contact and opportunity-to-company relationships persist after relaunch
- ✓ All data recovers intact after app quit and reopen
- ✓ Error messages are user-friendly and do not expose credentials or raw API text
- ✓ Auto-Pilot defaults to OFF in Settings

### Failing Check → Investigation Required
- Contact/company picker not visible in any editor: check EntityEditors.swift changes
- Relationship not persisting: check AppStore add/update/delete or Models.swift serialization
- Error message shows raw HTTP/API text: check error handling in AppStore or Integrations.swift

## Notes

- The contact picker in task/note editors is non-empty only after at least one contact is created
- Similarly for company, opportunity, and lead pickers
- Task reminders require notification permission (user is prompted once on first task creation or app launch)
- Auto-Pilot is OFF by default; turning it ON requires a valid PHAROS endpoint and API key
- External syncs (PHAROS push, Twenty upsert, Gap Analysis) are not tested in this scenario; integration tests are deferred

## Pass/Fail Criteria

**PASS**: Acceptance scenario completes; all relationship links persist through relaunch; no unresolved promise remains "working on inspection alone"

**FAIL**: Any relationship fails to display in editor, any relationship fails to persist across relaunch, or error messages leak credentials/raw API text
