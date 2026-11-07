import Foundation

@MainActor
enum KairosTests {
    private struct ConnectedFixture: Decodable {
        let ids: [String: String]
        let workspace: String
    }

    private final class RecordingLiveTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        private var readOnly = true
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            lock.withLock {
                paths.append(request.url?.path ?? "")
                readOnly = readOnly && request.httpMethod == "GET" && request.url?.host == "127.0.0.1" && request.url?.port == 8883
            }
            return try await URLSessionTransport().send(request)
        }
        var summary: (readOnly: Bool, paths: [String]) { lock.withLock { (readOnly, paths) } }
    }

    /// Opt-in real HTTP to the pinned current KAIROS Worker, with local disposable D1 only.
    static func connected() async throws {
        let env = ProcessInfo.processInfo.environment
        let endpoint = "http://127.0.0.1:8883"
        guard env["CONTROLWARD_TEST_KAIROS"] == endpoint,
              let keyPath = env["CONTROLWARD_TEST_KAIROS_KEY_FILE"],
              let operatorPath = env["CONTROLWARD_TEST_KAIROS_OPERATOR_KEY_FILE"],
              let fixturePath = env["CONTROLWARD_TEST_KAIROS_FIXTURE"],
              let phase = env["CONTROLWARD_TEST_KAIROS_PHASE"], ["initial", "updated"].contains(phase) else {
            throw SmokeTestFailure.failed("Use bin/test-connected-kairos with its disposable local fixture")
        }
        let fixtureURL = URL(fileURLWithPath: fixturePath).standardizedFileURL
        let root = fixtureURL.deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(ConnectedFixture.self, from: Data(contentsOf: fixtureURL))
        let workspaceURL = URL(fileURLWithPath: fixture.workspace).standardizedFileURL
        guard root.lastPathComponent.hasPrefix("controlward-kairos-d1-"), fixtureURL.lastPathComponent == "fixture.json",
              workspaceURL == root.appendingPathComponent("workspace/workspace.json"),
              URL(fileURLWithPath: keyPath).deletingLastPathComponent().standardizedFileURL == root,
              URL(fileURLWithPath: operatorPath).deletingLastPathComponent().standardizedFileURL == root,
              let openID = fixture.ids["open"], let answeredID = fixture.ids["answered"] else {
            throw SmokeTestFailure.failed("Unexpected disposable KAIROS fixture paths")
        }
        let key = try String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let transport = RecordingLiveTransport()
        let secrets = InMemorySecretStore([.kairos: key])
        let store = AppStore(storageURL: workspaceURL, secrets: secrets, transport: transport, reviewMode: false)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var checked = 0
        func check(_ value: Bool, _ name: String) throws {
            try expect(value, name); checked += 1; print("PASS connected KAIROS \(phase): \(name)")
        }
        if phase == "initial" {
            store.setEndpoint(endpoint, for: .kairos)
            var wrongRejected = false
            do { try await KairosClient(endpoint: endpoint, apiKey: "kai_sk_wrong_disposable_key", transport: transport).verify() }
            catch IntegrationError.http(let status, _, _) { wrongRejected = status == 401 }
            try check(wrongRejected, "real Worker rejects an unknown key")
            let operatorKey = try String(contentsOfFile: operatorPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            var operatorRefused = false
            do { try await KairosClient(endpoint: endpoint, apiKey: operatorKey, transport: transport).verify() }
            catch IntegrationError.http(let status, _, _) { operatorRefused = status == 403 }
            try check(operatorRefused, "current Worker refuses operator API keys on the account route")
            let verified = await store.verifyConnector(.kairos)
            try check(verified, "native customer-account verification reaches the actual Worker")
            let imported = await store.importKairosLeads()
            try check(imported.status == "synced" && imported.detail == "2 new, 0 updated, 0 unchanged, 2 skipped.", "actual inbox imports two lead-intent conversations and skips ignored/non-lead entries")
            try check(Set(store.leads.compactMap(\.sourceID)) == ["kairos:\(openID)", "kairos:\(answeredID)"], "customer scope excludes the other account's lead")
            try check(store.leads.first { $0.sourceID == "kairos:\(answeredID)" }?.status == .contacted, "actual answered status maps to contacted")
            let identities = store.leads.map(\.id)
            let replay = await store.importKairosLeads()
            try check(replay.status == "synced" && replay.detail == "0 new, 0 updated, 2 unchanged, 2 skipped." && store.leads.map(\.id) == identities, "actual HTTP replay keeps local IDs and creates no duplicates")
            var lead = store.leads.first { $0.sourceID == "kairos:\(openID)" }!
            lead.status = .quoteSent; lead.notes = "Owner decision retained across connected imports"
            lead.lastMessage = "Synthetic previously logged reply"
            lead.history = [FollowUpEvent(date: "2026-11-01", message: lead.lastMessage)]
            lead.outreachDraft = "Unsent follow-up under review"
            try check(store.update(lead), "local workflow decision is durably saved")
            let directory = workspaceURL.deletingLastPathComponent(), retained = root.appendingPathComponent("retained-workspace")
            let before = try encoder.encode(store.workspace)
            try FileManager.default.moveItem(at: directory, to: retained)
            try Data("synthetic write blocker".utf8).write(to: directory)
            let failed = await store.importKairosLeads()
            try check(failed.status == "failed" && (try encoder.encode(store.workspace)) == before, "actual HTTP read with blocked storage publishes no phantom job, health or record")
            try FileManager.default.removeItem(at: directory); try FileManager.default.moveItem(at: retained, to: directory)
            let retry = await store.importKairosLeads()
            try check(retry.status == "synced" && store.leads.map(\.id) == identities, "connected retry preserves identities after a real local write failure")
            let reloaded = AppStore(storageURL: workspaceURL, secrets: secrets, transport: transport, reviewMode: false)
            try check(try encoder.encode(reloaded.workspace) == encoder.encode(store.workspace), "complete connected import survives workspace reload")
        } else {
            let before = store.leads.first { $0.sourceID == "kairos:\(openID)" }!
            let imported = await store.importKairosLeads()
            let lead = store.leads.first { $0.sourceID == "kairos:\(openID)" }!
            try check(imported.status == "synced" && imported.detail == "0 new, 1 updated, 1 unchanged, 2 skipped.", "actual D1 inbound update imports once")
            try check(lead.id == before.id && lead.sourceMessage == "Nouveau message synthétique — aucune réponse envoyée" && lead.sourceUpdatedAt == "2026-11-02T10:00:00.000Z", "new backend incoming text and timestamp preserve local identity exactly")
            try check(lead.status == .quoteSent && lead.notes == "Owner decision retained across connected imports", "new backend answer preserves the owner's workflow status and notes")
            try check(lead.lastMessage == before.lastMessage && lead.history == before.history && lead.outreachDraft == before.outreachDraft,
                      "new real-backend incoming message preserves the saved reply and sent history")
            let reloaded = AppStore(storageURL: workspaceURL, secrets: secrets, transport: transport, reviewMode: false)
            try check(try encoder.encode(reloaded.workspace) == encoder.encode(store.workspace), "updated real-backend data survives reload")
        }
        let requestSummary = transport.summary
        try check(requestSummary.readOnly && requestSummary.paths.allSatisfy { ["/v1/me", "/v1/inbox"].contains($0) }, "native client used only the two allowed GET routes on the disposable service")
        let data = try String(contentsOf: workspaceURL, encoding: .utf8)
        try check(!data.contains(key), "test key is absent from the durable workspace and diagnostics")
        print("Connected KAIROS \(phase): \(checked) assertions; \(requestSummary.paths.count) GET requests to the real Worker.")
    }

    static func run() async -> Bool {
        let tests: [(String, () async throws -> Void)] = [
            ("Kairos: answered-only update persists and repeated import is unchanged", answeredOnlyUpdate),
            ("Kairos: answer does not overwrite local workflow status", preservesLocalStatus),
            ("Kairos: older inbox snapshot cannot change lead status or message", ignoresOlderSnapshot),
            ("Kairos: newer message imports while preserving local status", newerMessage),
            ("Kairos: a blocked save publishes no new or updated lead; retry survives reload", failedSaveAndRetry),
            ("Kairos: a newer incoming message preserves the saved reply and sent history", preservesOutreach),
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

    static func failedSaveAndRetry() async throws {
        let fm = FileManager.default
        for existing in [false, true] {
            let changed = conversation(status: "answered", at: "2026-10-14T10:00:00Z", message: "New synthetic inbound text")
            let snapshots = existing ? [conversation(), changed, changed] : [changed, changed]
            let (store, directory) = try makeStore(snapshots)
            let retained = directory.appendingPathExtension("retained")
            defer { try? fm.removeItem(at: directory); try? fm.removeItem(at: retained) }
            _ = store.saveBusiness(BusinessProfile())
            if existing {
                _ = await store.importKairosLeads()
                var lead = store.leads[0]; lead.status = .quoteSent; lead.notes = "Owner decision retained"; store.update(lead)
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let before = try encoder.encode(store.workspace), disk = try Data(contentsOf: store.storageURL)
            try fm.moveItem(at: directory, to: retained)
            try Data("synthetic storage blocker".utf8).write(to: directory)
            let failed = await store.importKairosLeads()
            try expect(failed.status == "failed", "blocked write reported success")
            try expect(try encoder.encode(store.workspace) == before, "failed import published phantom data or health")
            try expect(try Data(contentsOf: retained.appendingPathComponent("workspace.json")) == disk, "failed import changed durable data")
            try expect(store.saveFailure != nil, "storage failure was not surfaced")
            try fm.removeItem(at: directory); try fm.moveItem(at: retained, to: directory)
            let retry = await store.importKairosLeads()
            try expect(retry.status == "synced" && store.leads.count == 1 && store.leads[0].sourceMessage == "New synthetic inbound text", "retry lost or duplicated the lead")
            if existing { try expect(store.leads[0].status == .quoteSent && store.leads[0].notes == "Owner decision retained", "retry overwrote owner fields") }
            let reloaded = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
            try expect(try encoder.encode(reloaded.workspace) == encoder.encode(store.workspace), "successful retry did not survive reload")
        }
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
        try expect(store.leads[0].sourceMessage == first.sourceMessage && store.leads[0].lastMessage.isEmpty && store.leads[0].service.isEmpty && store.leads[0].sourceUpdatedAt == timestamp, "status-only update overwrote incoming data or invented outgoing context")
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
        try expect(store.leads[0].sourceMessage == "Updated brief" && store.leads[0].lastMessage.isEmpty && store.leads[0].sourceUpdatedAt == later, "new incoming data missing or stored as an outgoing message")
        try expect(store.leads[0].status == .quoteSent, "new message overwrote local status")
    }

    static func preservesOutreach() async throws {
        let (store, directory) = try makeStore([conversation(), conversation(status: "answered", at: "2026-10-14T10:00:00Z", message: "A newer incoming question")])
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = await store.importKairosLeads()
        var lead = store.leads[0]
        lead.status = .quoteSent; lead.service = "AI workflow review"
        lead.lastMessage = "Synthetic previously logged reply"
        lead.history = [FollowUpEvent(date: "2026-10-13", message: lead.lastMessage)]
        lead.outreachDraft = "Unsent follow-up under review"
        store.update(lead)
        let job = await store.importKairosLeads()
        try expect(job.status == "synced", "updated incoming message was not imported")
        let current = store.leads[0]
        try expect(current.lastMessage == lead.lastMessage && current.history == lead.history && current.outreachDraft == lead.outreachDraft,
                   "a new incoming message replaced the owner's reply or sent-message context")
        try expect(current.service == lead.service && current.status == lead.status, "import replaced the owner's request or workflow status")
    }
}
