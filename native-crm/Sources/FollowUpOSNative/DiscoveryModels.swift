import Foundation

struct KairosStrategy: Codable, Equatable, Sendable {
    var positioning: String
    var audience: String
    var updatedAt: String?
}

struct KairosInsights: Codable, Equatable, Sendable {
    struct Totals: Codable, Equatable, Sendable {
        var posts: Int
        var impressions: Int
        var engagements: Int
        var follows: Int
    }
    struct Pillar: Codable, Equatable, Sendable {
        var name: String
        var posts: Int
        var avg_score: Double?
    }
    var window: String
    var totals: Totals
    var pillars: [Pillar]
}

struct KairosEnquiryState: Codable, Equatable, Sendable {
    var intent: String
    var status: String
    var lastMessageAt: String
    var hasIncomingText: Bool
    var eligible: Bool { intent.lowercased() == "lead" && status.lowercased() != "ignored" && hasIncomingText }
}

/// Account-scoped, read-only context. Aggregate content metrics never become prospect interest.
struct KairosDiscoveryContext: Codable, Equatable, Sendable {
    var endpoint: String
    var fetchedAt: String
    var strategyRevision: UUID
    var strategy: KairosStrategy?
    var insights: KairosInsights
    var disabledPlatforms: [String]?
    var inboxFetchedAt: String?
    var enquiryStates: [String: KairosEnquiryState]?

    var targetingBrief: String {
        guard let strategy else { return "No saved KAIROS strategy. Audience and offer fit need review." }
        return "Audience: \(strategy.audience)\nPositioning: \(strategy.positioning)\nSource: \(endpoint)/v1/strategy\nRetrieved: \(fetchedAt)"
    }

    func validate() throws {
        guard let url = URL(string: endpoint), ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              endpoint.count <= 2_000, fetchedAt.count <= 80,
              (strategy?.audience.count ?? 0) <= 20_000, (strategy?.positioning.count ?? 0) <= 20_000,
              (strategy?.updatedAt?.count ?? 0) <= 80,
              insights.window.count <= 80, insights.pillars.count <= 500,
              insights.pillars.allSatisfy({ $0.name.count <= 1_000 && $0.posts >= 0 && ($0.avg_score?.isFinite ?? true) }),
              [insights.totals.posts, insights.totals.impressions, insights.totals.engagements, insights.totals.follows].allSatisfy({ $0 >= 0 }),
              (disabledPlatforms?.count ?? 0) <= 100, disabledPlatforms?.allSatisfy({ $0.count <= 80 }) ?? true else {
            throw ResearchStorageError.invalidCache
        }
        guard (inboxFetchedAt?.count ?? 0) <= 80, (enquiryStates?.count ?? 0) <= 200,
              enquiryStates?.allSatisfy({ $0.key.hasPrefix("kairos:") && $0.key.count <= 507 && $0.value.intent.count <= 80 && $0.value.status.count <= 80 && $0.value.lastMessageAt.count <= 80 }) ?? true else {
            throw ResearchStorageError.invalidCache
        }
    }
}

enum DiscoveryFit: String, Codable, CaseIterable, Identifiable, Sendable {
    case unassessed, fits, outside
    var id: String { rawValue }
    var label: String {
        switch self { case .unassessed: "Fit unknown"; case .fits: "Fits the offer"; case .outside: "Outside the offer" }
    }
}

struct DiscoveryFitReview: Codable, Equatable, Sendable {
    var decision: DiscoveryFit
    var reason: String
    var reviewedAt: String
    var strategyRevision: UUID?
}

struct DiscoveryEnquiryLink: Codable, Equatable, Sendable {
    /// nil records an explicit unlink, so merging an older cache cannot resurrect it.
    var businessKey: String?
    var confirmedAt: String
    var reason: String?
    var incomingExcerpt: String?
    var incomingAt: String?
    var businessSourceURL: String?
}


enum ResearchStorageError: Error, LocalizedError {
    case responseTooLarge, invalidCache
    var errorDescription: String? {
        switch self {
        case .responseTooLarge: "Saved research exceeds the supported size. Existing evidence was retained."
        case .invalidCache: "Saved research has inconsistent identities. Existing evidence was retained."
        }
    }
}

struct DiscoveryCandidate: Codable, Identifiable, Equatable, Sendable {
    var sourceID: String
    var name: String
    var category: String
    var address: String
    var website: String?
    var phone: String?
    var email: String?
    var sourceURL: String
    var latitude: Double
    var longitude: Double
    var query: String
    var capturedAt: String

    var id: String { sourceID }
    var categoryLocationPoints: Int { sourceID.hasPrefix("website:") ? 0 : 50 }
    private func recorded(_ value: String?) -> Bool { !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var websitePoints: Int { recorded(website) ? 20 : 0 }
    var phonePoints: Int { recorded(phone) ? 15 : 0 }
    var emailPoints: Int { recorded(email) ? 15 : 0 }
    var researchPriority: Int { categoryLocationPoints + websitePoints + phonePoints + emailPoints }
    var readyForHumanReview: Bool { researchPriority >= 65 }
    var evidence: String {
        [
            "\(sourceID.hasPrefix("website:") ? "Website research input" : "Public business listing"): \(name)",
            "Category / area: \(category) · \(query)",
            address.isEmpty ? nil : "Address: \(address)",
            website.map { "Website: \($0)" },
            phone.map { "Phone: \($0)" },
            email.map { "Email: \($0)" },
            sourceID.hasPrefix("website:") ? nil : "Map coordinates: \(latitude), \(longitude)",
            "Source: \(sourceURL)",
            "Retrieved: \(capturedAt)",
            "Research priority: \(researchPriority)/100 (category/area \(categoryLocationPoints), website \(websitePoints), phone \(phonePoints), email \(emailPoints)). Buyer intent is unknown."
        ].compactMap { $0 }.joined(separator: "\n")
    }
}

/// Unreviewed findings survive closing the search sheet or the app. Native workspaces include them in backups;
/// reviewing or saving a lead never converts a public contact into a sent message.
struct WebsiteResearchCache: Codable, Equatable, Sendable {
    var candidates: [DiscoveryCandidate] = []
    var results: [String: QuickScanResearchResult] = [:]
    // Optional additions preserve workspaces/backups created before KAIROS targeting.
    var kairosContext: KairosDiscoveryContext?
    var enquiryBusinessLinks: [String: DiscoveryEnquiryLink]?
    var fitReviews: [String: DiscoveryFitReview]?

    static func load(_ url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let data = try Data(contentsOf: url)
        guard data.count <= 20_000_000 else { throw ResearchStorageError.responseTooLarge }
        let value = try JSONDecoder.iso.decode(Self.self, from: data)
        try value.validate()
        return value
    }

    mutating func merge(_ candidate: DiscoveryCandidate, result: QuickScanResearchResult) {
        discover([candidate])
        results[candidate.sourceID] = result
    }

    mutating func discover(_ incoming: [DiscoveryCandidate]) {
        for candidate in incoming {
            candidates.removeAll { $0.sourceID == candidate.sourceID }
            candidates.append(candidate)
        }
    }

    func validate() throws {
        let ids = Set(candidates.map(\.sourceID))
        guard candidates.count <= 10_000, results.count <= 10_000,
              ids.count == candidates.count, ids.allSatisfy({ !$0.isEmpty }),
              Set(results.keys).isSubset(of: ids),
              (enquiryBusinessLinks?.count ?? 0) <= 10_000, (fitReviews?.count ?? 0) <= 10_000,
              enquiryBusinessLinks?.allSatisfy({ $0.key.hasPrefix("kairos:") && $0.key.count > 7 && $0.key.count <= 500 && ($0.value.businessKey.map { !$0.isEmpty && $0.count <= 1_000 } ?? true) && $0.value.confirmedAt.count <= 80 && ($0.value.reason?.count ?? 0) <= 2_000 && ($0.value.incomingExcerpt?.count ?? 0) <= 4_000 && ($0.value.incomingAt?.count ?? 0) <= 80 && ($0.value.businessSourceURL?.count ?? 0) <= 2_000 }) ?? true,
              fitReviews?.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 1_000 && $0.value.reason.count <= 2_000 && $0.value.reviewedAt.count <= 80 }) ?? true else { throw ResearchStorageError.invalidCache }
        try kairosContext?.validate()
    }

    /// Recovery and legacy copies never replace newer research already saved in the workspace.
    mutating func mergePreservingNewest(_ incoming: Self) {
        for candidate in incoming.candidates {
            if let result = incoming.results[candidate.sourceID] {
                if let old = results[candidate.sourceID], old.checkedAt > result.checkedAt { continue }
                merge(candidate, result: result)
            } else if !candidates.contains(where: { $0.sourceID == candidate.sourceID }) { discover([candidate]) }
        }
        if let context = incoming.kairosContext, context.fetchedAt > (kairosContext?.fetchedAt ?? "") { kairosContext = context }
        for (source, link) in incoming.enquiryBusinessLinks ?? [:] {
            if link.confirmedAt > (enquiryBusinessLinks?[source]?.confirmedAt ?? "") {
                if enquiryBusinessLinks == nil { enquiryBusinessLinks = [:] }
                enquiryBusinessLinks?[source] = link
            }
        }
        for (key, review) in incoming.fitReviews ?? [:] {
            if review.reviewedAt > (fitReviews?[key]?.reviewedAt ?? "") {
                if fitReviews == nil { fitReviews = [:] }
                fitReviews?[key] = review
            }
        }
    }

    func save(_ url: URL) throws {
        try validate()
        let data = try JSONEncoder.iso.encode(self)
        guard data.count <= 20_000_000 else { throw ResearchStorageError.responseTooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

