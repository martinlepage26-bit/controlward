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
            print("Discovery tests: 2/2 passed")
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
        let store = AppStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent("discovery-\(UUID().uuidString).json"), secrets: InMemorySecretStore(), transport: fake)
        let leadID = store.acceptDiscovery(candidate)
        try expect(store.leads.first?.id == leadID && store.signals.first?.fitScore == 85, "selected prospect was not added with its score")
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
}
