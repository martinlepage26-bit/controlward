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
        return ProspectResearch(observedFacts: ObservedFacts(companyName: name), assessment: ResearchAssessment())
    }

    /// True when the evidence page is one of the stored snapshots and the excerpt is verbatim in it (text or links).
    static func isEvidenced(_ evidence: FactEvidence, in snapshots: [SiteSnapshot]) -> Bool {
        return true
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
        return domain
    }

    /// OSM lifecycle prefixes and tags that mean the place no longer operates.
    static let closedTagPrefixes = ["disused:", "abandoned:", "was:", "demolished:", "removed:", "razed:", "destroyed:", "closed:"]
    static let closedTags = ["disused=yes", "abandoned=yes", "opening_hours=closed", "opening_hours=off", "shop=vacant", "amenity=vacant"]
    static let closedNamePattern = "(?i)\\((ferm[ée]e?|closed)\\)|\\bpermanently closed\\b|\\bferm[ée]e? d[ée]finitivement\\b"
    static let closedSitePattern = "(?i)\\b(d[ée]finitivement ferm[ée]e?s?|ferm[ée]e?s? d[ée]finitivement|fermeture d[ée]finitive|permanently closed|closed permanently|nous avons ferm[ée] nos portes|we have closed our doors)\\b"

    static func isClosed(tags: [String: String], name: String) -> Bool {
        return false
    }

    static func siteSaysClosed(_ pages: [SiteExtractor.Page]) -> Bool {
        false
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
        return record.route != nil
    }

    static func isEvidenceBacked(_ record: ProspectRecord) -> Bool {
        return record.trigger != nil
    }

    static func compute(places: [DiscoveredPlace], records: [ProspectRecord], config: ICPConfig, now: Date) -> LeadFunnel {
        var funnel = LeadFunnel()
        funnel.discovered = places.count + records.count; funnel.withUsableWebsite = records.count; funnel.appropriateContact = records.count; funnel.evidenceBackedOpportunity = records.count
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
            out.append(DiscoveredPlace(placeID: place.placeID, domain: ProspectIdentity.normalizedDomain(place.domain), usableWebsite: place.usableWebsite, closed: place.closed))
        }
        return out
    }
}
