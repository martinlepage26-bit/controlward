import Foundation

@MainActor enum ReleaseReviewTests {
    static func run() async -> Bool {
        do {
            try expect(try StorageLocation.parseReviewID(nil) == nil, "normal launch became a review")
            let id = UUID()
            try expect(try StorageLocation.parseReviewID(id.uuidString.lowercased()) == id, "valid v4 ID refused")
            for raw in ["", "../workspace", "not-a-uuid", "00000000-0000-0000-0000-000000000000"] {
                var refused = false
                do { _ = try StorageLocation.parseReviewID(raw) } catch { refused = true }
                try expect(refused, "invalid review ID accepted")
            }
            print("PASS Release review: explicit v4 launch ID, invalid IDs refused")
            try await isolation()
            print("PASS Release review: injected accounts, provider transport and notifications stay untouched")
            print("Release review tests: 2/2 passed")
            return true
        } catch { print("FAIL Release review: \(error)"); return false }
    }
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw SmokeTestFailure.failed(message) }
    }
    final class Tripwire: SecretStore, MailTokenStore, HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        private func hit() { lock.withLock { count += 1 } }
        func read(_ target: SyncTarget) throws -> String? { hit(); return nil }
        func write(_ value: String, for target: SyncTarget) throws { hit() }
        func delete(_ target: SyncTarget) throws { hit() }
        func exists(_ target: SyncTarget) -> Bool { hit(); return true }
        func read(_ email: String) throws -> String? { hit(); return nil }
        func write(_ value: String, for email: String) throws { hit() }
        func delete(_ email: String) throws { hit() }
        func exists(_ email: String) -> Bool { hit(); return true }
        func send(_ request: URLRequest) async throws -> HTTPResponse { hit(); throw MailIntakeError.notConnected }
    }
    static func isolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("controlward-release-review-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let tripwire = Tripwire()
        let center = ReminderTests.FakeCenter()
        let reminder = ReminderTests.sample()
        center.pending[reminder.id] = reminder
        let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"), secrets: tripwire,
            transport: tripwire, reminderCenter: center, reviewMode: true)
        let mail = MailIntakeController(tokens: tripwire, transport: tripwire, accessMode: .live, reviewMode: true)
        try expect(store.isReviewMode && store.savedKeys.isEmpty && !mail.anyConnected, "review observed accounts")
        try expect(store.secrets is InMemorySecretStore && mail.accessMode == .isolated, "live account store selected")
        try expect(store.createWorkspace(name: "Review", industry: "Consulting"), "review workspace did not save")
        let task = CRMTask(title: "Synthetic review", dueDate: "2030-01-01")
        try expect(store.add(task), "local CRM write failed")
        _ = await store.scheduleDueFollowUpReminders()
        var opened = false
        await mail.connect(.personalGmail, store: store) { _, _ in opened = true; throw MailIntakeError.cancelled }
        await mail.refreshAll(store: store)
        mail.startPeriodic(store: store)
        for transport in [store.transport, mail.transport] {
            do { _ = try await transport.send(URLRequest(url: URL(string: "https://example.test")!)) }
            catch MailIntakeError.notConnected { continue }
            throw SmokeTestFailure.failed("review request was not rejected")
        }
        try expect(tripwire.calls == 0 && !opened, "review accessed injected accounts or transport")
        try expect(center.pending[reminder.id] == reminder && center.requestCalls == 0, "review touched notifications")
        let reloaded = AppStore(storageURL: store.storageURL, secrets: tripwire, reviewMode: true)
        try expect(reloaded.tasks == [task] && tripwire.calls == 0, "review record lost after reload")
    }
}
