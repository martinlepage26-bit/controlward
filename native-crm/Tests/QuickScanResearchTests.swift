import Foundation

enum QuickScanResearchTests {
    private struct CancelOnSleepClock: LeadClock {
        var now: Date { LeadKit.now }
        func sleep(seconds: Double) async { withUnsafeCurrentTask { $0?.cancel() } }
    }
    static func fixture(_ html: String? = nil, now: Date = LeadKit.now) throws -> (QuickScanResearcher, FakeLeadTransport, LeadCandidate) {
        let config = try LeadKit.config()
        let inner = FakeLeadTransport()
        let clock = FakeLeadClock(now)
        inner.respond("https://www.clinique-exemple.test/robots.txt", body: "User-agent: *\nAllow: /", headers: ["content-type": "text/plain"])
        inner.respond(LeadKit.homePage, body: html ?? """
        <h1>Clinique Exemple Nord</h1>
        <a href="/en/contact-us">Contact</a><a href="/notre-equipe">Équipe</a><a href="/intelligence-artificielle">Notre utilisation de l'IA</a>
        <a href="https://autre.test/contact">Un autre site</a>
        """)
        inner.respond("https://www.clinique-exemple.test/en/contact-us", body: "<address>\(LeadKit.clinicAddress)</address><a href=\"mailto:info@clinique-exemple.test\">Écrivez-nous</a>")
        inner.respond("https://www.clinique-exemple.test/notre-equipe", body: "<p>Alex Fictif, directrice générale</p>")
        inner.respond("https://www.clinique-exemple.test/intelligence-artificielle", body: "<p>Nous utilisons <a href=\"https://openai.com\">ChatGPT</a> pour préparer nos documents internes.</p>")
        let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: clock)
        let candidate = LeadCandidate(osmID: "osm:node:1001", name: "Clinique Exemple Nord", website: LeadKit.homePage, tags: ["healthcare=clinic"], city: "Montréal", latitude: 45.5, longitude: -73.6, discoveredVia: "OpenStreetMap")
        return (QuickScanResearcher(config: config, transport: guarded, clock: clock), inner, candidate)
    }

    static func run() async -> Bool {
        let expect = PortableCheck.expect
        return await PortableCheck.suite("Quick Scan research", [
            ("Discovery website becomes a sourced contact, AI-use claim and gated 99 CAD draft", {
                let (researcher, inner, candidate) = try fixture()
                let result = await researcher.research(candidate, segmentID: "clinic")
                try expect(result.record.status == .ready, "\(result.record.reasons)")
                try expect(result.email == "info@clinique-exemple.test", "mailto evidence retained")
                try expect(result.hasAIUseEvidence && result.aiUse[0].excerpt.contains("ChatGPT"), "explicit use with inline link")
                try expect(result.record.contact?.name == "Alex Fictif", "person found automatically")
                let draft = result.draft(config: researcher.config, suppression: SuppressionList(), now: researcher.clock.now)
                try expect(draft?.body.contains("99 $ CA") == true, "priced Quick Scan draft")
                try expect(draft?.body.contains(result.aiUse[0].excerpt) == true, "literal cited evidence")
                try expect(!inner.urls.contains { $0.contains("autre.test") || $0.contains("openai.com") }, "own-site boundary")
                try expect(inner.urls.count == 5 && inner.requests.allSatisfy { $0.httpMethod == "GET" }, "robots plus four public pages; no send")
                try expect(result.contacts.allSatisfy { $0.isSupported(in: result.record) }, "contact fields backed by literal source")
                if let draft { try expect(OutreachSendGate.check(draft, approval: nil, config: researcher.config, suppression: SuppressionList()) != nil, "send still needs approval") }
            }),
            ("Bilingual explicit first-party AI use is supported", {
                for statement in ["We use AI to prepare internal documents", "Our team uses ChatGPT to prepare drafts", "Nous utilisons l’intelligence artificielle dans notre travail", "Notre équipe utilise Copilot pour préparer les documents", "Clinique Exemple Nord uses artificial intelligence for administration", "Nous utilisons ChatGPT sans transmettre de données"] {
                    let page = SiteExtractor.read(html: "<p>\(statement)</p>", url: URL(string: LeadKit.homePage)!, fetchedAt: LeadKit.now)
                    try expect(AIUseEvidence.find(in: [page], organisation: "Clinique Exemple Nord").count == 1, statement)
                }
            }),
            ("Generic mentions, negations, questions, future plans and third-party quotes do not qualify", {
                let negatives = ["<p>AI is changing our industry</p>", "<p>Prendre rendez-vous en ligne</p>", "<p>Loi 25 et protection des renseignements personnels</p>", "<p>We do not use AI</p>", "<p>Nous n’utilisons pas ChatGPT</p>", "<p>Nous utilisons pas ChatGPT</p>", "<p>We could use AI in the future</p>", "<p>Do we use AI?</p>", "<p>If we use AI, we will review it</p>", "<p>Our clients use AI</p>", "<p>We help our clients use AI</p>", "<blockquote>We use ChatGPT every day</blockquote>", "<footer>We use AI</footer>", "<nav>We use ChatGPT</nav>", "<p>Our client says we use AI</p>"]
                for html in negatives {
                    let page = SiteExtractor.read(html: html, url: URL(string: LeadKit.homePage)!, fetchedAt: LeadKit.now)
                    try expect(AIUseEvidence.find(in: [page], organisation: "Clinique Exemple Nord").isEmpty, html)
                }
            }),
            ("Booking or privacy signals cannot produce a Quick Scan draft", {
                let (researcher, _, candidate) = try fixture("<h1>Clinique Exemple Nord</h1><p>Prendre rendez-vous en ligne. Loi 25.</p>")
                let result = await researcher.research(candidate, segmentID: "clinic")
                try expect(!result.hasAIUseEvidence && result.record.trigger == nil, "not inferred from generic signal")
                try expect(result.draft(config: researcher.config, suppression: SuppressionList(), now: researcher.clock.now) == nil, "no unsupported draft")
            }),
            ("Tampered contact fields and off-domain proof are refused", {
                let (researcher, _, candidate) = try fixture()
                var result = await researcher.research(candidate, segmentID: "clinic")
                result.contacts[0].value = "invented@clinique-exemple.test"
                try expect(result.email == nil, "field must occur in its proof")
                result.contacts[0].value = "info@clinique-exemple.test"
                result.contacts[0].evidence.url = "https://other.test/contact"
                try expect(result.email == nil, "foreign evidence refused")
            }),
            ("Unrelated and noreply addresses are not business contact routes", {
                let page = SiteExtractor.read(html: "<p>noreply@clinique-exemple.test</p><p>Example: someone@other.test</p><a href=\"mailto:designer@other.test\">Website designer</a>", url: URL(string: LeadKit.homePage)!, fetchedAt: LeadKit.now)
                try expect(QuickScanResearcher.contacts(in: [page], domain: LeadKit.clinicDomain).isEmpty, "no guessed contact")
            }),
            ("Explicitly published external business mailbox keeps its source", {
                let page = SiteExtractor.read(html: "<p>Contactez-nous : clinique-exemple@gmail.com</p>", url: URL(string: LeadKit.contactPage)!, fetchedAt: LeadKit.now)
                let contacts = QuickScanResearcher.contacts(in: [page], domain: LeadKit.clinicDomain)
                try expect(contacts.first?.value == "clinique-exemple@gmail.com", "explicit public contact")
                let spaced = SiteExtractor.read(html: "<p>Courriel: service @ clinique-exemple.test</p>", url: URL(string: LeadKit.contactPage)!, fetchedAt: LeadKit.now)
                let normalised = QuickScanResearcher.contacts(in: [spaced], domain: LeadKit.clinicDomain)
                try expect(normalised.first?.value == "service@clinique-exemple.test" && normalised.first?.evidence.excerpt.contains("service @ clinique-exemple.test") == true, "normalisation retains printed evidence")
            }),
            ("No-solicitation on another checked page blocks the draft", {
                let (researcher, inner, candidate) = try fixture()
                inner.respond("https://www.clinique-exemple.test/notre-equipe", body: "<p>Alex Fictif, directrice générale</p><p>Aucune sollicitation</p>")
                let result = await researcher.research(candidate, segmentID: "clinic")
                try expect(result.hasAIUseEvidence && result.email != nil && result.record.consent == nil, "research still records facts")
                try expect(result.draft(config: researcher.config, suppression: SuppressionList(), now: researcher.clock.now) == nil, "no draft")
            }),
            ("Robots exclusions stop own-site research", {
                let (researcher, inner, candidate) = try fixture()
                inner.respond("https://www.clinique-exemple.test/robots.txt", body: "User-agent: *\nDisallow: /")
                let result = await researcher.research(candidate, segmentID: "clinic")
                try expect(result.record.snapshots.isEmpty && result.email == nil && !result.hasAIUseEvidence, "no fabricated observations")
                try expect(inner.urls.count == 1 && result.issues.contains { $0.contains("robots") }, "only robots fetched")
            }),
            ("Cross-domain redirect never supplies contact or AI evidence", {
                let (researcher, inner, candidate) = try fixture()
                inner.respondFrom(LeadKit.homePage, finalURL: "https://autre.test/", body: "<p>We use ChatGPT</p><p>info@autre.test</p>")
                let result = await researcher.research(candidate, segmentID: "clinic")
                try expect(result.record.snapshots.isEmpty && result.email == nil && !result.hasAIUseEvidence, "redirect refused")
            }),
            ("Cancellation starts no research requests and produces no draft", {
                let (researcher, inner, candidate) = try fixture()
                let task = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return await researcher.research(candidate, segmentID: "clinic")
                }
                let result = await task.value
                try expect(!result.complete && inner.urls.isEmpty, "cancelled before network")
                try expect(result.draft(config: researcher.config, suppression: SuppressionList(), now: researcher.clock.now) == nil, "no draft")
            }),
            ("Cancellation during host pacing prevents the next page request", {
                let config = try LeadKit.config()
                let inner = FakeLeadTransport()
                inner.respond("https://www.clinique-exemple.test/robots.txt", body: "User-agent: *\nAllow: /")
                let clock = CancelOnSleepClock()
                let guarded = GuardedLeadTransport(config: config, inner: inner, audit: MemoryAuditSink(), clock: clock)
                let researcher = QuickScanResearcher(config: config, transport: guarded, clock: clock)
                let (_, _, candidate) = try fixture()
                let task = Task { await researcher.research(candidate, segmentID: "clinic") }
                let result = await task.value
                try expect(!result.complete && inner.urls == ["https://www.clinique-exemple.test/robots.txt"], "cancelled wait must not be followed by a page fetch")
            }),
            ("Conflict and RBQ holds remain in force for researched trades", {
                let (researcher, _, candidate) = try fixture()
                let result = await researcher.research(candidate, segmentID: "construction_trades")
                try expect(result.record.status == .conflictReview && result.draft(config: researcher.config, suppression: SuppressionList(), now: researcher.clock.now) == nil, "licence hold preserved")
            }),
            ("Generic website discovery cannot bypass a trade licence hold", {
                let (researcher, _, candidate) = try fixture("<h1>Toiture Exemple</h1><p>Nous utilisons ChatGPT pour préparer les documents.</p>")
                let config = researcher.config.interactiveSearch()
                guard let segment = config.segments.first(where: { $0.osmSelectors.contains("office=company") }) else { throw PortableCheckFailure(description: "generic segment missing") }
                let result = await QuickScanResearcher(config: config, transport: researcher.transport, clock: researcher.clock).research(candidate, segmentID: segment.id)
                try expect(result.record.status == .conflictReview && result.record.reasons.contains { $0.contains("rbq-licence-unverified") }, "generic input did not bypass held trade")
                try expect(result.draft(config: config, suppression: SuppressionList(), now: researcher.clock.now) == nil, "no draft for an unverified construction firm")
            }),
            ("A construction client mentioned by a web agency is not the agency's trade", {
                let (researcher, _, candidate) = try fixture("<h1>Agence web Exemple</h1><p>Client: Construction Exemple</p><p>Nous utilisons ChatGPT pour préparer les documents.</p>")
                let config = researcher.config.interactiveSearch()
                let segment = config.segments.first { $0.osmSelectors.contains("office=company") }!
                let result = await QuickScanResearcher(config: config, transport: researcher.transport, clock: researcher.clock).research(candidate, segmentID: segment.id)
                try expect(result.record.segment == segment.id && !result.record.reasons.contains { $0.contains("rbq-licence-unverified") }, "portfolio text did not change business identity")
            }),
            ("A printed multiline unit address remains verbatim own-site evidence", {
                let (researcher, inner, candidate) = try fixture()
                let address = "1201 - 200 Exemple-Nord\nMontréal, Qc\nH0H 0H0"
                inner.respond("https://www.clinique-exemple.test/en/contact-us", body: "<address>1201 - 200 Exemple-Nord<br>Montréal, Qc<br>H0H 0H0</address><a href=\"mailto:info@clinique-exemple.test\">Contact</a>")
                let result = await researcher.research(candidate, segmentID: "clinic")
                try expect(result.record.address == address && AddressProvenance.check(result.record) == nil, "exact multiline source retained")
                try expect(result.draft(config: researcher.config, suppression: SuppressionList(), now: researcher.clock.now) != nil, "address formatting does not withhold a grounded draft")
                try expect(SiteExtractor.address(in: "514-555-0100\nMontréal, QC\nH0H 0H0") == nil, "a phone and postal code are not a street address")
            }),
            ("Source evidence and dated research survive encoding", {
                let (researcher, _, candidate) = try fixture()
                let result = await researcher.research(candidate, segmentID: "clinic")
                let restored = try JSONDecoder.iso.decode(QuickScanResearchResult.self, from: JSONEncoder.iso.encode(result))
                try expect(restored == result && restored.email == result.email && restored.hasAIUseEvidence, "round trip")
                var legacy = try JSONSerialization.jsonObject(with: JSONEncoder.iso.encode(result)) as! [String: Any]
                legacy.removeValue(forKey: "researchVersion")
                let earlier = try JSONDecoder.iso.decode(QuickScanResearchResult.self, from: JSONSerialization.data(withJSONObject: legacy))
                try expect(earlier.researchVersion == nil && earlier.email == result.email, "older findings stay readable and can be rechecked")
            }),
            ("A withheld draft explains the unchanged address requirement", {
                let (researcher, _, candidate) = try fixture()
                var result = await researcher.research(candidate, segmentID: "clinic")
                result.record.address = nil
                let assessment = result.draftAssessment(config: researcher.config, suppression: SuppressionList(), now: researcher.clock.now)
                try expect(assessment.draft == nil && assessment.reason?.lowercased().contains("address") == true, "missing address is explained, not bypassed")
            }),
            ("Only the explicitly selected Quick Scan price is allowed; other pricing stays blocked", {
                let (researcher, _, candidate) = try fixture()
                let result = await researcher.research(candidate, segmentID: "clinic")
                guard var draft = result.draft(config: researcher.config, suppression: SuppressionList(), now: researcher.clock.now) else {
                    throw PortableCheckFailure(description: "Quick Scan draft refused")
                }
                try expect(OutreachDraftGate.content(draft, config: researcher.config) == nil, "approved offer")
                let approvedHash = OutreachApproval.contentHash(draft)
                draft.approvedOffer = nil
                try expect(OutreachDraftGate.content(draft, config: researcher.config)?.code == "refused:draft-content:pricing", "no global price exception")
                try expect(OutreachApproval.contentHash(draft) != approvedHash, "offer designation bound to approval")
                draft.approvedOffer = .quickScan99CAD
                draft.body += "\nAnother offer costs 500 $ CA."
                try expect(OutreachDraftGate.content(draft, config: researcher.config)?.code == "refused:draft-content:pricing", "other amount blocked")
            }),

        ])
    }
}
