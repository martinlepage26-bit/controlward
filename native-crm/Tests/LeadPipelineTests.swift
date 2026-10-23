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
                try expect(config.conflictAreas.first?.description == "all plumbing, excavation and related trades in Québec", "default conflict area")
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
                let found = await LeadDiscovery(transport: guarded).search(selectors: ["healthcare=clinic"], latitude: 45.5, longitude: -73.6, radiusMeters: 3000, limit: 5)
                try expect(found.count == 1, "found \(found.count)")
                try expect(inner.requests.compactMap { $0.url?.host } == ["overpass.private.coffee"], "hosts \(inner.urls)")
                let agent = inner.requests.first?.value(forHTTPHeaderField: "User-Agent") ?? ""
                try expect(agent.hasPrefix("ControlWard/") && agent.contains("contact "), "identifying UA, got \(agent)")
                try expect(clock.sleeps.isEmpty, "no backoff on success: \(clock.sleeps)")
            }),
            ("Discovery: a private.coffee timeout retries with backoff, then falls back to overpass-api.de with tags and coordinates only", {
                try expect(config.allowlist.discoveryHosts.contains("overpass-api.de"), "overpass-api.de allowlisted")
                let inner = FakeLeadTransport()
                inner.fail(LeadDiscovery.overpass.absoluteString, URLError(.timedOut))
                inner.respond("https://overpass-api.de/api/interpreter", body: LeadKit.overpassOneClinic, headers: ["content-type": "application/json"])
                let clock = FakeLeadClock()
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: clock)
                let found = await LeadDiscovery(transport: guarded).search(selectors: ["healthcare=clinic"], latitude: 45.5, longitude: -73.6, radiusMeters: 3000, limit: 5)
                try expect(found.count == 1, "found \(found.count)")
                try expect(inner.requests.compactMap { $0.url?.host } == ["overpass.private.coffee", "overpass.private.coffee", "overpass-api.de"], "hosts \(inner.urls)")
                try expect(clock.sleeps == [5, 10], "exponential backoff 5 s then 10 s, got \(clock.sleeps)")
                try expect(inner.requests.allSatisfy { ($0.value(forHTTPHeaderField: "User-Agent") ?? "").hasPrefix("ControlWard/") }, "UA on every Overpass request (overpass-api.de answers 406 without one)")
                let bodies = inner.requests.compactMap { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } }
                let query = LeadDiscovery.overpassQuery(key: "healthcare", value: "clinic", latitude: 45.5, longitude: -73.6, radius: 3000, limit: 5)
                try expect(bodies.count == 3 && Set(bodies).count == 1, "same payload to both servers")
                try expect(bodies[2].removingPercentEncoding == "data=" + query, "payload is the tag query only: \(bodies[2])")
                try expect(!bodies[2].contains("%40") && !bodies[2].contains("@") && !bodies[2].lowercased().contains("clinique"), "no contact data")
                try expect(!inner.urls.contains { $0.contains("photon") }, "Photon not needed")
            }),
            ("Discovery: 429 honours Retry-After and 5xx backs off before the retry", {
                let inner = FakeLeadTransport()
                inner.enqueue(LeadDiscovery.overpass.absoluteString, status: 429, body: "rate limited", headers: ["retry-after": "30"])
                inner.respond(LeadDiscovery.overpass.absoluteString, body: LeadKit.overpassOneClinic, headers: ["content-type": "application/json"])
                let clock = FakeLeadClock()
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: clock)
                let found = await LeadDiscovery(transport: guarded).search(selectors: ["healthcare=clinic"], latitude: 45.5, longitude: -73.6, radiusMeters: 3000, limit: 5)
                try expect(found.count == 1 && inner.requests.count == 2, "retried once: \(inner.urls)")
                try expect(clock.sleeps == [30], "Retry-After 30 s honoured, got \(clock.sleeps)")
                let inner5 = FakeLeadTransport()
                inner5.enqueue(LeadDiscovery.overpass.absoluteString, status: 504, body: "gateway timeout")
                inner5.respond(LeadDiscovery.overpass.absoluteString, body: LeadKit.overpassOneClinic, headers: ["content-type": "application/json"])
                let clock5 = FakeLeadClock()
                let guarded5 = GuardedLeadTransport(config: config, inner: inner5, audit: MemoryAuditSink(), clock: clock5)
                let found5 = await LeadDiscovery(transport: guarded5).search(selectors: ["healthcare=clinic"], latitude: 45.5, longitude: -73.6, radiusMeters: 3000, limit: 5)
                try expect(found5.count == 1 && inner5.requests.compactMap { $0.url?.host } == ["overpass.private.coffee", "overpass.private.coffee"], "504 retried on the same server: \(inner5.urls)")
                try expect(clock5.sleeps.first == 5 && clock5.sleeps.reduce(0, +) >= 10, "5 s backoff, then the 10 s per-host fair-use spacing: \(clock5.sleeps)")
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
            ("Allowlist: RBQ open data is on, with exactly Air's two download links", {
                let source = try unwrap(RBQOpenData.source(config), "rbq source")
                try expect(source.host == "www.donneesquebec.ca" && source.minSecondsBetweenRequests == 10 && source.maxDownloadAgeHours == 24, "host, delay, daily")
                try expect(source.downloadUrls == [
                    "https://www.donneesquebec.ca/recherche/dataset/755b45d6-7aee-46df-a216-748a0191c79f/resource/5183fdd4-55b1-418c-8a7d-0a70058ed68d/download/rdl01_extractiondonneesouvertes.json",
                    "https://www.donneesquebec.ca/recherche/dataset/755b45d6-7aee-46df-a216-748a0191c79f/resource/32f6ec46-85fd-45e9-945b-965d9235840a/download/rdl01_extractiondonneesouvertes.zip"
                ], "download URLs")
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
            ("Guard: RBQ only through the two fixed links; never /api/, /recherche/api/ or a query string", {
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
            ("RBQ config: holds on sub-category codes 15.5 and 2.5, each on RBQ's official list, source URL cited", {
                let area = try unwrap(config.conflictAreas.first { $0.rbqSubcategoryCodes != nil }, "conflict area with RBQ codes")
                let codes = area.rbqSubcategoryCodes ?? []
                try expect(codes == ["15.5", "2.5"], "codes \(codes)")
                for code in codes {
                    let title = try unwrap(RBQFixture.officialSubcategories[code], "\(code) is on RBQ's official list")
                    try expect(title.contains("plomberie") || title.contains("excavation"), "\(code) is \(title)")
                }
                try expect((area.rbqSubcategorySource ?? "").contains("https://www.rbq.gouv.qc.ca/licence/determiner-vos-sous-categories-de-licence/entrepreneur-specialise/sous-categories-dentrepreneur-specialise/"), "source URL cited")
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                let header = RBQFixture.csvHeader.dropFirst().dropLast().components(separatedBy: "\",\"")
                for role in ["licence_number", "name", "other_names", "municipality", "region_code", "region", "category", "subcategory"] {
                    let label = try unwrap(source.label(role), role)
                    try expect(header.contains(label), "\(role) label '\(label)' is in the real header row")
                }
                try expect(source.label("subcategory_list") == "Catégories et sous-catégories" && source.label("json_record") == "Licence", "JSON shape labels")
                try expect(Set(header).isSubset(of: Set(source.knownHeaders ?? [])), "known headers cover the real row")
            }),
            ("RBQ CSV parser: real header row, rows grouped by licence, never-stored fields not kept", {
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                let data = RBQFixture.csv([
                    RBQFixture.csvRow(licence: "0000-0000-01", name: "Plomberie Fictive Est inc.", town: "Montréal", category: "Specialisee", code: "15.5", otherName: "PFE \"test\", enr."),
                    RBQFixture.csvRow(licence: "0000-0000-01", name: "Plomberie Fictive Est inc.", town: "Montréal", category: "", code: "GPC", otherName: "PFE \"test\", enr."),
                    RBQFixture.csvRow(licence: "0000-0000-02", name: "Toitures Fictives", town: "Laval", category: "Generale", code: "1.3")
                ])
                let parsed = try RBQOpenData.parse(data: data, source: source)
                try expect(parsed.count == 2, "two licences from three rows: \(parsed.count)")
                let first = try unwrap(parsed.first { $0.licenceNumber == "0000-0000-01" }, "licence 01")
                try expect(first.subcategories == ["15.5", "GPC"] && first.licenceClasses == ["Specialisee"], "codes \(first.subcategories) classes \(first.licenceClasses)")
                try expect(first.otherNames == ["PFE \"test\", enr."] && first.municipality == "Montréal" && first.regionCode == "06", "fields \(first)")
                let encoded = String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self)
                try expect(!encoded.contains("secret@") && !encoded.contains("555-0100") && !encoded.contains("Mandataire Fictif") && !encoded.contains("rue Nulle"), "never-stored fields leaked")
                try expect(first.provenance == "RBQ / Données Québec, CC BY 4.0", "provenance")
                var badMap = source
                badMap.fields.append(.init(role: "email", label: "Courriel"))
                try expect((try? RBQOpenData.parse(data: data, source: badMap)) == nil, "mapping Courriel is refused")
            }),
            ("RBQ JSON parser: real record shape {\"Licence\":{...}} with nested sub-categories, streamed from a file", {
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                let data = RBQFixture.json([
                    RBQFixture.jsonRecord(licence: "0000-0000-03", name: "Excavation Fictive Sud", town: "Longueuil", codes: [("Specialisee", "16"), (nil, "2.5"), (nil, "SEC")]),
                    RBQFixture.jsonRecord(licence: "0000-0000-04", name: "Ébénisterie Fictive", town: "Laval", codes: [("Specialisee", "12"), (nil, "11.2")])
                ])
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("cw-rbq-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: file) }
                try data.write(to: file)
                var parsed: [RBQLicence] = []
                try RBQOpenData.parse(file: file, source: source, chunkSize: 7) { parsed.append($0) }
                try expect(parsed.count == 2, "two licences: \(parsed.count)")
                try expect(parsed[0].name == "Excavation Fictive Sud" && parsed[0].subcategories == ["16", "2.5", "SEC"], "nested codes \(parsed.first?.subcategories ?? [])")
                try expect(parsed[1].subcategories == ["12", "11.2"] && parsed[1].licenceClasses == ["Specialisee"], "non-numeric and dotted codes")
                let encoded = String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self)
                try expect(!encoded.contains("secret@") && !encoded.contains("555-0100") && !encoded.contains("Mandataire Fictif"), "never-stored fields leaked")
            }),
            ("RBQ hold: rows of one licence spread across the file are grouped, so a 2.5 row held later still holds the firm; a licence without listed codes is not held", {
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                let held = "Rénovations Fictives inc.", clear = "Menuiserie Fictive Ouest"
                let data = RBQFixture.csv([
                    RBQFixture.csvRow(licence: "0000-0000-05", name: held, town: "Montréal", category: "Specialisee", code: "16"),
                    RBQFixture.csvRow(licence: "0000-0000-06", name: clear, town: "Montréal", category: "Specialisee", code: "6.2"),
                    RBQFixture.csvRow(licence: "0000-0000-05", name: held, town: "Montréal", category: "", code: "GPC"),
                    RBQFixture.csvRow(licence: "0000-0000-06", name: clear, town: "Montréal", category: "", code: "11.2"),
                    RBQFixture.csvRow(licence: "0000-0000-06", name: clear, town: "Montréal", category: "", code: "GPC"),
                    RBQFixture.csvRow(licence: "0000-0000-05", name: held, town: "Montréal", category: "", code: "2.5")
                ])
                let index = RBQIndex(try RBQOpenData.parse(data: data, source: source))
                try expect(index.count == 2, "index holds one entry per licence: \(index.count)")
                func prospect(_ name: String) -> ProspectRecord {
                    var record = LeadKit.readyClinic()
                    record.segment = "construction_trades"
                    record.organisation = name
                    record.osmTags = ["craft=builder"]
                    return record
                }
                var heldProspect = prospect(held)
                let route = heldProspect.route
                try expect(LeadDefinition.evaluate(heldProspect, config: config, now: now).status != .conflictReview, "not held before RBQ data")
                index.enrich(&heldProspect, municipality: "Montréal", source: source)
                try expect(heldProspect.rbqCategories == ["16", "GPC", "2.5"], "grouped codes \(heldProspect.rbqCategories)")
                try expect(heldProspect.route == route && heldProspect.contact?.source == .ownSite, "enrich never touches contact data")
                try expect(LeadDefinition.evaluate(heldProspect, config: config, now: now).status == .conflictReview, "held on 2.5 after grouping")
                try expect(ProspectDisplay.attribution(for: heldProspect, config: config) == "Source: RBQ / Données Québec, CC BY 4.0", "credit")
                try expect(ProspectDisplay.lines(for: heldProspect, config: config).last == "Source: RBQ / Données Québec, CC BY 4.0", "credit shown on the row")
                var clearProspect = prospect(clear)
                let before = LeadDefinition.evaluate(clearProspect, config: config, now: now).status
                index.enrich(&clearProspect, municipality: "Montréal", source: source)
                try expect(clearProspect.rbqCategories == ["6.2", "11.2", "GPC"], "clear codes \(clearProspect.rbqCategories)")
                let after = LeadDefinition.evaluate(clearProspect, config: config, now: now).status
                try expect(after != .conflictReview && after == before, "no listed code, not held: \(after)")
                for (codes, expected) in [(["15.5"], true), (["15.50"], false), (["2.55"], false), (["12.5"], false), (["GPC", "SEC"], false), ([" 2.5 "], true)] {
                    var record = prospect("Entreprise Fictive")
                    record.rbqCategories = codes
                    let status = LeadDefinition.evaluate(record, config: config, now: now).status
                    try expect((status == .conflictReview) == expected, "codes \(codes): \(status)")
                }
                try expect(ProspectDisplay.attribution(for: LeadKit.readyClinic(), config: config) == nil, "no credit without RBQ data")
            }),
            ("RBQ header: a missing or unknown column fails loudly with refused:open-data-header, never a silent skip", {
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                let row = RBQFixture.csvRow(licence: "0000-0000-07", name: "Plomberie Fictive Nord", town: "Montréal", category: "Specialisee", code: "15.5")
                func refusal(_ data: Data) -> LeadPipelineRefusal? {
                    do { _ = try RBQOpenData.parse(data: data, source: source); return nil } catch { return error as? LeadPipelineRefusal }
                }
                let oldGuess = RBQFixture.csvHeader.replacingOccurrences(of: #""Categorie","Sous-catégories""#, with: #""Catégories et sous-catégories","Nombre""#)
                let missing = refusal(RBQFixture.csv([row], header: oldGuess))
                try expect(missing?.code == "refused:open-data-header" && (missing?.detail ?? "").contains("Sous-catégories"), "missing column: \(String(describing: missing))")
                let unknown = refusal(RBQFixture.csv([row + #","x""#], header: RBQFixture.csvHeader + #","Colonne inconnue""#))
                try expect(unknown?.code == "refused:open-data-header" && (unknown?.detail ?? "").contains("Colonne inconnue"), "unknown column: \(String(describing: unknown))")
                let noName = refusal(RBQFixture.json([RBQFixture.jsonRecord(licence: "0000-0000-08", name: "X", town: "Laval", codes: [("Specialisee", "15.5")], dropping: "Nom de l'intervenant")]))
                try expect(noName?.code == "refused:open-data-header" && (noName?.detail ?? "").contains("Nom de l'intervenant"), "JSON missing key: \(String(describing: noName))")
                let flat = refusal(Data(#"{"records":[{"Numéro de licence":"1","Nom de l'intervenant":"X"}]}"#.utf8))
                try expect(flat?.code == "refused:open-data-header", "JSON without the Licence wrapper: \(String(describing: flat))")
                try expect(refusal(Data())?.code == "refused:open-data-header" && refusal(RBQFixture.csv([]))?.code == "refused:open-data-header", "empty file or header only")
                // The app path: a cached file with a bad header stops the search instead of running without the hold.
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("cw-leads-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                let env = try LeadPipelineEnvironment.load(configDirectory: LeadKit.configDirectory, root: root)
                try FileManager.default.createDirectory(at: env.rbqDirectory, withIntermediateDirectories: true)
                try RBQFixture.csv([row], header: oldGuess).write(to: RBQOpenData.cacheFile(in: env.rbqDirectory))
                do { _ = try env.cachedRBQIndex(); try expect(false, "bad cache accepted") }
                catch let error as LeadPipelineRefusal { try expect(error.code == "refused:open-data-header", "cache: \(error)") }
                let fixture = SearchFixture(config: config)
                let audit = MemoryAuditSink()
                let reports = await env.searchAndIngest([.init(segmentID: "clinic", latitude: 45.5, longitude: -73.6, radiusMeters: 3000, limit: 5)],
                                                        inner: fixture.inner, audit: audit, clock: fixture.clock)
                try expect(reports.isEmpty && fixture.inner.requests.isEmpty, "no search without a readable RBQ file: \(reports.count) reports, \(fixture.inner.requests.count) requests")
                try expect(audit.lines.contains { $0.result == "refused:open-data-header" }, "refusal audited")
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
                var test = LeadKit.readyClinic(id: "cw:test:1", email: "test@exemple.test")
                test.isTest = true
                test.provenance = .test
                test.businessDomain = "exemple.test"
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

    func run() async -> ProspectSearchRun.Report {
        let guarded = GuardedLeadTransport(config: config, inner: inner, audit: audit, clock: clock)
        let search = ProspectSearchRun(config: config, transport: guarded, audit: audit, clock: clock, suppression: SuppressionList(), runID: "test-run")
        return await search.run(.init(segmentID: "clinic", latitude: 45.5, longitude: -73.6, radiusMeters: 3000, limit: 5))
    }
}
