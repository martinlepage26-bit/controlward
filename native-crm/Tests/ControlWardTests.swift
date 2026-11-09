import Foundation

@MainActor
enum ControlWardTests {
    static var count = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw SmokeTestFailure.failed(message) }
        count += 1
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { count += 1; return }
        throw SmokeTestFailure.failed(message)
    }
    static func metadata(subject: String = "Synthetic review", source: String = "thread-1", date: String = "2026-10-17T09:00:00Z") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema_version": "controlward.mail.v1", "messages": [[
            "source_id": source, "subject": subject, "sender": "fixture@example.test", "recipient": "owner@example.test",
            "received_at": date, "provider": "synthetic", "account_id": "account-a", "synthetic": true,
            "body_text": "BODY_MUST_NOT_PERSIST", "access_token": "TOKEN_MUST_NOT_PERSIST"
        ]]])
    }
    static func run() -> Bool {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("controlward-tests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"))
            store.createWorkspace(name: "Synthetic ControlWard", industry: "Consulting")
            try expect(try store.importMailMetadata(metadata()) == 1, "mail import must add one message")
            let first = store.mail[0]
            try expect(MailMetadata.sourceIdentity(account: "a:b", message: "c", synthetic: false) != MailMetadata.sourceIdentity(account: "a", message: "b:c", synthetic: false), "mail identity has a delimiter collision")
            try expect(first.capture.sourceID.count <= 256, "mail capture identity exceeds the Worker contract")
            var contact = Contact(); contact.firstName = "Synthetic"; store.add(contact)
            var company = Company(); company.name = "Érable Studio"; store.add(company)
            try store.reviewMail(first.id, reviewed: true, contactID: contact.id, companyID: company.id)
            let task = try store.createMailTask(first.id)
            try expect(try store.createMailTask(first.id) == task && store.tasks.count == 1, "repeated task action duplicated work")
            try expect(try store.importMailMetadata(metadata(subject: "Updated subject")) == 0, "re-import must dedupe")
            try expect(store.mail[0].id == first.id && store.mail[0].reviewed && store.mail[0].taskID == task && store.mail[0].contactID == contact.id, "re-import overwrote local decisions")
            try expect(store.mail[0].subject == "Updated subject", "metadata refresh was not applied")
            let encoded = String(decoding: try JSONEncoder().encode(store.workspace), as: UTF8.self)
            try expect(!encoded.contains("BODY_MUST_NOT_PERSIST") && !encoded.contains("TOKEN_MUST_NOT_PERSIST"), "unknown private fields were retained")
            try expect(!store.activity.contains { $0.message.contains("fixture@example.test") }, "mail activity log contains sender metadata")
            try store.completeTask(task, completed: true)
            try expect(try store.createMailTask(first.id) == task && store.tasks[0].status == .done, "task retry revived completed work")
            try rejects("invalid calendar day accepted") { _ = try store.importMailMetadata(metadata(date: "2026-02-31T10:00:00Z")) }
            try rejects("empty subject accepted") { _ = try store.importMailMetadata(metadata(subject: " ")) }
            try expect(store.mail.count == 1, "failed import changed records")
            let recordKey = "contacts:\(contact.id.uuidString.lowercased())"
            try store.linkProject(recordKey: recordKey, register: "https://register-a.example.test", projectID: "abc012345678", title: "Synthetic project A")
            try store.linkProject(recordKey: recordKey, register: "https://register-b.example.test", projectID: "abc012345678", title: "Synthetic project B")
            try expect(store.workspace.controlWard.projectLinks.count == 2, "links from distinct registers were merged")
            try store.linkProject(recordKey: recordKey, register: "https://register-a.example.test", projectID: "def012345678", title: "Updated project A")
            try expect(store.workspace.controlWard.projectLinks.count == 2, "relink duplicated a record link")
            try rejects("credential URL accepted") { try store.linkProject(recordKey: recordKey, register: "https://user:synthetic@example.test", projectID: "abc", title: "Bad") }
            try rejects("missing local record accepted") { try store.linkProject(recordKey: "contacts:missing", register: "https://example.test", projectID: "abc", title: "Bad") }
            try store.recordCapture(recordKey: recordKey, register: "https://example.test", itemID: "captured-1")
            try store.recordCapture(recordKey: recordKey, register: "https://example.test", itemID: "captured-1")
            try expect(store.workspace.controlWard.captures.count == 1, "capture receipts duplicated")
            try expect(store.records(search: "erable studio").contains { $0.recordID == company.id }, "search does not normalize accents")
            try expect(store.records(kind: "tasks", filter: .completed).count == 1 && store.records(kind: "tasks", filter: .open).isEmpty, "saved view status filters mismatch")
            let invalid = WorkspaceRecord(recordID: UUID(), kind: "tasks", title: "Invalid due", detail: "", date: "2026-02-31", supportsCompletion: true)
            let overdue = WorkspaceRecord(recordID: UUID(), kind: "tasks", title: "Due", detail: "", date: "2026-01-01", supportsCompletion: true)
            try expect(WorkspaceRecord.query([invalid, overdue], search: "", filter: .overdue, sort: .due, today: "2026-10-17").map(\.id) == [overdue.id], "overdue count included an invalid date")
            let old = try JSONDecoder().decode(PersistentWorkspace.self, from: Data("{}".utf8))
            try expect(old.controlWard.mail.isEmpty && old.controlWard.projectLinks.isEmpty, "legacy workspace requires a destructive migration")
            let legacyView = try JSONDecoder().decode(SavedView.self, from: Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"Old\",\"objectName\":\"Contacts\",\"filter\":\"all\"}".utf8))
            try expect(legacyView.search == nil, "legacy saved view no longer loads")
            let companyKey = TwentyMapper.key("company", company.id)
            try store.commitWorkspace { next in
                next.twentyLinks[companyKey] = TwentyLink(twentyID: "stale-backup-id", object: .companies, payloadHash: "old")
            }
            let backupURL = root.appendingPathComponent("export.json")
            try store.exportControlWardBackup(to: backupURL)
            let data = try Data(contentsOf: backupURL)
            let permissions = try FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions] as? NSNumber
            try expect(permissions?.intValue == 0o600, "backup is not owner-only")
            store.setEndpoint("https://current.example.test", for: .gaps)
            try store.commitWorkspace { next in
                next.twentyLinks[companyKey] = TwentyLink(twentyID: "current-id", object: .companies, payloadHash: "current")
                next.twentyLinks["company:deleted"] = TwentyLink(twentyID: "deleted-id", object: .companies, payloadHash: "old")
            }
            try rejects("unconfirmed restore accepted") { try store.restoreControlWardBackup(data, confirmed: false) }
            try store.restoreControlWardBackup(data, confirmed: true)
            try expect(store.endpoint(for: .gaps) == "https://current.example.test", "restore changed connector destinations")
            try expect(store.workspace.twentyLinks[companyKey]?.twentyID == "current-id" && store.workspace.twentyLinks["company:deleted"] == nil, "restore lost current sync identity or imported stale remote IDs")
            try expect(store.mail[0].reviewed && store.workspace.controlWard.captures.count == 1, "restore lost owner workflow state")
            try expect(!store.workspace.autoPilotEnabled && store.workspace.syncJobs.isEmpty, "restore reactivated queued writes")
            try expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("before-restore-") }, "restore did not preserve a rollback backup")
            var bad = try AppStore.readControlWardBackup(data); bad.workspace.contacts.append(bad.workspace.contacts[0])
            try rejects("duplicate backup identities accepted") { _ = try AppStore.readControlWardBackup(JSONEncoder().encode(bad)) }
            var unsafeBackup = try AppStore.readControlWardBackup(data)
            unsafeBackup.workspace.controlWard.mail[0].link = "javascript:alert(1)"
            try rejects("restore bypassed mail link validation") { _ = try AppStore.readControlWardBackup(JSONEncoder().encode(unsafeBackup)) }
            let blocker = root.appendingPathComponent("blocked-parent"); try Data("file".utf8).write(to: blocker)
            let unwritable = AppStore(storageURL: blocker.appendingPathComponent("workspace.json"))
            try rejects("unwritable import claimed success") { _ = try unwritable.importMailMetadata(metadata()) }
            try expect(unwritable.mail.isEmpty, "failed disk write changed in-memory mail")
            let reloaded = AppStore(storageURL: store.storageURL)
            try expect(reloaded.mail == store.mail && reloaded.workspace.controlWard.projectLinks == store.workspace.controlWard.projectLinks, "new workflows did not survive reload")
            let scratchRoot = root.appendingPathComponent("scratch-mail")
            try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
            let scratch = AppStore(storageURL: scratchRoot.appendingPathComponent("workspace.json"))
            scratch.createWorkspace(name: "Synthetic Trash", industry: "Consulting")
            try expect(try scratch.importMailMetadata(metadata(source: "gone")) == 1, "scratch import")
            let gone = scratch.mail[0].id
            try scratch.forgetMailMetadata(id: gone)
            try expect(scratch.mail.isEmpty, "trashed metadata row was kept")
            let scratchFile = String(decoding: try Data(contentsOf: scratch.storageURL), as: UTF8.self)
            try expect(scratchFile.contains("mail_trash") && !scratchFile.contains("BODY_MUST_NOT_PERSIST"), "trash note")
            try rejects("forgetting a missing message") { try scratch.forgetMailMetadata(id: gone) }
            let hygiene = AppStore(storageURL: root.appendingPathComponent("hygiene/workspace.json"), secrets: InMemorySecretStore())
            var synthetic = Lead.blank(); synthetic.name = "Synthetic hygiene acceptance"
            hygiene.add(synthetic)
            _ = hygiene.runLocalExposureScan()
            let finding = hygiene.exposureFindings[0]
            try hygiene.createSecurityReviewTask(finding.id)
            let taskIDs = hygiene.tasks.map(\.id)
            _ = hygiene.runLocalExposureScan()
            try expect(hygiene.exposureFindings.map(\.id) == [finding.id], "rescan replaced a finding identity")
            try hygiene.createSecurityReviewTask(finding.id)
            try expect(hygiene.tasks.map(\.id) == taskIDs && hygiene.workspace.controlWard.remediationTasks[finding.id] == taskIDs[0], "rescan lost or duplicated a review task")
            hygiene.resolve(finding)
            _ = hygiene.runLocalExposureScan()
            try expect(hygiene.exposureFindings.count == 1 && hygiene.exposureFindings[0].resolved, "rescan discarded the operator resolution")
            let reopenedHygiene = AppStore(storageURL: hygiene.storageURL, secrets: InMemorySecretStore())
            try expect(reopenedHygiene.exposureFindings == hygiene.exposureFindings && reopenedHygiene.tasks.map(\.id) == taskIDs, "security decisions did not survive reopen")
            try mailLeadReview(root.appendingPathComponent("mail-leads"))
            try BackupIdentityTests.run()
            print("ControlWard workflow tests: \(count) assertions passed")
            return true
        } catch { print("FAIL ControlWard workflow tests: \(error)"); return false }
    }

    static func mailLeadReview(_ root: URL) throws {
        let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore())
        store.createWorkspace(name: "Synthetic mail-to-lead acceptance", industry: "Consulting")
        var company = Company(); company.name = "Synthetic Studio"
        var contact = Contact(); contact.firstName = "Camille"; contact.email = "camille@example.test"; contact.companyID = company.id
        var lead = Lead.blank(); lead.name = "Camille Example"; lead.email = "studio@example.test"
        lead.companyID = company.id; lead.contactID = contact.id; lead.nextFollowUp = "2026-11-09"
        lead.outreachDraft = "Saved unsent draft"; lead.notes = "Private notes stay private"
        var opportunity = Opportunity(); opportunity.name = "Synthetic unsent review"; opportunity.leadID = lead.id
        opportunity.companyID = company.id; opportunity.contactID = contact.id
        var task = CRMTask(); task.title = "Existing owner next action"; task.details = "Keep this wording"
        task.leadID = lead.id; task.contactID = contact.id; task.companyID = company.id; task.opportunityID = opportunity.id
        task.dueDate = lead.nextFollowUp; task.reminderAt = "2026-11-09T14:00:00Z"; lead.followUpTaskID = task.id
        var other = Lead.blank(); other.name = "Different record"; other.email = "other@example.test"
        var mail = MailMetadata(sourceID: "gmail:synthetic-received", subject: "Synthetic incoming review", sender: "Camille <CAMILLE@example.test>", recipient: "owner@example.test", receivedAt: "2026-11-08T12:00:00Z", provider: "gmail", accountID: "owner@example.test", synthetic: true)
        try store.commitWorkspace { w in
            w.leads = [lead, other]; w.companies = [company]; w.contacts = [contact]
            w.opportunities = [opportunity]; w.tasks = [task]; w.controlWard.mail = [mail]
        }
        let baseline = store.workspace
        try expect(store.mailLeadMatches(mail).map(\.id) == [lead.id], "linked-contact address should suggest the existing lead")
        try expect(store.workspace == baseline, "suggestions changed the workspace")
        try expect(store.mailRequiresResend(mail), "exact lead sender was permitted to fall back to the mailbox")
        var personal = mail; personal.sender = "friend@elsewhere.example.test"
        try expect(!store.mailRequiresResend(personal), "unrelated personal mail was treated as lead outreach")
        try expect(store.mailRequiresResend(personal, compose: MailCompose(draftID: nil, to: ["studio@example.test"], cc: [], subject: "Synthetic", body: "Synthetic")), "edited To field bypassed the lead sender route")
        try expect(store.mailRequiresResend(personal, compose: MailCompose(draftID: nil, to: ["friend@elsewhere.example.test"], cc: ["camille@example.test"], subject: "Synthetic", body: "Synthetic")), "edited Cc field bypassed the lead sender route")
        var shared = other; shared.email = lead.email; _ = store.update(shared)
        var sharedMail = mail; sharedMail.sender = "studio@example.test"
        try expect(store.mailLeadMatches(sharedMail).count == 2, "shared business routes must retain ambiguity")
        for sender in ["Name only", "studio@lookalike.example.test", "studio@example.test, other@example.test", "ml@pharos-ai.ca", "owner@example.test"] {
            var candidate = mail; candidate.sender = sender
            try expect(store.mailLeadMatches(candidate).isEmpty, "unsafe, owner or nonmatching sender suggestion: \(sender)")
        }
        for sender in ["o'studio@example.test", "!studio@example.test", "éstudio@example.test", "studio@example.test_extra"] {
            var candidate = mail; candidate.sender = sender
            try expect(store.mailLeadMatches(candidate).isEmpty, "partial sender address suggested another lead: \(sender)")
            try expect(!store.mailRequiresResend(candidate), "partial sender address was treated as an exact lead route: \(sender)")
        }
        var punctuated = shared; punctuated.email = "o'connor@example.test"; _ = store.update(punctuated)
        var punctuatedMail = mail; punctuatedMail.sender = "O'Connor <O'CONNOR@example.test>"
        try expect(store.mailLeadMatches(punctuatedMail).map(\.id) == [punctuated.id], "complete apostrophe address lost its exact lead match")
        try expect(store.mailRequiresResend(punctuatedMail), "complete apostrophe lead address bypassed Resend routing")
        try expect(store.mailRequiresResend(personal, compose: MailCompose(draftID: nil, to: [punctuated.email], cc: [], subject: "Synthetic", body: "Synthetic")), "complete apostrophe compose recipient bypassed Resend routing")
        var asciiLead = shared; asciiLead.email = "konnor@ekample.test"; _ = store.update(asciiLead)
        for sender in ["Konnor@ekample.test", "konnor@eKample.test"] {
            var candidate = mail; candidate.sender = sender
            try expect(store.mailLeadMatches(candidate).isEmpty, "Unicode case folding suggested an ASCII lead: \(sender)")
            try expect(!store.mailRequiresResend(candidate), "Unicode case folding created an exact lead route: \(sender)")
        }
        var asciiMail = mail; asciiMail.sender = "KONNOR@EKAMPLE.TEST"
        try expect(store.mailLeadMatches(asciiMail).map(\.id) == [asciiLead.id] && store.mailRequiresResend(asciiMail), "ASCII uppercase exact address lost its lead route")
        _ = store.update(shared)
        let beforeInvalid = store.workspace
        try rejects("missing lead accepted") { try store.reviewMail(mail.id, reviewed: true, contactID: nil, companyID: nil, leadID: UUID()) }
        try rejects("conflicting contact accepted") { try store.reviewMail(mail.id, reviewed: true, contactID: UUID(), companyID: nil, leadID: lead.id) }
        try expect(store.workspace == beforeInvalid, "rejected association partially saved")
        try store.reviewMail(mail.id, reviewed: true, contactID: nil, companyID: nil, leadID: lead.id)
        try expect(store.mail[0].leadID == lead.id && store.mail[0].contactID == contact.id && store.mail[0].companyID == company.id, "review did not use the lead's existing relationships")
        personal.leadID = lead.id
        try expect(store.mailRequiresResend(personal), "manual lead association bypassed the Resend route")
        try expect(store.leads.first { $0.id == lead.id } == lead && store.workspace.resendDispatches.isEmpty, "association changed lead context, history, dates or send state")
        try expect(try store.createMailTask(mail.id) == task.id && store.tasks == [task], "mail review duplicated or rewrote the existing next action")
        try expect(try store.createMailTask(mail.id) == task.id && store.tasks.count == 1, "repeated next-action link duplicated work")
        let beforeConflict = store.workspace
        try rejects("mail task reassigned to another lead") { try store.reviewMail(mail.id, reviewed: true, contactID: nil, companyID: nil, leadID: other.id) }
        try expect(store.workspace == beforeConflict, "task ownership conflict changed data")
        var incoming = mail; incoming.subject = "Refreshed metadata"; incoming.leadID = other.id
        _ = try store.mergeMail([incoming], activity: "Synthetic metadata refresh")
        try expect(store.mail[0].leadID == lead.id && store.mail[0].taskID == task.id && store.mail[0].reviewed, "refresh overwrote the owner association or task receipt")
        try store.completeTask(task.id, completed: true)
        let completed = store.tasks[0]
        try expect(try store.createMailTask(mail.id) == task.id && store.tasks[0] == completed, "mail retry revived completed next-action work")
        let saved = store.workspace
        let reopened = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
        try expect(reopened.workspace.controlWard.mail == saved.controlWard.mail && reopened.leads == saved.leads && reopened.tasks == saved.tasks, "mail association and lead work did not survive reopen")
        // Upstream JSON is untrusted metadata, not permission to set local CRM associations.
        var file = try JSONSerialization.jsonObject(with: metadata(source: "untrusted-local-links")) as! [String: Any]
        var rows = file["messages"] as! [[String: Any]]; rows[0]["leadID"] = lead.id.uuidString; rows[0]["lead_id"] = lead.id.uuidString; file["messages"] = rows
        let imported = try MailMetadataImport.decode(JSONSerialization.data(withJSONObject: file))
        try expect(imported[0].leadID == nil, "metadata import supplied a local lead association")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mail)) as! [String: Any]; legacy.removeValue(forKey: "leadID")
        try expect(try JSONDecoder().decode(MailMetadata.self, from: JSONSerialization.data(withJSONObject: legacy)).leadID == nil, "older metadata no longer decodes")
        // A lead without an existing action gets one, with the already recorded date and links.
        var fresh = Lead.blank(); fresh.name = "New review"; fresh.nextFollowUp = "2026-11-10"
        _ = store.add(fresh)
        var second = mail; second.id = UUID(); second.sourceID = "gmail:second"; second.taskID = nil; second.leadID = nil
        _ = try store.mergeMail([second], activity: "Synthetic second message")
        try store.reviewMail(second.id, reviewed: true, contactID: nil, companyID: nil, leadID: fresh.id)
        let newTaskID = try store.createMailTask(second.id)
        try expect(store.tasks.first { $0.id == newTaskID }?.leadID == fresh.id && store.tasks.first { $0.id == newTaskID }?.dueDate == fresh.nextFollowUp, "new lead action lost its relationship or existing date")
        try expect(store.leads.first { $0.id == fresh.id }?.followUpTaskID == newTaskID, "new action is detached from the Pipeline next action")
        _ = store.delete(store.tasks.first { $0.id == newTaskID }!)
        try rejects("deleted mail task recreated") { _ = try store.createMailTask(second.id) }
        var closed = Lead.blank(); closed.name = "Closed record"; closed.status = .lost; _ = store.add(closed)
        var closedMail = mail; closedMail.id = UUID(); closedMail.sourceID = "gmail:closed"; closedMail.taskID = nil; closedMail.leadID = nil
        _ = try store.mergeMail([closedMail], activity: "Synthetic closed record")
        try store.reviewMail(closedMail.id, reviewed: true, contactID: nil, companyID: nil, leadID: closed.id)
        let closedBefore = store.workspace
        try rejects("closed lead silently reopened") { _ = try store.createMailTask(closedMail.id) }
        try expect(store.workspace == closedBefore, "closed-lead refusal changed records")
        _ = store.delete(store.leads.first { $0.id == lead.id }!)
        try expect(store.mail.first { $0.id == mail.id }?.leadID == nil && store.mail.first { $0.id == mail.id }?.taskID == task.id, "lead deletion left a dangling association or lost a task receipt")
        mail.leadID = nil
    }
}

/// Exercises decoded backup boundaries, including records outside the original
/// eight CRM collections. Historical references may repeat; record IDs may not.
@MainActor
private enum BackupIdentityTests {
    static func run() throws {
        var workspace = PersistentWorkspace()
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let company = Company()
        let profile = GTMProfile(name: "Synthetic offer", criteria: ["Sector", "Size", "Area", "Need"], createdAt: now)
        var lead = Lead(); lead.history = [FollowUpEvent(date: "2026-11-07", message: "Synthetic history")]
        var audit = BilingualAudit(); audit.name = "Synthetic audit"; audit.transcripts = [BAEATranscript()]
        workspace.contacts = [Contact()]; workspace.companies = [company]
        workspace.opportunities = [Opportunity()]; workspace.tasks = [CRMTask()]; workspace.notes = [CRMNote()]
        workspace.leads = [lead]; workspace.signals = [Signal()]; workspace.audits = [audit]
        workspace.activity = [ActivityEvent(kind: "fixture", message: "Synthetic event")]
        workspace.syncJobs = [SyncJob(target: .pharos)]
        workspace.exposureFindings = [ExposureFinding(lens: "fixture", severity: .warning, title: "Synthetic finding", detail: "Fixture")]
        workspace.controlWard.mail = try MailMetadataImport.decode(ControlWardTests.metadata())
        workspace.controlWard.projectLinks = [RecordProjectLink(recordKey: "companies:\(company.id)", register: "https://example.test", projectID: "fixture", projectTitle: "Synthetic project")]
        workspace.controlWard.captures = [ProjectCaptureReceipt(recordKey: "companies:\(company.id)", register: "https://example.test", itemID: "fixture")]
        workspace.accountIntelligence.profiles = [profile]
        workspace.accountIntelligence.assessments = [GTMFitAssessment(companyID: company.id, profileID: profile.id, evidence: Array(repeating: GTMFitEvidence(), count: 4), assessedAt: now)]
        let event = GTMEvent(profileID: profile.id, source: "fixture", sourceEventID: "event", sourceAccountID: "account", accountName: "Synthetic", actionKey: "action", candidateCompanyID: company.id, domain: "example.test", kind: .handRaise, occurredAt: now, receivedAt: now, reference: "Synthetic evidence", isBotOrInternal: false)
        workspace.accountIntelligence.events = [event]
        workspace.accountIntelligence.observations = [GTMObservation(companyID: company.id, profileID: profile.id, source: "fixture", startsAt: now, throughAt: now, reference: "Synthetic window")]
        workspace.accountIntelligence.snapshots = [AccountScoring.evaluate(company: company, profile: profile, workspace: workspace, now: now)]
        // Two reviews of one event are a valid journal, not duplicate records.
        workspace.accountIntelligence.reviews = [GTMEventReview(eventID: event.id, companyID: company.id, reason: "First review", reviewedAt: now), GTMEventReview(eventID: event.id, companyID: company.id, reason: "Later review", reviewedAt: now.addingTimeInterval(1))]
        let encoded = try JSONEncoder().encode(ControlWardBackup(workspace: workspace))
        let original = try JSONSerialization.jsonObject(with: encoded)
        let paths = [
            ["contacts"], ["companies"], ["opportunities"], ["tasks"], ["notes"], ["leads"], ["signals"],
            ["audits"], ["automationRules"], ["activity"], ["syncJobs"], ["exposureFindings"], ["savedViews"],
            ["controlWard", "mail"], ["controlWard", "projectLinks"], ["controlWard", "captures"],
            ["accountIntelligence", "profiles"], ["accountIntelligence", "assessments"], ["accountIntelligence", "events"],
            ["accountIntelligence", "observations"], ["accountIntelligence", "snapshots"],
            ["leads", "0", "history"], ["audits", "0", "transcripts"]
        ]
        func replacing(_ value: Any, path: ArraySlice<String>, change: ([Any]) -> [Any]) -> Any {
            guard let key = path.first else { return change(value as! [Any]) }
            if let index = Int(key) {
                var array = value as! [Any]; array[index] = replacing(array[index], path: path.dropFirst(), change: change); return array
            }
            var object = value as! [String: Any]; object[key] = replacing(object[key]!, path: path.dropFirst(), change: change); return object
        }
        func modified(_ path: [String], change: ([Any]) -> [Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: replacing(original, path: (["workspace"] + path)[...], change: change))
        }
        func refuses(_ data: Data) -> Bool {
            do { _ = try AppStore.readControlWardBackup(data); return false } catch { return true }
        }
        var checks = 0, failures: [String] = []
        func check(_ passed: Bool, _ name: String) {
            checks += 1
            if passed { print("  PASS backup: \(name)") }
            else { failures.append(name); print("  FAIL backup: \(name)") }
        }
        check(try AppStore.readControlWardBackup(encoded).workspace == workspace, "valid complete records and repeated review references round-trip")
        for path in paths {
            check(refuses(try modified(path) { $0 + [$0[0]] }), "refuse duplicate \(path.joined(separator: ".")) identities")
        }
        for path in [["contacts"], ["companies"], ["opportunities"], ["tasks"], ["notes"], ["leads"], ["signals"], ["controlWard", "mail"]] {
            let oversized = try modified(path) { values in
                (0...10_000).map { _ -> Any in var row = values[0] as! [String: Any]; row["id"] = UUID().uuidString; return row }
            }
            check(refuses(oversized), "retain 10000-record cap for \(path.joined(separator: "."))")
        }
        // Do not introduce a new history limit that rejects existing valid backups.
        let longHistory = try modified(["activity"]) { values in
            (0...10_000).map { _ -> Any in var row = values[0] as! [String: Any]; row["id"] = UUID().uuidString; return row }
        }
        check(!refuses(longHistory), "unique activity history beyond10000 remains readable within20MB")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-refusal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore())
        store.createWorkspace(name: "Keep this synthetic workspace", industry: "Consulting")
        let before = store.workspace, durable = try Data(contentsOf: store.storageURL)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        var refused = false
        do { try store.restoreControlWardBackup(modified(["audits"]) { $0 + [$0[0]] }, confirmed: true) } catch { refused = true }
        let afterBytes = try Data(contentsOf: store.storageURL)
        let afterFiles = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        check(refused && store.workspace == before && afterBytes == durable && afterFiles == files, "malformed confirmed restore changes no memory, bytes or rollback files")
        try store.restoreControlWardBackup(encoded, confirmed: true)
        let reopened = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
        check(reopened.audits == workspace.audits && reopened.gtm.reviews == workspace.accountIntelligence.reviews, "valid retry restores audits and review history through restart")
        try store.commitWorkspace { next in next.audits.append(next.audits[0]) }
        let existingExport = root.appendingPathComponent("existing-export.json")
        let untouched = Data("Existing private backup must stay".utf8)
        try SecureFiles.writePrivate(untouched, to: existingExport)
        let newExport = root.appendingPathComponent("new-export.json")
        var exportRefusals = 0
        for target in [existingExport, newExport] {
            do { try store.exportControlWardBackup(to: target) } catch { exportRefusals += 1 }
        }
        let retainedExport = try Data(contentsOf: existingExport)
        check(exportRefusals == 2 && retainedExport == untouched && !FileManager.default.fileExists(atPath: newExport.path), "invalid export preserves an existing backup and creates no new file")
        print("Backup identity tests: \(checks - failures.count)/\(checks) passed")
        if !failures.isEmpty { throw SmokeTestFailure.failed("Backup identity validation: \(failures.count) failed") }
    }
}
