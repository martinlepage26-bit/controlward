import Foundation

@MainActor
enum RecordDeletionTests {
    static func fixture() -> PersistentWorkspace {
        var w = PersistentWorkspace()
        let company = Company(name: "Synthetic Company", domain: "company.example.test")
        var lead = Lead.blank(); lead.name = "Synthetic Person"; lead.companyID = company.id
        lead.email = "fixture@company.example.test"; lead.company = company.name; lead.sourceID = "leadgen:synthetic-delete"
        lead.quoteAmount = 1200; lead.nextFollowUp = "2030-01-10"
        let contact = Contact(firstName: "Synthetic", lastName: "Person", companyID: company.id, leadID: lead.id)
        lead.contactID = contact.id
        let opportunity = Opportunity(name: "Synthetic deal", amount: 1200, contactID: contact.id, companyID: company.id, leadID: lead.id)
        let task = CRMTask(title: "Follow up: Synthetic Person", dueDate: lead.nextFollowUp, reminderAt: "2030-01-10T14:00:00Z", contactID: contact.id, companyID: company.id, opportunityID: opportunity.id, leadID: lead.id)
        lead.followUpTaskID = task.id
        let note = CRMNote(title: "Synthetic context", body: "Retain this text", contactID: contact.id, companyID: company.id, opportunityID: opportunity.id)
        var signal = Signal(); signal.title = "Synthetic source"; signal.evidence = "Synthetic evidence"
        signal.leadID = lead.id; signal.contactID = contact.id; signal.companyID = company.id
        var audit = BilingualAudit(); audit.name = "Synthetic Lantern"; audit.contactID = contact.id; audit.companyID = company.id; audit.leadID = lead.id
        var otherLead = Lead.blank(); otherLead.name = "Unrelated"; otherLead.nextFollowUp = nil
        w.leads = [lead, otherLead]; w.contacts = [contact, Contact(firstName: "Unrelated")]
        w.companies = [company, Company(name: "Unrelated")]; w.opportunities = [opportunity, Opportunity(name: "Unrelated")]
        w.tasks = [task, CRMTask(title: "Unrelated")]; w.notes = [note, CRMNote(title: "Unrelated")]
        w.signals = [signal]; w.audits = [audit]
        w.controlWard.mail = [MailMetadata(sourceID: "synthetic-delete-mail", subject: "Synthetic fixture", sender: "fixture@example.test", recipient: "owner@example.test", receivedAt: "2026-11-06T09:00:00Z", provider: "synthetic", accountID: "synthetic", synthetic: true, contactID: contact.id, companyID: company.id, taskID: task.id)]
        w.controlWard.remediationTasks = [UUID(): task.id]
        w.accountIntelligence.taskLinks = [GTMTaskLink(companyID: company.id, profileID: UUID(), taskID: task.id, snapshotID: UUID(), createdAt: .now)]
        for (kind, id) in [("contacts", contact.id), ("companies", company.id), ("opportunities", opportunity.id), ("tasks", task.id), ("notes", note.id), ("leads", lead.id)] {
            let key = "\(kind):\(id.uuidString.lowercased())"
            w.controlWard.projectLinks.append(RecordProjectLink(recordKey: key, register: "https://register.example.test", projectID: "synthetic-project", projectTitle: "Synthetic register"))
            w.controlWard.captures.append(ProjectCaptureReceipt(recordKey: key, register: "https://register.example.test", itemID: "synthetic-item"))
        }
        return w
    }

    static func withStore(_ action: (AppStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("controlward-delete-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(), reviewMode: true)
        try store.commitWorkspace { $0 = fixture() }
        try action(store)
    }

    static func run() -> Bool {
        let expect = PortableCheck.expect
        var passed = 0
        let cases: [(String, () throws -> Void)] = [
            ("Contact deletion clears only live contact links and preserves related content", {
                try withStore { s in
                    let before = s.workspace; let contact = s.contacts[0]
                    try expect(s.delete(contact), "delete saved")
                    let w = s.workspace
                    try expect(w.contacts == [before.contacts[1]] && w.leads.count == 2 && w.tasks.count == 2 && w.notes.count == 2, "other records retained")
                    try expect(w.leads[0].contactID == nil && w.tasks[0].contactID == nil && w.notes[0].contactID == nil && w.opportunities[0].contactID == nil && w.audits[0].contactID == nil && w.signals[0].contactID == nil && w.controlWard.mail[0].contactID == nil, "all live contact links cleared")
                    try expect(w.leads[0].email == before.leads[0].email && w.notes[0].body == before.notes[0].body && w.leads[0].companyID == before.leads[0].companyID, "independent values unchanged")
                    try expect(w.controlWard.captures == before.controlWard.captures && w.controlWard.projectLinks.count == before.controlWard.projectLinks.count - 1, "historical captures retained; deleted record unlinked")
                }
            }),
            ("Company deletion unlinks people and work without erasing account evidence history", {
                try withStore { s in
                    let before = s.workspace
                    try expect(s.delete(s.companies[0]), "company deleted")
                    let w = s.workspace
                    try expect(w.companies == [before.companies[1]] && w.contacts[0].companyID == nil && w.leads[0].companyID == nil && w.opportunities[0].companyID == nil && w.tasks[0].companyID == nil && w.notes[0].companyID == nil && w.signals[0].companyID == nil && w.audits[0].companyID == nil && w.controlWard.mail[0].companyID == nil, "live company links cleared")
                    try expect(w.leads[0].company == before.leads[0].company && w.accountIntelligence == before.accountIntelligence && w.controlWard.captures == before.controlWard.captures, "independent text and evidence journal retained")
                }
            }),
            ("Opportunity deletion retains its lead, task and note, clearing only opportunity links", {
                try withStore { s in
                    let before = s.workspace
                    try expect(s.delete(s.opportunities[0]), "opportunity deleted")
                    try expect(s.opportunities == [before.opportunities[1]] && s.leads == before.leads && s.tasks[0].opportunityID == nil && s.notes[0].opportunityID == nil, "relations unlinked without cascading")
                }
            }),
            ("Next-action deletion clears follow-up, cancels its reminder and retains task receipts", {
                try withStore { s in
                    let before = s.workspace; let task = s.tasks[0]
                    try expect(s.delete(task), "task deleted")
                    try expect(s.leads[0].followUpTaskID == nil && s.leads[0].nextFollowUp == nil, "lead next action cleared")
                    try expect(LeadWorkflow.reminders(in: s.workspace).isEmpty, "no replacement lead reminder")
                    try expect(s.workspace.controlWard.mail[0].taskID == task.id && s.workspace.controlWard.remediationTasks == before.controlWard.remediationTasks && s.gtm.taskLinks == before.accountIntelligence.taskLinks, "receipts not erased")
                    do { _ = try s.createMailTask(s.mail[0].id); throw PortableCheckFailure(description: "deleted mail task recreated") }
                    catch is ControlWardError { }
                    let count = s.tasks.count; _ = s.runAutomations()
                    try expect(s.tasks.count == count, "automation does not recreate deleted next action")
                }
            }),
            ("Deleting a legacy next-action task also prevents a fallback lead reminder", {
                try withStore { s in
                    try s.commitWorkspace { w in w.leads[0].followUpTaskID = nil; w.tasks[0].title = "Follow up with \(w.leads[0].name)" }
                    try expect(s.delete(s.tasks[0]), "legacy task deleted")
                    try expect(s.leads[0].nextFollowUp == nil && LeadWorkflow.reminders(in: s.workspace).isEmpty, "no legacy fallback resurrection")
                }
            }),
            ("Deleting an ordinary linked task does not clear a different next action", {
                try withStore { s in
                    try s.commitWorkspace { w in w.tasks[1].leadID = w.leads[0].id }
                    let lead = s.leads[0]
                    try expect(s.delete(s.tasks[1]) && s.leads[0] == lead, "unrelated task removal preserves lead")
                }
            }),
            ("Note deletion preserves its relationships and other notes", {
                try withStore { s in
                    let before = s.workspace
                    try expect(s.delete(s.notes[0]), "note deleted")
                    try expect(s.notes == [before.notes[1]] && s.contacts == before.contacts && s.companies == before.companies && s.opportunities == before.opportunities, "no cascade")
                }
            }),
            ("Lead deletion clears live links, closes next action and remembers upstream dismissal", {
                try withStore { s in
                    let before = s.workspace
                    try expect(s.delete(s.leads[0]), "lead deleted")
                    try expect(s.leads == [before.leads[1]] && s.contacts[0].leadID == nil && s.opportunities[0].leadID == nil && s.tasks[0].leadID == nil && s.signals[0].leadID == nil && s.audits[0].leadID == nil, "live lead links cleared")
                    try expect(s.tasks[0].status == .done && s.tasks[0].reminderAt == nil && s.workspace.dismissedLeadSources.contains("leadgen:synthetic-delete"), "no follow-up or upstream resurrection")
                }
            }),
            ("Deletion backup is private, complete and restorable through the native recovery path", {
                try withStore { s in
                    try s.recordDiscoveryCandidates(WebsiteResearchQueue.parse("Unreviewed fixture | https://unreviewed.example.test"))
                    try expect(s.suppressionList.record("excluded@example.test", at: .now, via: "synthetic unsubscribe"), "exclusion saved")
                    let before = s.workspace
                    try expect(s.delete(s.contacts[0]), "record deleted")
                    guard let backup = s.lastDeletionBackup else { throw PortableCheckFailure(description: "missing deletion backup") }
                    let data = try Data(contentsOf: backup); let envelope = try AppStore.readControlWardBackup(data)
                    try expect(envelope.workspace.contacts == before.contacts && envelope.workspace.websiteResearch == before.websiteResearch && envelope.workspace.restoredSuppressionEntries.contains { $0.address == "excluded@example.test" }, "backup includes research and exclusions")
                    try expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600 && (try FileManager.default.attributesOfItem(atPath: backup.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700, "private file and directory")
                    let reopened = AppStore(storageURL: s.storageURL, secrets: InMemorySecretStore(), reviewMode: true)
                    try expect(reopened.contacts == s.contacts && reopened.leads == s.leads, "deletion persists")
                    try reopened.restoreControlWardBackup(data, confirmed: true)
                    try expect(reopened.contacts == before.contacts && reopened.leads == before.leads && reopened.tasks == before.tasks && reopened.notes == before.notes && reopened.suppressionList.contains("excluded@example.test"), "ordinary restore recovers related records and policy")
                }
            }),
            ("Missing target is refused before backup or mutation", {
                try withStore { s in
                    let before = s.workspace
                    try expect(!s.delete(Contact(firstName: "Missing")) && s.workspace == before, "stale editor cannot mutate")
                    try expect(!FileManager.default.fileExists(atPath: s.deletionRecoveryDirectory.path), "no spurious backup")
                }
            }),
            ("Backup failure and later commit failure preserve records; retry writes a new recovery copy", {
                try withStore { s in
                    let fm = FileManager.default; let before = s.workspace
                    try Data("backup blocker".utf8).write(to: s.deletionRecoveryDirectory)
                    try expect(!s.delete(s.contacts[0]) && s.workspace == before && s.lastDeletionBackup == nil, "failed backup leaves record")
                    try fm.removeItem(at: s.deletionRecoveryDirectory)
                    let retained = s.storageURL.deletingLastPathComponent().appendingPathComponent("retained.json")
                    try fm.moveItem(at: s.storageURL, to: retained); try fm.createDirectory(at: s.storageURL, withIntermediateDirectories: true)
                    try expect(!s.delete(s.contacts[0]) && s.workspace == before && s.lastDeletionBackup == nil, "failed commit not published")
                    let first = try fm.contentsOfDirectory(at: s.deletionRecoveryDirectory, includingPropertiesForKeys: nil)
                    try expect(first.count == 1 && AppStore.readControlWardBackup(Data(contentsOf: first[0])).workspace.contacts == before.contacts, "completed rollback retained after failure")
                    try fm.removeItem(at: s.storageURL); try fm.moveItem(at: retained, to: s.storageURL)
                    try expect(s.delete(s.contacts[0]) && s.contacts.count == 1, "retry succeeds")
                    try expect(try fm.contentsOfDirectory(at: s.deletionRecoveryDirectory, includingPropertiesForKeys: nil).count == 2, "recovery copies never overwritten")
                }
            })
        ]
        for (name, body) in cases {
            do { try body(); passed += 1; print("  PASS \(name)") }
            catch { print("  FAIL \(name): \(error)") }
        }
        print("Record deletion tests: \(passed)/\(cases.count) passed")
        return passed == cases.count
    }
}
