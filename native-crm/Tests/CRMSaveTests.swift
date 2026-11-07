import Foundation

@MainActor enum CRMSaveTests {
    static func run() -> Bool {
        let cases: [(String, (AppStore) -> Void)] = [
            ("create lead", { s in var l = Lead.blank(); l.name = "New"; s.add(l) }),
            ("create contact", { $0.add(Contact(firstName: "New")) }),
            ("edit contact", { s in var c = s.contacts[0]; c.firstName = "Changed"; s.update(c) }),
            ("delete company", { $0.delete($0.companies[0]) }),
            ("create company", { $0.add(Company(name: "New")) }),
            ("create opportunity", { $0.add(Opportunity(name: "New")) }),
            ("close opportunity and linked follow-up", { s in var o = s.opportunities[0]; o.stage = .won; s.update(o) }),
            ("reschedule task and linked lead", { s in var t = s.tasks[0]; t.dueDate = "2030-01-01"; s.update(t) }),
            ("delete task", { $0.delete($0.tasks[0]) }),
            ("create note", { $0.add(CRMNote(title: "New")) }),
            ("create signal", { s in var v = Signal(); v.title = "New"; s.add(v) }),
            ("create audit", { s in var v = BilingualAudit(); v.name = "New"; s.add(v) }),
            ("save view", { $0.add(SavedView(name: "New", objectName: "Companies", filter: "all", search: "")) }),
            ("edit lead and linked task", { s in var l = s.leads[0]; l.nextFollowUp = "2030-01-02"; s.update(l) }),
            ("delete lead and close task", { $0.delete($0.leads[0]) }),
            ("link lead and signal", { s in s.linkLead(s.leads[0].id, companyID: s.companies[0].id, contactID: s.contacts[0].id) }),
            ("save business", { s in var b = s.business; b.name = "Changed"; s.saveBusiness(b) }),
            ("local security scan", { _ = $0.runLocalExposureScan() }),
            ("resolve security finding", { $0.resolve($0.exposureFindings[0]) }),
            ("mark security review", { $0.markSecurityReviewed() }),
            ("log follow-up", { s in var l = s.leads[0]; s.markMessageSent(on: &l, message: "Synthetic message") }),
        ]
        var failures = 0
        for (name, action) in cases {
            do { try failedSaveAndRetry(action); print("PASS CRM save: \(name)") }
            catch { failures += 1; print("FAIL CRM save: \(name): \(error)") }
        }
        print("CRM save tests: \(cases.count - failures)/\(cases.count) passed")
        return failures == 0
    }

    private static func bytes(_ workspace: PersistentWorkspace) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(workspace)
    }

    /// Move only a test directory aside and replace it with a file. This induces a
    /// real write failure without relying on permissions or touching owner data.
    private static func failedSaveAndRetry(_ action: (AppStore) -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("controlward-crm-save-\(UUID())")
        let data = root.appendingPathComponent("data")
        let saved = root.appendingPathComponent("saved")
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = AppStore(storageURL: data.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore())
        try store.commitWorkspace { w in
            var lead = Lead.blank(); lead.name = "Synthetic"; lead.nextFollowUp = "2029-01-01"
            let task = CRMTask(title: "Follow up", dueDate: lead.nextFollowUp, leadID: lead.id)
            lead.followUpTaskID = task.id
            w.leads = [lead]; w.tasks = [task]
            w.contacts = [Contact(firstName: "Original")]; w.companies = [Company(name: "Original")]
            w.opportunities = [Opportunity(name: "Original", leadID: lead.id)]
            w.exposureFindings = [ExposureFinding(lens: "Identity Exposure", severity: .warning, title: "Existing review", detail: "Synthetic", recordID: lead.id)]
            var signal = Signal(); signal.leadID = lead.id; w.signals = [signal]
        }
        let before = try bytes(store.workspace)
        let disk = try Data(contentsOf: store.storageURL)
        try fm.moveItem(at: data, to: saved)
        try Data("write blocker".utf8).write(to: data)
        action(store)
        guard try bytes(store.workspace) == before else { throw SmokeTestFailure.failed("failed write changed the visible workspace") }
        guard try Data(contentsOf: saved.appendingPathComponent("workspace.json")) == disk else { throw SmokeTestFailure.failed("failed write changed durable records") }
        guard store.notice?.contains("not saved") == true else { throw SmokeTestFailure.failed("save failure was not explained") }
        try fm.removeItem(at: data); try fm.moveItem(at: saved, to: data)
        action(store)
        guard try bytes(store.workspace) != before else { throw SmokeTestFailure.failed("retry did not apply the edit") }
        let reloaded = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
        guard try bytes(reloaded.workspace) == bytes(store.workspace) else { throw SmokeTestFailure.failed("retry did not survive reload") }
    }
}
