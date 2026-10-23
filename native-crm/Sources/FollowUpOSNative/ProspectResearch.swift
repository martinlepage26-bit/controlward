import Foundation

/// One piece of on-site evidence: the page and a verbatim excerpt of its text.
struct FactEvidence: Codable, Equatable, Hashable, Sendable {
    var url: String
    var excerpt: String
}

/// What the business's own site says, and nothing more. Every filled field has evidence under its key.
struct ObservedFacts: Codable, Equatable, Sendable {
    var companyName: String
    var serviceCategories: [String] = []
    var serviceAreas: [String] = []
    /// `fr` and/or `en`, as seen on the site.
    var languagesSeen: [String] = []
    var contactPageURL: String?
    var bookingURL: String?
    /// Fact key (`company_name`, `service_categories`, `service_areas`, `languages_seen`, `contact_page_url`, `booking_url`) to evidence.
    var evidence: [String: [FactEvidence]] = [:]

    enum CodingKeys: String, CodingKey {
        case companyName = "company_name", serviceCategories = "service_categories", serviceAreas = "service_areas"
        case languagesSeen = "languages_seen", contactPageURL = "contact_page_url", bookingURL = "booking_url", evidence
    }

    /// Writes `contact_page_url` and `booking_url` as `null` when unknown, so the stored object always has every field.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(companyName, forKey: .companyName)
        try container.encode(serviceCategories, forKey: .serviceCategories)
        try container.encode(serviceAreas, forKey: .serviceAreas)
        try container.encode(languagesSeen, forKey: .languagesSeen)
        try container.encode(contactPageURL, forKey: .contactPageURL)
        try container.encode(bookingURL, forKey: .bookingURL)
        try container.encode(evidence, forKey: .evidence)
    }
}

/// ControlWard's reading of the facts. A draft may quote only evidence that checks out against the stored snapshots.
struct ResearchAssessment: Codable, Equatable, Sendable {
    var potentialOffer: String?
    var supportingEvidence: [FactEvidence] = []
    var unknowns: [String] = []
    var requiresManualReview = true

    enum CodingKeys: String, CodingKey {
        case potentialOffer = "potential_offer", supportingEvidence = "supporting_evidence", unknowns, requiresManualReview = "requires_manual_review"
    }
}

struct ProspectResearch: Codable, Equatable, Sendable {
    var observedFacts: ObservedFacts
    var assessment: ResearchAssessment

    enum CodingKeys: String, CodingKey {
        case observedFacts = "observed_facts", assessment
    }
}

/// Builds `observed_facts` and `assessment` from own-site pages only. Local text processing, no requests.
enum ProspectResearcher {
    static let maxExcerpt = 160
    static let bookingWords = ["rendez-vous", "rendezvous", "booking", "book-online", "book online", "reservation", "réservation", "appointment", "prendre-rdv"]
    static let contactPathWords = ["contact", "nous-joindre", "joindre"]
    static let areaPattern = "(?i)\\b(?:territoires?\\s+desservis?|secteurs?\\s+desservis?|r[ée]gions?\\s+desservies?|nous\\s+desservons|desservons|nous\\s+servons|service\\s+areas?|serving|we\\s+serve)\\b\\s*:?\\s*(.+)"
    static let frenchWords: Set<String> = ["nous", "votre", "vos", "notre", "nos", "les", "des", "pour", "avec", "équipe", "joindre", "rendez-vous", "services"]
    static let englishWords: Set<String> = ["our", "your", "the", "and", "with", "team", "contact", "us", "book", "services", "about"]

    static func research(name: String, pages: [SiteExtractor.Page], segment: ICPConfig.Segment, triggers: [ProspectTrigger],
                         config: ICPConfig) -> ProspectResearch {
        var facts = ObservedFacts(companyName: name)
        if let hit = firstLine(in: pages, where: { $0.lowercased().contains(name.lowercased()) }) {
            facts.evidence["company_name"] = [hit]
        }
        for keyword in segment.keywords {
            if let hit = firstLine(in: pages, where: { $0.lowercased().contains(keyword.lowercased()) }) {
                facts.serviceCategories.append(keyword)
                facts.evidence["service_categories", default: []].append(hit)
            }
        }
        for page in pages {
            for line in lines(page.text) {
                guard let area = capture(line, areaPattern) else { continue }
                let cleaned = area.trimmingCharacters(in: CharacterSet(charactersIn: " .;:"))
                guard !cleaned.isEmpty, !facts.serviceAreas.contains(cleaned) else { continue }
                facts.serviceAreas.append(cleaned)
                facts.evidence["service_areas", default: []].append(FactEvidence(url: page.url, excerpt: clip(line)))
            }
        }
        for (code, words) in [("fr", frenchWords), ("en", englishWords)] {
            if let hit = firstLine(in: pages, where: { languageScore($0, words) >= 2 }) {
                facts.languagesSeen.append(code)
                facts.evidence["languages_seen", default: []].append(hit)
            }
        }
        if let page = pages.first(where: { page in
            let path = (URL(string: page.url)?.path ?? "").lowercased()
            return contactPathWords.contains { path.contains($0) } && !page.text.isEmpty
        }), let first = lines(page.text).first {
            facts.contactPageURL = page.url
            facts.evidence["contact_page_url"] = [FactEvidence(url: page.url, excerpt: clip(first))]
        }
        for page in pages {
            guard facts.bookingURL == nil else { break }
            if let link = page.links.first(where: { link in bookingWords.contains { link.lowercased().contains($0) } && !link.lowercased().hasPrefix("mailto:") }) {
                facts.bookingURL = link
                let line = lines(page.text).first { line in bookingWords.contains { line.lowercased().contains($0) } }
                facts.evidence["booking_url"] = [FactEvidence(url: page.url, excerpt: line.map(clip) ?? link)]
            }
        }

        var assessment = ResearchAssessment()
        for trigger in triggers {
            guard let page = pages.first(where: { $0.url == trigger.url }) else { continue }
            let phrases = config.triggerSignals[trigger.kind] ?? []
            if let line = lines(page.text).first(where: { line in phrases.contains { SiteExtractor.phraseMatches($0, in: line) } }) {
                assessment.supportingEvidence.append(FactEvidence(url: page.url, excerpt: clip(line)))
            }
        }
        if let first = triggers.first, !assessment.supportingEvidence.isEmpty {
            assessment.potentialOffer = "\(segment.label): AI-use guardrails review (signal: \(first.kind))"
        }
        if facts.evidence["company_name"] == nil { assessment.unknowns.append("company name not seen on the site") }
        if facts.serviceCategories.isEmpty { assessment.unknowns.append("service categories") }
        if facts.serviceAreas.isEmpty { assessment.unknowns.append("service areas") }
        if facts.languagesSeen.isEmpty { assessment.unknowns.append("site language") }
        if facts.contactPageURL == nil { assessment.unknowns.append("contact page") }
        if facts.bookingURL == nil { assessment.unknowns.append("booking URL") }
        if assessment.potentialOffer == nil { assessment.unknowns.append("no on-site signal for an offer") }
        assessment.requiresManualReview = assessment.potentialOffer == nil || assessment.supportingEvidence.isEmpty
        return ProspectResearch(observedFacts: facts, assessment: assessment)
    }

    /// True when the evidence page is one of the stored snapshots and the excerpt is verbatim in it (text or links).
    static func isEvidenced(_ evidence: FactEvidence, in snapshots: [SiteSnapshot]) -> Bool {
        guard !evidence.excerpt.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return snapshots.contains { $0.url == evidence.url && ($0.text.contains(evidence.excerpt) || ($0.links ?? []).contains(evidence.excerpt)) }
    }

    /// Everything a draft is allowed to quote: evidenced observed facts and evidenced supporting evidence.
    static func citable(_ record: ProspectRecord) -> [FactEvidence] {
        guard let research = record.research else { return [] }
        let all = research.observedFacts.evidence.values.flatMap { $0 } + research.assessment.supportingEvidence
        return all.filter { isEvidenced($0, in: record.snapshots) }
    }

    /// The single quote a draft uses: the first evidenced supporting excerpt.
    static func citation(for record: ProspectRecord) -> FactEvidence? {
        guard let research = record.research, !research.assessment.requiresManualReview else { return nil }
        return research.assessment.supportingEvidence.first { isEvidenced($0, in: record.snapshots) }
    }

    // MARK: - Text helpers

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func clip(_ line: String) -> String {
        line.count <= maxExcerpt ? line : String(line.prefix(maxExcerpt))
    }

    static func firstLine(in pages: [SiteExtractor.Page], where match: (String) -> Bool) -> FactEvidence? {
        for page in pages {
            if let line = lines(page.text).first(where: match) { return FactEvidence(url: page.url, excerpt: clip(line)) }
        }
        return nil
    }

    static func languageScore(_ line: String, _ words: Set<String>) -> Int {
        let tokens = line.lowercased().components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "-")).inverted)
        return Set(tokens.filter { words.contains($0) }).count
    }

    static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}

/// Place id + normalized domain dedupe, and the closed-business filter.
enum ProspectIdentity {
    static func normalizedDomain(_ domain: String?) -> String? {
        guard var host = domain?.trimmingCharacters(in: .whitespaces).lowercased(), !host.isEmpty else { return nil }
        if let parsed = URL(string: host.contains("://") ? host : "https://\(host)")?.host?.lowercased() { host = parsed }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return HostMatch.registrable(host)
    }

    /// OSM lifecycle prefixes and tags that mean the place no longer operates.
    static let closedTagPrefixes = ["disused:", "abandoned:", "was:", "demolished:", "removed:", "razed:", "destroyed:", "closed:"]
    static let closedTags = ["disused=yes", "abandoned=yes", "opening_hours=closed", "opening_hours=off", "shop=vacant", "amenity=vacant"]
    static let closedNamePattern = "(?i)\\((ferm[ée]e?|closed)\\)|\\bpermanently closed\\b|\\bferm[ée]e? d[ée]finitivement\\b"
    static let closedSitePattern = "(?i)\\b(d[ée]finitivement ferm[ée]e?s?|ferm[ée]e?s? d[ée]finitivement|fermeture d[ée]finitive|permanently closed|closed permanently|nous avons ferm[ée] nos portes|we have closed our doors)\\b"

    static func isClosed(tags: [String: String], name: String) -> Bool {
        if tags.keys.contains(where: { key in closedTagPrefixes.contains { key.hasPrefix($0) } }) { return true }
        if tags.contains(where: { closedTags.contains("\($0.key)=\($0.value.lowercased())") }) { return true }
        if let end = tags["end_date"], !end.isEmpty { return true }
        return name.range(of: closedNamePattern, options: .regularExpression) != nil
    }

    static func siteSaysClosed(_ pages: [SiteExtractor.Page]) -> Bool {
        pages.contains { $0.text.range(of: closedSitePattern, options: .regularExpression) != nil }
    }
}

/// Funnel for the Overview: discovered → usable website → appropriate contact → evidence-backed opportunity.
struct LeadFunnel: Codable, Equatable, Sendable {
    var discovered = 0
    var withUsableWebsite = 0
    var appropriateContact = 0
    var evidenceBackedOpportunity = 0

    static let labels = ["Businesses discovered", "With a usable website", "Appropriate contact found", "Evidence-backed opportunity"]
    var values: [Int] { [discovered, withUsableWebsite, appropriateContact, evidenceBackedOpportunity] }
    var stages: [(label: String, value: Int)] { Array(zip(Self.labels, values)).map { (label: $0.0, value: $0.1) } }

    /// A named person from the own site (LEAD_DEF) and a route from the own site.
    static func hasAppropriateContact(_ record: ProspectRecord, config: ICPConfig, now: Date) -> Bool {
        guard record.route?.source == .ownSite else { return false }
        return !LeadDefinition.evaluate(record, config: config, now: now).reasons.contains("no named person")
    }

    static func isEvidenceBacked(_ record: ProspectRecord) -> Bool {
        guard let research = record.research, !research.assessment.requiresManualReview, research.assessment.potentialOffer != nil else { return false }
        return !research.assessment.supportingEvidence.isEmpty
            && research.assessment.supportingEvidence.allSatisfy { ProspectResearcher.isEvidenced($0, in: record.snapshots) }
    }

    static func compute(places: [DiscoveredPlace], records: [ProspectRecord], config: ICPConfig, now: Date) -> LeadFunnel {
        var funnel = LeadFunnel()
        let open = places.filter { !$0.closed }
        funnel.discovered = open.count
        funnel.withUsableWebsite = open.filter(\.usableWebsite).count
        let live = records.filter { $0.status != .drop && !$0.isTest }
        funnel.appropriateContact = live.filter { hasAppropriateContact($0, config: config, now: now) }.count
        funnel.evidenceBackedOpportunity = live.filter { hasAppropriateContact($0, config: config, now: now) && isEvidenceBacked($0) }.count
        return funnel
    }
}

/// One discovered place, kept for the funnel. Holds the OSM id and domain only: no contact data.
struct DiscoveredPlace: Codable, Equatable, Sendable {
    var placeID: String
    var domain: String?
    var usableWebsite: Bool
    var closed = false

    enum CodingKeys: String, CodingKey { case placeID = "place_id", domain, usableWebsite = "usable_website", closed }

    /// Merge by place id, then by normalized domain. A later sighting can upgrade `usableWebsite`.
    static func merge(_ incoming: [DiscoveredPlace], into existing: [DiscoveredPlace]) -> [DiscoveredPlace] {
        var out = existing
        for place in incoming {
            let domain = ProspectIdentity.normalizedDomain(place.domain)
            if let index = out.firstIndex(where: { $0.placeID == place.placeID || (domain != nil && ProspectIdentity.normalizedDomain($0.domain) == domain) }) {
                out[index].usableWebsite = out[index].usableWebsite || place.usableWebsite
                out[index].closed = out[index].closed || place.closed
                if out[index].domain == nil { out[index].domain = domain }
                continue
            }
            out.append(DiscoveredPlace(placeID: place.placeID, domain: ProspectIdentity.normalizedDomain(place.domain), usableWebsite: place.usableWebsite, closed: place.closed))
        }
        return out
    }
}
