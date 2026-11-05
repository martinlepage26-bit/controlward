import Foundation

@MainActor enum LeadGenFileTests {
    static func run() -> Bool {
        let cases: [(String, () throws -> Void)] = [
            ("replay and renamed exports stay deduplicated after reload", replay),
            ("an existing lead keeps owner edits and imported scores stay attributed", preserveOwner),
            ("legacy exports without IDs deduplicate by normalized identity", noEventID),
            ("legacy import evidence prevents another copy", legacy),
            ("failed storage or ambiguous identity commits no part of the batch", atomicFailure),
        ]
        var failures = 0
        for (name, test) in cases {
            do { try test(); print("PASS LeadGen file: \(name)") }
            catch { failures += 1; print("FAIL LeadGen file: \(name): \(error)") }
        }
        print("LeadGen file import tests: \(cases.count - failures)/\(cases.count) passed")
        return failures == 0
    }

    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw SmokeTestFailure.failed(message) }
    }
    private static func event(_ id: String? = "evt-file-1", email: String = "person@example.test", score: Int = 80) -> [String: Any] {
        var result: [String: Any] = ["raw_identity": ["first_name": "Camille", "last_name": "Example", "email": email, "company_name_raw": "Synthetic Studio"], "fit_score": score]
        if let id { result["event_id"] = id }
        return result
    }
    private static func withStore(_ body: (AppStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("controlward-leadgen-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(AppStore(storageURL: root.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore()), root)
    }
    private static func file(_ events: [[String: Any]], _ root: URL, name: String = "leads.json") throws -> URL {
        let url = root.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: events).write(to: url)
        return url
    }
    private static func replay() throws {
        try withStore { store, root in
            let url = try file([event(), event()], root)
            try expect(try store.importLeadGenJSON(from: url) == 1, "same batch duplicated an event")
            let reloaded = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
            try expect(try reloaded.importLeadGenJSON(from: file([event()], root, name: "renamed.json")) == 0, "relaunch or rename bypassed deduplication")
            try expect(reloaded.leads.count == 1 && reloaded.signals.count == 1 && reloaded.activity.count == 1, "replay changed record counts")
            let lead = reloaded.leads[0]
            try expect(!LeadWorkflow.origin(of: lead).isInbound, "file import invented inbound contact")
            try expect(LeadWorkflow.draft(for: lead, in: reloaded.workspace, business: reloaded.business).subject == "Introduction", "file import generated a prior-contact subject")
        }
    }
    private static func preserveOwner() throws {
        try withStore { store, root in
            var lead = Lead.blank(); lead.name = "Owner's chosen name"; lead.email = "PERSON@example.test"
            lead.notes = "Private owner note"; lead.quoteAmount = 1250; lead.status = .won
            store.add(lead)
            try expect(try store.importLeadGenJSON(from: file([event()], root)) == 1, "new event did not import")
            try expect(store.leads == [lead], "import overwrote the owner's lead")
            try expect(store.signals[0].leadID == lead.id && store.signals[0].source == .imported, "event was not linked or attributed")
            try expect(store.signals[0].evidence.contains("supplied in this file") && !store.activity.map(\.message).joined().contains(lead.notes), "evidence attribution or private-note boundary failed")
        }
    }
    private static func noEventID() throws {
        try withStore { store, root in
            _ = try store.importLeadGenJSON(from: file([event(nil)], root))
            try expect(try store.importLeadGenJSON(from: file([event(nil, email: " PERSON@EXAMPLE.TEST ", score: 99)], root, name: "different-name.json")) == 0, "no-ID identity changed with case, filename or score")
            try expect(store.leads.count == 1 && store.signals.count == 1, "no-ID duplicate records")
        }
    }
    private static func legacy() throws {
        try withStore { store, root in
            var lead = Lead.blank(); lead.name = "Camille Example"; lead.email = "person@example.test"; store.add(lead)
            var signal = Signal(); signal.title = "LeadGen: Camille Example"; signal.leadID = lead.id
            signal.evidence = "Imported from old.json. Event ID: evt-file-1."; store.add(signal)
            try expect(try store.importLeadGenJSON(from: file([event()], root)) == 0, "legacy event imported again")
            try expect(store.leads.count == 1 && store.signals.count == 1, "legacy retry changed records")
        }
    }
    private static func atomicFailure() throws {
        try withStore { store, root in
            let blocker = root.appendingPathComponent("not-a-directory"); try Data("blocked".utf8).write(to: blocker)
            let blocked = AppStore(storageURL: blocker.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore())
            let url = try file([event()], root)
            var refused = false
            do { _ = try blocked.importLeadGenJSON(from: url) } catch { refused = true }
            try expect(refused && blocked.leads.isEmpty && blocked.signals.isEmpty && blocked.activity.isEmpty, "failed save published records")
            for name in ["First", "Second"] { var lead = Lead.blank(); lead.name = name; lead.email = "person@example.test"; store.add(lead) }
            refused = false
            do { _ = try store.importLeadGenJSON(from: file([event("new", email: "new@example.test"), event()], root)) } catch { refused = true }
            try expect(refused && store.leads.count == 2 && store.signals.isEmpty, "ambiguous second row left a partial batch")
            try expect(AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore()).leads.count == 2, "partial batch reached disk")
        }
    }
}
