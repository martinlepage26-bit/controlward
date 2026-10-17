import Foundation

struct DiscoveryCandidate: Identifiable, Equatable, Sendable {
    var sourceID: String
    var name: String
    var category: String
    var address: String
    var website: String?
    var phone: String?
    var email: String?
    var sourceURL: String
    var latitude: Double
    var longitude: Double
    var query: String
    var capturedAt: String

    var id: String { sourceID }
    var categoryLocationPoints: Int { 50 }
    var websitePoints: Int { website == nil ? 0 : 20 }
    var phonePoints: Int { phone == nil ? 0 : 15 }
    var emailPoints: Int { email == nil ? 0 : 15 }
    var researchPriority: Int { categoryLocationPoints + websitePoints + phonePoints + emailPoints }
    var readyForHumanReview: Bool { researchPriority >= 65 }
    var evidence: String {
        [
            "Public business listing: \(name)",
            "Category / area: \(category) · \(query)",
            address.isEmpty ? nil : "Address: \(address)",
            website.map { "Website: \($0)" },
            phone.map { "Phone: \($0)" },
            email.map { "Email: \($0)" },
            "Map coordinates: \(latitude), \(longitude)",
            "Source: \(sourceURL)",
            "Retrieved: \(capturedAt)",
            "Research priority: \(researchPriority)/100 (category/area 50, website 20, phone 15, email 15). Buyer intent is unknown."
        ].compactMap { $0 }.joined(separator: "\n")
    }
}

enum DiscoverySearchError: LocalizedError {
    case invalidLocation
    case rateLimited
    case unavailable(Int)
    case responseTooLarge
    case malformed

    var errorDescription: String? {
        switch self {
        case .invalidLocation: "Choose a supported area and search category."
        case .rateLimited: "The public map search is busy. Wait before trying again."
        case .unavailable(429): "The public map search is busy. Wait before trying again."
        case .unavailable(504): "The public map search timed out. Try a smaller radius."
        case .unavailable: "The public map search is temporarily unavailable. Try again later."
        case .responseTooLarge: "The search returned too much data. Reduce the search radius."
        case .malformed: "The public map search returned data ControlWard could not read."
        }
    }
}

struct DiscoveryClient: Sendable {
    static let endpoint = URL(string: "https://overpass.private.coffee/api/interpreter")!
    static let fallbackEndpoint = URL(string: "https://photon.komoot.io/api/")!
    static let maxResponseBytes = 3 * 1024 * 1024
    var transport: HTTPTransport = URLSessionTransport()

    func search(category: String, latitude: Double, longitude: Double, radiusMeters: Int, limit: Int = 50) async throws -> [DiscoveryCandidate] {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude),
              !category.isEmpty, radiusMeters > 0 else { throw DiscoverySearchError.invalidLocation }
        let safeRadius = min(max(radiusMeters, 100), 10_000)
        let safeLimit = min(max(limit, 1), 50)
        let categoryParts = category.split(separator: "=", maxSplits: 1).map(String.init)
        guard categoryParts.count == 2, ["amenity", "shop", "office", "craft", "tourism"].contains(categoryParts[0]) else {
            throw DiscoverySearchError.invalidLocation
        }
        let key = categoryParts[0].replacingOccurrences(of: "\"", with: "")
        let value = categoryParts[1].replacingOccurrences(of: "\"", with: "")
        let query = "[out:json][timeout:8];nwr[\"\(key)\"=\"\(value)\"][\"name\"](around:\(safeRadius),\(latitude),\(longitude));out center tags \(safeLimit);"
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("ControlWard/1.0 (public prospect search)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let formAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? "")".data(using: .utf8)
        let response: HTTPResponse
        do { response = try await transport.send(request) }
        catch { return try await photonSearch(category: category, key: key, value: value, latitude: latitude, longitude: longitude, radiusMeters: safeRadius, limit: safeLimit) }
        guard response.body.count <= Self.maxResponseBytes else { throw DiscoverySearchError.responseTooLarge }
        guard response.status == 200 else {
            if response.status == 429 || response.status >= 500 {
                return try await photonSearch(category: category, key: key, value: value, latitude: latitude, longitude: longitude, radiusMeters: safeRadius, limit: safeLimit)
            }
            throw DiscoverySearchError.unavailable(response.status)
        }
        guard let decoded = try? JSONDecoder().decode(OverpassEnvelope.self, from: response.body) else { throw DiscoverySearchError.malformed }
        let captured = Date.now.ISO8601Format()
        var seen = Set<String>()
        return decoded.elements.compactMap { element in
            let sourceID = "osm:\(element.type):\(element.id)"
            guard seen.insert(sourceID).inserted,
                  let name = element.tags["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            let pointLat = element.lat ?? element.center?.lat ?? latitude
            let pointLon = element.lon ?? element.center?.lon ?? longitude
            let street = [element.tags["addr:housenumber"], element.tags["addr:street"]].compactMap { $0 }.joined(separator: " ")
            let address = [street.isEmpty ? nil : street, element.tags["addr:city"], element.tags["addr:postcode"], element.tags["addr:country"]].compactMap { $0 }.joined(separator: ", ")
            let label = element.tags[key].map { "\(categoryParts[1]) · \($0)" } ?? categoryParts[1].capitalized
            let url = "https://www.openstreetmap.org/\(element.type)/\(element.id)"
            return DiscoveryCandidate(sourceID: sourceID, name: name, category: label, address: address,
                                      website: element.tags["contact:website"] ?? element.tags["website"],
                                      phone: element.tags["contact:phone"] ?? element.tags["phone"],
                                      email: element.tags["contact:email"] ?? element.tags["email"], sourceURL: url,
                                      latitude: pointLat, longitude: pointLon,
                                      query: "\(category) around \(latitude), \(longitude) · radius \(safeRadius)m", capturedAt: captured)
        }.prefix(safeLimit).map { $0 }
    }

    private func photonSearch(category: String, key: String, value: String, latitude: Double, longitude: Double, radiusMeters: Int, limit: Int) async throws -> [DiscoveryCandidate] {
        var components = URLComponents(url: Self.fallbackEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: value),
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lon", value: String(longitude)),
            URLQueryItem(name: "limit", value: String(min(limit, 50))),
            URLQueryItem(name: "lang", value: "en")
        ]
        guard let url = components.url else { throw DiscoverySearchError.invalidLocation }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("ControlWard/1.0 (public prospect search)", forHTTPHeaderField: "User-Agent")
        let response: HTTPResponse
        do { response = try await transport.send(request) } catch { throw DiscoverySearchError.unavailable(0) }
        guard response.body.count <= Self.maxResponseBytes else { throw DiscoverySearchError.responseTooLarge }
        guard response.status == 200 else {
            if response.status == 429 { throw DiscoverySearchError.rateLimited }
            throw DiscoverySearchError.unavailable(response.status)
        }
        guard let decoded = try? JSONDecoder().decode(PhotonEnvelope.self, from: response.body) else { throw DiscoverySearchError.malformed }
        let captured = Date.now.ISO8601Format()
        let radius = Double(radiusMeters)
        return decoded.features.compactMap { feature -> DiscoveryCandidate? in
            let place = feature.properties
            guard place.osmKey == key, place.osmValue == value,
                  let name = place.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let coordinates = feature.geometry?.coordinates, coordinates.count >= 2 else { return nil }
            let lon = coordinates[0], lat = coordinates[1]
            guard Self.distanceMeters(latitude, longitude, lat, lon) <= radius else { return nil }
            let type = place.osmType ?? "N"
            let osmType = type == "W" ? "way" : (type == "R" ? "relation" : "node")
            let sourceID = "osm:\(osmType):\(place.osmID)"
            let address = [
                [place.houseNumber, place.street].compactMap { $0 }.joined(separator: " ")
            ].filter { !$0.isEmpty } + [place.city, place.postcode, place.country].compactMap { $0 }
            let formattedAddress = address.joined(separator: ", ")
            return DiscoveryCandidate(sourceID: sourceID, name: name, category: value.capitalized,
                                      address: formattedAddress, website: place.website, phone: place.phone, email: place.email,
                                      sourceURL: "https://www.openstreetmap.org/\(osmType)/\(place.osmID)",
                                      latitude: lat, longitude: lon, query: "\(category) around \(latitude), \(longitude) · radius \(radiusMeters)m (Photon fallback)", capturedAt: captured)
        }.prefix(limit).map { $0 }
    }

    private static func distanceMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radians = Double.pi / 180
        let dLat = (lat2 - lat1) * radians
        let dLon = (lon2 - lon1) * radians
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

private struct PhotonEnvelope: Decodable { var features: [PhotonFeature] }
private struct PhotonFeature: Decodable {
    var properties: Properties
    var geometry: Geometry?
    struct Geometry: Decodable { var coordinates: [Double] }
    struct Properties: Decodable {
        var osmType: String?
        var osmID: Int64
        var osmKey: String
        var osmValue: String
        var name: String?
        var houseNumber: String?
        var street: String?
        var city: String?
        var postcode: String?
        var country: String?
        var website: String?
        var phone: String?
        var email: String?
        enum CodingKeys: String, CodingKey {
            case osmType = "osm_type", osmID = "osm_id", osmKey = "osm_key", osmValue = "osm_value"
            case name, houseNumber = "housenumber", street, city, postcode, country, website, phone, email
        }
    }
}

private struct OverpassEnvelope: Decodable {
    var elements: [OverpassElement]
}

private struct OverpassElement: Decodable {
    var type: String
    var id: Int64
    var lat: Double?
    var lon: Double?
    var center: Center?
    var tags: [String: String]

    struct Center: Decodable { var lat: Double; var lon: Double }
}

enum DiscoveryCategory: String, CaseIterable, Identifiable {
    case restaurant, cafe, contractor, plumber, electrician, landscaping, consulting
    var id: String { rawValue }
    var label: String {
        switch self {
        case .restaurant: "Restaurants"
        case .cafe: "Cafés"
        case .contractor: "General contractors"
        case .plumber: "Plumbers"
        case .electrician: "Electricians"
        case .landscaping: "Landscapers"
        case .consulting: "Consultants"
        }
    }
    var selector: String {
        switch self {
        case .restaurant: "amenity=restaurant"
        case .cafe: "amenity=cafe"
        case .contractor: "craft=builder"
        case .plumber: "craft=plumber"
        case .electrician: "craft=electrician"
        case .landscaping: "craft=gardener"
        case .consulting: "office=consulting"
        }
    }
}

enum DiscoveryLocation: String, CaseIterable, Identifiable {
    case montreal, quebecCity, ottawa, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .montreal: "Montréal"
        case .quebecCity: "Québec City"
        case .ottawa: "Ottawa"
        case .custom: "Custom coordinates"
        }
    }
    var coordinates: (Double, Double) {
        switch self {
        case .montreal: (45.5017, -73.5673)
        case .quebecCity: (46.8139, -71.2080)
        case .ottawa: (45.4215, -75.6972)
        case .custom: (0, 0)
        }
    }
}
