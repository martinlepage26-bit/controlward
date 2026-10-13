import Foundation

@MainActor
enum KairosTests {
    static func run() async -> Bool {
        let tests: [(String, () async throws -> Void)] = [
            ("Kairos: answered-only update persists and repeated import is unchanged", answeredOnlyUpdate),
            ("Kairos: answer does not overwrite local workflow status", preservesLocalStatus),
            ("Kairos: older inbox snapshot cannot change lead status or message", ignoresOlderSnapshot),
            ("Kairos: newer message imports while preserving local status", newerMessage),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS  \(name)") }
            catch { failures += 1; print("FAIL  \(name): \(error)") }
        }
        print("Kairos tests: \(tests.count - failures)/\(tests.count) passed")
        return failures == 0
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeTestFailure.failed(message) }
    }

    nonisolated private static let timestamp = "2026-10-13T10:00:00Z"

    private static func conversation(status: String = "open", at: String = timestamp,
                                     message: String = "Please send a quote") -> [String: Any] {
        ["id": "synthetic-conversation", "author_handle": "Synthetic Lead", "intent": "lead",
         "priority": 1, "status": status, "last_message_at": at, "platform": "instagram", "latest_message": message]
    }

    private final class FakeInbox: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [Data]

        init(_ conversations: [[String: Any]]) throws {
            snapshots = try conversations.map { try JSONSerialization.data(withJSONObject: ["conversations": [$0]]) }
        }

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            try lock.withLock {
                guard request.httpMethod == "GET", request.url?.path == "/v1/inbox", !snapshots.isEmpty else {
                    throw SmokeTestFailure.failed("Unexpected Kairos request")
                }
                return HTTPResponse(status: 200, headers: [:], body: snapshots.removeFirst())
            }
        }
    }

    private static func makeStore(_ snapshots: [[String: Any]]) throws -> (AppStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("contextward-kairos-\(UUID().uuidString)")
        let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"),
                             secrets: InMemorySecretStore([.kairos: "synthetic-test-key"]), transport: try FakeInbox(snapshots))
        return (store, directory)
    }

    static func answeredOnlyUpdate() async throws {
        let answered = conversation(status: "answered", message: "Same timestamp must not replace a local message")
        let (store, directory) = try makeStore([conversation(), answered, answered])
        defer { try? FileManager.default.removeItem(at: directory) }
        try expect(await store.importKairosLeads().status == "synced", "initial import failed")
        let first = store.leads[0]
        let update = await store.importKairosLeads()
        try expect(update.status == "synced" && update.detail == "0 new, 1 updated, 0 unchanged, 0 skipped.", "status-only update not counted")
        try expect(store.leads.count == 1 && store.leads[0].id == first.id, "status update duplicated the lead")
        try expect(store.leads[0].status == .contacted, "answered lead still marked new")
        try expect(store.leads[0].lastMessage == first.lastMessage && store.leads[0].sourceUpdatedAt == timestamp, "status-only update overwrote message data")
        let reloaded = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
        try expect(reloaded.leads[0].status == .contacted, "status change was not persisted")
        let repeated = await store.importKairosLeads()
        try expect(repeated.detail == "0 new, 0 updated, 1 unchanged, 0 skipped.", "repeated answer not idempotent")
    }

    static func preservesLocalStatus() async throws {
        for status in [LeadStatus.contacted, .quoteSent, .won, .lost] {
            let (store, directory) = try makeStore([conversation(), conversation(status: "answered")])
            defer { try? FileManager.default.removeItem(at: directory) }
            _ = await store.importKairosLeads()
            var lead = store.leads[0]
            lead.status = status
            store.update(lead)
            let job = await store.importKairosLeads()
            try expect(store.leads[0].status == status, "overwrote local \(status.rawValue)")
            try expect(job.detail == "0 new, 0 updated, 1 unchanged, 0 skipped.", "unchanged local status counted as update")
        }
    }

    static func ignoresOlderSnapshot() async throws {
        let (store, directory) = try makeStore([conversation(), conversation(status: "answered", at: "2026-10-12T10:00:00Z", message: "Old message")])
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = await store.importKairosLeads()
        let first = store.leads[0]
        let job = await store.importKairosLeads()
        try expect(store.leads[0] == first, "older snapshot changed the lead")
        try expect(job.detail == "0 new, 0 updated, 1 unchanged, 0 skipped.", "older snapshot not unchanged")
    }

    static func newerMessage() async throws {
        let later = "2026-10-14T10:00:00Z"
        let (store, directory) = try makeStore([conversation(), conversation(status: "answered", at: later, message: "Updated brief")])
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = await store.importKairosLeads()
        var lead = store.leads[0]
        lead.status = .quoteSent
        store.update(lead)
        let job = await store.importKairosLeads()
        try expect(job.detail == "0 new, 1 updated, 0 unchanged, 0 skipped.", "new message not updated")
        try expect(store.leads[0].lastMessage == "Updated brief" && store.leads[0].sourceUpdatedAt == later, "new message data missing")
        try expect(store.leads[0].status == .quoteSent, "new message overwrote local status")
    }
}
