import Foundation

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
              Set(results.keys).isSubset(of: ids) else { throw ResearchStorageError.invalidCache }
    }

    /// Recovery and legacy copies never replace newer research already saved in the workspace.
    mutating func mergePreservingNewest(_ incoming: Self) {
        for candidate in incoming.candidates {
            if let result = incoming.results[candidate.sourceID] {
                if let old = results[candidate.sourceID], old.checkedAt > result.checkedAt { continue }
                merge(candidate, result: result)
            } else if !candidates.contains(where: { $0.sourceID == candidate.sourceID }) { discover([candidate]) }
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

