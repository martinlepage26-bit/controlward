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
    /// OSM lifecycle tags or the name say the place no longer operates. Closed places are dropped by the run.
    var closed = false
    /// The discovery endpoint that returned this place (an Overpass server or Photon), for the audit.
    var provider: URL?
}

/// Overpass first (overpass.private.coffee, then overpass-api.de), then Photon (photon.komoot.io), per segment selector from icp.json.
struct LeadDiscovery: Sendable {
    static let overpass = URL(string: "https://overpass.private.coffee/api/interpreter")!
    static let photon = URL(string: "https://photon.komoot.io/api/")!

    let transport: GuardedLeadTransport
    /// Jitter source in [0, 1] for the retry backoff; tests pass a fixed value.
    var jitter: @Sendable () -> Double = { Double.random(in: 0...1) }

    /// One Overpass query area.
    struct Tile: Equatable, Sendable {
        var latitude: Double
        var longitude: Double
        var radiusMeters: Int
    }

    /// Per segment selector: Overpass cell by cell (centre out) until the limit, keeping only hits inside the requested circle;
    /// Photon (unchanged, whole circle) when Overpass found nothing for that selector. Once both Overpass hosts have used up
    /// their retries in this search, the remaining cells and selectors go straight to Photon instead of retrying again.
    func search(selectors: [String], latitude: Double, longitude: Double, radiusMeters: Int, limit: Int) async -> [LeadCandidate] {
        await searchWithOutcomes(selectors: selectors, latitude: latitude, longitude: longitude, radiusMeters: radiusMeters, limit: limit).candidates
    }

    /// Which provider actually answered for one selector (Earth 8:19): the Overpass server or Photon with result ok, or no
    /// provider and the last real error.
    struct SelectorOutcome: Equatable, Sendable {
        var selector: String
        var provider: URL?
        var result: String
    }

    func searchWithOutcomes(selectors: [String], latitude: Double, longitude: Double, radiusMeters: Int,
                            limit: Int) async -> (candidates: [LeadCandidate], outcomes: [SelectorOutcome]) {
        var outcomes: [SelectorOutcome] = []
        let shape = transport.config.etiquette.discoveryQuery ?? .standard
        let cells = Self.tiles(latitude: latitude, longitude: longitude, radiusMeters: radiusMeters, tileRadiusMeters: shape.tileRadiusMeters)
        var out: [LeadCandidate] = []
        var seen = Set<String>()
        var overpassExhausted = false
        for selector in selectors {
            let parts = selector.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, Self.isTag(parts[0]), Self.isTag(parts[1]) else { continue }
            var overpassHits = 0
            var answeredBy: URL?
            var lastResult = overpassExhausted ? "error:overpass-exhausted" : "error:no-answer"
            if !overpassExhausted {
                cellLoop: for cell in cells {
                    switch await overpass(key: parts[0], value: parts[1], tile: cell, limit: limit, shape: shape) {
                    case .answered(let found, let server):
                        answeredBy = answeredBy ?? server
                        let inside = found.filter { Self.isInside($0, latitude: latitude, longitude: longitude, radiusMeters: radiusMeters) }
                        overpassHits += inside.count
                        for candidate in inside where seen.insert(candidate.osmID).inserted { out.append(candidate) }
                        if out.count >= limit { break cellLoop }
                    case .exhausted(let last):
                        overpassExhausted = true
                        lastResult = last
                        break cellLoop
                    case .stopped(let last):
                        lastResult = last
                        break cellLoop
                    }
                }
            }
            // Photon only when Overpass returned nothing inside the circle for this selector (as before tiling).
            if overpassHits == 0 {
                let (found, photonResult) = await photonAudited(key: parts[0], value: parts[1], latitude: latitude, longitude: longitude, limit: limit)
                for candidate in found where seen.insert(candidate.osmID).inserted { out.append(candidate) }
                if photonResult == "ok" {
                    outcomes.append(SelectorOutcome(selector: selector, provider: Self.photon, result: "ok"))
                } else if let answeredBy {
                    outcomes.append(SelectorOutcome(selector: selector, provider: answeredBy, result: "ok"))
                } else {
                    outcomes.append(SelectorOutcome(selector: selector, provider: nil, result: photonResult))
                }
            } else {
                outcomes.append(SelectorOutcome(selector: selector, provider: answeredBy, result: answeredBy == nil ? lastResult : "ok"))
            }
            if out.count >= limit { break }
        }
        return (Array(out.prefix(limit)), outcomes)
    }

    /// OSM keys and values only: letters, digits, `_`, `:` and `-`. Nothing else can reach a discovery host.
    static func isTag(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 40 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_:-".contains($0)) }
    }

    static func overpassQuery(key: String, value: String, latitude: Double, longitude: Double, radius: Int, limit: Int,
                              timeoutSeconds: Int = ICPConfig.DiscoveryQuery.standard.overpassQueryTimeoutSeconds) -> String {
        let r = min(max(radius, 100), 50_000)
        return "[out:json][timeout:\(timeoutSeconds)];nwr[\"\(key)\"=\"\(value)\"][\"name\"](around:\(r),\(String(format: "%.5f", latitude)),\(String(format: "%.5f", longitude)));out center tags \(min(max(limit, 1), 200));"
    }

    // MARK: - Smaller query areas (Water 7:49)

    static let metersPerDegreeLatitude = 111_320.0

    /// Splits a search circle into cells of `tileRadiusMeters` (icp.json `discovery_query.tile_radius_meters`) so each
    /// Overpass query covers a smaller area. Cells sit on a square grid whose squares are inscribed in each cell's circle
    /// (spacing r·√2), so the cells together cover every point of the original circle; cells whose square misses the circle
    /// are left out. Odd grid, centre cell first, then outward. A circle no larger than one cell stays one query.
    static func tiles(latitude: Double, longitude: Double, radiusMeters: Int, tileRadiusMeters: Int) -> [Tile] {
        guard tileRadiusMeters > 0, radiusMeters > tileRadiusMeters else {
            return [Tile(latitude: latitude, longitude: longitude, radiusMeters: radiusMeters)]
        }
        let r = Double(radiusMeters), step = Double(tileRadiusMeters) * 2.0.squareRoot()
        var n = Int((2 * r / step).rounded(.up))
        if n % 2 == 0 { n += 1 }
        let half = Double(n - 1) / 2
        var offsets: [(dx: Double, dy: Double)] = []
        for i in 0..<n {
            for j in 0..<n {
                let dx = (Double(i) - half) * step, dy = (Double(j) - half) * step
                let nx = max(abs(dx) - step / 2, 0), ny = max(abs(dy) - step / 2, 0)
                if nx * nx + ny * ny <= r * r { offsets.append((dx, dy)) }
            }
        }
        offsets.sort { a, b in
            let da = a.dx * a.dx + a.dy * a.dy, db = b.dx * b.dx + b.dy * b.dy
            return abs(da - db) > 1e-6 ? da < db : atan2(a.dy, a.dx) < atan2(b.dy, b.dx)
        }
        let metersPerDegreeLongitude = metersPerDegreeLatitude * cos(latitude * .pi / 180)
        return offsets.map {
            Tile(latitude: latitude + $0.dy / metersPerDegreeLatitude, longitude: longitude + $0.dx / metersPerDegreeLongitude,
                 radiusMeters: tileRadiusMeters)
        }
    }

    /// Great-circle distance in metres.
    static func distanceMeters(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let dLat = (bLat - aLat) * .pi / 180, dLon = (bLon - aLon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(aLat * .pi / 180) * cos(bLat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6_371_000 * asin(min(1, h.squareRoot()))
    }

    /// Cells overhang the circle at its edge; a hit there is outside the requested search and is dropped, so the
    /// coverage stays exactly the original circle. A hit without coordinates is kept.
    static func isInside(_ candidate: LeadCandidate, latitude: Double, longitude: Double, radiusMeters: Int) -> Bool {
        if candidate.latitude == 0 && candidate.longitude == 0 { return true }
        return distanceMeters(latitude, longitude, candidate.latitude, candidate.longitude) <= Double(radiusMeters)
    }

    // MARK: - Overpass servers and retries

    /// Overpass servers in order: overpass.private.coffee is primary, overpass-api.de is the fallback (Water, 6:30 AM ET).
    static let overpassServers = [overpass, URL(string: "https://overpass-api.de/api/interpreter")!]

    /// What one Overpass attempt produced.
    enum OverpassAttempt: Equatable, Sendable {
        case answered([LeadCandidate])
        /// Timeout, network error, 429 or 5xx: worth another attempt after a backoff. `retryAfter` is the server's own wait.
        case retryable(retryAfter: Double?)
        /// A refusal (allowlist, payload, bot challenge) or another 4xx: stop asking Overpass.
        case stop

    }

    /// The real result of one request for the audit: ok, error:<status>, error:network or the refusal code.
    static func auditResult(status: Int) -> String { (200..<300).contains(status) ? "ok" : "error:\(status)" }

    /// What one cell's query produced across all servers.
    enum OverpassOutcome: Equatable, Sendable {
        case answered([LeadCandidate], server: URL)
        /// Every server used up its retries; the last attempt's real result.
        case exhausted(String)
        /// A refusal or non-retryable 4xx, with its real result.
        case stopped(String)
    }

    /// Backoff before retry `retry` (1-based) on one host: base·2^(retry−1), stretched by up to `jitterFraction` (jitter in
    /// [0, 1]), never below the server's Retry-After, never above `maxDelaySeconds`.
    static func backoffSeconds(retry: Int, policy: ICPConfig.DiscoveryRetry, jitter: Double, serverWait: Double?) -> Double {
        let exponential = policy.baseDelaySeconds * pow(2, Double(max(retry, 1) - 1))
        let stretched = exponential * (1 + max(policy.jitterFraction, 0) * min(max(jitter, 0), 1))
        return min(max(stretched, serverWait ?? 0), policy.maxDelaySeconds)
    }

    /// Asks each server in turn: one try plus `retries_per_host` retries, backoff counted per host. Same tag-and-coordinate
    /// payload every time, the transport's identifying User-Agent, client timeout = the query's `[timeout:N]` + margin.
    func overpass(key: String, value: String, tile: Tile, limit: Int, shape: ICPConfig.DiscoveryQuery) async -> OverpassOutcome {
        let query = Self.overpassQuery(key: key, value: value, latitude: tile.latitude, longitude: tile.longitude, radius: tile.radiusMeters,
                                       limit: limit, timeoutSeconds: shape.overpassQueryTimeoutSeconds)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = Data("data=\(query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")".utf8)
        let policy = transport.config.etiquette.discoveryRetry ?? .standard
        let attemptsPerHost = 1 + max(policy.retriesPerHost, 0)
        var last = "error:no-answer"
        for server in Self.overpassServers {
            var serverWait: Double?
            for number in 1...attemptsPerHost {
                if number > 1 {
                    await transport.backoff(seconds: Self.backoffSeconds(retry: number - 1, policy: policy, jitter: jitter(), serverWait: serverWait))
                }
                let meter = LeadWaitMeter()
                let (result, audited) = await attempt(server, body: body, via: "overpass \(key)=\(value)", timeout: shape.clientTimeoutSeconds, meter: meter)
                transport.auditDiscoveryAttempt(server, attempt: number, of: attemptsPerHost, result: audited, waitMilliseconds: meter.milliseconds)
                last = audited
                switch result {
                case .answered(let found): return .answered(found, server: server)
                case .stop: return .stopped(audited)
                case .retryable(let retryAfter): serverWait = retryAfter
                }
            }
        }
        return .exhausted(last)
    }

    func attempt(_ server: URL, body: Data, via: String, timeout: Double, meter: LeadWaitMeter? = nil) async -> (OverpassAttempt, String) {
        do {
            let response = try await transport.fetch(server, purpose: .discovery, method: "POST", body: body,
                                                     headers: ["Content-Type": "application/x-www-form-urlencoded"], timeout: timeout, meter: meter)
            let audited = Self.auditResult(status: response.status)
            if (200..<300).contains(response.status) {
                let found = Self.parseOverpass(response.body, via: via).map { candidate -> LeadCandidate in
                    var candidate = candidate
                    candidate.provider = server
                    return candidate
                }
                return (.answered(found), audited)
            }
            if response.status == 429 || response.status >= 500 {
                return (.retryable(retryAfter: response.headers["retry-after"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }), audited)
            }
            return (.stop, audited)
        } catch let refusal as LeadPipelineRefusal {
            return (.stop, refusal.code)
        } catch {
            return (.retryable(retryAfter: nil), "error:network")
        }
    }

    func photon(key: String, value: String, latitude: Double, longitude: Double, limit: Int) async throws -> [LeadCandidate] {
        await photonAudited(key: key, value: value, latitude: latitude, longitude: longitude, limit: limit).candidates
    }

    /// One Photon request (unchanged query), audited like an Overpass attempt with its real result and wait.
    func photonAudited(key: String, value: String, latitude: Double, longitude: Double, limit: Int) async -> (candidates: [LeadCandidate], result: String) {
        guard let url = Self.photonURL(key: key, value: value, latitude: latitude, longitude: longitude, limit: limit) else { return ([], "refused:photon-url") }
        let meter = LeadWaitMeter()
        var found: [LeadCandidate] = []
        var audited: String
        do {
            let response = try await transport.fetch(url, purpose: .discovery, meter: meter)
            audited = Self.auditResult(status: response.status)
            if (200..<300).contains(response.status) {
                found = Self.parsePhoton(response.body, via: "photon \(key)=\(value)").map { candidate -> LeadCandidate in
                    var candidate = candidate
                    candidate.provider = Self.photon
                    return candidate
                }
            }
        } catch let refusal as LeadPipelineRefusal {
            audited = refusal.code
        } catch {
            audited = "error:network"
        }
        transport.auditDiscoveryAttempt(Self.photon, attempt: 1, of: 1, result: audited, waitMilliseconds: meter.milliseconds)
        return (found, audited)
    }

    /// The Photon request for one selector: the tag, the circle centre and the limit, nothing else.
    static func photonURL(key: String, value: String, latitude: Double, longitude: Double, limit: Int) -> URL? {
        var components = URLComponents(url: Self.photon, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: value.replacingOccurrences(of: "_", with: " ")),
            URLQueryItem(name: "osm_tag", value: "\(key):\(value)"),
            URLQueryItem(name: "lat", value: String(format: "%.5f", latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.5f", longitude)),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))
        ]
        return components.url
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
                                 city: tags["addr:city"], latitude: lat, longitude: lon, discoveredVia: via,
                                 closed: ProspectIdentity.isClosed(tags: tags, name: name))
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
                                 longitude: coordinates.first ?? 0, discoveredVia: via,
                                 closed: ProspectIdentity.isClosed(tags: [:], name: name))
        }
    }
}

/// Water 9:02 AM ET: both Overpass servers stay in config; the live proof may start as soon as one probe on either server
/// answers, and probes run at most once every 5 minutes (the servers' usage policy).
enum OverpassProbe {
    static let minimumIntervalSeconds: Double = 300

    /// One server's probe: its real result (ok, error:<status>, error:network or a refusal code) and measured wait.
    struct HostResult: Equatable, Sendable {
        var server: URL
        var result: String
        var waitMilliseconds: Int?
    }

    /// One small query, one attempt per server (no retries), servers in config order, stopping at the first that answers.
    static func probe(_ discovery: LeadDiscovery, latitude: Double = 45.5017, longitude: Double = -73.5673) async -> [HostResult] {
        []
    }

    static func liveRunMayStart(_ results: [HostResult]) -> Bool { false }

    static func mayProbe(lastProbe: Date?, now: Date) -> Bool { true }
}
