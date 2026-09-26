import Foundation

/// Gap analysis connector: reads active gap clusters from the Supabase REST API
/// (`/rest/v1/gap_clusters` with embedded `gap_scores`) and turns them into signals.
/// The fake mirrors PostgREST: `apikey` + Bearer headers, JSON array body.
@MainActor
enum GapAnalysisTests {
    static func run() async -> Bool {
        let tests: [(String, () async throws -> Void)] = [
            ("Gaps: verify is an authenticated read; 401 is an error", verify),
            ("Gaps: import turns active clusters into signals with scores", importClusters),
            ("Gaps: re-import updates by cluster id, never duplicates", reimport),
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
    static let key = "sb_anon_\(UUID().uuidString)"

    final class FakeSupabase: HTTPTransport, @unchecked Sendable {
        let key: String
        private let lock = NSLock()
        var clusters: [[String: Any]] = []
        private(set) var requests: [URLRequest] = []
        init(key: String) { self.key = key }

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            lock.withLock {
                requests.append(request)
                guard request.value(forHTTPHeaderField: "apikey") == key,
                      request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)" else {
                    return HTTPResponse(status: 401, headers: [:], body: Data(#"{"message":"Invalid API key"}"#.utf8))
                }
                guard request.url?.path == "/rest/v1/gap_clusters", request.httpMethod == "GET" else {
                    return HTTPResponse(status: 404, headers: [:], body: Data("{}".utf8))
                }
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let active = query.contains { $0.name == "status" && $0.value == "eq.active" }
                let rows = clusters.filter { !active || ($0["status"] as? String) == "active" }
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

    private static func makeStore(_ fake: FakeSupabase, withKey: Bool = true, withEndpoint: Bool = true) throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("contextward-gaps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(withKey ? [.gaps: key] : [:]), transport: fake)
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
