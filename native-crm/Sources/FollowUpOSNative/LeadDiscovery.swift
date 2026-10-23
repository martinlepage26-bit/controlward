import Foundation

/// A business found on OpenStreetMap. Discovery hosts only ever receive a tag and coordinates.
struct LeadCandidate: Equatable, Sendable {
    var osmID: String
    var name: String
    var website: String?
    var tags: [String]
    var city: String?
    var latitude: Double
    var longitude: Double
    var discoveredVia: String
}

/// Overpass first (overpass.private.coffee), then Photon (photon.komoot.io), per segment selector from icp.json.
struct LeadDiscovery: Sendable {
    static let overpass = URL(string: "https://overpass.private.coffee/api/interpreter")!
    static let photon = URL(string: "https://photon.komoot.io/api/")!

    let transport: GuardedLeadTransport

    func search(selectors: [String], latitude: Double, longitude: Double, radiusMeters: Int, limit: Int) async -> [LeadCandidate] {
        var out: [LeadCandidate] = []
        var seen = Set<String>()
        for selector in selectors {
            let parts = selector.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, Self.isTag(parts[0]), Self.isTag(parts[1]) else { continue }
            var found = (try? await overpass(key: parts[0], value: parts[1], latitude: latitude, longitude: longitude, radius: radiusMeters, limit: limit)) ?? []
            if found.isEmpty {
                found = (try? await photon(key: parts[0], value: parts[1], latitude: latitude, longitude: longitude, limit: limit)) ?? []
            }
            for candidate in found where seen.insert(candidate.osmID).inserted { out.append(candidate) }
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }

    /// OSM keys and values only: letters, digits, `_`, `:` and `-`. Nothing else can reach a discovery host.
    static func isTag(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 40 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_:-".contains($0)) }
    }

    static func overpassQuery(key: String, value: String, latitude: Double, longitude: Double, radius: Int, limit: Int) -> String {
        let r = min(max(radius, 100), 50_000)
        return "[out:json][timeout:20];nwr[\"\(key)\"=\"\(value)\"][\"name\"](around:\(r),\(String(format: "%.5f", latitude)),\(String(format: "%.5f", longitude)));out center tags \(min(max(limit, 1), 200));"
    }

    func overpass(key: String, value: String, latitude: Double, longitude: Double, radius: Int, limit: Int) async throws -> [LeadCandidate] {
        let query = Self.overpassQuery(key: key, value: value, latitude: latitude, longitude: longitude, radius: radius, limit: limit)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = Data("data=\(query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")".utf8)
        let response = try await transport.fetch(Self.overpass, purpose: .discovery, method: "POST", body: body,
                                                 headers: ["Content-Type": "application/x-www-form-urlencoded"])
        guard (200..<300).contains(response.status) else { return [] }
        return Self.parseOverpass(response.body, via: "overpass \(key)=\(value)")
    }

    func photon(key: String, value: String, latitude: Double, longitude: Double, limit: Int) async throws -> [LeadCandidate] {
        var components = URLComponents(url: Self.photon, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: value.replacingOccurrences(of: "_", with: " ")),
            URLQueryItem(name: "osm_tag", value: "\(key):\(value)"),
            URLQueryItem(name: "lat", value: String(format: "%.5f", latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.5f", longitude)),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))
        ]
        guard let url = components.url else { return [] }
        let response = try await transport.fetch(url, purpose: .discovery)
        guard (200..<300).contains(response.status) else { return [] }
        return Self.parsePhoton(response.body, via: "photon \(key)=\(value)")
    }

    static func parseOverpass(_ data: Data, via: String) -> [LeadCandidate] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return [] }
        return elements.compactMap { element in
            let tags = element["tags"] as? [String: String] ?? [:]
            guard let name = tags["name"], !name.isEmpty else { return nil }
            let center = element["center"] as? [String: Double]
            let lat = element["lat"] as? Double ?? center?["lat"] ?? 0
            let lon = element["lon"] as? Double ?? center?["lon"] ?? 0
            let type = element["type"] as? String ?? "node"
            let id = (element["id"] as? NSNumber)?.stringValue ?? "\(element["id"] ?? "")"
            let website = tags["website"] ?? tags["contact:website"] ?? tags["url"]
            let tagList = tags.filter { !["name", "website", "contact:website", "url", "phone", "contact:phone", "email", "contact:email"].contains($0.key) && !$0.key.hasPrefix("addr:") }
                .map { "\($0.key)=\($0.value)" }.sorted()
            return LeadCandidate(osmID: "osm:\(type)/\(id)", name: name, website: website, tags: tagList,
                                 city: tags["addr:city"], latitude: lat, longitude: lon, discoveredVia: via)
        }
    }

    static func parsePhoton(_ data: Data, via: String) -> [LeadCandidate] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return [] }
        return features.compactMap { feature in
            let properties = feature["properties"] as? [String: Any] ?? [:]
            guard let name = properties["name"] as? String, !name.isEmpty else { return nil }
            let coordinates = (feature["geometry"] as? [String: Any])?["coordinates"] as? [Double] ?? [0, 0]
            let type = properties["osm_type"] as? String ?? "N"
            let id = (properties["osm_id"] as? NSNumber)?.stringValue ?? ""
            var tags: [String] = []
            if let key = properties["osm_key"] as? String, let value = properties["osm_value"] as? String { tags.append("\(key)=\(value)") }
            let extra = properties["extra"] as? [String: Any]
            return LeadCandidate(osmID: "osm:\(type)/\(id)", name: name, website: extra?["website"] as? String, tags: tags,
                                 city: properties["city"] as? String, latitude: coordinates.count > 1 ? coordinates[1] : 0,
                                 longitude: coordinates.first ?? 0, discoveredVia: via)
        }
    }
}
