import Foundation

/// Where a person's title was confirmed (S3-R12).
enum TitleSource: String, Codable, Sendable {
    case checkedDirect = "checked-direct"
    case searchOnly = "search-only"
}

/// Where a contact, address or trigger came from. Only `ownSite` and the two registries are acceptable
/// person sources, and only `ownSite` is acceptable for an address or a consent basis (S3-R10, S3-R17).
enum ProspectDataSource: String, Codable, Sendable {
    case ownSite = "own_site"
    case registraire = "registraire_des_entreprises"
    case professionalOrder = "professional_order_directory"
    case openStreetMap = "osm"
    case searchSnippet = "search_snippet"
    case rbqOpenData = "rbq_open_data"
    case dataBroker = "data_broker"
    case linkedin
}

/// Who put the record into ControlWard (S3-R16).
enum ProspectProvenance: String, Codable, Sendable {
    /// ControlWard's own search and fetcher.
    case controlWardSearch = "controlward-search"
    /// A record found by search anywhere else (an agent, a script, a spreadsheet).
    case externalSearch = "external-search"
    /// A lead from one of Martin's own web forms.
    case inboundForm = "inbound-form"
    /// A synthetic test lead.
    case test
}

enum TriggerState: String, Codable, Sendable { case live, changed, gone }

/// How a trigger was observed. Only a fetched page or feed item counts (S3-R13).
enum TriggerOrigin: String, Codable, Sendable {
    case pageFetch = "page-fetch"
    case feedItem = "feed-item"
    case searchSnippet = "search-snippet"
    case inferred
}

struct ProspectTrigger: Codable, Equatable, Sendable {
    /// One of the segment's `triggers` in icp.json, e.g. `ai_tool_on_own_site`.
    var kind: String
    var url: String?
    var fetchedAt: Date?
    var origin: TriggerOrigin
    var state: TriggerState = .live
    /// Publication date of a job posting or notice, when the page gives one.
    var publishedAt: Date?
    /// Deadline of a tender, when known.
    var deadline: Date?
    var summary: String = ""
}

struct ProspectContact: Codable, Equatable, Sendable {
    var name: String
    var title: String?
    var titleSource: TitleSource?
    var source: ProspectDataSource
    var sourceURL: String?
}

/// A public way to reach the person, published on the business's own site.
struct ProspectRoute: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case email, phone, form }
    var kind: Kind
    var value: String
    var sourceURL: String
    /// Only `ownSite` is acceptable. An RBQ Courriel or phone never becomes a route.
    var source: ProspectDataSource = .ownSite
}

/// The stored text of one page from the business's own domain.
struct SiteSnapshot: Codable, Equatable, Sendable {
    var url: String
    var fetchedAt: Date
    var text: String
    /// Links seen on the page (optional so older stores still decode). Evidence for a booking URL may be a link.
    var links: [String]? = nil
    var host: String { URL(string: url)?.host?.lowercased() ?? "" }
}

/// The recorded consent basis (S3-R6): `express`, `implied:<reason>` or `conspicuous-publication:<url>`.
enum ConsentBasis: Equatable, Codable, Sendable {
    case express
    case implied(String)
    case conspicuousPublication(String)

    var text: String {
        switch self {
        case .express: "express"
        case .implied(let reason): "implied:\(reason)"
        case .conspicuousPublication(let url): "conspicuous-publication:\(url)"
        }
    }

    init?(text: String) {
        if text == "express" { self = .express; return }
        if text.hasPrefix("implied:"), text.count > 8 { self = .implied(String(text.dropFirst(8))); return }
        let prefix = "conspicuous-publication:"
        if text.hasPrefix(prefix), let url = URL(string: String(text.dropFirst(prefix.count))), url.scheme?.hasPrefix("http") == true {
            self = .conspicuousPublication(url.absoluteString); return
        }
        return nil
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = ConsentBasis(text: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown consent basis"))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

enum ProspectStatus: String, Codable, Sendable {
    case ready = "Ready"
    case fix = "Fix"
    case drop = "Drop"
    /// Held for Martin (conflict area); never listed or drafted on its own (S3-R14, S3-R17d).
    case conflictReview = "conflict_review"
}

/// One prospect found by ControlWard's search, with its evidence.
struct ProspectRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var organisation: String
    var segment: String?
    /// The page the record's evidence was fetched from, and when (S3-R5).
    var sourceURL: String?
    var fetchedAt: Date?
    var provenance: ProspectProvenance = .controlWardSearch
    /// The run that produced it, e.g. `controlward:<uuid>`.
    var fetcher: String = "controlward"
    var isTest = false
    var businessDomain: String?
    var address: String?
    var addressSource: ProspectDataSource?
    var addressSourceURL: String?
    var snapshots: [SiteSnapshot] = []
    var contact: ProspectContact?
    var route: ProspectRoute?
    var trigger: ProspectTrigger?
    var fit: String?
    var risk: String?
    var consent: ConsentBasis?
    var email: String?
    var phone: String?
    var osmTags: [String] = []
    /// RBQ licence categories (open data). Used only for the conflict hold, never for contact data.
    var rbqCategories: [String] = []
    var linkedinNote: String?
    var openTenderURL: String?
    /// Set when any field came from an open-data file, e.g. `RBQ / Données Québec, CC BY 4.0`. Shown wherever the record is shown.
    var dataAttribution: String?
    var status: ProspectStatus = .fix
    var reasons: [String] = []
    /// Own-site research: `observed_facts` and `assessment`. Drafts quote only evidence that checks out against `snapshots`.
    var research: ProspectResearch?
}
