import Foundation

/// A refusal from any lead-pipeline gate. `code` is the CW-AUDIT `result=` value, e.g. `refused:loi25-gate`.
struct LeadPipelineRefusal: Error, Equatable, CustomStringConvertible, Sendable {
    var code: String
    var detail: String = ""
    var description: String { detail.isEmpty ? code : "\(code) (\(detail))" }
}

/// The ICP and pipeline policy, read from `Resources/config/icp.json` (S3-R9).
/// Segment ids are data: Swift code never lists them.
struct ICPConfig: Codable, Equatable, Sendable {
    struct Segment: Codable, Equatable, Sendable {
        var id: String
        var label: String
        var priority: Int
        var triggerRule: String
        var osmSelectors: [String]
        var keywords: [String]
        var allowedContactSources: [String]
        var ownSitePaths: [String]
        var triggers: [String]
    }
    struct TriggerRule: Codable, Equatable, Sendable {
        var maxFetchAgeDays: Int
        var jobPostingMaxAgeDays: Int?
    }
    struct ContentRule: Codable, Equatable, Sendable {
        var rule: String
        var patterns: [String]
    }
    struct ConflictArea: Codable, Equatable, Sendable {
        var id: String
        var description: String
        var action: String
        var osmSelectors: [String]
        var keywords: [String]
        var region: String
        /// RBQ sub-category codes (e.g. "15.5", "2.5", "GPC") that put a licensed firm in this hold. Matched exactly against
        /// the codes of the whole licence, after grouping the file's rows by "Numéro de licence".
        var rbqSubcategoryCodes: [String]?
        /// Where the codes were checked: RBQ's own sub-category list (URL and date).
        var rbqSubcategorySource: String?
        /// Segments that are held unless the RBQ lookup matched a licence (fail closed: no file, no match or a parse error holds).
        var rbqRequiredSegments: [String]?
    }
    struct Sender: Codable, Equatable, Sendable {
        var name: String
        var organization: String
        var from: String
        var mailingAddress: String
        var unsubscribeMailto: String
        var unsubscribeSubject: String
    }
    struct Loi25Gate: Codable, Equatable, Sendable {
        var open: Bool
        var note: String?
        var martinAddresses: [String]
    }
    struct DisabledSource: Codable, Equatable, Sendable {
        var id: String
        var hosts: [String]
        var enabled: Bool
        var reason: String
        var allowedPathPrefixes: [String]?
        var deniedPathPrefixes: [String]?
        var minSecondsBetweenRequests: Double?
    }
    /// A host that is never fetched, whatever else the config says.
    struct DeniedHost: Codable, Equatable, Sendable {
        var pattern: String
        /// `host` matches exactly; `domain` matches the domain and every subdomain.
        var match: String
        var reason: String
    }
    struct Allowlist: Codable, Equatable, Sendable {
        var discoveryHosts: [String]
        var discoveryNote: String?
        var businessDomain: String
        var watchHosts: [String]
        var gmailHosts: [String]
        var disabledSources: [DisabledSource]
        var deniedHosts: [DeniedHost]
        var openDataSources: [OpenDataSource]
    }
    /// A public open-data file fetched only from fixed download URLs (e.g. the RBQ licence list).
    struct OpenDataSource: Codable, Equatable, Sendable {
        var id: String
        var label: String
        var attribution: String
        var licenceUrl: String
        var datasetUrl: String
        var enabled: Bool
        var host: String
        var downloadUrls: [String]
        var deniedPathPrefixes: [String]
        var minSecondsBetweenRequests: Double
        var maxDownloadAgeHours: Double
        var maxResponseBytes: Int
        var uses: [String]
        var fields: [FieldLabel]
        var neverStoredFields: [String]
        /// Every column the real file is known to have. A key outside this list stops the parse (refused:open-data-schema).
        var knownHeaders: [String]?
        /// Keys allowed in one entry of the nested sub-category list ("Categorie", "Sous-catégories").
        var knownSubcategoryKeys: [String]?
        var headerNote: String?
        var note: String?
        struct FieldLabel: Codable, Equatable, Sendable { var role: String; var label: String }
        func label(_ role: String) -> String? { fields.first { $0.role == role }?.label }
    }
    struct Etiquette: Codable, Equatable, Sendable {
        var userAgent: String
        var minSecondsBetweenRequestsPerHost: Double
        var maxPagesPerSite: Int
        var maxResponseBytes: Int
        var neverFetchDomains: [String]
        var linkedinNote: String
        var botChallenge: String?
        /// Overpass retry policy (Air): attempts per server and exponential backoff on timeout, 429 or 5xx.
        var discoveryRetry: DiscoveryRetry?
    }
    struct DiscoveryRetry: Codable, Equatable, Sendable {
        var attemptsPerHost: Int
        var baseDelaySeconds: Double
        var maxDelaySeconds: Double
        static let standard = DiscoveryRetry(attemptsPerHost: 2, baseDelaySeconds: 5, maxDelaySeconds: 60)
    }
    struct WatchFeed: Codable, Equatable, Sendable {
        var id: String
        var hostGroup: String
        var url: String?
        var enabled: Bool
        var reason: String?
    }

    var schema: String
    var segments: [Segment]
    var triggerRules: [String: TriggerRule]
    var triggerSignals: [String: [String]]
    var draftForbidden: [ContentRule]
    var conflictAreas: [ConflictArea]
    var sender: Sender
    var loi25Gate: Loi25Gate
    var allowlist: Allowlist
    var etiquette: Etiquette
    var watchFeeds: [WatchFeed]

    func segment(_ id: String?) -> Segment? { segments.first { $0.id == id } }

    /// The contact sources a segment may use today: listed for the segment and enabled in config.
    func enabledContactSources(for segment: Segment) -> [String] {
        segment.allowedContactSources.filter { id in
            id == ProspectDataSource.ownSite.rawValue || allowlist.disabledSources.first { $0.id == id }?.enabled == true
        }
    }

    static func decode(_ data: Data) throws -> ICPConfig {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ICPConfig.self, from: data)
    }

    /// Loads icp.json and icp.confirmed.json from a config directory and validates them together.
    static func load(directory: URL) throws -> ICPConfig {
        let config = try decode(Data(contentsOf: directory.appendingPathComponent("icp.json")))
        let confirmed = try ICPConfirmed.decode(Data(contentsOf: directory.appendingPathComponent("icp.confirmed.json")))
        if let refusal = config.validate(against: confirmed) { throw refusal }
        return config
    }

    /// The bundled config directory in the app, or `CONTROLWARD_CONFIG_DIR` when set (used by the scripted proof).
    static func defaultDirectory(bundle: Bundle? = nil) -> URL? {
        if let override = ProcessInfo.processInfo.environment["CONTROLWARD_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return bundle?.url(forResource: "config", withExtension: nil)
    }

    /// S3-R9: the configured segments must equal the confirmed list, each with the same priority.
    func validate(against confirmed: ICPConfirmed) -> LeadPipelineRefusal? {
        let ids = segments.map(\.id)
        if Set(ids).count != ids.count { return LeadPipelineRefusal(code: "refused:icp-config", detail: "duplicate segment") }
        let missing = confirmed.segments.filter { !ids.contains($0) }
        if !missing.isEmpty { return LeadPipelineRefusal(code: "refused:icp-config", detail: "segment dropped: \(missing.joined(separator: ","))") }
        let extra = ids.filter { !confirmed.segments.contains($0) }
        if !extra.isEmpty { return LeadPipelineRefusal(code: "refused:icp-config", detail: "segment not confirmed: \(extra.joined(separator: ","))") }
        if confirmed.equalPriority, Set(segments.map(\.priority)).count > 1 {
            return LeadPipelineRefusal(code: "refused:icp-config", detail: "unequal segment priority")
        }
        for segment in segments where triggerRules[segment.triggerRule] == nil {
            return LeadPipelineRefusal(code: "refused:icp-config", detail: "unknown trigger rule for \(segment.id)")
        }
        return nil
    }

    // MARK: - Hosts

    func disabledSource(forHost host: String) -> DisabledSource? {
        let host = host.lowercased()
        return allowlist.disabledSources.first { source in source.hosts.contains { host == $0.lowercased() } }
    }

    func deniedHost(_ host: String) -> DeniedHost? {
        let host = host.lowercased()
        return allowlist.deniedHosts.first { entry in
            entry.match == "host" ? host == entry.pattern : (host == entry.pattern || host.hasSuffix("." + entry.pattern))
        }
    }

    func openDataSource(forHost host: String) -> OpenDataSource? {
        allowlist.openDataSources.first { $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    func isNeverFetch(host: String) -> Bool {
        let host = host.lowercased()
        return etiquette.neverFetchDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func isMartinAddress(_ address: String) -> Bool {
        loi25Gate.martinAddresses.contains { $0.caseInsensitiveCompare(MailAddress.bare(address)) == .orderedSame }
    }
}

/// The segment list Martin confirmed (D1). Kept in its own file so a dropped segment in icp.json is caught.
struct ICPConfirmed: Codable, Equatable, Sendable {
    var schema: String
    var confirmedAt: String
    var segments: [String]
    var equalPriority: Bool

    static func decode(_ data: Data) throws -> ICPConfirmed {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ICPConfirmed.self, from: data)
    }
}

/// Finds a hard-coded segment list in Swift source (S3-R9). Two or more segment ids as string literals in one file is a hit.
enum ICPSourceScanner {
    static func hardCodedSegments(in source: String, segmentIDs: [String]) -> [String] {
        let hits = segmentIDs.filter { source.contains("\"\($0)\"") }
        return hits.count >= 2 ? hits : []
    }
}

enum MailAddress {
    /// `Name <a@b>` → `a@b`, lowercased and trimmed.
    static func bare(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            text = String(text[text.index(after: open)..<close])
        }
        return text.lowercased()
    }

    static func domain(_ value: String) -> String? {
        let bare = bare(value)
        guard let at = bare.lastIndex(of: "@") else { return nil }
        let domain = String(bare[bare.index(after: at)...])
        return domain.isEmpty ? nil : domain
    }
}

/// Host helpers shared by the transport guard and address provenance.
enum HostMatch {
    /// `www.example.ca` and `clinique.example.ca` both belong to `example.ca`.
    static func belongs(_ host: String, to domain: String) -> Bool {
        let host = host.lowercased(), domain = registrable(domain.lowercased())
        return host == domain || host.hasSuffix("." + domain)
    }

    /// Strips a leading `www.`; ControlWard treats the rest as the business domain.
    static func registrable(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
