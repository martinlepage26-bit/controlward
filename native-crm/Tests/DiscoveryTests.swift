import Foundation

@MainActor
enum DiscoveryTests {
    final class FakeTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [HTTPResponse]
        private(set) var requests: [URLRequest] = []
        init(_ responses: [HTTPResponse]) { self.responses = responses }
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            lock.withLock {
                requests.append(request)
                return responses.isEmpty ? HTTPResponse(status: 500, headers: [:], body: Data()) : responses.removeFirst()
            }
        }
    }

    static func run() async -> Bool {
        do {
            try await overpassResultsCarryEvidenceAndDeduplicate()
            try await photonFallbackMapsOnlyNearbyMatchingBusinesses()
            try await automaticResearchSurvivesSaveAndReload()
            try await failedResearchSaveKeepsOriginal()
            try websiteQueuesKeepInputsUnverifiedAndRejectPrivateURLs()
            print("Discovery tests: 5/5 passed")
            return true
        } catch {
            print("Discovery tests: FAIL \(error)")
            return false
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeTestFailure.failed(message) }
    }

    static func overpassResultsCarryEvidenceAndDeduplicate() async throws {
        let payload = #"{"elements":[{"type":"node","id":101,"lat":45.5017,"lon":-73.5673,"tags":{"name":"Synthetic Cafe","amenity":"cafe","website":"https://example.test","phone":"514-555-0100","addr:city":"Montréal"}},{"type":"node","id":101,"lat":45.5017,"lon":-73.5673,"tags":{"name":"Synthetic Cafe","amenity":"cafe"}}]}"#.data(using: .utf8)!
        let fake = FakeTransport([HTTPResponse(status: 200, headers: [:], body: payload)])
        let client = DiscoveryClient(transport: fake)
        let candidates = try await client.search(category: "amenity=cafe", latitude: 45.5017, longitude: -73.5673, radiusMeters: 2_000)
        try expect(candidates.count == 1, "Overpass result was not parsed and deduplicated")
        guard let candidate = candidates.first else { return }
        try expect(candidate.name == "Synthetic Cafe" && candidate.sourceID == "osm:node:101", "source identity was not preserved")
        try expect(candidate.researchPriority == 85 && candidate.readyForHumanReview, "visible evidence score is incorrect")
        try expect(candidate.evidence.contains("Buyer intent is unknown") && candidate.evidence.contains("Source:"), "evidence rationale or attribution missing")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("controlward-discovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(), transport: fake)
        let leadID = store.acceptDiscovery(candidate)
        try expect(leadID != nil && store.leads.first?.id == leadID && store.signals.first?.fitScore == 85, "selected prospect was not saved: \(store.saveFailure ?? "no save error")")
        let reloaded = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
        try expect(reloaded.leads.first?.id == leadID && reloaded.signals.first?.fitScore == 85, "discovery import did not survive reload")
        try expect(store.leads.first?.service.isEmpty == true, "business category became a requested service")
        try expect(candidate.evidence.contains("website 20, phone 15, email 0"), "evidence lists maximum points instead of earned points")
        var blank = candidate
        blank.website = "  "; blank.phone = ""; blank.email = "\n"
        try expect(blank.researchPriority == 50 && blank.evidence.contains("website 0, phone 0, email 0"), "blank contact fields earned points")
        _ = store.acceptDiscovery(candidate)
        try expect(store.leads.count == 1, "duplicate public source was added twice")
        guard let body = fake.requests.first?.httpBody, let encoded = String(data: body, encoding: .utf8) else { throw SmokeTestFailure.failed("Overpass request body missing") }
        try expect(encoded.contains("%5B") && !encoded.contains("[out:"), "Overpass form query was not safely encoded")
    }

    static func photonFallbackMapsOnlyNearbyMatchingBusinesses() async throws {
        let fallback = #"{"features":[{"geometry":{"coordinates":[-73.5673,45.5017]},"properties":{"osm_type":"N","osm_id":202,"osm_key":"amenity","osm_value":"cafe","name":"Nearby Cafe","city":"Montréal"}},{"geometry":{"coordinates":[-73.40,45.50]},"properties":{"osm_type":"N","osm_id":203,"osm_key":"amenity","osm_value":"cafe","name":"Far Cafe"}},{"geometry":{"coordinates":[-73.5673,45.5017]},"properties":{"osm_type":"N","osm_id":204,"osm_key":"amenity","osm_value":"restaurant","name":"Not a Cafe"}}]}"#.data(using: .utf8)!
        let fake = FakeTransport([HTTPResponse(status: 504, headers: [:], body: Data()), HTTPResponse(status: 200, headers: [:], body: fallback)])
        let client = DiscoveryClient(transport: fake)
        let candidates = try await client.search(category: "amenity=cafe", latitude: 45.5017, longitude: -73.5673, radiusMeters: 2_000)
        try expect(candidates.map(\.name) == ["Nearby Cafe"], "Photon fallback did not filter by category and radius")
        try expect(candidates.first?.query.contains("Photon fallback") == true, "fallback source was not recorded in evidence")
    }

    static func researchFixture() async throws -> (DiscoveryCandidate, QuickScanResearchResult, ICPConfig) {
        let (researcher, _, source) = try QuickScanResearchTests.fixture(now: Date.now.addingTimeInterval(-120))
        let result = await researcher.research(source, segmentID: "clinic")
        let candidate = DiscoveryCandidate(sourceID: source.osmID, name: source.name, category: "clinic", address: "Montréal", website: source.website,
                                           phone: nil, email: "old-map@clinique-exemple.test", sourceURL: "https://www.openstreetmap.org/node/1001",
                                           latitude: source.latitude, longitude: source.longitude, query: "healthcare=clinic", capturedAt: Date.now.ISO8601Format())
        return (candidate, result, researcher.config)
    }

    static func automaticResearchSurvivesSaveAndReload() async throws {
        let (candidate, result, config) = try await researchFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("controlward-research-save-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var cache = WebsiteResearchCache()
        cache.merge(candidate, result: result)
        cache.merge(candidate, result: result)
        let cacheURL = root.appendingPathComponent("research.json")
        try cache.save(cacheURL)
        let loadedCache = try WebsiteResearchCache.load(cacheURL)
        try expect(try JSONEncoder.iso.encode(loadedCache) == JSONEncoder.iso.encode(cache) && cache.candidates.count == 1,
                   "unreviewed findings survive reopen without duplicates at the ISO millisecond precision")
        let attributes = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "research cache is owner-only")
        let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore())
        let id = store.acceptDiscovery(candidate, research: result, researchConfig: config)
        try expect(id != nil && store.leads.first?.email == "info@clinique-exemple.test", "own-site contact replaces unverified map value")
        try expect(store.leads.first?.name == "Alex Fictif" && store.leads.first?.quoteAmount == nil, "actual person, no invented deal value")
        try expect(store.leads.first?.outreachDraft?.contains("99 $ CA") == true && store.leads.first?.history.isEmpty == true, "priced unsent draft retained")
        var converted = store.workspace
        if let id, let plan = LeadWorkflow.conversionPlan(for: id, in: converted) {
            _ = try LeadWorkflow.applyConversion(plan, to: &converted)
            try expect(converted.contacts.first?.email == "" && converted.contacts.first?.phone == "", "business routes were not invented as personal contact details")
            try expect(plan.warnings.contains { $0.contains("not a verified personal inbox") }, "preview states the association limit")
        } else { throw SmokeTestFailure.failed("conversion plan missing") }
        let reopened = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
        try expect(reopened.leads.first?.quickScanResearch == result && reopened.leads.first?.outreachDraft == store.leads.first?.outreachDraft, "research and draft survive restart")
        var edited = store.leads[0]; edited.email = "owner-edited@other.test"; edited.outreachDraft = "Owner's saved draft"
        store.update(edited)
        _ = store.acceptDiscovery(candidate, research: result, researchConfig: config)
        try expect(store.leads.count == 1 && store.signals.count == 1, "repeated research creates no duplicate")
        try expect(store.leads[0].email == edited.email && store.leads[0].outreachDraft == edited.outreachDraft, "owner edits retained")
        var queued = candidate; queued.sourceID = "website:" + LeadKit.clinicDomain
        var secondResult = result; secondResult.record.id = "cw:" + queued.sourceID
        _ = store.acceptDiscovery(queued, research: secondResult, researchConfig: config)
        try expect(store.leads.count == 1 && store.signals.count == 1 && store.leads[0].sourceID == candidate.sourceID, "map and website queue dedupe by researched domain without replacing source identity")
    }

    static func failedResearchSaveKeepsOriginal() async throws {
        let (candidate, result, config) = try await researchFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("controlward-research-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocked = root.appendingPathComponent("blocked")
        try Data("write blocker".utf8).write(to: blocked)
        let store = AppStore(storageURL: blocked.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore())
        try expect(store.acceptDiscovery(candidate, research: result, researchConfig: config) == nil && store.leads.isEmpty && store.signals.isEmpty,
                   "research save failure publishes nothing")
        try FileManager.default.removeItem(at: blocked)
        try expect(store.acceptDiscovery(candidate, research: result, researchConfig: config) != nil && store.leads.count == 1, "retry saves one researched lead")
    }

    static func websiteQueuesKeepInputsUnverifiedAndRejectPrivateURLs() throws {
        let queue = try WebsiteResearchQueue.parse("Example | https://www.example.test/en/about?tracking=1#top\nOther label | https://example.test/contact")
        try expect(queue.count == 1 && queue[0].sourceID == "website:example.test", "domain dedupe")
        try expect(queue[0].email == nil && queue[0].phone == nil && queue[0].website == "https://www.example.test/en/about", "queue supplies no guessed contact or AI claim")
        try expect(!queue[0].evidence.contains("Map coordinates") && queue[0].categoryLocationPoints == 0, "website queue invents no location or geographic fit")
        try expect(LeadWorkflow.origin(of: { var l = Lead.blank(); l.sourceID = queue[0].sourceID; return l }()) == .prospectSearch, "outbound origin")
        for invalid in ["http://127.0.0.1", "https://localhost", "http://10.0.0.1", "https://user:password@example.test", "file:///etc/hosts"] {
            do { _ = try WebsiteResearchQueue.parse(invalid); throw SmokeTestFailure.failed("accepted \(invalid)") }
            catch DiscoverySearchError.invalidWebsiteQueue {}
        }
    }
}
