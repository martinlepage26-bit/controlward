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
            print("ControlWard workflow tests: \(count) assertions passed")
            return true
        } catch { print("FAIL ControlWard workflow tests: \(error)"); return false }
    }
}
