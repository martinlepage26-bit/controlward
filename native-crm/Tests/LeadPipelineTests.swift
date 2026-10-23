import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Correctness tests for the Slice 3 pipeline (not planted reds). Synthetic data only.
enum LeadPipelineTests {
    static func run() async -> Bool {
        let config: ICPConfig
        let confirmed: ICPConfirmed
        do {
            config = try LeadKit.config()
            confirmed = try LeadKit.confirmed()
        } catch {
            print("  FAIL lead pipeline: config did not load: \(error)")
            return false
        }
        let now = LeadKit.now
        let expect = PortableCheck.expect

        return await PortableCheck.suite("Lead pipeline", [
            ("ICP config: seven confirmed segments, equal priority, valid", {
                try expect(config.validate(against: confirmed) == nil, "config should validate: \(String(describing: config.validate(against: confirmed)))")
                try expect(config.segments.count == 7 && Set(config.segments.map(\.priority)).count == 1, "7 equal-priority segments")
                try expect(config.conflictAreas.first?.description == "plumbing, excavation and related trades in the city of Saguenay (its boroughs and merged former towns)", "default conflict area: \(String(describing: config.conflictAreas.first?.description))")
                try expect(config.sender.from == "ml@pharos-ai.ca" && config.sender.mailingAddress == "2456 rue de Rouen, Montréal QC H2K 1M2", "sender identity")
                try expect(config.loi25Gate.open == false, "Loi 25 gate starts closed")
            }),
            ("ICP config: clinic and trades take named people from the own site only", {
                // Water, 6:30 AM ET: the list stays in config; only own_site is enabled.
                for id in config.segments.map(\.id) where config.segment(id)?.triggerRule == "same_day" {
                    let segment = try unwrap(config.segment(id), id)
                    try expect(Set(segment.allowedContactSources) == ["own_site", "registraire_des_entreprises", "professional_order_directory"], "\(id) lists \(segment.allowedContactSources)")
                    try expect(config.enabledContactSources(for: segment) == ["own_site"], "\(id) enabled \(config.enabledContactSources(for: segment))")
                }
            }),
            ("Sources: a disabled contact source is never fetched", {
                let disabledIDs = ["registraire_des_entreprises", "professional_order_directory"]
                let hosts = config.allowlist.disabledSources.filter { disabledIDs.contains($0.id) && !$0.enabled }.flatMap(\.hosts)
                try expect(Set(config.allowlist.disabledSources.filter { !$0.enabled }.map(\.id)).isSuperset(of: disabledIDs), "both listed as disabled")
                try expect(!hosts.isEmpty, "disabled hosts present")
                let inner = FakeLeadTransport()
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
                for host in hosts {
                    for purpose in [FetchPurpose.ownSite(domain: host), .discovery, .watch] {
                        do { _ = try await guarded.fetch(URL(string: "https://\(host)/")!, purpose: purpose); throw PortableCheckFailure(description: "\(host) fetched") }
                        catch let refusal as LeadPipelineRefusal { try expect(refusal.code.hasPrefix("refused:"), refusal.code) }
                    }
                }
                try expect(inner.requests.isEmpty, "0 requests, got \(inner.urls)")
                var record = LeadKit.readyClinic()
                record.contact?.source = .registraire
                try expect(LeadDefinition.namedPerson(record, segment: try unwrap(config.segment("clinic"), "clinic"), config: config) == "no named person", "registraire person refused")
                let fixture = SearchFixture(config: config)
                _ = await fixture.run()
                let disabledHosts = Set(config.allowlist.disabledSources.filter { !$0.enabled }.flatMap(\.hosts))
                try expect(!fixture.inner.requests.contains { disabledHosts.contains($0.url?.host ?? "") }, "search run touched a disabled source")
            }),
            ("Discovery: overpass.private.coffee is primary, answers alone and gets an identifying User-Agent", {
                let inner = FakeLeadTransport()
                inner.respond(LeadDiscovery.overpass.absoluteString, body: LeadKit.overpassOneClinic, headers: ["content-type": "application/json"])
                let clock = FakeLeadClock()
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: clock)
                let found = await LeadDiscovery(transport: guarded).search(selectors: ["healthcare=clinic"], latitude: 45.5, longitude: -73.6, radiusMeters: 1000, limit: 5)
                try expect(found.count == 1, "found \(found.count)")
                try expect(inner.requests.compactMap { $0.url?.host } == ["overpass.private.coffee"], "hosts \(inner.urls)")
                let agent = inner.requests.first?.value(forHTTPHeaderField: "User-Agent") ?? ""
                try expect(agent.hasPrefix("ControlWard/") && agent.contains("contact "), "identifying UA, got \(agent)")
                try expect(clock.sleeps.isEmpty, "no backoff on success: \(clock.sleeps)")
            }),
            ("Discovery: a private.coffee timeout is retried twice with backoff, then overpass-api.de answers with tags and coordinates only", {
                try expect(config.allowlist.discoveryHosts.contains("overpass-api.de"), "overpass-api.de allowlisted")
                let inner = FakeLeadTransport()
                inner.fail(LeadDiscovery.overpass.absoluteString, URLError(.timedOut))
                inner.respond("https://overpass-api.de/api/interpreter", body: LeadKit.overpassOneClinic, headers: ["content-type": "application/json"])
                let clock = FakeLeadClock()
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: clock)
                let found = await LeadDiscovery(transport: guarded, jitter: { 0 }).search(selectors: ["healthcare=clinic"], latitude: 45.5, longitude: -73.6, radiusMeters: 1000, limit: 5)
                try expect(found.count == 1, "found \(found.count)")
                try expect(inner.requests.compactMap { $0.url?.host } == ["overpass.private.coffee", "overpass.private.coffee", "overpass.private.coffee", "overpass-api.de"], "hosts \(inner.urls)")
                try expect(clock.sleeps == [5, 10], "exponential backoff 5 s then 10 s on private.coffee, none before the first overpass-api.de try: \(clock.sleeps)")
                try expect(inner.requests.allSatisfy { ($0.value(forHTTPHeaderField: "User-Agent") ?? "").hasPrefix("ControlWard/") }, "UA on every Overpass request (overpass-api.de answers 406 without one)")
                let bodies = inner.requests.compactMap { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } }
                let query = LeadDiscovery.overpassQuery(key: "healthcare", value: "clinic", latitude: 45.5, longitude: -73.6, radius: 1000, limit: 5)
                try expect(bodies.count == 4 && Set(bodies).count == 1, "same payload to both servers")
                try expect(bodies[3].removingPercentEncoding == "data=" + query, "payload is the tag query only: \(bodies[3])")
                try expect(!bodies[3].contains("%40") && !bodies[3].contains("@") && !bodies[3].lowercased().contains("clinique"), "no contact data")
                try expect(!inner.urls.contains { $0.contains("photon") }, "Photon not needed")
            }),
            ("Discovery: 429 honours Retry-After and 5xx backs off before the retry", {
                let inner = FakeLeadTransport()
                inner.enqueue(LeadDiscovery.overpass.absoluteString, status: 429, body: "rate limited", headers: ["retry-after": "30"])
                inner.respond(LeadDiscovery.overpass.absoluteString, body: LeadKit.overpassOneClinic, headers: ["content-type": "application/json"])
                let clock = FakeLeadClock()
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: clock)
                let found = await LeadDiscovery(transport: guarded, jitter: { 0 }).search(selectors: ["healthcare=clinic"], latitude: 45.5, longitude: -73.6, radiusMeters: 1000, limit: 5)
                try expect(found.count == 1 && inner.requests.count == 2, "retried once: \(inner.urls)")
                try expect(clock.sleeps == [30], "Retry-After 30 s honoured, got \(clock.sleeps)")
                let inner5 = FakeLeadTransport()
                inner5.enqueue(LeadDiscovery.overpass.absoluteString, status: 504, body: "gateway timeout")
                inner5.respond(LeadDiscovery.overpass.absoluteString, body: LeadKit.overpassOneClinic, headers: ["content-type": "application/json"])
                let clock5 = FakeLeadClock()
                let guarded5 = GuardedLeadTransport(config: config, inner: inner5, audit: MemoryAuditSink(), clock: clock5)
                let found5 = await LeadDiscovery(transport: guarded5, jitter: { 0 }).search(selectors: ["healthcare=clinic"], latitude: 45.5, longitude: -73.6, radiusMeters: 1000, limit: 5)
                try expect(found5.count == 1 && inner5.requests.compactMap { $0.url?.host } == ["overpass.private.coffee", "overpass.private.coffee"], "504 retried on the same server: \(inner5.urls)")
                try expect(clock5.sleeps.first == 5 && clock5.sleeps.reduce(0, +) >= 10, "5 s backoff, then the 10 s per-host fair-use spacing: \(clock5.sleeps)")
            }),
            ("Discovery timeout (Water 7:49): the client waits the query's own [timeout:N] plus 10 s, both from one config value", {
                let shape = config.etiquette.discoveryQuery ?? .standard
                try expect(config.etiquette.discoveryQuery != nil, "icp.json carries discovery_query")
                try expect(shape.clientTimeoutMarginSeconds == 10, "margin is 10 s, got \(shape.clientTimeoutMarginSeconds)")
                try expect(shape.overpassQueryTimeoutSeconds == 60 && shape.clientTimeoutSeconds == 70, "Water 8:20: [timeout:60], client 70 s; got \(shape.overpassQueryTimeoutSeconds) / \(shape.clientTimeoutSeconds)")
                let inner = FakeLeadTransport()
                inner.respond(LeadDiscovery.overpass.absoluteString, body: LeadKit.overpassOneClinic, headers: ["content-type": "application/json"])
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
                _ = await LeadDiscovery(transport: guarded, jitter: { 0 }).search(selectors: ["healthcare=clinic"], latitude: 45.5, longitude: -73.6, radiusMeters: 1000, limit: 5)
                let posts = inner.requests.filter { $0.httpMethod == "POST" }
                try expect(!posts.isEmpty, "an Overpass query was sent")
                for request in posts {
                    let body = (request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "").removingPercentEncoding ?? ""
                    guard let open = body.range(of: "[timeout:"), let close = body[open.upperBound...].firstIndex(of: "]"),
                          let limit = Int(body[open.upperBound..<close]) else { throw PortableCheckFailure(description: "no [timeout:N] in \(body)") }
                    try expect(limit == shape.overpassQueryTimeoutSeconds, "query limit \(limit) comes from config (\(shape.overpassQueryTimeoutSeconds))")
                    try expect(request.timeoutInterval == Double(limit + 10), "client timeout \(request.timeoutInterval) s must be the query's [timeout:\(limit)] + 10 s")
                    try expect(request.timeoutInterval > Double(limit), "client gives up after the server's own limit, not at the same moment")
                }
            }),
            ("Discovery retries (Water 7:49): each Overpass host is retried at most 2 times with bounded, jittered, increasing backoff; every attempt audited", {
                let policy = config.etiquette.discoveryRetry ?? .standard
                try expect(policy.retriesPerHost == 2 && policy.jitterFraction > 0 && policy.jitterFraction <= 0.5, "config: 2 retries per host with jitter, got \(policy)")
                let inner = FakeLeadTransport()
                for server in LeadDiscovery.overpassServers { inner.fail(server.absoluteString, URLError(.timedOut)) }
                let clock = FakeLeadClock()
                let audit = MemoryAuditSink()
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: audit, clock: clock)
                _ = await LeadDiscovery(transport: guarded, jitter: { 0.5 }).search(selectors: ["healthcare=clinic"], latitude: 45.5, longitude: -73.6, radiusMeters: 1000, limit: 5)
                let hosts = inner.requests.compactMap { $0.url?.host }
                try expect(hosts.filter { $0 == "overpass.private.coffee" }.count == 3 && hosts.filter { $0 == "overpass-api.de" }.count == 3,
                           "1 try + 2 retries per host, then give up: \(hosts)")
                try expect(Array(hosts.prefix(6)) == ["overpass.private.coffee", "overpass.private.coffee", "overpass.private.coffee", "overpass-api.de", "overpass-api.de", "overpass-api.de"], "order \(hosts)")
                try expect(hosts.dropFirst(6).allSatisfy { $0 == "photon.komoot.io" }, "after both hosts give up, only Photon: \(hosts)")
                let first = 5 * (1 + policy.jitterFraction * 0.5), second = 10 * (1 + policy.jitterFraction * 0.5)
                try expect(clock.sleeps == [first, second, first, second], "per-host backoff \(first) s then \(second) s, got \(clock.sleeps)")
                let fetches = audit.lines.filter { $0.action == "fetch" && ($0.target == "overpass.private.coffee" || $0.target == "overpass-api.de") }
                try expect(fetches.count == 6 && fetches.allSatisfy { $0.result == "error:network" }, "each attempt audited as a fetch: \(fetches.map(\.text))")
                let attempts = audit.lines.filter { $0.action == "discovery-attempt" && $0.target != "photon.komoot.io" }
                try expect(attempts.map { $0.receipt.components(separatedBy: ",").first ?? "" } == ["attempt-1-of-3", "attempt-2-of-3", "attempt-3-of-3", "attempt-1-of-3", "attempt-2-of-3", "attempt-3-of-3"],
                           "each attempt audited with its number: \(attempts.map(\.text))")
                try expect(attempts.allSatisfy { $0.result == "error:network" }, "attempt results: \(attempts.map(\.result))")
                for retry in 1...12 {
                    let high = LeadDiscovery.backoffSeconds(retry: retry, policy: policy, jitter: 1, serverWait: nil)
                    let low = LeadDiscovery.backoffSeconds(retry: retry, policy: policy, jitter: 0, serverWait: nil)
                    try expect(low <= high && high <= policy.maxDelaySeconds, "retry \(retry): \(low)...\(high) bounded by \(policy.maxDelaySeconds)")
                    if retry > 1 { try expect(low >= LeadDiscovery.backoffSeconds(retry: retry - 1, policy: policy, jitter: 0, serverWait: nil), "backoff never shrinks") }
                }
            }),
            ("Search audit (Earth 8:19): the search line names the provider that actually answered; every host attempt has its real result; never ok for a failed Overpass call", {
                let fixture = SearchFixture(config: config)
                for server in LeadDiscovery.overpassServers { fixture.inner.fail(server.absoluteString, URLError(.notConnectedToInternet)) }
                let selectors = try unwrap(config.segment("clinic"), "clinic segment").osmSelectors
                let first = selectors[0].split(separator: "=").map(String.init)
                let photonURL = try unwrap(LeadDiscovery.photonURL(key: first[0], value: first[1], latitude: 45.5, longitude: -73.6, limit: 5), "photon url")
                fixture.inner.respond(photonURL.absoluteString, body: #"{"features":[{"type":"Feature","geometry":{"coordinates":[-73.6,45.5]},"properties":{"name":"Clinique Photon Test","osm_type":"N","osm_id":4001,"osm_key":"healthcare","osm_value":"clinic"}}]}"#,
                                      headers: ["content-type": "application/json"])
                _ = await fixture.run()
                let lines = fixture.audit.lines
                let overpassHosts = Set(LeadDiscovery.overpassServers.compactMap { $0.host })
                let overpassAttempts = lines.filter { $0.action == "discovery-attempt" && overpassHosts.contains($0.target) }
                try expect(overpassAttempts.count == 6 && overpassAttempts.allSatisfy { $0.result == "error:network" },
                           "each Overpass attempt records its real result: \(overpassAttempts.map { "\($0.target) \($0.result)" })")
                let photonAttempts = lines.filter { $0.action == "discovery-attempt" && $0.target == "photon.komoot.io" }
                try expect(photonAttempts.first?.result == "ok" && photonAttempts.count == selectors.count, "Photon attempts audited: \(photonAttempts.map(\.result))")
                try expect(photonAttempts.dropFirst().allSatisfy { $0.result == "error:404" }, "unanswered Photon selectors: \(photonAttempts.map(\.result))")
                let searches = lines.filter { $0.action == "search" }
                try expect(!searches.contains { $0.register.contains("overpass") && $0.result == "ok" }, "no search line says ok for Overpass: \(searches.map(\.text))")
                try expect(searches.contains { $0.register == CWAuditLine.register(for: LeadDiscovery.photon) && $0.result == "ok" }, "the search line names Photon as the provider that answered: \(searches.map(\.text))")
                try expect(searches.filter { $0.result != "ok" }.allSatisfy { $0.result.hasPrefix("error:") }, "a selector nobody answered is an error: \(searches.map(\.result))")
                let okFixture = SearchFixture(config: config)
                _ = await okFixture.run()
                let okSearches = okFixture.audit.lines.filter { $0.action == "search" && $0.result == "ok" }
                try expect(!okSearches.isEmpty && okSearches.allSatisfy { $0.register == CWAuditLine.register(for: LeadDiscovery.overpass) || $0.register == CWAuditLine.register(for: LeadDiscovery.photon) },
                           "when private.coffee answers, it is the named provider: \(okSearches.map(\.register))")
                try expect(okSearches.contains { $0.register == CWAuditLine.register(for: LeadDiscovery.overpass) }, "private.coffee named: \(okSearches.map(\.register))")
                try expect(okFixture.audit.lines.filter { $0.action == "discovery-attempt" && $0.target == "overpass.private.coffee" }.allSatisfy { $0.result == "ok" }, "answered attempts are ok")
            }),
            ("Skip audit (Earth 8:19): every skipped candidate gets an audit line with its provider, map id and reason", {
                let fixture = SearchFixture(config: config)
                fixture.inner.respond(LeadDiscovery.overpass.absoluteString, body: """
                {"elements":[{"type":"node","id":1001,"lat":45.5,"lon":-73.6,"tags":{"name":"Clinique Exemple Nord","healthcare":"clinic","website":"https://www.clinique-exemple.test","addr:city":"Montréal"}},{"type":"node","id":1002,"lat":45.5,"lon":-73.6,"tags":{"name":"Clinique Sans Site","healthcare":"clinic"}},{"type":"node","id":1003,"lat":45.5,"lon":-73.6,"tags":{"name":"Clinique Fermée Test","healthcare":"clinic","disused:healthcare":"clinic","website":"https://www.fermee.test"}}]}
                """, headers: ["content-type": "application/json"])
                let report = await fixture.run()
                try expect(report.skipped["osm:node/1002"] == "no own website on the listing", "skipped \(report.skipped)")
                let skips = fixture.audit.lines.filter { $0.action == "skip" }
                try expect(skips.count == report.skipped.count, "one skip line per skipped candidate: \(skips.count) lines for \(report.skipped.count) skipped")
                for (id, reason) in report.skipped {
                    let line = try unwrap(skips.first { $0.target == id }, "skip line for \(id)")
                    try expect(line.source == "overpass.private.coffee" && line.register == CWAuditLine.register(for: LeadDiscovery.overpass),
                               "\(id): provider recorded, got source=\(line.source) register=\(line.register)")
                    try expect(line.result == "skipped:" + ProspectSearchRun.reasonCode(reason) && line.receipt == "test-run", "\(id): reason recorded, got \(line.text)")
                }
                try expect(skips.contains { $0.target == "osm:node/1002" && $0.result == "skipped:no-own-website-on-the-listing" }, "no-website skip: \(skips.map(\.text))")
            }),
            ("Wait time (Earth 8:20): each Overpass host attempt logs how long the query actually waited, in ms", {
                let inner = FakeLeadTransport()
                inner.enqueue(LeadDiscovery.overpass.absoluteString, status: 504, body: "gateway timeout")
                inner.respond(LeadDiscovery.overpass.absoluteString, body: LeadKit.overpassOneClinic, headers: ["content-type": "application/json"])
                let clock = FakeLeadClock()
                let waits = [32.418, 1.5]
                let counter = NSLock()
                nonisolated(unsafe) var sent = 0
                inner.onSend = { _ in
                    let index = counter.withLock { () -> Int in sent += 1; return sent - 1 }
                    clock.advance(waits[min(index, waits.count - 1)])
                }
                let audit = MemoryAuditSink()
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: audit, clock: clock)
                _ = await LeadDiscovery(transport: guarded, jitter: { 0 }).search(selectors: ["healthcare=clinic"], latitude: 45.5, longitude: -73.6, radiusMeters: 1000, limit: 5)
                let attempts = audit.lines.filter { $0.action == "discovery-attempt" }
                try expect(attempts.map(\.receipt) == ["attempt-1-of-3,wait-32418ms", "attempt-2-of-3,wait-1500ms"], "wait per attempt: \(attempts.map(\.receipt))")
                try expect(attempts.map(\.result) == ["error:504", "ok"], "results \(attempts.map(\.result))")
            }),
            ("Discovery tiles (Water 7:49): a 3 km search is split into 1 km cells from config that cover the same circle; hits outside it are dropped", {
                let shape = config.etiquette.discoveryQuery ?? .standard
                try expect(shape.tileRadiusMeters > 0 && shape.tileRadiusMeters < 3000, "tile radius from config: \(shape.tileRadiusMeters)")
                let lat = 45.5017, lon = -73.5673
                let tiles = LeadDiscovery.tiles(latitude: lat, longitude: lon, radiusMeters: 3000, tileRadiusMeters: shape.tileRadiusMeters)
                func meters(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
                    let r = 6_371_000.0, dLat = (bLat - aLat) * .pi / 180, dLon = (bLon - aLon) * .pi / 180
                    let h = sin(dLat / 2) * sin(dLat / 2) + cos(aLat * .pi / 180) * cos(bLat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
                    return 2 * r * asin(min(1, sqrt(h)))
                }
                try expect(tiles.count > 1, "3 km is split, got \(tiles.count) tile(s)")
                try expect(tiles.allSatisfy { $0.radiusMeters <= shape.tileRadiusMeters }, "every query covers at most \(shape.tileRadiusMeters) m")
                try expect(meters(lat, lon, tiles[0].latitude, tiles[0].longitude) < 1, "centre cell first")
                try expect(tiles.allSatisfy { meters(lat, lon, $0.latitude, $0.longitude) <= 3000 + Double($0.radiusMeters) }, "no cell entirely outside the circle")
                var uncovered = 0
                for dy in stride(from: -3000.0, through: 3000, by: 100) {
                    for dx in stride(from: -3000.0, through: 3000, by: 100) where dx * dx + dy * dy <= 3000 * 3000 {
                        let pLat = lat + dy / 111_320, pLon = lon + dx / (111_320 * cos(lat * .pi / 180))
                        if !tiles.contains(where: { meters(pLat, pLon, $0.latitude, $0.longitude) <= Double($0.radiusMeters) + 1 }) { uncovered += 1 }
                    }
                }
                try expect(uncovered == 0, "\(uncovered) sample points of the 3 km circle are in no cell")
                try expect(LeadDiscovery.tiles(latitude: lat, longitude: lon, radiusMeters: 800, tileRadiusMeters: 1000) == [LeadDiscovery.Tile(latitude: lat, longitude: lon, radiusMeters: 800)],
                           "a circle no larger than a cell is one query")
                let near = #"{"type":"node","id":3001,"lat":45.5017,"lon":-73.5673,"tags":{"name":"Clinique Centre Test","healthcare":"clinic","website":"https://www.centre.test"}}"#
                let far = #"{"type":"node","id":3002,"lat":45.5467,"lon":-73.5673,"tags":{"name":"Clinique Loin Test","healthcare":"clinic","website":"https://www.loin.test"}}"#
                let inner = FakeLeadTransport()
                inner.respond(LeadDiscovery.overpass.absoluteString, body: #"{"elements":["# + near + "," + far + "]}", headers: ["content-type": "application/json"])
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
                let found = await LeadDiscovery(transport: guarded, jitter: { 0 }).search(selectors: ["healthcare=clinic"], latitude: lat, longitude: lon, radiusMeters: 3000, limit: 5)
                try expect(found.map(\.osmID) == ["osm:node/3001"], "only the hit inside 3 km is kept: \(found.map(\.osmID))")
                let posts = inner.requests.filter { $0.httpMethod == "POST" }
                try expect(posts.count == tiles.count, "one Overpass query per cell until the limit: \(posts.count) for \(tiles.count) cells")
                let bodies = posts.compactMap { $0.httpBody.map { String(decoding: $0, as: UTF8.self).removingPercentEncoding ?? "" } }
                try expect(bodies.allSatisfy { $0.contains("around:\(shape.tileRadiusMeters),") }, "each query asks for a \(shape.tileRadiusMeters) m cell")
            }),
            ("ICP source scan: no hard-coded segment list in Sources", {
                let files = (try FileManager.default.contentsOfDirectory(at: LeadKit.sourcesDirectory, includingPropertiesForKeys: nil))
                    .filter { $0.pathExtension == "swift" }
                try expect(files.count > 10, "found the Sources directory (\(files.count) files)")
                for file in files {
                    let hits = ICPSourceScanner.hardCodedSegments(in: try String(contentsOf: file, encoding: .utf8), segmentIDs: confirmed.segments)
                    try expect(hits.isEmpty, "\(file.lastPathComponent) hard-codes \(hits)")
                }
            }),
            ("Allowlist: registry rulings are explicit deny or held entries", {
                for host in ["www.registreentreprises.gouv.qc.ca", "pes.rbq.gouv.qc.ca", "ooq.connexence.com", "oppq.connexence.com",
                             "abc123-dsn.algolia.net", "www.ordrepsy.qc.ca", "www.omvq.qc.ca"] {
                    try expect(config.deniedHost(host) != nil, "\(host) must be denied")
                }
                for host in ["www.cmq.org", "www.odq.qc.ca", "www.opq.org", "oppq.qc.ca", "www.ooq.org", "espace-membre-ocq.eudonet.com", "www.rbq.gouv.qc.ca"] {
                    try expect(config.disabledSource(forHost: host)?.enabled == false, "\(host) must be held/disabled")
                }
                try expect(config.deniedHost("www.rbq.gouv.qc.ca") == nil && config.deniedHost("rbq.gouv.qc.ca") == nil, "pes host rule is exact")
            }),
            ("Allowlist: RBQ open data is on, with exactly one download link: the JSON file", {
                let source = try unwrap(RBQOpenData.source(config), "rbq source")
                try expect(source.host == "www.donneesquebec.ca" && source.minSecondsBetweenRequests == 10 && source.maxDownloadAgeHours == 24, "host, delay, daily")
                try expect(source.downloadUrls == [
                    "https://www.donneesquebec.ca/recherche/dataset/755b45d6-7aee-46df-a216-748a0191c79f/resource/5183fdd4-55b1-418c-8a7d-0a70058ed68d/download/rdl01_extractiondonneesouvertes.json"
                ], "download URLs \(source.downloadUrls)")
                try expect(source.attribution == "Source: RBQ / Données Québec, CC BY 4.0" && source.label == "RBQ / Données Québec, CC BY 4.0", "attribution strings")
                try expect(Set(source.neverStoredFields).isSuperset(of: ["Courriel", "Numéro de téléphone", "Mandataire"]), "never-stored fields")
            }),
            ("LEAD_DEF table: ready clinic is Ready", {
                let verdict = LeadDefinition.evaluate(LeadKit.readyClinic(), config: config, now: now)
                try expect(verdict.status == .ready, "got \(verdict)")
            }),
            ("LEAD_DEF table: a role mailbox with no named person is Fix, with no draft (no role path)", {
                var lead = LeadKit.readyClinic()
                lead.contact = ProspectContact(name: "Réception", title: nil, titleSource: .checkedDirect, source: .ownSite, sourceURL: LeadKit.contactPage)
                let verdict = LeadDefinition.evaluate(lead, config: config, now: now)
                try expect(verdict.status == .fix && verdict.reasons.contains("no named person"), "got \(verdict)")
                let refusal = OutreachDraftGate.check(LeadKit.draft(for: lead, config: config), prospect: lead, config: config, suppression: SuppressionList(), now: now)
                try expect(refusal?.code == "refused:lead-def", "no draft: \(String(describing: refusal))")
            }),
            ("LEAD_DEF table: a person from the RBQ file or a held registry is not a named person", {
                for source in [ProspectDataSource.rbqOpenData, .registraire, .professionalOrder, .dataBroker, .linkedin] {
                    var lead = LeadKit.readyClinic()
                    lead.contact?.source = source
                    try expect(LeadDefinition.evaluate(lead, config: config, now: now).reasons.contains("no named person"), "\(source)")
                }
            }),
            ("LEAD_DEF table: institutional 89 days Ready, job posting older than 90 days Fix, gone trigger Fix, unknown segment Drop", {
                try expect(LeadDefinition.evaluate(LeadKit.university(fetchedDaysAgo: 89), config: config, now: now).status == .ready, "89 days")
                var job = LeadKit.university(fetchedDaysAgo: 1)
                job.trigger = ProspectTrigger(kind: "job_posting", url: LeadKit.homePage + "carrieres", fetchedAt: now, origin: .pageFetch,
                                              publishedAt: now.addingTimeInterval(-95 * 86_400))
                try expect(LeadDefinition.evaluate(job, config: config, now: now).reasons.contains("stale trigger"), "old posting")
                var gone = LeadKit.readyClinic()
                gone.trigger?.state = .gone
                try expect(LeadDefinition.evaluate(gone, config: config, now: now).reasons.contains("trigger gone"), "gone")
                var other = LeadKit.readyClinic()
                other.segment = "restaurant"
                try expect(LeadDefinition.evaluate(other, config: config, now: now).status == .drop, "drop")
            }),
            ("Risk line and trigger state are shown for each lead", {
                var lead = LeadKit.readyClinic()
                try expect(LeadDefinition.riskLine(lead) == "Low: own-site evidence, dated trigger.", "low")
                lead.trigger?.state = .changed
                try expect(LeadDefinition.riskLine(lead).hasPrefix("Trigger changed"), "changed")
                lead.openTenderURL = "https://www.seao.ca/x"
                try expect(LeadDefinition.riskLine(lead).hasPrefix("Open tender"), "tender")
                let lines = ProspectDisplay.lines(for: LeadKit.readyClinic(), config: config)
                try expect(lines.contains { $0.hasPrefix("Trigger (live)") } && lines.contains { $0.hasPrefix("Risk: ") }, "\(lines)")
            }),
            ("Recall fixture: an award notice turns a tender trigger gone (synthetic, SAAQ-like)", {
                let open = WatchItem(id: "t-1", title: "Services-conseils IA", link: "https://www.seao.ca/avis/t-1", organisation: "Société Fictive de l'Assurance",
                                     deadline: now.addingTimeInterval(10 * 86_400), status: "Ouvert")
                var awarded = open
                awarded.status = "Adjugé"
                try expect(TenderWatcher.state(previous: open, current: awarded) == .gone, "award = gone")
                try expect(TenderWatcher.openTender(for: "Société Fictive de l'Assurance", in: [awarded], now: now) == nil, "no open tender after award")
                try expect(TenderWatcher.openTender(for: "Société Fictive de l'Assurance", in: [open], now: now) != nil, "open before award")
            }),
            ("Recall fixture: a deadline moved to Nov 5 is a changed trigger (synthetic, Loto-like)", {
                let before = WatchItem(id: "t-2", title: "Appel d'offres IA", link: "https://www.merx.com/x", organisation: "Loterie Fictive",
                                       deadline: ISO8601DateFormatter().date(from: "2026-10-29T21:00:00Z"), status: "Open")
                var after = before
                after.deadline = ISO8601DateFormatter().date(from: "2026-11-05T21:00:00Z")
                try expect(TenderWatcher.state(previous: before, current: after) == .changed, "deadline moved = changed")
                try expect(TenderWatcher.state(previous: before, current: before) == .live, "unchanged = live")
                try expect(TenderWatcher.state(previous: before, current: nil) == .gone, "no longer listed = gone")
            }),
            ("Recall fixture: an inferred-only institutional prospect is rejected (synthetic, Fonds-FTQ-like)", {
                var fund = LeadKit.university(fetchedDaysAgo: 2)
                fund.organisation = "Fonds Fictif de Solidarité"
                fund.segment = "ai_governance_need"
                fund.trigger?.kind = "newsroom"
                fund.trigger?.origin = .inferred
                fund.contact = nil
                let verdict = LeadDefinition.evaluate(fund, config: config, now: now)
                try expect(verdict.status == .fix && verdict.reasons.contains("no named person") && verdict.reasons.contains("trigger is a inferred"), "\(verdict)")
            }),
            ("Feed parser reads RSS items with a deadline", {
                let rss = """
                <?xml version="1.0"?><rss><channel><item><title>Avis A</title><link>https://www.seao.ca/avis/a</link><guid>a</guid>
                <organisation>Organisme Fictif</organisation><deadline>2026-11-05</deadline><status>Ouvert</status></item></channel></rss>
                """
                let items = TenderWatcher.parseFeed(Data(rss.utf8))
                try expect(items.count == 1 && items[0].organisation == "Organisme Fictif" && items[0].deadline != nil, "\(items)")
            }),
            ("Site extractor: verbatim address, named person, route, consent and trigger from own-site HTML", {
                let html = """
                <html><head><script>var x = "1 rue Cachée H0H 0H0";</script></head><body>
                <h1>Clinique Exemple Nord</h1><p>Prendre rendez-vous en ligne</p>
                <footer><address>1234, rue Imaginaire, Montréal (Québec) H0H 0H0</address>
                <a href="mailto:info@clinique-exemple.test">Écrivez-nous</a> <a href="https://www.linkedin.com/company/x">LinkedIn</a></footer>
                <ul><li>Alex Fictif, directrice générale</li><li>Sam Exemple – Dentiste</li></ul></body></html>
                """
                let page = SiteExtractor.read(html: html, url: URL(string: LeadKit.homePage)!, fetchedAt: now)
                try expect(page.address == LeadKit.clinicAddress && page.text.contains(LeadKit.clinicAddress), "address: \(String(describing: page.address))")
                try expect(page.people.first == .init(name: "Alex Fictif", title: "directrice générale"), "people: \(page.people)")
                try expect(page.emails == ["info@clinique-exemple.test"], "emails: \(page.emails)")
                try expect(page.linkedinURLs.count == 1 && !page.text.contains("Cachée"), "linkedin + no script text")
                let triggers = SiteExtractor.triggers(in: page, segment: config.segment("clinic")!, config: config)
                try expect(triggers.first?.kind == "ai_tool_on_own_site" && triggers.first?.origin == .pageFetch, "\(triggers)")
                try expect(SiteExtractor.read(html: "<p>Aucune sollicitation svp</p>", url: URL(string: LeadKit.homePage)!, fetchedAt: now).refusesSolicitation, "no-solicitation notice")
            }),
            ("Guard: per-host rate limit waits 10 s between own-site requests", {
                let inner = FakeLeadTransport()
                inner.respond("https://www.clinique-exemple.test/robots.txt", body: "User-agent: *\nAllow: /\n")
                inner.respond(LeadKit.homePage, body: "<p>a</p>")
                inner.respond(LeadKit.contactPage, body: "<p>b</p>")
                let clock = FakeLeadClock()
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: clock)
                _ = try await guarded.fetch(URL(string: LeadKit.homePage)!, purpose: .ownSite(domain: LeadKit.clinicDomain))
                _ = try await guarded.fetch(URL(string: LeadKit.contactPage)!, purpose: .ownSite(domain: LeadKit.clinicDomain))
                try expect(clock.sleeps.count == 2 && clock.sleeps.allSatisfy { abs($0 - 10) < 0.001 }, "sleeps: \(clock.sleeps)")
                try expect(inner.urls.filter { $0.hasSuffix("/robots.txt") }.count == 1, "robots fetched once")
            }),
            ("Guard: a bot challenge is a hard fail for that host (no retry, no bypass)", {
                let inner = FakeLeadTransport()
                inner.respond("https://www.clinique-exemple.test/robots.txt", body: "")
                inner.respond(LeadKit.homePage, status: 403, body: "<title>Just a moment...</title><script src=/cdn-cgi/challenge-platform/x></script>")
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
                var first: String?
                do { _ = try await guarded.fetch(URL(string: LeadKit.homePage)!, purpose: .ownSite(domain: LeadKit.clinicDomain)) } catch let r as LeadPipelineRefusal { first = r.code }
                let before = inner.requests.count
                var second: String?
                do { _ = try await guarded.fetch(URL(string: LeadKit.contactPage)!, purpose: .ownSite(domain: LeadKit.clinicDomain)) } catch let r as LeadPipelineRefusal { second = r.code }
                try expect(first == "refused:bot-challenge" && second == "refused:bot-challenge" && inner.requests.count == before, "\(String(describing: first)) \(String(describing: second))")
            }),
            ("Guard: denied and held hosts never reach the network", {
                let inner = FakeLeadTransport()
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
                for (url, code) in [("https://www.registreentreprises.gouv.qc.ca/x", "refused:denied-host"), ("https://pes.rbq.gouv.qc.ca/x", "refused:denied-host"),
                                    ("https://oppq.connexence.com/ext/x", "refused:denied-host"), ("https://abc-dsn.algolia.net/1/indexes", "refused:denied-host"),
                                    ("https://www.cmq.org/bottin", "refused:source-disabled:professional_order_directory")] {
                    let host = URL(string: url)!.host!
                    do { _ = try await guarded.fetch(URL(string: url)!, purpose: .ownSite(domain: host)); try expect(false, "\(url) fetched") }
                    catch let refusal as LeadPipelineRefusal { try expect(refusal.code == code, "\(url): \(refusal.code)") }
                }
                try expect(inner.requests.isEmpty, "0 requests")
            }),
            ("Guard: RBQ only through the one fixed JSON link; never /api/, /recherche/api/ or a query string", {
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                let inner = FakeLeadTransport()
                inner.respond(source.downloadUrls[0], body: "[]", headers: ["content-type": "application/json"])
                let clock = FakeLeadClock()
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: clock)
                for bad in ["https://www.donneesquebec.ca/api/3/action/package_search?q=rbq",
                            "https://www.donneesquebec.ca/recherche/api/3/action/package_show",
                            source.downloadUrls[0] + "?download=1",
                            "https://www.donneesquebec.ca/recherche/dataset/licencesactives"] {
                    do { _ = try await guarded.fetch(URL(string: bad)!, purpose: .openData(id: RBQOpenData.sourceID)); try expect(false, "\(bad) fetched") }
                    catch let refusal as LeadPipelineRefusal { try expect(refusal.code == "refused:open-data-path", "\(bad): \(refusal.code)") }
                    do { _ = try await guarded.fetch(URL(string: bad)!, purpose: .ownSite(domain: "donneesquebec.ca")); try expect(false, "\(bad) via own-site") }
                    catch let refusal as LeadPipelineRefusal { try expect(refusal.code == "refused:loi25-host", "\(bad) own-site: \(refusal.code)") }
                }
                try expect(inner.requests.isEmpty, "no bad request reached the network")
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cw-rbq-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: directory) }
                try await RBQOpenData.refreshCache(config: config, transport: guarded, directory: directory, now: clock.now)
                try await RBQOpenData.refreshCache(config: config, transport: guarded, directory: directory, now: clock.now.addingTimeInterval(3600))
                try expect(inner.requests.count == 1, "second refresh within a day uses the cache")
                try await RBQOpenData.refreshCache(config: config, transport: guarded, directory: directory, now: clock.now.addingTimeInterval(25 * 3600))
                try expect(inner.requests.count == 2 && inner.urls.allSatisfy { $0 == source.downloadUrls[0] }, "daily re-download: \(inner.urls)")
            }),
            ("RBQ config: holds on sub-category codes 15.5 and 2.5, each on RBQ's official list, source URL cited; construction trades fail closed", {
                let area = try unwrap(config.conflictAreas.first { $0.rbqSubcategoryCodes != nil }, "conflict area with RBQ codes")
                let codes = area.rbqSubcategoryCodes ?? []
                try expect(codes == ["15.5", "2.5"], "codes \(codes)")
                for code in codes {
                    let title = try unwrap(RBQFixture.officialSubcategories[code], "\(code) is on RBQ's official list")
                    try expect(title.contains("plomberie") || title.contains("excavation"), "\(code) is \(title)")
                }
                try expect((area.rbqSubcategorySource ?? "").contains("https://www.rbq.gouv.qc.ca/licence/determiner-vos-sous-categories-de-licence/entrepreneur-specialise/sous-categories-dentrepreneur-specialise/"), "source URL cited")
                try expect(area.rbqRequiredSegments == ["construction_trades"], "fail-closed segments \(String(describing: area.rbqRequiredSegments))")
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                for role in ["licence_number", "name", "other_names", "municipality", "region_code", "region", "subcategory_list"] {
                    let label = try unwrap(source.label(role), role)
                    try expect(RBQFixture.jsonKeys.contains(label), "\(role) label '\(label)' is a key of the real JSON record")
                }
                try expect(source.label("category") == "Categorie" && source.label("subcategory") == "Sous-catégories" && source.label("json_record") == "Licence", "nested labels")
                try expect(Set(source.knownHeaders ?? []) == Set(RBQFixture.jsonKeys), "known headers are exactly the JSON record keys")
                try expect(source.knownSubcategoryKeys == ["Categorie", "Sous-catégories"], "nested keys \(String(describing: source.knownSubcategoryKeys))")
            }),
            ("RBQ JSON parser: real shape {\"Liste Licence\":[{\"Licence\":{...}}]}, nested codes, streamed from a file, never-stored fields not kept", {
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                let data = RBQFixture.json([
                    RBQFixture.jsonRecord(licence: "0000-0000-03", name: "Excavation Fictive Sud", town: "Longueuil", codes: [("Specialisee", "16"), (nil, "2.5"), (nil, "SEC")],
                                          otherNames: #"["EFS \"test\", enr."]"#),
                    RBQFixture.jsonRecord(licence: "0000-0000-04", name: "Ébénisterie Fictive", town: "Laval", codes: [("Specialisee", "12"), (nil, "11.2"), (nil, "GPC")])
                ])
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("cw-rbq-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: file) }
                try data.write(to: file)
                var parsed: [RBQLicence] = []
                try RBQOpenData.parse(file: file, source: source, chunkSize: 7) { parsed.append($0) }
                try expect(parsed.count == 2, "two licences: \(parsed.count)")
                try expect(parsed[0].name == "Excavation Fictive Sud" && parsed[0].subcategories == ["16", "2.5", "SEC"], "nested codes \(parsed.first?.subcategories ?? [])")
                try expect(parsed[0].otherNames == ["EFS \"test\", enr."] && parsed[0].municipality == "Longueuil" && parsed[0].regionCode == "06", "fields \(parsed[0])")
                try expect(parsed[1].subcategories == ["12", "11.2", "GPC"] && parsed[1].licenceClasses == ["Specialisee"], "non-numeric and dotted codes")
                try expect(parsed[0].provenance == "RBQ / Données Québec, CC BY 4.0", "provenance")
                let encoded = String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self)
                try expect(!encoded.contains("secret@") && !encoded.contains("555-0100") && !encoded.contains("Mandataire Fictif") && !encoded.contains("rue Nulle"), "never-stored fields leaked")
                var badMap = source
                badMap.fields.append(.init(role: "email", label: "Courriel"))
                try expect((try? RBQOpenData.parse(data: data, source: badMap)) == nil, "mapping Courriel is refused")
            }),
            ("RBQ hold: a matched licence with 15.5 or 2.5 is held, a matched licence with none of the listed codes is not; the JSON has one record per licence", {
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                let held = "Rénovations Fictives inc.", clear = "Menuiserie Fictive Ouest"
                let data = RBQFixture.json([
                    RBQFixture.jsonRecord(licence: "0000-0000-05", name: held, town: "Saguenay", codes: [("Specialisee", "16"), (nil, "GPC"), (nil, "2.5")]),
                    RBQFixture.jsonRecord(licence: "0000-0000-06", name: clear, town: "Montréal", codes: [("Specialisee", "6.2"), (nil, "11.2"), (nil, "GPC")])
                ])
                let index = RBQIndex(try RBQOpenData.parse(data: data, source: source))
                try expect(index.count == 2, "one record per licence: \(index.count)")
                func prospect(_ name: String) -> ProspectRecord {
                    var record = LeadKit.readyClinic()
                    record.segment = "construction_trades"
                    record.organisation = name
                    record.osmTags = ["craft=builder"]
                    return record
                }
                var heldProspect = prospect(held)
                let route = heldProspect.route
                try expect(LeadDefinition.evaluate(heldProspect, config: config, now: now).status == .conflictReview, "held before any RBQ lookup (fail closed)")
                index.enrich(&heldProspect, municipality: "Saguenay", source: source)
                try expect(heldProspect.rbqCheck == "matched" && heldProspect.rbqCategories == ["16", "GPC", "2.5"], "codes \(heldProspect.rbqCategories) \(String(describing: heldProspect.rbqCheck))")
                try expect(heldProspect.route == route && heldProspect.contact?.source == .ownSite, "enrich never touches contact data")
                try expect(LeadDefinition.evaluate(heldProspect, config: config, now: now).status == .conflictReview, "held on 2.5")
                try expect(ProspectDisplay.attribution(for: heldProspect, config: config) == "Source: RBQ / Données Québec, CC BY 4.0", "credit")
                try expect(ProspectDisplay.lines(for: heldProspect, config: config).last == "Source: RBQ / Données Québec, CC BY 4.0", "credit shown on the row")
                var clearProspect = prospect(clear)
                index.enrich(&clearProspect, municipality: "Montréal", source: source)
                try expect(clearProspect.rbqCheck == "matched" && clearProspect.rbqCategories == ["6.2", "11.2", "GPC"], "clear codes \(clearProspect.rbqCategories)")
                let after = LeadDefinition.evaluate(clearProspect, config: config, now: now)
                try expect(after.status == .ready, "matched, no listed code: not held: \(after)")
                var stranger = prospect("Entreprise Inconnue")
                index.enrich(&stranger, municipality: "Montréal", source: source)
                try expect(stranger.rbqCheck == "no-match" && LeadDefinition.evaluate(stranger, config: config, now: now).status == .conflictReview, "no match holds")
                for (codes, expected) in [(["15.5"], true), (["15.50"], false), (["2.55"], false), (["12.5"], false), (["GPC", "SEC"], false), ([" 2.5 "], true)] {
                    var record = prospect("Entreprise Fictive")
                    record.rbqCheck = "matched"
                    record.rbqCategories = codes
                    let status = LeadDefinition.evaluate(record, config: config, now: now).status
                    try expect((status == .conflictReview) == expected, "codes \(codes): \(status)")
                }
                try expect(LeadDefinition.evaluate(LeadKit.readyClinic(), config: config, now: now).status == .ready, "segments outside the list need no RBQ match")
                try expect(ProspectDisplay.attribution(for: LeadKit.readyClinic(), config: config) == nil, "no credit without RBQ data")
            }),
            ("RBQ bundle rule (Water 7:20/7:26, Air 10c): 15.5 always held; 2.5 held only without the full Annexe III bundle and without a 1.x code; the rule is config; an unreadable index still holds all", {
                let area = try unwrap(config.conflictAreas.first { $0.rbqSubcategoryCodes != nil }, "conflict area with RBQ codes")
                try expect(area.rbqSubcategoryCodes == ["15.5", "2.5"], "15.5 and 2.5 stay listed: \(String(describing: area.rbqSubcategoryCodes))")
                // One synthetic licence of each kind, through the real JSON parser, the index and LEAD_DEF.
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                let bundle = RBQFixture.annexeIIIBundle.map { (nil as String?, $0) }
                let partial = RBQFixture.annexeIIIBundle.filter { $0 != "17.2" }.map { (nil as String?, $0) }
                let kinds: [(name: String, codes: [(String?, String)], held: Bool, why: String)] = [
                    ("Excavation Fictive Seule", [("Specialisee", "2.5")], true, "2.5 alone"),
                    ("Terrassement Fictif Inc.", [("Specialisee", "2.5"), (nil, "SEC")], true, "2.5 with an admin code only"),
                    ("Ouvrages Fictifs Partiels", partial, true, "2.5 with 12 of the 13 bundle codes"),
                    ("Bâtiments Fictifs Groupés", bundle, false, "2.5 within the full bundle"),
                    ("Entreprise Générale Fictive", [("Generale", "1.3"), ("Specialisee", "2.5")], false, "2.5 with a 1.x code"),
                    ("Habitations Fictives Est", [("Generale", "1.1.1"), ("Specialisee", "2.5"), (nil, "4.2")], false, "2.5 with 1.1.1"),
                    ("Plomberie Fictive Groupée", bundle + [(nil, "15.5")], true, "15.5 with the full bundle"),
                    ("Plomberie Fictive Générale", [("Generale", "1.3"), ("Specialisee", "15.5"), (nil, "2.5")], true, "15.5 with a 1.x code and 2.5")
                ]
                let data = RBQFixture.json(kinds.enumerated().map { index, kind in
                    RBQFixture.jsonRecord(licence: "0000-0001-\(10 + index)", name: kind.name, town: "Saguenay", codes: kind.codes)
                })
                let index = RBQIndex(try RBQOpenData.parse(data: data, source: source))
                for kind in kinds {
                    var record = LeadKit.readyClinic()
                    record.segment = "construction_trades"
                    record.organisation = kind.name
                    record.osmTags = ["craft=builder"]
                    index.enrich(&record, municipality: "Saguenay", source: source)
                    let status = LeadDefinition.evaluate(record, config: config, now: now).status
                    try expect(record.rbqCheck == "matched" && (status == .conflictReview) == kind.held,
                               "\(kind.why): expected \(kind.held ? "held" : "not held"), got \(status) (\(String(describing: record.rbqCheck)))")
                }
                // The rule is config (icp.json), cited.
                let rules = area.rbqCodeConditions ?? []
                try expect(rules.count == 1 && rules.first?.code == "2.5", "one condition, on 2.5 only (15.5 has none): \(rules.map(\.code))")
                let rule = try unwrap(rules.first, "2.5 condition")
                try expect(rule.notHeldIfAllOf == RBQFixture.annexeIIIBundle, "bundle is Air's 13 Annexe III codes: \(rule.notHeldIfAllOf)")
                try expect(rule.notHeldIfAnyCodeStartsWith == ["1."], "general 1.x codes: \(rule.notHeldIfAnyCodeStartsWith)")
                let cited = rule.source ?? ""
                try expect(cited.contains("10c") && cited.contains("https://www.rbq.gouv.qc.ca/") && cited.contains("Annexe III"), "cites Air 10c and RBQ's list: \(cited)")
                try expect(LeadDefinition.rbqHeldCodes(["2.5"], area: area) == ["2.5"], "proof predicate: 2.5 alone")
                try expect(LeadDefinition.rbqHeldCodes(RBQFixture.annexeIIIBundle, area: area).isEmpty, "proof predicate: bundle")
                try expect(LeadDefinition.rbqHeldCodes(["1.7G", "2.5"], area: area).isEmpty, "proof predicate: 1.x")
                try expect(LeadDefinition.rbqHeldCodes(RBQFixture.annexeIIIBundle + ["1.3", "15.5"], area: area) == ["15.5"], "proof predicate: 15.5")
                // Fail closed stays: no index or a truncated one holds every firm of the mixed batch.
                for contents in [nil, Data(#"{"Liste Licence":[{"Licence":{"#.utf8)] as [Data?] {
                    let out = try await EarthRBQ.appRun(contents: contents)
                    try expect(out.prospects.count == SearchFixture.constructionBatch.count && out.prospects.allSatisfy({ $0.status == .conflictReview }) && out.drafts.isEmpty,
                               "unreadable index holds all: \(out.prospects.map(\.status))")
                }
            }),
            ("RBQ area rule (Martin 8:39, Water 8:41, list widened 9:02): the code hold applies only in the Saguenay area (whole, normalised Municipalité), or with no location; never a substring", {
                let area = try unwrap(config.conflictAreas.first { $0.rbqSubcategoryCodes != nil }, "conflict area with RBQ codes")
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                let bundle = RBQFixture.annexeIIIBundle.map { (nil as String?, $0) }
                // Neutral names (no conflict keyword), so only the licence code and its place decide.
                let kinds: [(name: String, town: String, codes: [(String?, String)], held: Bool, why: String)] = [
                    ("Services Fictifs Alpha", "Jonquière", [("Specialisee", "15.5")], true, "15.5 in Jonquière"),
                    ("Services Fictifs Bravo", "Montréal", [("Specialisee", "15.5")], false, "15.5 in Montréal"),
                    ("Services Fictifs Charlie", "", [("Specialisee", "15.5")], true, "15.5 with no location"),
                    ("Services Fictifs Delta", "Petit-Saguenay", [("Specialisee", "15.5")], false, "15.5 in Petit-Saguenay (no substring match)"),
                    ("Services Fictifs Echo", "Saguenay", [("Specialisee", "15.5")], true, "15.5 in Saguenay"),
                    ("Services Fictifs Foxtrot", " SAGUENAY ", [("Specialisee", "15.5")], true, "15.5 in ' SAGUENAY ' (case and spaces)"),
                    ("Services Fictifs Golf", "Jonquiere", [("Specialisee", "15.5")], true, "15.5 in 'Jonquiere' (accent-normalised)"),
                    ("Services Fictifs Hotel", "Saguenay", [("Specialisee", "2.5")], true, "2.5 alone in Saguenay"),
                    ("Services Fictifs India", "Laval", [("Specialisee", "2.5")], false, "2.5 alone in Laval"),
                    ("Services Fictifs Juliett", "Saguenay", bundle, false, "2.5 within the full bundle in Saguenay"),
                    ("Services Fictifs Kilo", "Saguenay-Lac-Saint-Jean", [("Specialisee", "15.5")], false, "15.5 in a longer name containing Saguenay")
                ]
                let data = RBQFixture.json(kinds.enumerated().map { index, kind in
                    RBQFixture.jsonRecord(licence: "0000-0002-\(10 + index)", name: kind.name, town: kind.town, codes: kind.codes)
                })
                let index = RBQIndex(try RBQOpenData.parse(data: data, source: source))
                for kind in kinds {
                    var record = LeadKit.readyClinic()
                    record.segment = "construction_trades"
                    record.organisation = kind.name
                    record.osmTags = ["craft=builder"]
                    index.enrich(&record, municipality: nil, source: source)
                    let status = LeadDefinition.evaluate(record, config: config, now: now).status
                    try expect(record.rbqCheck == "matched" && (status == .conflictReview) == kind.held,
                               "\(kind.why): expected \(kind.held ? "held" : "not held"), got \(status) (\(String(describing: record.rbqCheck)))")
                    try expect(LeadDefinition.rbqHeldCodes(kind.codes.map(\.1), area: area, municipality: kind.town).isEmpty == !kind.held, "proof predicate: \(kind.why)")
                }
                try expect(LeadDefinition.rbqAreaMatch("Petit-Saguenay", area: area) == .outside && LeadDefinition.rbqAreaMatch(nil, area: area) == .unknown
                           && LeadDefinition.rbqAreaMatch("  ", area: area) == .unknown && LeadDefinition.rbqAreaMatch("jonquière", area: area) == .inside("Jonquière"),
                           "area match classes")
                // The full list (Water 9:02 replaces the two values of 8:41) is asserted in the "Conflict area (Water 9:02)" test.
                try expect(area.municipalities?.prefix(2) == ["Saguenay", "Jonquière"], "conflict area starts with Martin's two values: \(String(describing: area.municipalities))")
                // Fail closed is unchanged: no index holds every construction firm.
                let out = try await EarthRBQ.appRun(contents: nil)
                try expect(out.prospects.allSatisfy({ $0.status == .conflictReview }) && out.drafts.isEmpty, "no index still holds all: \(out.prospects.map(\.status))")
            }),
            ("Conflict area (Water 9:02): keyword and map-tag holds follow the Saguenay area; unreadable town held; elsewhere not held", {
                let area = try unwrap(config.conflictAreas.first, "conflict area")
                try expect(area.municipalities == ["Saguenay", "Jonquière", "Chicoutimi", "Chicoutimi-Nord", "La Baie", "Laterrière", "Shipshaw",
                                                   "Lac-Kénogami", "Canton-Tremblay", "Arvida", "Kénogami"], "one list in icp.json: \(String(describing: area.municipalities))")
                // A matched licence with no listed code, so only the keyword or map tag and the town decide.
                func firm(_ name: String, tags: [String], town: String?) -> ProspectRecord {
                    var record = LeadKit.readyClinic()
                    record.segment = "construction_trades"
                    record.organisation = name
                    record.osmTags = tags
                    record.rbqCheck = "matched"
                    record.rbqCategories = ["1.3"]
                    record.town = town
                    return record
                }
                let cases: [(record: ProspectRecord, held: Bool, why: String)] = [
                    (firm("Plomberie Fictive Mike", tags: ["craft=builder"], town: "Montréal"), false, "keyword firm in Montréal"),
                    (firm("Plomberie Fictive November", tags: ["craft=builder"], town: nil), true, "keyword firm with no town"),
                    (firm("Plomberie Fictive Oscar", tags: ["craft=builder"], town: "  "), true, "keyword firm with a blank town"),
                    (firm("Services Fictifs Papa", tags: ["craft=plumber"], town: "Petit-Saguenay"), false, "map-data plumber in Petit-Saguenay"),
                    (firm("Excavation Fictive Quebec", tags: ["craft=builder"], town: "arvida"), true, "keyword firm in 'arvida' (normalised)"),
                    (firm("Services Fictifs Romeo", tags: ["craft=excavation"], town: "Laval"), false, "map-data excavation in Laval")
                ]
                for item in cases {
                    let status = LeadDefinition.evaluate(item.record, config: config, now: now).status
                    try expect((status == .conflictReview) == item.held, "\(item.why): expected \(item.held ? "held" : "not held"), got \(status)")
                    try expect((LeadDefinition.conflictArea(for: item.record, config: config) != nil) == item.held, "outreach check: \(item.why)")
                }
                // The search run keeps the map listing's town on the record.
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                let licences = try RBQOpenData.parse(data: RBQFixture.json([
                    RBQFixture.jsonRecord(licence: "0000-0000-09", name: SearchFixture.builderName, town: "", codes: [("Specialisee", "1.3")])
                ]), source: source)
                let run = await SearchFixture.builder(config: config).run(segment: "construction_trades", rbq: RBQIndex(licences))
                try expect(run.prospects.first?.town == "Montréal", "map town kept: \(String(describing: run.prospects.first?.town))")
            }),
            ("Chicoutimi map-data plumber held (Water 10:04): a craft=plumber listing in Chicoutimi is held for conflict review", {
                var record = LeadKit.readyClinic()
                record.segment = "construction_trades"
                record.organisation = "Services Fictifs Lima"
                record.osmTags = ["craft=plumber"]
                record.rbqCheck = "matched"
                record.rbqCategories = ["1.3"]
                record.town = "Chicoutimi"
                let status = LeadDefinition.evaluate(record, config: config, now: now).status
                try expect(status == .conflictReview, "map-data plumber in Chicoutimi: expected held, got \(status)")
                try expect(LeadDefinition.conflictArea(for: record, config: config) != nil, "outreach check: map-data plumber in Chicoutimi")
            }),
            ("Live proof cause 2 (Water 10:13, unmatched=5): a prospect fetched at a millisecond time still matches its fetch and score lines after prospects.json is saved and read back", {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("cw-ms-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                let env = try LeadPipelineEnvironment.load(configDirectory: LeadKit.configDirectory, root: root)
                let fixture = SearchFixture(config: config)
                fixture.clock.advance(0.891)
                let audit = env.audit
                _ = env.recordLaunch(audit: audit, now: fixture.clock.now)
                let reports = await env.searchAndIngest([.init(segmentID: "clinic", latitude: 45.5, longitude: -73.6, radiusMeters: 3000, limit: 5)],
                                                        inner: fixture.inner, audit: audit, clock: fixture.clock)
                let live = try unwrap(reports.first?.prospects.first?.fetchedAt, "fetch time in the run")
                let inputs = env.proofInputs()
                let stored = try unwrap(inputs.prospects.first?.fetchedAt, "fetch time read back")
                try expect(CWAuditLine.timestamp(stored) == CWAuditLine.timestamp(live),
                           "prospects.json keeps the fetch time: run \(CWAuditLine.timestamp(live)), read back \(CWAuditLine.timestamp(stored))")
                let checks = LeadProofVerifier.verify(storeCountAtLaunch: inputs.launchCount, auditLines: inputs.lines, prospects: inputs.prospects, drafts: inputs.drafts, config: config)
                let two = try unwrap(checks.first { $0.number == 2 }, "check 2")
                try expect(two.passed, "check 2 after save and read back: \(two.detail)")
            }),
            ("Live proof cause 1 (Water 10:13, 0 contacts): the crawl follows the home page's own links to its team and contact pages when the guessed paths are missing", {
                let fixture = SearchFixture(config: config)
                let site = "https://www.clinique-exemple.test"
                fixture.inner.respond(LeadKit.homePage, body: "<h1>Clinique Exemple Nord</h1><p>Prendre rendez-vous en ligne</p>"
                                      + "<a href=\"/pourquoi-nous/our-team\">Our team</a> <a href=\"/en/contact-us\">Contact us</a> <a href=\"/blogue/article-1\">Blogue</a>")
                fixture.inner.respond("\(site)/equipe", status: 404, body: "")
                fixture.inner.respond("\(site)/a-propos", status: 404, body: "")
                fixture.inner.respond("\(site)/pourquoi-nous/our-team", body: "<ul><li>Alex Fictif, directrice générale</li></ul>")
                fixture.inner.respond("\(site)/en/contact-us", body: "<p>Nous joindre</p><address>\(LeadKit.clinicAddress)</address><a href=\"mailto:info@clinique-exemple.test\">info</a>")
                let report = await fixture.run()
                let pages = fixture.inner.urls.filter { $0.hasPrefix(site) && !$0.hasSuffix("/robots.txt") }
                try expect(pages.contains("\(site)/pourquoi-nous/our-team") && pages.contains("\(site)/en/contact-us"), "linked team and contact pages fetched: \(pages)")
                try expect(pages.count <= config.etiquette.maxPagesPerSite, "page budget kept: \(pages.count) > \(config.etiquette.maxPagesPerSite)")
                try expect(!pages.contains("\(site)/blogue/article-1"), "unrelated link not fetched")
                let record = try unwrap(report.prospects.first, "prospect")
                try expect(record.contact?.name == "Alex Fictif" && record.route?.kind == .email, "contact \(String(describing: record.contact?.name)) route \(String(describing: record.route?.kind)) reasons \(record.reasons)")
                try expect(record.status == .ready && report.drafts.count == 1, "ready and drafted: \(record.status) \(record.reasons) drafts=\(report.drafts.count)")
            }),
            ("Check 5 (Earth 10:10): a host a listing names as its own site counts as allowed; an unrelated host still fails", {
                func line(_ host: String) -> String {
                    CWAuditLine(ts: now, surface: "leads", action: "fetch", register: CWAuditLine.register(for: URL(string: "https://\(host)/")),
                                target: host, source: "own-site", result: "redirect:301").text
                }
                let listing = "www.listing-fictif.test"
                let pass = LeadProofVerifier.verify(storeCountAtLaunch: 0, auditLines: [line(listing)], prospects: [], drafts: [], config: config,
                                                    listingDomains: ["listing-fictif.test"])
                let five = try unwrap(pass.first { $0.number == 5 }, "check 5")
                try expect(five.passed, "own-site host of a listing must pass: \(five.detail)")
                let fail = LeadProofVerifier.verify(storeCountAtLaunch: 0, auditLines: [line("www.autre-fictif.test")], prospects: [], drafts: [], config: config,
                                                    listingDomains: ["listing-fictif.test"])
                let other = try unwrap(fail.first { $0.number == 5 }, "check 5")
                try expect(!other.passed && other.detail.contains("www.autre-fictif.test"), "unrelated host must fail: \(other.detail)")
            }),
            ("Photon fallback (Water 10:09 a): the Photon request carries only the category tag and coordinates, no names or free text", {
                let fixture = SearchFixture.photonOnly(config: config)
                _ = await fixture.run()
                let photon = fixture.inner.requests.filter { $0.url?.host == "photon.komoot.io" }
                try expect(!photon.isEmpty, "Photon was asked")
                let selectors = try unwrap(config.segments.first { $0.id == "clinic" }, "clinic").osmSelectors
                for request in photon {
                    let url = try unwrap(request.url, "url")
                    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                    try expect(Set(items.map(\.name)) == ["q", "osm_tag", "lat", "lon", "limit"] && items.count == 5, "query names: \(items.map(\.name))")
                    let tag = query["osm_tag"] ?? ""
                    try expect(selectors.contains(tag.replacingOccurrences(of: ":", with: "=")), "osm_tag is a segment category tag: \(tag)")
                    try expect(query["q"] == tag.split(separator: ":").last.map { $0.replacingOccurrences(of: "_", with: " ") }, "q is the category value only: \(query["q"] ?? "")")
                    try expect(query["lat"] == "45.50000" && query["lon"] == "-73.60000" && Int(query["limit"] ?? "") != nil, "coordinates and limit: \(query)")
                    try expect((request.httpMethod ?? "GET") == "GET" && (request.httpBody ?? Data()).isEmpty, "no body")
                    for word in ["Fictif", "Exemple", "Imaginaire", "clinique-exemple", "Montr"] { try expect(!url.absoluteString.contains(word), "no name or free text: \(word)") }
                }
            }),
            ("Photon fallback (Water 10:09 a): when Overpass fails, the run log names Photon as the server that answered", {
                let fixture = SearchFixture.photonOnly(config: config)
                let report = await fixture.run()
                try expect(report.prospects.count == 1, "Photon listing became a prospect: \(report.prospects.count)")
                let lines = fixture.audit.lines
                let search = lines.filter { $0.action == "search" && $0.source == "controlward" && $0.result == "ok" }
                try expect(!search.isEmpty && search.allSatisfy { URL(string: $0.register)?.host == "photon.komoot.io" }, "search line names Photon: \(search.map(\.register))")
                try expect(lines.contains { $0.action == "discovery-attempt" && $0.target == "photon.komoot.io" && $0.result == "ok" }, "Photon attempt ok")
                try expect(lines.contains { $0.action == "discovery-attempt" && $0.target == "overpass-api.de" && $0.result.hasPrefix("error:") }, "Overpass failure logged first")
            }),
            ("Risk line (Earth 12:19): a prospect with no dated trigger never shows 'dated trigger' and gets an honest risk line", {
                let honest = "No trigger on the own site with a fetch time: no draft."
                var none = LeadKit.readyClinic()
                none.trigger = nil
                try expect(!LeadDefinition.riskLine(none).contains("dated trigger") && LeadDefinition.riskLine(none) == honest, "no trigger: \(LeadDefinition.riskLine(none))")
                var undated = LeadKit.readyClinic()
                undated.trigger?.fetchedAt = nil
                try expect(LeadDefinition.riskLine(undated) == honest, "trigger without fetch time: \(LeadDefinition.riskLine(undated))")
                try expect(LeadDefinition.riskLine(LeadKit.readyClinic()) == "Low: own-site evidence, dated trigger.", "a dated trigger keeps the low line")
            }),
            ("Trigger phrases (Water 12:19): a synthetic clinic site is Ready when an own-site AI-governance phrase, a named person and a consent basis are present; without the phrase it stays Fix", {
                func site(home: String) -> SearchFixture {
                    let fixture = SearchFixture(config: config)
                    let root = "https://www.clinique-exemple.test"
                    fixture.inner.respond(LeadKit.homePage, body: "<h1>Clinique Exemple Nord</h1><p>\(home)</p>"
                                          + "<a href=\"/notre-equipe\">Notre équipe</a> <a href=\"/nous-joindre\">Nous joindre</a>")
                    fixture.inner.respond("\(root)/notre-equipe", body: "<ul><li>Alex Fictif, directrice générale</li></ul>")
                    fixture.inner.respond("\(root)/nous-joindre", body: "<p>Nous joindre</p><address>\(LeadKit.clinicAddress)</address><a href=\"mailto:info@clinique-exemple.test\">info</a>")
                    return fixture
                }
                let with = site(home: "Le tri des demandes passe par une DÉCISION AUTOMATISÉE revue chaque semaine.")
                let report = await with.run()
                let record = try unwrap(report.prospects.first, "prospect")
                try expect(record.contact?.name == "Alex Fictif" && record.consent != nil, "named person and consent basis: \(String(describing: record.contact?.name)) \(String(describing: record.consent))")
                try expect(record.trigger?.kind == "ai_governance_signal" && record.trigger?.url == LeadKit.homePage && record.trigger?.fetchedAt != nil
                           && record.trigger?.summary.contains("décision automatisée") == true, "trigger: \(String(describing: record.trigger))")
                try expect(record.status == .ready && report.drafts.count == 1, "ready and drafted: \(record.status) \(record.reasons) drafts=\(report.drafts.count)")
                let without = site(home: "Bienvenue à la clinique.")
                let plain = await without.run()
                let other = try unwrap(plain.prospects.first, "prospect without phrase")
                try expect(other.status == .fix && other.reasons.contains("no trigger URL with fetch time") && plain.drafts.isEmpty, "no phrase stays Fix: \(other.status) \(other.reasons)")
            }),
            ("Trigger phrases (Water 12:19, Earth/Air 12:21): 'AI' and 'IA' match only as whole uppercase words; other phrases match whole words in any case, with or without accents", {
                var custom = config
                custom.triggerSignals = ["ai_tool_on_own_site": ["AI", "IA", "décision automatisée", "chatbot"]]  // only these phrases, under one kind
                let clinic = try unwrap(custom.segments.first { $0.id == "clinic" }, "clinic")
                func hits(_ text: String) -> [String] {
                    let page = SiteExtractor.read(html: "<p>\(text)</p>", url: URL(string: LeadKit.homePage)!, fetchedAt: now)
                    return SiteExtractor.triggers(in: page, segment: clinic, config: custom).map(\.summary)
                }
                let negative = "He said we maintain records via the média portal. J'ai vu la liaison avec la pharmacie. Ai-je raison? MAINTENANT. Thaïlande."
                try expect(hits(negative).isEmpty, "substrings and lowercase must not trigger: \(hits(negative))")
                for (text, phrase) in [("Nous utilisons l'IA pour le tri.", "IA"), ("AI-assisted triage at the front desk.", "AI"), ("We use AI.", "AI"),
                                       ("Decision automatisee des rendez-vous.", "décision automatisée"), ("Essayez notre CHATBOT.", "chatbot")] {
                    let found = hits(text)
                    try expect(found.count == 1 && found[0].contains("“\(phrase)”"), "\(text) -> \(found)")
                }
            }),
            ("Live sample (Water 12:19, Earth/Air 12:21): a sample of 60 is split across all seven target sectors, banks and general AI-governance included", {
                let ids = config.segments.map(\.id)
                try expect(Set(ids) == ["clinic", "construction_trades", "university", "bank", "insurer", "public_body", "ai_governance_need"], "sectors: \(ids)")
                let split = LeadProofSample.split(60, across: ids)
                try expect(split.map(\.id) == ids && split.reduce(0) { $0 + $1.limit } == 60, "total 60 in config order: \(split)")
                let limits = split.map(\.limit)
                try expect((limits.min() ?? 0) >= 8 && (limits.max() ?? 0) - (limits.min() ?? 0) <= 1, "even shares: \(limits)")
            }),
            ("LIVE-R5 (Ready needs consent): a record that passes every other rule but has no recorded consent basis is Fix, not Ready", {
                var lead = LeadKit.readyClinic()
                try expect(LeadDefinition.evaluate(lead, config: config, now: now).status == .ready, "fixture is Ready with consent")
                lead.consent = nil
                let verdict = LeadDefinition.evaluate(lead, config: config, now: now)
                try expect(verdict.status == .fix && verdict.reasons.contains("no consent basis recorded"),
                           "no consent basis: \(verdict.status) \(verdict.reasons)")
            }),
            ("LIVE-R5 (check 3): a Ready prospect whose draft was refused gives ready=1 drafted=0 and the refusing rule, never 'no Ready prospect'", {
                var lead = LeadKit.readyClinic()
                lead.status = .ready
                let refused = CWAuditLine(ts: now, surface: "leads", action: "draft", register: URLCanonical.register(lead.sourceURL), target: lead.id,
                                          source: "controlward", result: "refused:address-provenance").text
                let checks = LeadProofVerifier.verify(storeCountAtLaunch: 0, auditLines: [refused], prospects: [lead], drafts: [], config: config)
                let check3 = try unwrap(checks.first { $0.number == 3 }, "check 3")
                try expect(!check3.passed, "check 3 fails without a draft: \(check3.detail)")
                try expect(check3.detail.contains("ready=1") && check3.detail.contains("drafted=0")
                           && check3.detail.contains("\(lead.id) refused:address-provenance") && !check3.detail.contains("no Ready prospect"),
                           "check 3 names the Ready count and the refusing rule: \(check3.detail)")
                var other = LeadKit.readyClinic(id: "cw:osm:node/1002")
                other.status = .fix
                let none = LeadProofVerifier.verify(storeCountAtLaunch: 0, auditLines: [], prospects: [other], drafts: [], config: config)
                let empty = try unwrap(none.first { $0.number == 3 }, "check 3")
                try expect(!empty.passed && empty.detail.contains("ready=0") && empty.detail.contains("drafted=0"), "zero Ready is counted: \(empty.detail)")
            }),
            ("LIVE-R6 (cross-record merge): two prospects on different own domains that share a phone line stay two records, each with only its own evidence", {
                let first = LeadR6.record(LeadKit.readyClinic(), phone: "514 555 0100")
                let second = try LeadR6.moved(LeadKit.readyClinic(id: "cw:osm:way/3003"), to: "universite-fictive.test", phone: "514 555 0100")
                let store = ProspectLeadsStore()
                let result = await ProspectIngest.ingest([first, second], into: store, config: config, now: now, audit: MemoryAuditSink())
                // Each prospect id belongs to one organisation: evidence under an id must stay on that organisation's own domain.
                let owner = ["cw:osm:node/1001": LeadKit.clinicDomain, "cw:osm:way/3003": "universite-fictive.test"]
                let leaks = store.records.flatMap { record in LeadR6.urls(record).filter { url in
                    !HostMatch.belongs(URL(string: url)?.host ?? "-", to: owner[record.id] ?? "-") }.map { "\(record.id) <- \($0)" } }
                try expect(leaks.isEmpty, "no record carries another prospect's evidence: \(leaks)")
                try expect(store.records.count == 2 && result.merged.isEmpty, "two organisations stay two records: count=\(store.records.count) merged=\(result.merged)")
                let ids = Dictionary(uniqueKeysWithValues: store.records.map { ($0.id, $0.businessDomain ?? "-") })
                try expect(ids["cw:osm:node/1001"] == LeadKit.clinicDomain && ids["cw:osm:way/3003"] == "universite-fictive.test", "each id keeps its own domain: \(ids)")
            }),
            ("LIVE-R6 (evidence domain invariant): ingest refuses a record with an evidence URL off its own domain and audits refused:cross-domain-evidence", {
                var tampered = LeadKit.readyClinic(id: "cw:osm:node/4004")
                tampered.trigger?.url = "https://www.universite-fictive.test/nouvelles"
                let audit = MemoryAuditSink()
                let store = ProspectLeadsStore()
                let result = await ProspectIngest.ingest([tampered, LeadKit.readyClinic()], into: store, config: config, now: now, audit: audit)
                try expect(store.records.map(\.id) == ["cw:osm:node/1001"], "only the clean record is stored: \(store.records.map(\.id))")
                try expect(result.rejected["cw:osm:node/4004"] == "refused:cross-domain-evidence", "rejected: \(result.rejected)")
                try expect(audit.lines.contains { $0.target == "cw:osm:node/4004" && $0.result == "refused:cross-domain-evidence" },
                           "audited: \(audit.lines.map(\.text))")
            }),
            ("LIVE-R6 (proof check 6): any record with an evidence URL off its own domain is a hard fail; clean records pass with cross-domain=0", {
                var tampered = LeadKit.readyClinic(id: "cw:osm:node/4004")
                tampered.snapshots.append(SiteSnapshot(url: "https://www.universite-fictive.test/", fetchedAt: now, text: "Université Fictive"))
                let fail = LeadProofVerifier.verify(storeCountAtLaunch: 0, auditLines: [], prospects: [LeadKit.readyClinic(), tampered], drafts: [], config: config)
                let check6 = try unwrap(fail.first { $0.number == 6 }, "check 6")
                try expect(!check6.passed && check6.detail.contains("cross-domain=1") && check6.detail.contains("cw:osm:node/4004 www.universite-fictive.test"),
                           "check 6 fails and names the record and host: \(check6.detail)")
                let pass = LeadProofVerifier.verify(storeCountAtLaunch: 0, auditLines: [], prospects: [LeadKit.readyClinic()], drafts: [], config: config)
                let clean = try unwrap(pass.first { $0.number == 6 }, "check 6")
                try expect(clean.passed && clean.detail.contains("cross-domain=0"), "clean: \(clean.detail)")
            }),
            ("LIVE-R4 (trigger/fit): a synthetic clinic whose only match is a footer 'privacy' link gets no trigger and no fit line", {
                let fixture = SearchFixture(config: config)
                let root = "https://www.clinique-exemple.test"
                fixture.inner.respond(LeadKit.homePage, body: "<h1>Clinique Exemple Nord</h1><p>Bienvenue à la clinique.</p>"
                                      + "<a href=\"/notre-equipe\">Notre équipe</a> <a href=\"/nous-joindre\">Nous joindre</a>"
                                      + "<footer><a href=\"/privacy\">Privacy</a> · <a href=\"/privacy-policy\">Privacy policy</a></footer>")
                fixture.inner.respond("\(root)/notre-equipe", body: "<ul><li>Alex Fictif, directrice générale</li></ul>")
                fixture.inner.respond("\(root)/nous-joindre", body: "<p>Nous joindre</p><address>\(LeadKit.clinicAddress)</address><a href=\"mailto:info@clinique-exemple.test\">info</a>")
                let report = await fixture.run()
                let record = try unwrap(report.prospects.first, "prospect")
                try expect(record.trigger == nil && record.fit == nil, "no trigger and no fit from a footer link: \(String(describing: record.trigger)) fit=\(String(describing: record.fit))")
                try expect(record.status != .ready && record.reasons.contains("no trigger URL with fetch time") && report.drafts.isEmpty,
                           "stays Fix without a draft: \(record.status) \(record.reasons) drafts=\(report.drafts.count)")
            }),
            ("LIVE-R4 (trigger/fit): nav, header and footer text and link text never count, bare 'privacy' never counts; an AI phrase or a specific Loi 25 phrase in body text does", {
                let clinic = try unwrap(config.segments.first { $0.id == "clinic" }, "clinic")
                func kinds(_ html: String) -> [String] {
                    let page = SiteExtractor.read(html: html, url: URL(string: LeadKit.homePage)!, fetchedAt: now)
                    return SiteExtractor.triggers(in: page, segment: clinic, config: config).map(\.kind).filter { $0 == "ai_governance_signal" }
                }
                var failures: [String] = []
                for html in ["<nav><a href=\"/ia\">Intelligence artificielle</a></nav><p>Bienvenue à la clinique.</p>",
                             "<header><p>Chatbot</p></header><p>Bienvenue à la clinique.</p>",
                             "<p>Bienvenue à la clinique.</p><footer><p>Loi 25</p><a href=\"/vie-privee\">Protection des renseignements personnels</a></footer>",
                             "<p>Bienvenue. <a href=\"/ia\">Notre politique sur l'IA</a></p>",
                             "<p>We respect your privacy.</p>", "<p>Privacy</p>"] where !kinds(html).isEmpty {
                    failures.append("counted: \(html)")
                }
                for html in ["<p>Conformément à la Loi 25, notre responsable de la protection des renseignements répond à vos questions.</p>",
                             "<p>Nous utilisons l'IA pour trier les demandes.</p>",
                             "<main><p>Our privacy team reviews every AI tool we use.</p></main><footer><a href=\"/privacy\">Privacy</a></footer>"] where kinds(html).isEmpty {
                    failures.append("missed: \(html)")
                }
                try expect(failures.isEmpty, "\(failures)")
            }),
            ("LIVE-R7 (URL canonicalisation, check 2, cw-audit L213/L214): the fetch and score lines match the prospect's source URL when the page came back with a trailing slash, another host case, the default port or a fragment", {
                var failures: [String] = []
                for final in ["\(Check2Site.root)/nous-joindre/", "https://WWW.Clinique-Exemple.TEST/nous-joindre",
                              "https://www.clinique-exemple.test:443/nous-joindre", "\(Check2Site.root)/nous-joindre#equipe"] {
                    let result = try await Check2Site.check2(config: config, servedFrom: final)
                    if !result.source.lowercased().contains("nous-joindre") { failures.append("\(final): source URL is \(result.source)") }
                    if !result.passed { failures.append("\(final): \(result.detail)") }
                }
                try expect(failures.isEmpty, "check 2 must pass: \(failures)")
            }),
            ("LIVE-R7 (URL canonicalisation, check 2): a page that came back from a different path, a different path case, a deeper path or a different query string is never matched to the fetch of another URL", {
                var failures: [String] = []
                for final in ["\(Check2Site.root)/nous-joindre-2", "\(Check2Site.root)/Nous-joindre", "\(Check2Site.root)/nous-joindre/plan",
                              "\(Check2Site.root)/nous-joindre?lang=en"] {
                    let result = try await Check2Site.check2(config: config, servedFrom: final)
                    if result.passed || !result.detail.hasSuffix("unmatched=1") { failures.append("\(final): \(result.detail)") }
                }
                try expect(failures.isEmpty, "check 2 must stay unmatched: \(failures)")
            }),
            ("Planted-red tally (Water/Earth): one planted red that slips prints 'expected 56 failures, got 55: MISMATCH' and fails the run", {
                var cases = try LeadPipelinePlantedReds.makeCases()
                try expect(cases.count == 56, "56 planted cases, got \(cases.count)")
                // Make the count independent of a local vitest run: reds 9/10 stand in as caught.
                for index in cases.indices where cases[index].label.contains("(pharos-api vitest)") {
                    cases[index].probe = { "stub: vitest caught it" }
                }
                let slipIndex = try unwrap(cases.firstIndex { $0.group == "S3-RED-SPAM" }, "an S3-RED-SPAM case")
                let slipped = cases[slipIndex].label
                cases[slipIndex].probe = { nil }   // the bad input gets through
                let result = await LeadPipelinePlantedReds.tally(cases)
                try expect(result.summary == "Slice 3 planted reds (41 Wind + 13 Argus + 2 Earth): expected 56 failures, got 55: MISMATCH", "summary: \(result.summary)")
                try expect(result.failures == 55 && !result.ok, "one slip must fail the run: failures=\(result.failures) ok=\(result.ok)")
                try expect(result.lines.contains("S3-RED-SPAM: expected 5 failures, got 4: MISMATCH"), "group line names the slip")
                try expect(result.lines.contains("  RED-MISSED [S3-RED-SPAM] \(slipped): the planted bad input was accepted"), "the slipped red is named")
                try expect(!result.lines.contains { $0.hasPrefix("expected 56 failures, got") && $0.hasSuffix(": OK") }, "no OK line when a red slips")
                try expect(LeadPipelinePlantedReds.tallyMessage(expected: 56, got: result.failures) == "Slice 3 planted reds: expected 56 failures, got 55: MISMATCH", "fatal text carries 55")
            }),
            ("Planted-red tally (CI 9:45): a missing pharos-api vitest report reads NOT-RUN, never 'accepted'; the failure text carries the real counts", {
                let missing = FileManager.default.temporaryDirectory.appendingPathComponent("cw-no-report-\(UUID().uuidString).json").path
                for path in [nil, "", missing] as [String?] {
                    guard case .missing = PharosPlantedReds.status("ARGUS-RED-9", path: path) else {
                        throw PortableCheckFailure(description: "no report at \(String(describing: path)) must be .missing, got \(PharosPlantedReds.status("ARGUS-RED-9", path: path))")
                    }
                }
                let report = FileManager.default.temporaryDirectory.appendingPathComponent("cw-report-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: report) }
                try Data(#"{"testResults":[{"assertionResults":[{"fullName":"ARGUS-RED-9 refused","status":"passed"},{"fullName":"ARGUS-RED-10 x","status":"failed"}]}]}"#.utf8).write(to: report)
                try expect(PharosPlantedReds.status("ARGUS-RED-9", path: report.path) == .caught("vitest passed: ARGUS-RED-9 refused"), "caught from the report")
                try expect(PharosPlantedReds.status("ARGUS-RED-10", path: report.path) == .notCaught, "failed vitest case is not caught")
                try expect(PharosPlantedReds.status("ARGUS-RED-11", path: report.path) == .missing("no ARGUS-RED-11 case in the vitest report"), "absent case is missing, not accepted")
                let line = LeadPipelinePlantedReds.missedLine(group: "ARGUS-RED", label: "9 PUSH-MIXED-RETRACT", report: .missing("CW_PHAROS_PLANTED_REDS not set"))
                try expect(line.contains("NOT-RUN") && !line.contains("accepted") && line.contains("CW_PHAROS_PLANTED_REDS not set"), "missing tool line: \(line)")
                try expect(LeadPipelinePlantedReds.missedLine(group: "S3-RED", label: "x").contains("RED-MISSED"), "a real miss still says RED-MISSED")
                try expect(LeadPipelinePlantedReds.tallyMessage(expected: 56, got: 54) == "Slice 3 planted reds: expected 56 failures, got 54: MISMATCH",
                           "real counts: \(LeadPipelinePlantedReds.tallyMessage(expected: 56, got: 54))")
            }),
            ("Overpass probe (Water 9:02): the live rerun may start once either host answers; one attempt per host; at most every 5 minutes", {
                func probe(_ setup: (FakeLeadTransport) -> Void) async -> (results: [OverpassProbe.HostResult], inner: FakeLeadTransport, clock: FakeLeadClock) {
                    let inner = FakeLeadTransport()
                    setup(inner)
                    let clock = FakeLeadClock()
                    let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: clock)
                    return (await OverpassProbe.probe(LeadDiscovery(transport: guarded, jitter: { 0 })), inner, clock)
                }
                let api = "https://overpass-api.de/api/interpreter"
                let second = await probe { inner in
                    inner.fail(LeadDiscovery.overpass.absoluteString, URLError(.timedOut))
                    inner.respond(api, body: LeadKit.overpassOneClinic, headers: ["content-type": "application/json"])
                }
                try expect(second.results.map(\.result) == ["error:network", "ok"] && second.results.map { $0.server.host ?? "" } == ["overpass.private.coffee", "overpass-api.de"],
                           "private.coffee times out, overpass-api.de answers: \(second.results)")
                try expect(OverpassProbe.liveRunMayStart(second.results), "either host answering is enough")
                try expect(second.inner.requests.compactMap { $0.url?.host } == ["overpass.private.coffee", "overpass-api.de"] && second.clock.sleeps.isEmpty,
                           "one attempt per host, no backoff: \(second.inner.urls) \(second.clock.sleeps)")
                let first = await probe { $0.respond(LeadDiscovery.overpass.absoluteString, body: LeadKit.overpassOneClinic, headers: ["content-type": "application/json"]) }
                try expect(first.results.map(\.result) == ["ok"] && first.inner.requests.count == 1 && OverpassProbe.liveRunMayStart(first.results),
                           "private.coffee answers: stop there: \(first.results)")
                let neither = await probe { inner in
                    inner.fail(LeadDiscovery.overpass.absoluteString, URLError(.timedOut))
                    inner.respond(api, status: 502, body: "at capacity")
                }
                try expect(neither.results.map(\.result) == ["error:network", "error:502"] && !OverpassProbe.liveRunMayStart(neither.results),
                           "neither answers: no live run: \(neither.results)")
                try expect(!OverpassProbe.liveRunMayStart([]), "no probe, no live run")
                let t = LeadKit.now
                try expect(OverpassProbe.mayProbe(lastProbe: nil, now: t) && !OverpassProbe.mayProbe(lastProbe: t.addingTimeInterval(-299), now: t)
                           && OverpassProbe.mayProbe(lastProbe: t.addingTimeInterval(-300), now: t), "at most one probe every 5 minutes")
                let body = String(decoding: second.inner.requests.first?.httpBody ?? Data(), as: UTF8.self).removingPercentEncoding ?? ""
                try expect(body.contains("[timeout:60]") && body.contains("out center tags 1;"), "small query with the configured limit: \(body)")
            }),
            ("RBQ schema: a CSV, a missing, renamed or unknown key, a flat record or an empty file throws refused:open-data-schema", {
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                func refusal(_ data: Data) -> LeadPipelineRefusal? {
                    do { _ = try RBQOpenData.parse(data: data, source: source); return nil } catch { return error as? LeadPipelineRefusal }
                }
                let ok = RBQFixture.jsonRecord(licence: "0000-0000-07", name: "Plomberie Fictive Nord", town: "Montréal", codes: [("Specialisee", "15.5")])
                try expect(refusal(RBQFixture.json([ok])) == nil, "the real shape parses")
                let csv = refusal(RBQFixture.csv([RBQFixture.csvRow(licence: "0000-0000-07", name: "Plomberie Fictive Nord", town: "Montréal", category: "Specialisee", code: "15.5")]))
                try expect(csv?.code == "refused:open-data-schema", "CSV: \(String(describing: csv))")
                let renamed = refusal(RBQFixture.json([RBQFixture.jsonRecord(licence: "0000-0000-08", name: "X", town: "Laval", codes: [("Specialisee", "15.5")],
                                                                             renaming: ("Catégories et sous-catégories", "Categories"))]))
                try expect(renamed?.code == "refused:open-data-schema" && (renamed?.detail ?? "").contains("Catégories et sous-catégories"), "renamed: \(String(describing: renamed))")
                let noName = refusal(RBQFixture.json([RBQFixture.jsonRecord(licence: "0000-0000-08", name: "X", town: "Laval", codes: [("Specialisee", "15.5")], dropping: "Nom de l'intervenant")]))
                try expect(noName?.code == "refused:open-data-schema" && (noName?.detail ?? "").contains("Nom de l'intervenant"), "missing key: \(String(describing: noName))")
                let unknown = refusal(RBQFixture.json([RBQFixture.jsonRecord(licence: "0000-0000-08", name: "X", town: "Laval", codes: [("Specialisee", "15.5")], extra: ("Colonne inconnue", "1"))]))
                try expect(unknown?.code == "refused:open-data-schema" && (unknown?.detail ?? "").contains("Colonne inconnue"), "unknown key: \(String(describing: unknown))")
                let nested = refusal(RBQFixture.json([ok.replacingOccurrences(of: #""Sous-catégories":"15.5""#, with: #""Code":"15.5""#)]))
                try expect(nested?.code == "refused:open-data-schema", "renamed nested key: \(String(describing: nested))")
                let flat = refusal(Data(#"{"Liste Licence":[{"Numéro de licence":"1","Nom de l'intervenant":"X"}]}"#.utf8))
                try expect(flat?.code == "refused:open-data-schema", "record without the Licence wrapper: \(String(describing: flat))")
                try expect(refusal(Data())?.code == "refused:open-data-schema" && refusal(RBQFixture.json([]))?.code == "refused:open-data-schema", "empty file or no records")
                try expect(refusal(Data(#"{"Liste Licence":[{"Licence":{"#.utf8))?.code == "refused:open-data-schema", "truncated file")
            }),
            ("RBQ fails closed in a run: no file, an unreadable file or no licence match holds a construction prospect with no draft", {
                for (rbq, failure, expected) in [(nil as RBQIndex?, nil as String?, "unavailable"), (nil, "refused:open-data-schema", "error:refused:open-data-schema"),
                                                 (RBQIndex([]), nil, "no-match")] {
                    let fixture = SearchFixture.builder(config: config)
                    let report = await fixture.run(segment: "construction_trades", rbq: rbq, rbqFailure: failure)
                    let prospect = try unwrap(report.prospects.first, "prospect (\(expected))")
                    try expect(prospect.rbqCheck == expected && prospect.status == .conflictReview && report.drafts.isEmpty,
                               "\(expected): rbqCheck=\(String(describing: prospect.rbqCheck)) status=\(prospect.status) drafts=\(report.drafts.count)")
                }
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                let licences = try RBQOpenData.parse(data: RBQFixture.json([
                    RBQFixture.jsonRecord(licence: "0000-0000-09", name: SearchFixture.builderName, town: "Montréal", codes: [("Specialisee", "1.3")])
                ]), source: source)
                let clear = await SearchFixture.builder(config: config).run(segment: "construction_trades", rbq: RBQIndex(licences))
                try expect(clear.prospects.first?.rbqCheck == "matched" && clear.prospects.first?.status != .conflictReview, "a matched licence without listed codes is not held")
                let plumbing = try RBQOpenData.parse(data: RBQFixture.json([
                    RBQFixture.jsonRecord(licence: "0000-0000-09", name: SearchFixture.builderName, town: "Jonquière", codes: [("Generale", "1.3"), ("Specialisee", "15.5")])
                ]), source: source)
                let held = await SearchFixture.builder(config: config).run(segment: "construction_trades", rbq: RBQIndex(plumbing))
                try expect(held.prospects.first?.status == .conflictReview && held.drafts.isEmpty, "a silent site with a 15.5 licence is held")
                // The app path: an unreadable cache no longer stops the run; it holds construction trades and audits the refusal.
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("cw-leads-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                let env = try LeadPipelineEnvironment.load(configDirectory: LeadKit.configDirectory, root: root)
                try FileManager.default.createDirectory(at: env.rbqDirectory, withIntermediateDirectories: true)
                try RBQFixture.csv([]).write(to: RBQOpenData.cacheFile(in: env.rbqDirectory))
                do { _ = try env.cachedRBQIndex(); try expect(false, "bad cache accepted") }
                catch let error as LeadPipelineRefusal { try expect(error.code == "refused:open-data-schema", "cache: \(error)") }
                let fixture = SearchFixture.builder(config: config)
                let audit = MemoryAuditSink()
                let reports = await env.searchAndIngest([.init(segmentID: "construction_trades", latitude: 45.5, longitude: -73.6, radiusMeters: 3000, limit: 5)],
                                                        inner: fixture.inner, audit: audit, clock: fixture.clock)
                try expect(reports.first?.prospects.first?.status == .conflictReview && reports.first?.drafts.isEmpty == true, "held, not refused: \(reports.map(\.prospects))")
                try expect(audit.lines.contains { $0.action == "rbq-load" && $0.result == "refused:open-data-schema" }, "refusal audited")
            }),
            ("RBQ fails closed in the app (Earth 6:59, Water 7:18): a missing, truncated or bad-header cached index holds every firm of a mixed construction/trades batch in one run and audits why", {
                for (label, contents, expectedLoad) in [("missing", nil as Data?, nil as String?),
                                                        ("truncated", Data(#"{"Liste Licence":[{"Licence":{"#.utf8), "refused:open-data-schema"),
                                                        ("bad header", RBQFixture.json([RBQFixture.jsonRecord(licence: "0000-0000-07", name: SearchFixture.builderName, town: "Montréal",
                                                                                                             codes: [("Specialisee", "15.5")], renaming: ("Catégories et sous-catégories", "Categories"))]),
                                                         "refused:open-data-schema")] {
                    let held = try await EarthRBQ.appRun(contents: contents)
                    try expect(held.prospects.count == SearchFixture.constructionBatch.count && held.prospects.allSatisfy({ $0.status == .conflictReview }) && held.drafts.isEmpty,
                               "\(label): \(held.prospects.map { "\($0.status)/\($0.rbqCheck ?? "-")" }) drafts=\(held.drafts.count)")
                    if let expectedLoad {
                        try expect(held.audit.contains { $0.action == "rbq-load" && $0.result == expectedLoad }, "\(label): rbq-load audited as \(expectedLoad)")
                    }
                }
            }),
            ("Own-site SSRF: IP literals (v4, v6, decimal, octal, hex), single-label and internal hosts, and non-default ports are refused before the network", {
                let inner = FakeLeadTransport()
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
                let bad = ["http://127.0.0.1/", "http://169.254.169.254/latest/meta-data/", "http://[::1]/", "http://[fd00::1]/", "http://[::ffff:127.0.0.1]/",
                           "http://10.0.0.5/", "http://192.168.1.1/", "http://172.16.0.1/", "http://2130706433/", "http://0177.0.0.1/", "http://0x7f.0.0.1/",
                           "http://0x7f000001/", "http://127.1/", "http://intranet/", "http://localhost/", "http://printer.local/", "http://x.localhost/",
                           "http://db.internal/", "http://nas.lan/", "http://router.home.arpa/", "https://www.clinique-exemple.test:8443/", "http://www.clinique-exemple.test:22/"]
                for raw in bad {
                    let url = try unwrap(URL(string: raw), raw)
                    let host = url.host ?? ""
                    do { _ = try await guarded.fetch(url, purpose: .ownSite(domain: HostMatch.registrable(host))); try expect(false, "\(raw) admitted") }
                    catch let refusal as LeadPipelineRefusal { try expect(refusal.code == "refused:own-site-host", "\(raw): \(refusal.code)") }
                }
                try expect(inner.requests.isEmpty, "nothing reached the network: \(inner.urls)")
                for good in ["https://www.clinique-exemple.test/", "https://www.clinique-exemple.test:443/", "http://www.clinique-exemple.test:80/", "https://clinique-123.test/"] {
                    try expect(GuardedLeadTransport.ownSiteHostRefusal(URL(string: good)!) == nil, "\(good) is an ordinary site")
                }
                let fixture = SearchFixture(config: config)
                fixture.listWebsite("http://192.168.0.10:8080/admin")
                let report = await fixture.run()
                try expect(report.skipped["osm:node/3001"] == "website host not fetchable" && !fixture.inner.urls.contains { $0.contains("192.168") },
                           "listing with an internal website: \(report.skipped)")
            }),
            ("Redirects: an off-site hop is refused with no snapshot; a same-domain hop is re-admitted and robots-checked; at most 3 hops", {
                let inner = FakeLeadTransport()
                inner.respond("https://www.clinique-exemple.test/robots.txt", body: "User-agent: *\nAllow: /\n", headers: ["content-type": "text/plain"])
                inner.respond("https://clinique-exemple.test/robots.txt", body: "User-agent: *\nDisallow: /prive\n", headers: ["content-type": "text/plain"])
                inner.respond(LeadKit.homePage, status: 302, body: "", headers: ["location": "https://autre-site.example.test/accueil"])
                inner.respond(LeadKit.teamPage, status: 301, body: "", headers: ["location": "https://clinique-exemple.test/prive"])
                inner.respond("https://www.clinique-exemple.test/a-propos", status: 302, body: "", headers: ["location": "/nous-joindre"])
                inner.respond(LeadKit.contactPage, body: "<p>Nous joindre</p>")
                inner.respond("https://www.clinique-exemple.test/r1", status: 302, body: "", headers: ["location": "/r2"])
                inner.respond("https://www.clinique-exemple.test/r2", status: 302, body: "", headers: ["location": "/r3"])
                inner.respond("https://www.clinique-exemple.test/r3", status: 302, body: "", headers: ["location": "/r4"])
                inner.respond("https://www.clinique-exemple.test/r4", status: 302, body: "", headers: ["location": "/r5"])
                inner.respond("https://www.clinique-exemple.test/ip", status: 302, body: "", headers: ["location": "http://169.254.169.254/"])
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
                func code(_ raw: String) async -> String {
                    do { let r = try await guarded.fetch(URL(string: raw)!, purpose: .ownSite(domain: LeadKit.clinicDomain)); return "ok:\(r.status):\(r.url?.absoluteString ?? "-")" }
                    catch let refusal as LeadPipelineRefusal { return refusal.code } catch { return "error" }
                }
                for (raw, expected, label) in [(LeadKit.homePage, "refused:redirect-off-site", "off-site"),
                                               ("https://www.clinique-exemple.test/ip", "refused:redirect-off-site", "redirect to an IP literal"),
                                               (LeadKit.teamPage, "refused:robots", "same-domain hop is robots-checked"),
                                               ("https://www.clinique-exemple.test/a-propos", "ok:200:\(LeadKit.contactPage)", "same-site hop followed, final URL kept"),
                                               ("https://www.clinique-exemple.test/r1", "refused:redirect-limit", "more than 3 hops")] {
                    let got = await code(raw)
                    try expect(got == expected, "\(label): \(got)")
                }
                try expect(!inner.urls.contains { $0.contains("autre-site") || $0.contains("169.254") || $0.hasSuffix("/prive") || $0.hasSuffix("/r5") }, "\(inner.urls)")
                // A transport that followed a redirect on its own: the final URL is checked too.
                let sneaky = FakeLeadTransport()
                sneaky.respond("https://www.clinique-exemple.test/robots.txt", body: "", headers: ["content-type": "text/plain"])
                sneaky.respondFrom(LeadKit.homePage, finalURL: "https://autre-site.example.test/", body: "<p>Ailleurs</p>")
                let guarded2 = GuardedLeadTransport(config: config, inner: sneaky, audit: MemoryAuditSink(), clock: FakeLeadClock())
                do { _ = try await guarded2.fetch(URL(string: LeadKit.homePage)!, purpose: .ownSite(domain: LeadKit.clinicDomain)); try expect(false, "followed off-site") }
                catch let refusal as LeadPipelineRefusal { try expect(refusal.code == "refused:redirect-off-site", refusal.code) }
                // In a run, the off-site page never becomes a snapshot.
                let fixture = SearchFixture(config: config)
                fixture.inner.respond(LeadKit.homePage, status: 302, body: "", headers: ["location": "https://autre-site.example.test/"])
                let report = await fixture.run()
                try expect(!report.prospects.flatMap(\.snapshots).contains { $0.url.contains("autre-site") } && !fixture.inner.urls.contains { $0.contains("autre-site") }, "no off-site snapshot")
                try expect(URLSessionLeadTransport.followsRedirects == false, "the real transport hands every 30x to the guard")
            }),
            ("Robots: a robots.txt that answers 5xx or does not answer disallows the whole site; 404 allows it", {
                for (status, fails) in [(503, true), (500, true), (404, false)] {
                    let inner = FakeLeadTransport()
                    inner.respond("https://www.clinique-exemple.test/robots.txt", status: status, body: "", headers: ["content-type": "text/plain"])
                    inner.respond(LeadKit.homePage, body: "<p>a</p>")
                    let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
                    var code = "ok"
                    do { _ = try await guarded.fetch(URL(string: LeadKit.homePage)!, purpose: .ownSite(domain: LeadKit.clinicDomain)) }
                    catch let refusal as LeadPipelineRefusal { code = refusal.code }
                    try expect((code == "refused:robots") == fails && inner.urls.contains(LeadKit.homePage) == !fails, "robots \(status): \(code)")
                }
                let inner = FakeLeadTransport()
                inner.fail("https://www.clinique-exemple.test/robots.txt", URLError(.timedOut))
                inner.respond(LeadKit.homePage, body: "<p>a</p>")
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: FakeLeadClock())
                do { _ = try await guarded.fetch(URL(string: LeadKit.homePage)!, purpose: .ownSite(domain: LeadKit.clinicDomain)); try expect(false, "fetched without robots") }
                catch let refusal as LeadPipelineRefusal { try expect(refusal.code == "refused:robots", refusal.code) }
            }),
            ("Send gate: the approval is bound to a SHA-256 of recipient, subject, body and List-Unsubscribe", {
                try expect(SHA256Hex.digest(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 known answer")
                try expect(SHA256Hex.digest(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256 empty")
                try expect(SHA256Hex.digest(Data(String(repeating: "a", count: 1000).utf8)) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3", "SHA-256 multi-block")
                var cfg = config
                cfg.loi25Gate.open = true
                let draft = LeadKit.draft(for: LeadKit.readyClinic(), config: cfg)
                let approval = LeadKit.approval(draft)
                try expect(approval.contentHash.count == 64 && OutreachSendGate.check(draft, approval: approval, config: cfg, suppression: SuppressionList()) == nil, "approved draft passes")
                for change in ["body", "subject", "to", "unsubscribe"] {
                    var edited = draft
                    switch change {
                    case "body": edited.body += "\nP.S."
                    case "subject": edited.subject += " !"
                    case "to": edited.to = "autre@clinique-exemple.test"
                    default: edited.listUnsubscribe = "<mailto:autre@exemple.test>"
                    }
                    try expect(OutreachSendGate.check(edited, approval: approval, config: cfg, suppression: SuppressionList())?.code == "refused:approval-content-mismatch", "changed \(change)")
                }
                var legacy = approval
                legacy.contentHash = ""
                try expect(OutreachSendGate.check(draft, approval: legacy, config: cfg, suppression: SuppressionList())?.code == "refused:approval-content-mismatch", "an approval without a hash")
            }),
            ("Push policy: Swift LeadPushPolicy refuses a blank form source and a test flag that is not a real boolean, like pharos-api", {
                let refused: [[String: Any]] = [["provenance": ["kind": "inbound_form", "form_source": "   "]], ["provenance": ["kind": "inbound_form", "form_source": "\n\t"]],
                                                ["test": "true"], ["test": 1], ["test": NSNumber(value: 1)], ["provenance": ["kind": "inbound_form"]], [:]]
                for payload in refused { try expect(LeadPushPolicy.check(payload)?.code == "refused:push-not-inbound", "\(payload) must be refused") }
                let decoded = try JSONSerialization.jsonObject(with: Data(#"[{"test":true},{"test":1},{"test":"true"}]"#.utf8)) as? [[String: Any]] ?? []
                try expect(decoded.map { LeadPushPolicy.check($0) == nil } == [true, false, false], "JSON true only")
                try expect(LeadPushPolicy.check(["test": true]) == nil && LeadPushPolicy.check(["provenance": ["kind": "inbound_form", "form_source": "pharos-ai.example.test/contact"]]) == nil, "allowed")
            }),
            ("Audit: a CW-AUDIT line that cannot be written is a visible failure, never silent", {
                let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("cw-audit-block-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: blocker) }
                try Data("not a directory".utf8).write(to: blocker)
                let sink = FileAuditSink(url: blocker.appendingPathComponent("sub/audit.log"))
                sink.write(CWAuditLine(ts: now, surface: "leads", action: "fetch", result: "ok"))
                try expect(sink.failures.count == 1, "failures: \(sink.failures)")
                let good = FileAuditSink(url: FileManager.default.temporaryDirectory.appendingPathComponent("cw-audit-\(UUID().uuidString).log"))
                defer { try? FileManager.default.removeItem(at: good.url) }
                good.write(CWAuditLine(ts: now, surface: "leads", action: "fetch", result: "ok"))
                try expect(good.failures.isEmpty && ((try? String(contentsOf: good.url, encoding: .utf8)) ?? "").contains("action=fetch"), "a good write lands")
            }),
            ("Drafts: FR and EN carry the CASL footer and pass the gate; unsubscribe reply is recorded and persisted", {
                let prospect = LeadKit.readyClinic()
                for language in ["fr", "en"] {
                    let draft = LeadKit.draft(for: prospect, config: config, language: language)
                    try expect(draft.body.contains("PHAROS AI") && draft.body.contains("2456 rue de Rouen, Montréal QC H2K 1M2") && draft.from == "ml@pharos-ai.ca", language)
                    let refusal = OutreachDraftGate.check(draft, prospect: prospect, config: config, suppression: SuppressionList(), now: now)
                    try expect(refusal == nil, "\(language): \(String(describing: refusal))")
                }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("cw-supp-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: file) }
                let list = SuppressionList(storageURL: file)
                try expect(!list.processReply(from: "x@exemple.test", to: "someone@else.test", subject: "unsubscribe", firstLine: "", config: config, at: now), "wrong mailbox")
                try expect(list.processReply(from: "Alex <info@clinique-exemple.test>", to: config.sender.unsubscribeMailto, subject: "Re: question", firstLine: "Désabonner", config: config, at: now), "recorded")
                try expect(SuppressionList(storageURL: file).contains("INFO@clinique-exemple.test"), "persisted")
            }),
            ("Send gate: Martin's approval for that exact message, to Martin's own address, passes", {
                var draft = LeadKit.draft(for: LeadKit.readyClinic(), config: config)
                draft.to = "ml@pharos-ai.ca"
                try expect(OutreachSendGate.check(draft, approval: LeadKit.approval(draft), config: config, suppression: SuppressionList()) == nil, "allowed")
                let other = OutreachApproval(approver: "agent", approvalID: "A-9", messageID: draft.messageID)
                try expect(OutreachSendGate.check(draft, approval: other, config: config, suppression: SuppressionList())?.code == "refused:no-approval", "only martin")
            }),
            ("Push policy: test leads and inbound form leads with their form source are accepted", {
                try expect(LeadPushPolicy.check(["test": true]) == nil, "test lead")
                try expect(LeadPushPolicy.check(["provenance": ["kind": "inbound_form", "form_source": "pharos-ai.ca/contact"]]) == nil, "form lead")
                try expect(LeadPushPolicy.check(["provenance": ["kind": "inbound_form"]])?.code == "refused:push-not-inbound", "form without source")
            }),
            ("Ingest: dedupe by source id, then email, then phone; test leads excluded from the count; one audit line", {
                let store = ProspectLeadsStore()
                let audit = MemoryAuditSink()
                var phoneTwin = LeadKit.readyClinic(id: "cw:osm:node/7", email: "autre@clinique-exemple.test")
                phoneTwin.phone = "+1 514 555-0199"
                var original = LeadKit.readyClinic(id: "cw:osm:node/6", email: "info@clinique-exemple.test")
                original.phone = "(514) 555-0199"
                // LIVE-R6: the test lead lives on its own domain end to end (its evidence URLs used to stay on the clinic's domain).
                var test = try LeadR6.moved(LeadKit.readyClinic(id: "cw:test:1", email: "test@clinique-exemple.test"), to: "exemple.test", phone: "514 555 0100")
                test.isTest = true
                test.provenance = .test
                let result = await ProspectIngest.ingest([original, LeadKit.readyClinic(id: "cw:osm:node/6", email: "x@y.test"), phoneTwin, test],
                                                         into: store, config: config, now: now, audit: audit)
                try expect(store.records.count == 2 && result.merged.count == 2, "records \(store.records.map(\.id)) merged \(result.merged)")
                try expect(LeadDefinition.realLeadCount(store.records, config: config, now: now) == 1, "test lead excluded")
                try expect(audit.lines.count == 1 && audit.lines[0].action == "ingest" && audit.lines[0].surface == "leads", "one ingest line")
            }),
            ("CW-AUDIT: lines round-trip and registers drop query strings", {
                let line = CWAuditLine(ts: now, surface: "leads", action: "fetch", register: CWAuditLine.register(for: URL(string: "https://a.test/p?email=x%40y.test#f")),
                                       target: "a.test", source: "own-site", result: "ok")
                let parsed = try unwrap(CWAuditLine.parse(line.text), "parse")
                try expect(parsed["register"] == "https://a.test/p" && parsed["ts"] == "2026-10-23T14:00:00.000Z", "\(parsed)")
            }),
            ("Search run: ControlWard searches, fetches the own site, scores and drafts locally; nothing is sent", {
                let fixture = SearchFixture(config: config)
                let report = await fixture.run()
                let lines = fixture.audit.lines.map(\.text)
                let checks = LeadProofVerifier.verify(storeCountAtLaunch: 0, auditLines: lines, prospects: report.prospects, drafts: report.drafts, config: config)
                for check in checks { try expect(check.passed, "bar \(check.number) \(check.name): \(check.detail)") }
                try expect(report.prospects.count == 1 && report.prospects[0].status == .ready, "status \(report.prospects.map { ($0.status, $0.reasons) })")
                try expect(report.prospects[0].fetcher.hasPrefix("controlward:") && report.prospects[0].provenance == .controlWardSearch, "fetcher")
                try expect(report.prospects[0].linkedinNote == "confirm profile first", "linkedin note")
                try expect(lines.contains { $0.contains("surface=leads action=search") && $0.contains("source=controlward") }, "search line")
                try expect(!fixture.inner.urls.contains { $0.contains("linkedin") }, "linkedin never fetched")
                let discoveryBodies = fixture.inner.requests.filter { $0.url?.host == "overpass.private.coffee" }.compactMap { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } }
                try expect(!discoveryBodies.isEmpty && discoveryBodies.allSatisfy { !$0.contains("Fictif") && !$0.contains("Imaginaire") }, "overpass got tags and coordinates only")
                try expect(fixture.inner.requests.allSatisfy { $0.httpMethod != "POST" || $0.url?.host == "overpass.private.coffee" }, "no other POST")
            }),
            ("Environment: a run from an empty folder fills the Leads list, saves the draft locally and passes the bar", {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("cw-leads-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                let env = try LeadPipelineEnvironment.load(configDirectory: LeadKit.configDirectory, root: root)
                let fixture = SearchFixture(config: config)
                let audit = env.audit
                let launch = env.recordLaunch(audit: audit, now: fixture.clock.now)
                try expect(launch == 0, "store empty at launch")
                let reports = await env.searchAndIngest([.init(segmentID: "clinic", latitude: 45.5, longitude: -73.6, radiusMeters: 3000, limit: 5)],
                                                        inner: fixture.inner, audit: audit, clock: fixture.clock)
                try expect(reports.count == 1 && reports[0].drafts.count == 1, "one draft")
                let inputs = env.proofInputs()
                try expect(inputs.launchCount == 0 && inputs.prospects.count == 1 && inputs.drafts.count == 1, "read back \(inputs.launchCount) \(inputs.prospects.count) \(inputs.drafts.count)")
                let checks = LeadProofVerifier.verify(storeCountAtLaunch: inputs.launchCount, auditLines: inputs.lines, prospects: inputs.prospects, drafts: inputs.drafts, config: config)
                for check in checks { try expect(check.passed, "bar \(check.number) \(check.name): \(check.detail)") }
                try expect(inputs.lines.contains { $0.contains("surface=leads action=ingest") }, "ingest line")
                try expect(env.recordLaunch(audit: MemoryAuditSink()) == 1, "second launch sees one stored prospect")
            }),
            ("Research: observed_facts and assessment come from the own site, every fact with verbatim evidence", {
                let fixture = SearchFixture(config: config)
                let report = await fixture.run()
                let record = try unwrap(report.prospects.first, "prospect")
                let research = try unwrap(record.research, "research")
                let facts = research.observedFacts
                try expect(facts.companyName == "Clinique Exemple Nord" && facts.evidence["company_name"]?.first?.url == LeadKit.homePage, "company name \(facts)")
                try expect(facts.serviceCategories.contains("clinique") && facts.languagesSeen == ["fr"], "categories/languages \(facts)")
                try expect(facts.bookingURL == nil && research.assessment.unknowns.contains("booking URL"), "no booking link seen: \(research.assessment.unknowns)")
                for (key, items) in facts.evidence {
                    for item in items { try expect(ProspectResearcher.isEvidenced(item, in: record.snapshots), "\(key) evidence not verbatim: \(item)") }
                }
                try expect(research.assessment.supportingEvidence == [FactEvidence(url: LeadKit.homePage, excerpt: "Prendre rendez-vous en ligne")], "\(research.assessment)")
                try expect(research.assessment.potentialOffer != nil && !research.assessment.requiresManualReview, "evidence-backed offer")
                let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
                for key in ["\"observed_facts\"", "\"assessment\"", "\"supporting_evidence\"", "\"requires_manual_review\"", "\"booking_url\":null", "\"languages_seen\""] {
                    try expect(json.contains(key), "stored JSON has \(key)")
                }
            }),
            ("Research: a booking link and a service-area line become facts with evidence", {
                let page = SiteExtractor.read(html: "<p>Clinique Exemple Nord</p><p>Territoire desservi : Rosemont et Villeray.</p><a href=\"https://www.clinique-exemple.test/prendre-rendez-vous\">RDV</a><p>Our team and your care</p>",
                                              url: URL(string: LeadKit.homePage)!, fetchedAt: now)
                let segment = try unwrap(config.segment("clinic"), "clinic")
                let research = ProspectResearcher.research(name: "Clinique Exemple Nord", pages: [page], segment: segment, triggers: [], config: config)
                let facts = research.observedFacts
                try expect(facts.bookingURL == "https://www.clinique-exemple.test/prendre-rendez-vous", "booking \(String(describing: facts.bookingURL))")
                try expect(facts.serviceAreas == ["Rosemont et Villeray"], "areas \(facts.serviceAreas)")
                try expect(facts.languagesSeen.contains("en"), "en seen \(facts.languagesSeen)")
                let snapshot = SiteSnapshot(url: page.url, fetchedAt: now, text: page.text, links: page.links)
                for item in facts.evidence.values.flatMap({ $0 }) { try expect(ProspectResearcher.isEvidenced(item, in: [snapshot]), "evidence \(item)") }
                try expect(research.assessment.requiresManualReview && research.assessment.potentialOffer == nil, "no trigger, so manual review")
            }),
            ("Drafts: quote only evidenced facts; no conclusion, no unsupported quote or URL, nothing when review is needed", {
                let lead = LeadKit.readyClinic()
                let draft = LeadKit.draft(for: lead, config: config)
                try expect(draft.body.contains("« Prendre rendez-vous en ligne »") && draft.body.contains(LeadKit.homePage), "cites the evidence:\n\(draft.body)")
                try expect(!draft.body.contains(lead.fit ?? "<none>"), "the fit conclusion is not in the draft")
                try expect(OutreachDraftGate.check(draft, prospect: lead, config: config, suppression: SuppressionList(), now: now) == nil, "clean draft passes")
                var invented = draft
                invented.body = invented.body.replacingOccurrences(of: "« Prendre rendez-vous en ligne »", with: "« Chef de file en IA au Québec »")
                try expect(OutreachDraftGate.check(invented, prospect: lead, config: config, suppression: SuppressionList(), now: now)?.code == "refused:research:unsupported-claim", "invented quote")
                var elsewhere = draft
                elsewhere.body = elsewhere.body.replacingOccurrences(of: LeadKit.homePage, with: "https://annuaire.example.test/clinique")
                try expect(OutreachDraftGate.check(elsewhere, prospect: lead, config: config, suppression: SuppressionList(), now: now)?.code == "refused:research:unsupported-claim", "off-site URL")
                var stale = lead
                stale.snapshots[0].text = "Clinique Exemple Nord"
                try expect(OutreachDraftGate.check(draft, prospect: stale, config: config, suppression: SuppressionList(), now: now)?.code == "refused:research:manual-review", "excerpt gone from snapshot")
                var review = lead
                review.research?.assessment.requiresManualReview = true
                let reviewDraft = LeadKit.draft(for: review, config: config)
                try expect(!(reviewDraft.body.components(separatedBy: "\n--\n").first ?? "").contains("«"), "no quote when review is needed")
                try expect(OutreachDraftGate.check(reviewDraft, prospect: review, config: config, suppression: SuppressionList(), now: now)?.code == "refused:research:manual-review", "manual review")
            }),
            ("Dedupe: place id or normalized domain (www, case, trailing dot) is one lead", {
                try expect(ProspectIdentity.normalizedDomain("WWW.Clinique-Exemple.test.") == "clinique-exemple.test", "normalize")
                try expect(ProspectIdentity.normalizedDomain("https://www.clinique-exemple.test/equipe") == "clinique-exemple.test", "normalize URL")
                let store = ProspectLeadsStore()
                var first = LeadKit.readyClinic(id: "cw:osm:node/1", email: "info@clinique-exemple.test")
                first.phone = "514 555 0101"
                var second = LeadKit.readyClinic(id: "cw:osm:way/2", email: "accueil@clinique-exemple.test")
                second.phone = "514 555 0199"
                second.businessDomain = "WWW.clinique-exemple.test."
                _ = await ProspectIngest.ingest([first, second], into: store, config: config, now: now, audit: MemoryAuditSink())
                try expect(store.records.count == 1, "same domain is one lead: \(store.records.map(\.id))")
                let merged = DiscoveredPlace.merge([DiscoveredPlace(placeID: "osm:node/1", domain: "www.a.test", usableWebsite: false),
                                                    DiscoveredPlace(placeID: "osm:node/1", domain: nil, usableWebsite: true),
                                                    DiscoveredPlace(placeID: "osm:way/9", domain: "A.test", usableWebsite: true),
                                                    DiscoveredPlace(placeID: "osm:node/3", domain: "b.test", usableWebsite: true)], into: [])
                try expect(merged.count == 2 && merged[0].usableWebsite && merged[0].domain == "a.test", "\(merged)")
            }),
            ("Closed businesses are dropped: OSM lifecycle tags, a closed name, or the own site says so", {
                let data = Data("""
                {"elements":[{"type":"node","id":1,"lat":45.5,"lon":-73.6,"tags":{"name":"Clinique A","disused:healthcare":"clinic"}},
                {"type":"node","id":2,"lat":45.5,"lon":-73.6,"tags":{"name":"Clinique B","healthcare":"clinic","opening_hours":"closed"}},
                {"type":"node","id":3,"lat":45.5,"lon":-73.6,"tags":{"name":"Clinique C (fermé)","healthcare":"clinic"}},
                {"type":"node","id":4,"lat":45.5,"lon":-73.6,"tags":{"name":"Clinique D","healthcare":"clinic","end_date":"2025-06"}},
                {"type":"node","id":5,"lat":45.5,"lon":-73.6,"tags":{"name":"Clinique E","healthcare":"clinic"}}]}
                """.utf8)
                let parsed = LeadDiscovery.parseOverpass(data, via: "overpass")
                try expect(parsed.map(\.closed) == [true, true, true, true, false], "\(parsed.map { ($0.name, $0.closed) })")
                let fixture = SearchFixture(config: config)
                fixture.inner.respond(LeadKit.homePage, body: "<h1>Clinique Exemple Nord</h1><p>La clinique est définitivement fermée.</p><p>Prendre rendez-vous en ligne</p>")
                let report = await fixture.run()
                try expect(report.prospects.isEmpty && report.drafts.isEmpty, "closed site gives no lead")
                try expect(report.skipped["osm:node/1001"] == "closed business (own site)" && report.discovered.first?.closed == true, "\(report.skipped)")
            }),
            ("Funnel: discovered, usable website, appropriate contact, evidence-backed opportunity (not raw rows)", {
                try expect(LeadFunnel.labels == ["Businesses discovered", "With a usable website", "Appropriate contact found", "Evidence-backed opportunity"], "labels")
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("cw-funnel-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                let env = try LeadPipelineEnvironment.load(configDirectory: LeadKit.configDirectory, root: root)
                let fixture = SearchFixture(config: config)
                fixture.inner.respond("https://overpass.private.coffee/api/interpreter", body: """
                {"elements":[{"type":"node","id":1001,"lat":45.5,"lon":-73.6,"tags":{"name":"Clinique Exemple Nord","healthcare":"clinic","website":"https://www.clinique-exemple.test","addr:city":"Montréal"}},
                {"type":"node","id":1002,"lat":45.5,"lon":-73.6,"tags":{"name":"Clinique Sans Site","healthcare":"clinic"}},
                {"type":"node","id":1003,"lat":45.5,"lon":-73.6,"tags":{"name":"Clinique Miroir","healthcare":"clinic","website":"http://WWW.clinique-exemple.test/"}},
                {"type":"node","id":1004,"lat":45.5,"lon":-73.6,"tags":{"name":"Clinique Fermée","was:healthcare":"clinic","website":"https://ferme.example.test"}}]}
                """, headers: ["content-type": "application/json"])
                let reports = await env.searchAndIngest([.init(segmentID: "clinic", latitude: 45.5, longitude: -73.6, radiusMeters: 3000, limit: 10)],
                                                        inner: fixture.inner, audit: MemoryAuditSink(), clock: fixture.clock)
                try expect(reports[0].skipped["osm:node/1003"] == "duplicate domain" && reports[0].skipped["osm:node/1004"] == "closed business", "\(reports[0].skipped)")
                try expect(!fixture.inner.urls.contains { $0.contains("ferme.example.test") }, "closed site never fetched")
                let funnel = env.funnel(now: fixture.clock.now)
                try expect(funnel == LeadFunnel(discovered: 2, withUsableWebsite: 1, appropriateContact: 1, evidenceBackedOpportunity: 1), "\(funnel)")
                try expect(funnel.stages.map(\.label) == LeadFunnel.labels && zip(funnel.values, funnel.values.dropFirst()).allSatisfy { $0 >= $1 }, "monotone stages")
                _ = await env.searchAndIngest([.init(segmentID: "clinic", latitude: 45.5, longitude: -73.6, radiusMeters: 3000, limit: 10)],
                                              inner: fixture.inner, audit: MemoryAuditSink(), clock: fixture.clock)
                try expect(env.funnel(now: fixture.clock.now) == funnel, "a second run of the same places does not inflate the funnel")
            }),
            ("Proof verifier: flags a seeded store, a send line and an off-allowlist host", {
                let fixture = SearchFixture(config: config)
                let report = await fixture.run()
                var lines = fixture.audit.lines.map(\.text)
                lines.append(CWAuditLine(ts: now, surface: "leads", action: "send", register: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send", result: "ok").text)
                lines.append(CWAuditLine(ts: now, surface: "leads", action: "fetch", register: "https://api.enrich.test/v1", source: "discovery", result: "ok").text)
                let checks = LeadProofVerifier.verify(storeCountAtLaunch: 3, auditLines: lines, prospects: report.prospects, drafts: report.drafts, config: config)
                try expect(checks.first { $0.number == 1 }?.passed == false && checks.first { $0.number == 5 }?.passed == false, "\(checks)")
            })
        ])
    }

    static func unwrap<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw PortableCheckFailure(description: "missing \(label)") }
        return value
    }
}

/// One synthetic clinic on a fake Overpass and a fake own site.
struct SearchFixture {
    let config: ICPConfig
    let inner = FakeLeadTransport()
    let audit = MemoryAuditSink()
    let clock = FakeLeadClock()

    init(config: ICPConfig) {
        self.config = config
        inner.respond("https://overpass.private.coffee/api/interpreter", body: """
        {"elements":[{"type":"node","id":1001,"lat":45.5,"lon":-73.6,"tags":{"name":"Clinique Exemple Nord","healthcare":"clinic","website":"https://www.clinique-exemple.test","addr:city":"Montréal"}}]}
        """, headers: ["content-type": "application/json"])
        inner.respond("https://www.clinique-exemple.test/robots.txt", body: "User-agent: *\nDisallow: /admin\n", headers: ["content-type": "text/plain"])
        inner.respond(LeadKit.homePage, body: "<h1>Clinique Exemple Nord</h1><p>Prendre rendez-vous en ligne</p><a href=\"https://www.linkedin.com/company/x\">in</a>")
        inner.respond("https://www.clinique-exemple.test/equipe", body: "<ul><li>Alex Fictif, directrice générale</li></ul>")
        inner.respond("https://www.clinique-exemple.test/notre-equipe", status: 404, body: "")
        inner.respond("https://www.clinique-exemple.test/a-propos", body: "<p>Nous joindre</p><address>\(LeadKit.clinicAddress)</address><a href=\"mailto:info@clinique-exemple.test\">info</a>")
    }

    func run(segment: String = "clinic", rbq: RBQIndex? = nil, rbqFailure: String? = nil) async -> ProspectSearchRun.Report {
        let guarded = GuardedLeadTransport(config: config, inner: inner, audit: audit, clock: clock)
        var search = ProspectSearchRun(config: config, transport: guarded, audit: audit, clock: clock, suppression: SuppressionList(), runID: "test-run")
        search.rbq = rbq
        search.rbqFailure = rbqFailure
        return await search.run(.init(segmentID: segment, latitude: 45.5, longitude: -73.6, radiusMeters: 3000, limit: 5))
    }

    static let builderName = "Constructions Fictives Nord"

    /// The same synthetic site listed as a general contractor (craft=builder): its name and pages say nothing about plumbing,
    /// so only the RBQ lookup can hold it.
    static func builder(config: ICPConfig) -> SearchFixture {
        let fixture = SearchFixture(config: config)
        fixture.inner.respond("https://overpass.private.coffee/api/interpreter", body: """
        {"elements":[{"type":"node","id":2001,"lat":45.5,"lon":-73.6,"tags":{"name":"\(builderName)","craft":"builder","website":"https://www.clinique-exemple.test","addr:city":"Montréal"}}]}
        """, headers: ["content-type": "application/json"])
        return fixture
    }

    /// A mixed batch of construction and trades firms (builder, electrician, roofer, construction company), each with its
    /// own synthetic site whose pages say nothing about plumbing or excavation, so only the RBQ check can hold them.
    static let constructionBatch: [(id: Int, name: String, tag: String, host: String)] = [
        (2101, "Constructions Fictives Nord", "\"craft\":\"builder\"", "www.constructions-fictives-nord.test"),
        (2102, "Électricité Fictive Est", "\"craft\":\"electrician\"", "www.electricite-fictive-est.test"),
        (2103, "Toitures Fictives Ouest", "\"craft\":\"roofer\"", "www.toitures-fictives-ouest.test"),
        (2104, "Entreprise Fictive Bâtiment", "\"office\":\"construction_company\"", "www.entreprise-fictive-batiment.test")
    ]

    static func mixedConstructionBatch(config: ICPConfig) -> SearchFixture {
        let fixture = SearchFixture(config: config)
        let elements = constructionBatch.map { firm in
            #"{"type":"node","id":\#(firm.id),"lat":45.5,"lon":-73.6,"tags":{"name":"\#(firm.name)",\#(firm.tag),"website":"https://\#(firm.host)","addr:city":"Montréal"}}"#
        }
        fixture.inner.respond("https://overpass.private.coffee/api/interpreter", body: #"{"elements":["# + elements.joined(separator: ",") + "]}",
                              headers: ["content-type": "application/json"])
        for (index, firm) in constructionBatch.enumerated() {
            let site = "https://\(firm.host)"
            fixture.inner.respond("\(site)/robots.txt", body: "User-agent: *\nDisallow: /admin\n", headers: ["content-type": "text/plain"])
            fixture.inner.respond("\(site)/", body: "<h1>\(firm.name)</h1><p>Demandez une soumission en ligne</p>")
            fixture.inner.respond("\(site)/equipe", body: "<ul><li>Alex Fictif, directrice générale</li></ul>")
            fixture.inner.respond("\(site)/a-propos", body: "<p>Nous joindre</p><address>\(1240 + index), rue Imaginaire, Montréal (Québec) H0H 0H0</address><a href=\"mailto:info@\(firm.host.replacingOccurrences(of: "www.", with: ""))\">info</a>")
        }
        return fixture
    }

    /// Both Overpass servers answer 502; Photon answers the clinic tag with the synthetic clinic (Water 10:09 a).
    static func photonOnly(config: ICPConfig) -> SearchFixture {
        let fixture = SearchFixture(config: config)
        fixture.inner.respond("https://overpass.private.coffee/api/interpreter", status: 502, body: "")
        fixture.inner.respond("https://overpass-api.de/api/interpreter", status: 502, body: "")
        let url = LeadDiscovery.photonURL(key: "healthcare", value: "clinic", latitude: 45.5, longitude: -73.6, limit: 5)!.absoluteString
        fixture.inner.respond(url, body: #"{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[-73.6,45.5]},"properties":{"osm_type":"N","osm_id":1001,"osm_key":"healthcare","osm_value":"clinic","name":"Clinique Exemple Nord","city":"Montréal","extra":{"website":"https://www.clinique-exemple.test"}}}]}"#,
                              headers: ["content-type": "application/json"])
        return fixture
    }

    /// An overpass answer listing one business whose website is `website` (for the SSRF checks).
    func listWebsite(_ website: String) {
        inner.respond("https://overpass.private.coffee/api/interpreter", body: """
        {"elements":[{"type":"node","id":3001,"lat":45.5,"lon":-73.6,"tags":{"name":"Clinique Exemple Sud","healthcare":"clinic","website":"\(website)","addr:city":"Montréal"}}]}
        """, headers: ["content-type": "application/json"])
    }
}

/// Check 2 (14:03): a synthetic clinic whose contact page carries the trigger phrase and is answered from `servedFrom`
/// (as if the transport had followed a redirect itself). Returns check 2 over the run's own audit lines.
enum Check2Site {
    static let root = "https://www.clinique-exemple.test"

    static func check2(config: ICPConfig, servedFrom final: String) async throws -> (passed: Bool, detail: String, source: String) {
        let fixture = SearchFixture(config: config)
        fixture.inner.respond(LeadKit.homePage, body: "<h1>Clinique Exemple Nord</h1>"
                              + "<a href=\"/notre-equipe\">Notre équipe</a> <a href=\"/nous-joindre\">Nous joindre</a>")
        fixture.inner.respond("\(root)/notre-equipe", body: "<ul><li>Alex Fictif, directrice générale</li></ul>")
        fixture.inner.respondFrom("\(root)/nous-joindre", finalURL: final,
                                  body: "<p>Nous joindre. Une décision automatisée trie les demandes.</p><address>\(LeadKit.clinicAddress)</address>"
                                  + "<a href=\"mailto:info@clinique-exemple.test\">info</a>")
        let report = await fixture.run()
        let record = try LeadPipelineTests.unwrap(report.prospects.first, "prospect served from \(final)")
        let checks = LeadProofVerifier.verify(storeCountAtLaunch: 0, auditLines: fixture.audit.lines.map(\.text),
                                              prospects: report.prospects, drafts: report.drafts, config: config)
        let two = try LeadPipelineTests.unwrap(checks.first { $0.number == 2 }, "check 2")
        return (two.passed, two.detail, record.sourceURL ?? "-")
    }
}

/// LIVE-R6 helpers: a second synthetic organisation on its own domain, and every evidence URL a record carries.
enum LeadR6 {
    static func record(_ record: ProspectRecord, phone: String) -> ProspectRecord {
        var copy = record
        copy.phone = phone
        return copy
    }

    static func moved(_ record: ProspectRecord, to domain: String, phone: String) throws -> ProspectRecord {
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
            .replacingOccurrences(of: LeadKit.clinicDomain, with: domain)
            .replacingOccurrences(of: "Clinique Exemple Nord", with: "Université Fictive")
        var copy = try JSONDecoder().decode(ProspectRecord.self, from: Data(json.utf8))
        copy.phone = phone
        return copy
    }

    static func urls(_ record: ProspectRecord) -> [String] {
        var out = [record.sourceURL, record.addressSourceURL, record.contact?.sourceURL, record.route?.sourceURL, record.trigger?.url].compactMap { $0 }
        out += record.snapshots.map(\.url)
        if let research = record.research {
            out += research.observedFacts.evidence.values.flatMap { $0.map(\.url) } + research.assessment.supportingEvidence.map(\.url)
        }
        return out
    }
}
