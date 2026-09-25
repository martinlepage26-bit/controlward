import Foundation

/// Lead inbox tests: pull from the PHAROS Worker, dedupe, cursor persistence, ack, and
/// hygiene (no keys or PII in activity, sync jobs, health, notices, or log lines).
/// The fake mirrors pharos-api/src/index.ts: GET /v1/leads?since=&limit=, POST /v1/leads/ack.
@MainActor
enum LeadInboxTests {
    static func run() async -> Bool {
        let tests: [(String, () async throws -> Void)] = [
            ("Lead inbox: pull creates leads with source id, acks, counts-only activity", pullCreatesAndAcks),
            ("Lead inbox: dedupe by source id, then email, then phone; no duplicates", dedupe),
            ("Lead inbox: pages through has_more and sends the persisted cursor", paging),
            ("Lead inbox: cursor persists across relaunch; not advanced when ack fails", cursorPersistence),
            ("Lead inbox: 401 surfaces on the job and leaves the cursor untouched", unauthorized),
            ("Lead inbox: no keys or PII in activity, jobs, health, notices, or logs", noKeysOrPII),
            ("Lead inbox: auto pull on open only when enabled and configured", autoPull),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS  \(name)") }
            catch { failures += 1; print("FAIL  \(name): \(error)") }
        }
        print("Lead inbox tests: \(tests.count - failures)/\(tests.count) passed")
        return failures == 0
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeTestFailure.failed(message) }
    }

    static let pharosURL = "https://pharos-contextward-api.example.test"
    static let key = "pk_inbox_\(UUID().uuidString)"

    final class FakeInbox: HTTPTransport, @unchecked Sendable {
        struct Item { var sourceID: String; var seq: Int; var event: [String: Any]; var acked = false }
        let key: String
        private let lock = NSLock()
        private var items: [Item] = []
        private var counter = 0
        private(set) var requests: [URLRequest] = []
        var failAck = false
        init(key: String) { self.key = key }

        func add(_ sourceID: String, email: String? = nil, first: String? = nil, last: String? = nil, phone: String? = nil, company: String? = nil, fit: Int = 70, intent: Int = 50) {
            lock.withLock {
                counter += 1
                var identity: [String: Any] = [:]
                identity["email"] = email; identity["first_name"] = first; identity["last_name"] = last
                identity["phone_raw"] = phone; identity["company_name_raw"] = company
                let event: [String: Any] = ["schema_version": "leadgen.event.v1", "event_id": sourceID, "captured_at": "2026-09-25T12:00:00.000Z",
                                            "raw_identity": identity, "fit_score": fit, "intent_score": intent, "composite_score": (fit * 6 + intent * 4) / 10]
                items.removeAll { $0.sourceID == sourceID }
                items.append(Item(sourceID: sourceID, seq: counter, event: event))
            }
        }

        var pending: Int { lock.withLock { items.filter { !$0.acked }.count } }
        var pullSinceValues: [String] {
            lock.withLock { requests.filter { $0.url?.path == "/v1/leads" }.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "since" }?.value } }
        }

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            lock.withLock {
                requests.append(request)
                let path = request.url?.path ?? ""
                if path == "/v1/health" { return reply(200, ["ok": true]) }
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)" else { return reply(401, ["error": "unauthorized"]) }
                if path == "/v1/auth/check" { return reply(200, ["ok": true]) }
                if path == "/v1/leads", request.httpMethod == "GET" {
                    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let since = Int(query.first { $0.name == "since" }?.value ?? "0") ?? 0
                    let limit = Int(query.first { $0.name == "limit" }?.value ?? "100") ?? 100
                    let matching = items.filter { !$0.acked && $0.seq > since }.sorted { $0.seq < $1.seq }
                    let page = Array(matching.prefix(limit))
                    return reply(200, ["schema_version": "contextward.lead-inbox.v1",
                                       "leads": page.map { ["source_id": $0.sourceID, "seq": $0.seq, "content_hash": "h\($0.seq)", "event": $0.event] },
                                       "cursor": page.last?.seq ?? since, "has_more": matching.count > limit])
                }
                if path == "/v1/leads/ack", request.httpMethod == "POST" {
                    if failAck { return reply(503, ["error": "storage_failure"]) }
                    let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                    let acks = body?["acks"] as? [[String: Any]] ?? []
                    var acked = 0
                    for entry in acks {
                        if let index = items.firstIndex(where: { $0.sourceID == entry["source_id"] as? String && $0.seq == entry["seq"] as? Int }) {
                            items[index].acked = true; acked += 1
                        }
                    }
                    return reply(200, ["acked": acked, "stale": acks.count - acked])
                }
                return reply(404, ["error": "not_found"])
            }
        }

        private func reply(_ status: Int, _ object: Any) -> HTTPResponse {
            HTTPResponse(status: status, headers: [:], body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
    }

    private static func makeStore(_ fake: FakeInbox, storageURL: URL? = nil, withKey: Bool = true) throws -> AppStore {
        let url: URL
        if let storageURL { url = storageURL } else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("contextward-inbox-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("workspace.json")
        }
        let store = AppStore(storageURL: url, secrets: InMemorySecretStore(withKey ? [.pharos: key] : [:]), transport: fake)
        if storageURL == nil { store.setEndpoint(pharosURL, for: .pharos) }
        return store
    }

    static func pullCreatesAndAcks() async throws {
        let fake = FakeInbox(key: key)
        fake.add("ident_a", email: "ana.synthetic@example.test", first: "Ana", last: "Synthetic", phone: "+1 514 555 0101", company: "Synthetic Co", fit: 90, intent: 70)
        fake.add("ident_b", email: "ben.synthetic@example.test", first: "Ben", last: "Synthetic")
        let store = try makeStore(fake)
        let job = await store.pullLeads()
        try expect(job.status == "synced", "pull failed: \(job.error ?? "")")
        try expect(store.leads.count == 2, "expected 2 leads, got \(store.leads.count)")
        let ana = store.leads.first { $0.sourceID == "leadgen:ident_a" }
        try expect(ana?.name == "Ana Synthetic" && ana?.email == "ana.synthetic@example.test" && ana?.company == "Synthetic Co", "lead fields not mapped")
        let signal = store.signals.first { $0.leadID == ana?.id }
        try expect(signal?.fitScore == 90 && signal?.intentScore == 70 && signal?.source == .imported, "signal scores not mapped")
        try expect(fake.pending == 0, "leads were not acked")
        try expect(store.workspace.leadInboxCursor == 2, "cursor not stored: \(String(describing: store.workspace.leadInboxCursor))")
        try expect(job.detail?.contains("2 new") == true, "job detail lacks counts: \(job.detail ?? "")")
        let pullActivity = store.activity.filter { $0.kind == "lead_pull" }
        try expect(pullActivity.count == 1, "expected one counts-only activity entry, got \(pullActivity.count)")
        try expect(pullActivity[0].message.contains("2 new"), "activity lacks counts: \(pullActivity[0].message)")
    }

    static func dedupe() async throws {
        let fake = FakeInbox(key: key)
        let store = try makeStore(fake)
        var byEmail = Lead.blank(); byEmail.name = "Carla Local"; byEmail.email = "CARLA@example.test"; store.add(byEmail)
        var byPhone = Lead.blank(); byPhone.name = "Dan Local"; byPhone.phone = "(514) 555-0199"; store.add(byPhone)
        fake.add("ident_c", email: "carla@example.test", first: "Carla", last: "Remote", company: "Filled Co")
        fake.add("ident_d", first: "Dan", last: "Remote", phone: "+1 514-555-0199")
        fake.add("ident_e", email: "eve@example.test", first: "Eve", last: "New")
        let first = await store.pullLeads()
        try expect(first.status == "synced", "pull failed: \(first.error ?? "")")
        try expect(store.leads.count == 3, "dedupe created duplicates: \(store.leads.count) leads")
        let carla = store.leads.first { $0.id == byEmail.id }
        try expect(carla?.sourceID == "leadgen:ident_c" && carla?.name == "Carla Local" && carla?.company == "Filled Co", "email match did not link and fill empty fields only")
        try expect(store.leads.first { $0.id == byPhone.id }?.sourceID == "leadgen:ident_d", "phone match did not link")
        try expect(first.detail?.contains("1 new") == true && first.detail?.contains("2 updated") == true, "counts wrong: \(first.detail ?? "")")
        // A later version of an already-linked lead updates it by source id, even with a new email.
        fake.add("ident_c", email: "carla.new@example.test", first: "Carla", last: "Remote", fit: 99, intent: 99)
        let second = await store.pullLeads()
        try expect(store.leads.count == 3, "source-id update created a duplicate")
        try expect(store.signals.filter { $0.leadID == byEmail.id }.count == 1, "update created a second signal")
        try expect(store.signals.first { $0.leadID == byEmail.id }?.fitScore == 99, "update did not refresh scores")
        try expect(second.detail?.contains("1 updated") == true, "second pull counts wrong: \(second.detail ?? "")")
        // Same content again is unchanged.
        fake.add("ident_c", email: "carla.new@example.test", first: "Carla", last: "Remote", fit: 99, intent: 99)
        let third = await store.pullLeads()
        try expect(third.detail?.contains("1 unchanged") == true, "unchanged not counted: \(third.detail ?? "")")
    }

    static func paging() async throws {
        let fake = FakeInbox(key: key)
        for index in 0..<250 { fake.add("ident_\(index)", email: "p\(index)@example.test", first: "P", last: "\(index)") }
        let store = try makeStore(fake)
        let job = await store.pullLeads()
        try expect(job.status == "synced" && store.leads.count == 250, "paging missed leads: \(store.leads.count)")
        try expect(fake.pullSinceValues == ["0", "100", "200"], "cursor not sent per page: \(fake.pullSinceValues)")
        try expect(fake.pending == 0, "not every page was acked")
    }

    static func cursorPersistence() async throws {
        let fake = FakeInbox(key: key)
        fake.add("ident_a", email: "a@example.test", first: "A", last: "One")
        let store = try makeStore(fake)
        fake.failAck = true
        let failed = await store.pullLeads()
        try expect(failed.status == "failed", "ack failure was not reported")
        try expect(store.workspace.leadInboxCursor == nil, "cursor advanced although ack failed")
        try expect(store.leads.count == 1, "lead applied before ack was lost")
        fake.failAck = false
        let relaunched = try makeStore(fake, storageURL: store.storageURL)
        let retry = await relaunched.pullLeads()
        try expect(retry.status == "synced" && relaunched.leads.count == 1, "retry after failed ack duplicated or failed")
        try expect(relaunched.workspace.leadInboxCursor == 1, "cursor not stored after successful ack")
        fake.add("ident_b", email: "b@example.test", first: "B", last: "Two")
        let again = try makeStore(fake, storageURL: store.storageURL)
        try expect(again.workspace.leadInboxCursor == 1, "cursor did not survive relaunch")
        _ = await again.pullLeads()
        try expect(fake.pullSinceValues.last == "1", "relaunched store did not send the persisted cursor: \(fake.pullSinceValues)")
        try expect(again.leads.count == 2 && again.workspace.leadInboxCursor == 2, "second lead not pulled after relaunch")
    }

    static func unauthorized() async throws {
        let fake = FakeInbox(key: "a-different-key")
        fake.add("ident_a", email: "a@example.test", first: "A", last: "One")
        let store = try makeStore(fake)
        let job = await store.pullLeads()
        try expect(job.status == "failed" && job.error?.contains("401") == true, "401 not surfaced: \(job.error ?? "")")
        try expect(store.workspace.leadInboxCursor == nil && store.leads.isEmpty, "failed pull changed data")
    }

    static func noKeysOrPII() async throws {
        let fake = FakeInbox(key: key)
        let pii = ["zed.private@example.test", "Zed", "Privateperson", "+1 438 555 0177", "Private Holdings"]
        fake.add("ident_z", email: pii[0], first: pii[1], last: pii[2], phone: pii[3], company: pii[4])
        let store = try makeStore(fake)
        var logLines: [String] = []
        store.syncLogSink = { logLines.append($0) }
        var notices: [String] = []
        let job = await store.pullLeads()
        if let notice = store.notice { notices.append(notice) }
        try expect(job.status == "synced" && store.leads.count == 1, "pull failed, so the hygiene check proves nothing")
        try expect(!logLines.isEmpty, "no log lines captured, so the log check proves nothing")
        let surfaces = logLines + notices + store.activity.map(\.message) + store.syncJobs.compactMap { [$0.detail, $0.error].compactMap { $0 }.joined(separator: " ") }
            + store.workspace.connectorHealth.values.map(\.detail)
        for text in surfaces {
            try expect(!text.contains(key), "API key leaked: \(text)")
            for value in pii { try expect(!text.contains(value), "PII leaked (\(value)) into: \(text)") }
        }
        // Signal evidence carries the source id only, never identity values.
        let evidence = store.signals.first?.evidence ?? ""
        for value in pii { try expect(!evidence.contains(value), "PII in signal evidence") }
    }

    static func autoPull() async throws {
        let fake = FakeInbox(key: key)
        fake.add("ident_a", email: "a@example.test", first: "A", last: "One")
        let unconfigured = try makeStore(fake, withKey: false)
        await unconfigured.pullLeadsOnLaunch()
        try expect(unconfigured.leads.isEmpty && unconfigured.syncJobs.isEmpty, "auto pull ran without a key")
        let disabled = try makeStore(fake)
        disabled.setAutoPullLeads(false)
        await disabled.pullLeadsOnLaunch()
        try expect(disabled.leads.isEmpty, "auto pull ran while disabled")
        let enabled = try makeStore(fake)
        try expect(enabled.workspace.autoPullLeads, "auto pull should default to on")
        await enabled.pullLeadsOnLaunch()
        try expect(enabled.leads.count == 1, "auto pull did not run when enabled and configured")
    }
}
