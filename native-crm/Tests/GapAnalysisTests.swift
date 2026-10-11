import Foundation

/// Gap analysis connector: reads active gap clusters from the Supabase REST API
/// (`/rest/v1/gap_clusters` with embedded `gap_scores`) and turns them into signals.
/// The fake mirrors PostgREST key headers and returns a JSON array body.
@MainActor
enum GapAnalysisTests {
    static func run() async -> Bool {
        let tests: [(String, () async throws -> Void)] = [
            ("Gaps: verify is an authenticated read; 401 is an error", verify),
            ("Gaps: publishable key is sent only as apikey", publishableKeyHeaders),
            ("Gaps: secret key is rejected before any request", secretKeyRejected),
            ("Gaps: import turns active clusters into signals with scores", importClusters),
            ("Gaps: re-import updates by cluster id, never duplicates", reimport),
            ("Gaps: import paginates beyond 500 clusters without truncation", paginatesAllClusters),
            ("Gaps: non-advancing pagination fails without reconciliation", rejectsNonAdvancingPagination),
            ("Gaps: missing upstream clusters are retired without deleting local signals", reconcilesMissingClusters),
            ("Gaps: retired clusters leave operations and reactivate in place", retiredLifecycle),
            ("Gaps: scores embedded as an object or an array both work", embedShapes),
            ("Gaps: key never reaches activity, jobs, health, or logs", keyHygiene),
            ("Gaps: import without setup does nothing", needsSetup),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS  \(name)") }
            catch { failures += 1; print("FAIL  \(name): \(error)") }
        }
        print("Gap analysis tests: \(tests.count - failures)/\(tests.count) passed")
        return failures == 0
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeTestFailure.failed(message) }
    }

    static let url = "https://example-project.supabase.co"
    static let key = "eyJ_legacy_anon_\(UUID().uuidString)"

    final class FakeSupabase: HTTPTransport, @unchecked Sendable {
        let key: String
        let expectsBearer: Bool
        private let lock = NSLock()
        var clusters: [[String: Any]] = []
        var ignoresCursor = false
        private(set) var requests: [URLRequest] = []
        init(key: String, expectsBearer: Bool = true) {
            self.key = key
            self.expectsBearer = expectsBearer
        }

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            lock.withLock {
                requests.append(request)
                let expectedAuthorization = expectsBearer ? "Bearer \(key)" : nil
                guard request.value(forHTTPHeaderField: "apikey") == key,
                      request.value(forHTTPHeaderField: "Authorization") == expectedAuthorization else {
                    return HTTPResponse(status: 401, headers: [:], body: Data(#"{"message":"Invalid API key"}"#.utf8))
                }
                guard request.url?.path == "/rest/v1/gap_clusters", request.httpMethod == "GET" else {
                    return HTTPResponse(status: 404, headers: [:], body: Data("{}".utf8))
                }
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let active = query.contains { $0.name == "status" && $0.value == "eq.active" }
                let after = ignoresCursor ? nil : query.first { $0.name == "id" && $0.value?.hasPrefix("gt.") == true }?.value.map { String($0.dropFirst(3)) }
                let matching = clusters.filter { (!active || ($0["status"] as? String) == "active") && (after == nil || (($0["id"] as? String) ?? "") > after!) }
                    .sorted { (($0["id"] as? String) ?? "") < (($1["id"] as? String) ?? "") }
                let limit = query.first { $0.name == "limit" }.flatMap { $0.value }.flatMap(Int.init) ?? matching.count
                let rows = Array(matching.prefix(limit))
                return HTTPResponse(status: 200, headers: [:], body: (try? JSONSerialization.data(withJSONObject: rows)) ?? Data())
            }
        }
        var readCount: Int { lock.withLock { requests.count } }
    }

    static func cluster(_ id: String, label: String, total: Double, status: String = "active", embedAsArray: Bool = false) -> [String: Any] {
        let scores: [String: Any] = ["total_score": total, "frequency_score": 0.8, "intensity_score": 0.6, "breadth_score": 0.5,
                                     "wtp_score": 0.7, "workaround_score": 0.4, "segment_score": 0.9]
        return ["id": id, "market_key": "qc_smb_ai", "category": "missing_feature", "cluster_label": label,
                "summary": "Summary for \(label)", "status": status, "created_at": "2026-09-20T10:00:00Z",
                "gap_scores": embedAsArray ? [scores] as Any : scores as Any]
    }

    private static func makeStore(_ fake: FakeSupabase, apiKey: String? = nil, withKey: Bool = true, withEndpoint: Bool = true) throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("contextward-gaps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(withKey ? [.gaps: apiKey ?? key] : [:]), transport: fake)
        if withEndpoint { store.setEndpoint(url, for: .gaps) }
        return store
    }

    static func verify() async throws {
        let fake = FakeSupabase(key: key)
        let store = try makeStore(fake)
        try expect(await store.verifyConnector(.gaps), "verify failed with the right key")
        let request = fake.requests.last
        try expect(request?.url?.path == "/rest/v1/gap_clusters" && request?.httpMethod == "GET", "verify was not a read of gap_clusters")
        guard case .active = store.connectorStatus(.gaps) else { throw SmokeTestFailure.failed("verified connector not Active") }
        let wrong = try makeStore(FakeSupabase(key: "other"))
        try expect(await wrong.verifyConnector(.gaps) == false, "wrong key verified")
        guard case .error(let reason) = wrong.connectorStatus(.gaps), reason.contains("401") else { throw SmokeTestFailure.failed("401 not surfaced") }
    }

    static func publishableKeyHeaders() async throws {
        let publishableKey = "sb_publishable_test_\(UUID().uuidString)"
        let fake = FakeSupabase(key: publishableKey, expectsBearer: false)
        let store = try makeStore(fake, apiKey: publishableKey)
        try expect(await store.verifyConnector(.gaps), "publishable key was not accepted")
        let request = fake.requests.last
        try expect(request?.value(forHTTPHeaderField: "apikey") == publishableKey, "publishable key missing from apikey")
        try expect(request?.value(forHTTPHeaderField: "Authorization") == nil, "publishable key was incorrectly sent as Bearer")
    }

    static func secretKeyRejected() async throws {
        do {
            _ = try GapClient(endpoint: url, apiKey: "sb_secret_test", transport: FakeSupabase(key: "sb_secret_test"))
            throw SmokeTestFailure.failed("secret key was accepted")
        } catch let error as IntegrationError {
            try expect(error == .elevatedKeyNotAllowed, "wrong error for a secret key")
        }
    }

    static func importClusters() async throws {
        let fake = FakeSupabase(key: key)
        fake.clusters = [cluster("c1", label: "No French onboarding", total: 0.82), cluster("c2", label: "Too slow", total: 0.41),
                         cluster("c3", label: "Archived gap", total: 0.9, status: "archived")]
        let store = try makeStore(fake)
        let job = await store.importGaps()
        try expect(job.status == "synced", "import failed: \(job.error ?? "")")
        let gaps = store.signals.filter { $0.sourceID?.hasPrefix("gap:") == true }
        try expect(gaps.count == 2, "expected 2 active clusters as signals, got \(gaps.count)")
        let top = gaps.first { $0.sourceID == "gap:c1" }
        try expect(top?.title == "Market gap: No French onboarding", "title not mapped: \(top?.title ?? "nil")")
        try expect(top?.priority == 82 && top?.intentScore == 60 && top?.fitScore == 90, "scores not mapped")
        try expect(top?.evidence.contains("qc_smb_ai") == true && top?.evidence.contains("missing feature") == true, "evidence lacks market or category")
        try expect(job.detail?.contains("2 new") == true, "counts missing: \(job.detail ?? "")")
        let request = fake.requests.last.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false) }
        try expect(request?.queryItems?.contains { $0.name == "status" && $0.value == "eq.active" } == true, "import did not ask for active clusters only")
    }

    static func reimport() async throws {
        let fake = FakeSupabase(key: key)
        fake.clusters = [cluster("c1", label: "No French onboarding", total: 0.82)]
        let store = try makeStore(fake)
        _ = await store.importGaps()
        var signal = store.signals.first { $0.sourceID == "gap:c1" }!
        signal.owner = "Martin"; signal.status = .routed; store.update(signal)
        let same = await store.importGaps()
        try expect(same.detail?.contains("1 unchanged") == true, "unchanged not counted: \(same.detail ?? "")")
        fake.clusters = [cluster("c1", label: "No French onboarding at all", total: 0.9)]
        let changed = await store.importGaps()
        let gaps = store.signals.filter { $0.sourceID == "gap:c1" }
        try expect(gaps.count == 1, "re-import duplicated the signal")
        try expect(gaps[0].priority == 90 && gaps[0].title == "Market gap: No French onboarding at all", "update not applied")
        try expect(gaps[0].owner == "Martin" && gaps[0].status == .routed, "local routing was overwritten")
        try expect(changed.detail?.contains("1 updated") == true, "update not counted: \(changed.detail ?? "")")
    }

    static func paginatesAllClusters() async throws {
        let fake = FakeSupabase(key: key)
        fake.clusters = (0..<501).map { cluster(String(format: "c%04d", $0), label: "Gap \($0)", total: 0.5) }
        let store = try makeStore(fake)
        let job = await store.importGaps()
        try expect(job.status == "synced", "paginated import failed: \(job.error ?? "")")
        try expect(store.signals.filter { $0.sourceID?.hasPrefix("gap:") == true }.count == 501, "import silently truncated clusters")
        let cursors = fake.requests.compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "id" }?.value
        }
        try expect(cursors == ["gt.c0499"], "expected deterministic keyset pagination, got \(cursors)")
    }

    static func rejectsNonAdvancingPagination() async throws {
        let fake = FakeSupabase(key: key)
        fake.clusters = (0..<500).map { cluster(String(format: "c%04d", $0), label: "Gap \($0)", total: 0.5) }
        fake.ignoresCursor = true
        let store = try makeStore(fake)
        var existing = Signal(); existing.source = .imported; existing.sourceID = "gap:legacy"; existing.sourceActive = true
        store.add(existing)
        let job = await store.importGaps()
        try expect(job.status == "failed" && job.error?.contains("repeated a page") == true, "non-advancing server did not fail safely")
        try expect(store.signals.first { $0.sourceID == "gap:legacy" }?.sourceActive == true, "failed snapshot retired an existing signal")
    }

    static func reconcilesMissingClusters() async throws {
        let fake = FakeSupabase(key: key)
        fake.clusters = [cluster("c1", label: "Still active", total: 0.8), cluster("c2", label: "Will archive", total: 0.6)]
        let store = try makeStore(fake)
        _ = await store.importGaps()
        var retired = store.signals.first { $0.sourceID == "gap:c2" }!
        let localID = retired.id
        retired.owner = "Martin"
        retired.status = .routed
        retired.nextAction = "Keep this local decision."
        store.update(retired)

        fake.clusters = [cluster("c1", label: "Still active", total: 0.8), cluster("c2", label: "Will archive", total: 0.6, status: "archived")]
        let job = await store.importGaps()
        let signals = store.signals.filter { $0.sourceID == "gap:c2" }
        try expect(signals.count == 1 && signals[0].id == localID, "retired upstream gap was deleted or duplicated")
        try expect(signals[0].sourceActive == false, "missing upstream gap was not marked inactive")
        try expect(signals[0].owner == "Martin" && signals[0].status == .routed && signals[0].nextAction == "Keep this local decision.", "reconciliation overwrote user-owned fields")
        try expect(job.detail?.contains("1 retired") == true, "retired count missing: \(job.detail ?? "")")
    }

    static func retiredLifecycle() async throws {
        let fake = FakeSupabase(key: key)
        fake.clusters = [cluster("c1", label: "Lifecycle", total: 0.9)]
        let store = try makeStore(fake)
        _ = await store.importGaps()
        guard let original = store.signals.first(where: { $0.sourceID == "gap:c1" }) else { throw SmokeTestFailure.failed("gap not imported") }
        fake.clusters = []
        _ = await store.importGaps()
        try expect(store.activeSignals.isEmpty && store.qualifiedSignals.isEmpty, "retired gap remained in active queues")
        try expect(store.exchange.signals.isEmpty, "retired gap remained in exchange export")
        try expect(store.signals.contains { $0.id == original.id && $0.sourceActive == false }, "retired gap was not retained for audit")
        let tasksBefore = store.tasks.count
        _ = store.runAutomations()
        try expect(store.tasks.count == tasksBefore, "retired gap entered automation")
        fake.clusters = [cluster("c1", label: "Lifecycle returns", total: 0.95)]
        _ = await store.importGaps()
        let reactivated = store.signals.first { $0.sourceID == "gap:c1" }
        try expect(reactivated?.id == original.id && reactivated?.sourceActive == true, "reactivation did not restore the existing audit record")
        try expect(store.activeSignals.count == 1, "reactivated gap did not return to active operations")
    }

    static func embedShapes() async throws {
        let fake = FakeSupabase(key: key)
        fake.clusters = [cluster("c1", label: "Object embed", total: 0.5), cluster("c2", label: "Array embed", total: 0.7, embedAsArray: true)]
        var noScores = cluster("c3", label: "No scores yet", total: 0); noScores["gap_scores"] = NSNull()
        fake.clusters.append(noScores)
        let store = try makeStore(fake)
        let job = await store.importGaps()
        try expect(job.status == "synced", "import failed: \(job.error ?? "")")
        try expect(store.signals.first { $0.sourceID == "gap:c2" }?.priority == 70, "array embed not read")
        try expect(store.signals.first { $0.sourceID == "gap:c3" }?.priority == 0, "cluster without scores not imported")
    }

    static func keyHygiene() async throws {
        let fake = FakeSupabase(key: key)
        fake.clusters = [cluster("c1", label: "Gap", total: 0.5)]
        let store = try makeStore(fake)
        var lines: [String] = []
        store.syncLogSink = { lines.append($0) }
        _ = await store.verifyConnector(.gaps)
        _ = await store.importGaps()
        try expect(!lines.isEmpty, "no log lines captured")
        let text = (lines + store.activity.map(\.message) + store.syncJobs.compactMap(\.detail) + store.workspace.connectorHealth.values.map(\.detail)).joined(separator: "\n")
        try expect(!text.contains(key), "key leaked")
        let saved = try String(contentsOf: store.storageURL, encoding: .utf8)
        try expect(!saved.contains(key), "key reached workspace.json")
    }

    static func needsSetup() async throws {
        let fake = FakeSupabase(key: key)
        let store = try makeStore(fake, withKey: false)
        let job = await store.importGaps()
        try expect(job.status == "failed" && fake.readCount == 0, "import ran without a key")
        guard case .needsSetup = store.connectorStatus(.gaps) else { throw SmokeTestFailure.failed("status not Needs setup") }
    }
}
