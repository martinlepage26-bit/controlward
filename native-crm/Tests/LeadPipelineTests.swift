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
                for id in config.segments.map(\.id) where config.segment(id)?.triggerRule == "same_day" {
                    try expect(config.segment(id)?.allowedContactSources == ["own_site"], "\(id) contact sources")
                }
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
            ("RBQ parser: streams records, keeps categories, never reads Courriel, phone, Mandataire or Adresse", {
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                let json = """
                {"records":[{"Numéro de licence":"0000-0000-01","Nom de l'intervenant":"Plomberie Fictive Est inc.","Courriel":"secret@exemple-rbq.test",
                "Numéro de téléphone":"514-555-0100","Mandataire":"CMMTQ","Adresse":"1 rue Nulle","Municipalité":"Montréal","Code de région administrative":"06",
                "Région administrative":"Montréal","Catégories et sous-catégories":["15.5 Plomberie","15.2 Brûleurs"],"Autre nom":"PFE {test} \\"x\\""},
                {"Numéro de licence":"0000-0000-02","Nom de l'intervenant":"Toitures Fictives","Municipalité":"Laval","Catégories et sous-catégories":"7 Isolation; 9 Toiture"}]}
                """
                var parsed: [RBQLicence] = []
                var splitter = JSONRecordSplitter()
                for byte in Data(json.utf8) {
                    splitter.feed(Data([byte])) { if let licence = RBQOpenData.licence(from: $0, source: source) { parsed.append(licence) } }
                }
                try expect(parsed.count == 2, "two records, one byte at a time: \(parsed.count)")
                try expect(parsed[0].categories == ["15.5 Plomberie", "15.2 Brûleurs"] && parsed[1].categories == ["7 Isolation", "9 Toiture"], "categories")
                let encoded = String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self)
                try expect(!encoded.contains("secret@") && !encoded.contains("555-0100") && !encoded.contains("CMMTQ") && !encoded.contains("rue Nulle"), "never-stored fields leaked")
                try expect(parsed[0].provenance == "RBQ / Données Québec, CC BY 4.0", "provenance")
                var badMap = source
                badMap.fields.append(.init(role: "email", label: "Courriel"))
                try expect((try? RBQOpenData.parse(data: Data(json.utf8), source: badMap)) == nil, "mapping Courriel is refused")
            }),
            ("RBQ hold: a plumbing licence category puts the firm in conflict_review, with the RBQ credit shown", {
                let source = try unwrap(RBQOpenData.source(config), "rbq")
                let index = RBQIndex([RBQLicence(licenceNumber: "1", name: "Rénovations Fictives inc.", otherNames: [], municipality: "Montréal",
                                                 regionCode: "06", region: "Montréal", categories: ["15.5 Plomberie"], provenance: source.label)])
                var prospect = LeadKit.readyClinic()
                prospect.segment = "construction_trades"
                prospect.organisation = "Rénovations Fictives"
                prospect.osmTags = ["craft=builder"]
                let route = prospect.route
                index.enrich(&prospect, municipality: "Montréal", source: source)
                try expect(prospect.route == route && prospect.contact?.source == .ownSite, "enrich never touches contact data")
                try expect(LeadDefinition.evaluate(prospect, config: config, now: now).status == .conflictReview, "held")
                try expect(ProspectDisplay.attribution(for: prospect, config: config) == "Source: RBQ / Données Québec, CC BY 4.0", "credit")
                try expect(ProspectDisplay.lines(for: prospect, config: config).last == "Source: RBQ / Données Québec, CC BY 4.0", "credit shown on the row")
                try expect(ProspectDisplay.attribution(for: LeadKit.readyClinic(), config: config) == nil, "no credit without RBQ data")
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
