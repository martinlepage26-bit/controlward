import Foundation

/// Local account intelligence v1. No connector or legacy signal score is promoted to buyer intent.
struct GTMWorkspace: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var profiles: [GTMProfile] = []
    var identities: [GTMIdentityReview] = []
    var externalAccounts: [GTMExternalAccount] = []
    var assessments: [GTMFitAssessment] = []
    var events: [GTMEvent] = []
    var reviews: [GTMEventReview] = []
    var retractions: [GTMRetraction] = []
    var observations: [GTMObservation] = []
    var snapshots: [GTMScoreSnapshot] = []
    var taskLinks: [GTMTaskLink] = []
}

struct GTMProfile: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    /// Immutable once saved. A changed policy is a new profile; no silent re-scoring of history.
    var criteria: [String]
    var createdAt = Date()
    static let labels = ["Sector / use case", "Organization size", "Serviceable geography", "Operational need"]
    static let weights = [30, 20, 20, 30]
}

struct GTMIdentityReview: Codable, Equatable, Sendable {
    var companyID: UUID
    var companyName: String
    var domain: String?
    var reason: String
    var suppressionReason: String
    var reviewedAt: Date
}

struct GTMExternalAccount: Codable, Equatable, Sendable {
    var source: String
    var externalID: String
    var companyID: UUID
}

enum GTMMatch: String, Codable, CaseIterable, Sendable {
    case unknown, match, nonmatch
    var label: String { self == .nonmatch ? "Does not match" : rawValue.capitalized }
}

struct GTMFitEvidence: Codable, Equatable, Sendable {
    var result: GTMMatch = .unknown
    var reference = ""
}

struct GTMFitAssessment: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var companyID: UUID
    var profileID: UUID
    var evidence: [GTMFitEvidence]
    var exclusionReason = ""
    var assessedAt = Date()
}

enum GTMEventKind: String, Codable, CaseIterable, Sendable {
    case webEngagement, contentRequest, positiveReply, handRaise, publicListing, outboundMessage
    var label: String {
        switch self {
        case .webEngagement: "Meaningful website activity"
        case .contentRequest: "Requested content"
        case .positiveReply: "Positive buyer reply"
        case .handRaise: "Demo / consultation request"
        case .publicListing: "Public listing (research only)"
        case .outboundMessage: "Outbound message (not buyer activity)"
        }
    }
    var parameters: (weight: Double, cap: Double, halfLife: Double)? {
        switch self {
        case .webEngagement: (5, 10, 7)
        case .contentRequest: (10, 20, 14)
        case .positiveReply: (25, 25, 21)
        case .handRaise: (60, 60, 30)
        case .publicListing, .outboundMessage: nil
        }
    }
}

struct GTMEvent: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var profileID: UUID
    var source: String
    var sourceEventID: String
    var sourceAccountID: String
    var accountName: String
    /// Same real-world action must keep this key across adapters and event families.
    var actionKey: String
    var candidateCompanyID: UUID?
    var domain: String
    var kind: GTMEventKind
    var occurredAt: Date
    var receivedAt: Date
    var reference: String
    var isBotOrInternal: Bool
}

struct GTMEventReview: Codable, Equatable, Sendable {
    var eventID: UUID
    var companyID: UUID
    var reason: String
    var reviewedAt: Date
}

struct GTMRetraction: Codable, Equatable, Sendable {
    var eventID: UUID
    var reason: String
    var retractedAt: Date
}

/// A reviewed observation window supports zero; a single event cannot establish absence of activity.
struct GTMObservation: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var companyID: UUID
    var profileID: UUID
    var source: String
    var startsAt: Date
    var throughAt: Date
    var reference: String
}

struct GTMContribution: Codable, Equatable, Sendable {
    var eventID: UUID
    var kind: GTMEventKind
    var points: Double
}

struct GTMScoreSnapshot: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var companyID: UUID
    var profileID: UUID
    var asOf: Date
    var ruleVersion = "contextward.rules.v1"
    var assessmentID: UUID?
    var fit: Int
    var coverage: Int
    var fitBand: String
    var intent: Int?
    var stage: String
    var identityVerified: Bool
    var sourceFresh: Bool
    var contributions: [GTMContribution]
    var observationIDs: [UUID]
    var reasons: [String]
    var queue: GTMReviewQueue
}

enum GTMReviewQueue: String, Codable, Sendable {
    case blocked, observing, salesReview, handRaiseReview
    var eligible: Bool { self == .salesReview || self == .handRaiseReview }
    var label: String {
        switch self {
        case .blocked: "Blocked"
        case .observing: "More evidence needed"
        case .salesReview: "Ready for review"
        case .handRaiseReview: "Hand-raise review"
        }
    }
}

struct GTMTaskLink: Codable, Equatable, Sendable {
    var companyID: UUID
    var profileID: UUID
    var taskID: UUID
    var snapshotID: UUID
    var createdAt: Date
}

/// JSON import is an evidence journal, not an executable workflow. All imported events need local review.
struct GTMImportBatch: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var source: String
    var accounts: [Account]
    var events: [Event]
    struct Account: Codable, Equatable, Sendable {
        var externalID: String
        var name: String
        var domain: String
    }
    struct Event: Codable, Equatable, Sendable {
        var sourceEventID: String
        var accountExternalID: String
        var actionKey: String
        var kind: GTMEventKind
        var occurredAt: Date
        var reference: String
        var isBotOrInternal: Bool
    }
}

enum GTMError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
