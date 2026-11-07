import Foundation

enum LeadStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case new
    case contacted
    case quoteSent = "quote_sent"
    case won
    case lost

    var id: String { rawValue }

    var label: String {
        switch self {
        case .new: "New"
        case .contacted: "Contacted"
        case .quoteSent: "Quote Sent"
        case .won: "Won"
        case .lost: "Lost"
        }
    }

    var isOpen: Bool {
        self == .new || self == .contacted || self == .quoteSent
    }

    var initialFollowUpDelay: Int? {
        switch self {
        case .new: 1
        case .contacted: 3
        case .quoteSent: 7
        case .won, .lost: nil
        }
    }
}

struct BusinessProfile: Codable, Equatable, Sendable {
    var name = ""
    var industry = Industries.all[0]
}

struct FollowUpEvent: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date: String
    var action = "followup_sent"
    var message: String
}

struct Lead: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var email = ""
    var phone = ""
    var company = ""
    var companyID: UUID?
    var contactID: UUID?
    var service = ""
    var quoteAmount: Double?
    var status: LeadStatus = .new
    var nextFollowUp: String?
    var sequenceStage = 0
    var notes = ""
    /// Last outgoing-message context. Older KAIROS imports mixed incoming text into this field.
    var lastMessage = ""
    /// Unsent work, kept separate from recorded contact and sent-message history.
    var outreachDraft: String?
    /// Public website research, including literal source evidence and explicit unknowns.
    var quickScanResearch: QuickScanResearchResult?
    var history: [FollowUpEvent] = []
    var createdAt = Date.now.ISO8601Format()
    var wonAt: String?
    var lostAt: String?
    /// Stable upstream id, e.g. "leadgen:<identity id>", used to dedupe pulled leads. Not PII.
    var sourceID: String?
    /// Timestamp of the latest upstream message applied to this lead, when source-backed.
    var sourceUpdatedAt: String?
    /// Latest source-backed incoming message, separate from unsent drafts and sent history.
    var sourceMessage: String?
    /// Channel reported by the source. This is provenance, not a requested service.
    var sourcePlatform: String?
    /// The open follow-up task created when the owner converted this lead (its next action).
    var followUpTaskID: UUID?

    static func blank(today: Date = .now) -> Lead {
        var lead = Lead()
        lead.nextFollowUp = CalendarCRM.addDays(1, to: CalendarCRM.dayString(today))
        return lead
    }
}

struct PersistentWorkspace: Codable, Equatable, Sendable {
    var websiteResearch = WebsiteResearchCache()
    var researchMigrationComplete = true
    var researchGeneration = UUID()
    var consumedResearchRecovery: String?
    var restoredSuppressionEntries: [SuppressionList.Entry] = []
    var controlWard = ControlWardWorkspace()
    var accountIntelligence = GTMWorkspace()
    var business = BusinessProfile()
    var leads: [Lead] = []
    var contacts: [Contact] = []
    var companies: [Company] = []
    var opportunities: [Opportunity] = []
    var tasks: [CRMTask] = []
    var notes: [CRMNote] = []
    var signals: [Signal] = []
    var audits: [BilingualAudit] = []
    var automationRules: [AutomationRule] = AutomationRule.defaults
    var activity: [ActivityEvent] = []
    var syncJobs: [SyncJob] = []
    var exposureFindings: [ExposureFinding] = []
    var connectorEndpoints: [String: String] = [:]
    /// Last verification or sync result per connector. Never contains keys.
    var connectorHealth: [String: ConnectorHealth] = [:]
    /// Local record key (e.g. "company:<uuid>") to Twenty record id, for idempotent upserts.
    var twentyLinks: [String: TwentyLink] = [:]
    var savedViews: [SavedView] = SavedView.defaults
    var lastSecurityReview: String?
    /// Last PHAROS lead-inbox sequence number that was applied and acked.
    var leadInboxCursor: Int?
    /// Legacy background-pull preference retained only for backward-compatible decoding.
    var autoPullLeads = false
    /// When enabled, automations run on lead state changes and due-date triggers. External syncs still require preview and confirmation.
    var autoPilotEnabled = false
    /// Epoch of the inbox the cursor belongs to; a different epoch resets the cursor.
    var leadInboxEpoch: String?
    /// Imported source ids of deleted LeadGen/KAIROS leads, so later reads do not recreate them. Ids only.
    var dismissedLeadSources: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        websiteResearch = try container.decodeIfPresent(WebsiteResearchCache.self, forKey: .websiteResearch) ?? WebsiteResearchCache()
        researchMigrationComplete = try container.decodeIfPresent(Bool.self, forKey: .researchMigrationComplete) ?? false
        researchGeneration = try container.decodeIfPresent(UUID.self, forKey: .researchGeneration) ?? UUID()
        consumedResearchRecovery = try container.decodeIfPresent(String.self, forKey: .consumedResearchRecovery)
        restoredSuppressionEntries = try container.decodeIfPresent([SuppressionList.Entry].self, forKey: .restoredSuppressionEntries) ?? []
        try websiteResearch.validate()
        guard restoredSuppressionEntries.count <= 100_000,
              restoredSuppressionEntries.allSatisfy({ MailAddress.domain($0.address) != nil }) else {
            throw DecodingError.dataCorruptedError(forKey: .restoredSuppressionEntries, in: container, debugDescription: "Invalid restored unsubscribe records.")
        }
        controlWard = try container.decodeIfPresent(ControlWardWorkspace.self, forKey: .controlWard) ?? ControlWardWorkspace()
        accountIntelligence = try container.decodeIfPresent(GTMWorkspace.self, forKey: .accountIntelligence) ?? GTMWorkspace()
        guard accountIntelligence.schemaVersion == 1,
              accountIntelligence.profiles.allSatisfy({ $0.criteria.count == 4 }),
              accountIntelligence.assessments.allSatisfy({ $0.evidence.count == 4 }) else {
            throw DecodingError.dataCorruptedError(forKey: .accountIntelligence, in: container, debugDescription: "Unsupported or malformed account intelligence workspace.")
        }
        business = try container.decodeIfPresent(BusinessProfile.self, forKey: .business) ?? BusinessProfile()
        leads = try container.decodeIfPresent([Lead].self, forKey: .leads) ?? []
        contacts = try container.decodeIfPresent([Contact].self, forKey: .contacts) ?? []
        companies = try container.decodeIfPresent([Company].self, forKey: .companies) ?? []
        opportunities = try container.decodeIfPresent([Opportunity].self, forKey: .opportunities) ?? []
        tasks = try container.decodeIfPresent([CRMTask].self, forKey: .tasks) ?? []
        notes = try container.decodeIfPresent([CRMNote].self, forKey: .notes) ?? []
        signals = try container.decodeIfPresent([Signal].self, forKey: .signals) ?? []
        audits = try container.decodeIfPresent([BilingualAudit].self, forKey: .audits) ?? []
        automationRules = try container.decodeIfPresent([AutomationRule].self, forKey: .automationRules) ?? AutomationRule.defaults
        activity = try container.decodeIfPresent([ActivityEvent].self, forKey: .activity) ?? []
        syncJobs = try container.decodeIfPresent([SyncJob].self, forKey: .syncJobs) ?? []
        exposureFindings = try container.decodeIfPresent([ExposureFinding].self, forKey: .exposureFindings) ?? []
        connectorEndpoints = try container.decodeIfPresent([String: String].self, forKey: .connectorEndpoints) ?? [:]
        connectorHealth = try container.decodeIfPresent([String: ConnectorHealth].self, forKey: .connectorHealth) ?? [:]
        twentyLinks = try container.decodeIfPresent([String: TwentyLink].self, forKey: .twentyLinks) ?? [:]
        savedViews = try container.decodeIfPresent([SavedView].self, forKey: .savedViews) ?? SavedView.defaults
        lastSecurityReview = try container.decodeIfPresent(String.self, forKey: .lastSecurityReview)
        leadInboxCursor = try container.decodeIfPresent(Int.self, forKey: .leadInboxCursor)
        autoPullLeads = try container.decodeIfPresent(Bool.self, forKey: .autoPullLeads) ?? false
        leadInboxEpoch = try container.decodeIfPresent(String.self, forKey: .leadInboxEpoch)
        dismissedLeadSources = try container.decodeIfPresent([String].self, forKey: .dismissedLeadSources) ?? []
        autoPilotEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoPilotEnabled) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case websiteResearch, researchMigrationComplete, researchGeneration, consumedResearchRecovery, restoredSuppressionEntries
        case controlWard
        case accountIntelligence
        case business, leads, contacts, companies, opportunities, tasks, notes, signals, audits, automationRules, activity, syncJobs, exposureFindings, connectorEndpoints, connectorHealth, twentyLinks, savedViews, lastSecurityReview, leadInboxCursor, autoPullLeads, leadInboxEpoch, dismissedLeadSources, autoPilotEnabled
    }
}

/// Portable, versioned exchange envelope for future Twenty/API adapters.
/// It contains no credentials and is safe to review before any external sync.
struct WorkspaceExchange: Codable, Equatable, Sendable {
    var schemaVersion = "contextward.exchange.v1"
    var exportedAt = Date.now.ISO8601Format()
    var business: BusinessProfile
    var leads: [Lead]
    var contacts: [Contact]
    var companies: [Company]
    var opportunities: [Opportunity]
    var tasks: [CRMTask]
    var notes: [CRMNote]
    var signals: [Signal]
    var audits: [BilingualAudit]
    var activity: [ActivityEvent]
    var syncJobs: [SyncJob]
    var exposureFindings: [ExposureFinding]
    var connectorEndpoints: [String: String]
}

enum SyncTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case twenty, leadgen, pharos, gaps, kairos
    var id: String { rawValue }
    var label: String {
        switch self {
        case .twenty: "Twenty"
        case .leadgen: "LeadGen OS"
        case .pharos: "PHAROS backend"
        case .gaps: "Gap analysis"
        case .kairos: "Kairos"
        }
    }
    /// Targets whose API key is stored in the Keychain.
    static let keyed: [SyncTarget] = [.twenty, .pharos, .gaps, .kairos]
    /// Targets that receive exchange snapshots through the sync queue (gap analysis is read-only).
    static let exchangeTargets: [SyncTarget] = [.twenty, .leadgen, .pharos]
}

struct SyncJob: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var target: SyncTarget
    var status = "queued"
    var snapshotSchema = "contextward.exchange.v1"
    var createdAt = Date.now.ISO8601Format()
    var completedAt: String?
    var error: String?
    var idempotencyKey: String?
    /// Non-PII outcome summary, such as counts or a receipt id.
    var detail: String?
}

struct SyncManifest: Codable, Equatable, Sendable {
    var schemaVersion = "contextward.sync-manifest.v1"
    var target: SyncTarget
    var jobID: UUID
    var idempotencyKey: String
    var generatedAt = Date.now.ISO8601Format()
    var entityCounts: [String: Int]
    var exchangeSchema = "contextward.exchange.v1"
}

enum ExposureSeverity: String, Codable, CaseIterable, Identifiable, Sendable {
    case info, warning, high
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct ExposureFinding: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var lens: String
    var severity: ExposureSeverity
    var title: String
    var detail: String
    var recordID: UUID?
    var createdAt = Date.now.ISO8601Format()
    var resolved = false
}

enum SignalStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case captured, qualified, routed, nurtured, suppressed
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum SignalSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case website, referral, imported, event, manual, audit
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct Signal: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title = ""
    var source: SignalSource = .manual
    var status: SignalStatus = .captured
    var intentScore = 0
    var fitScore = 0
    var priority = 0
    var owner = ""
    var contactID: UUID?
    var companyID: UUID?
    var leadID: UUID?
    var evidence = ""
    var nextAction = ""
    var capturedAt = Date.now.ISO8601Format()
    var routedAt: String?
    /// Stable upstream id, e.g. "gap:<cluster id>", used to update instead of duplicate. Not PII.
    var sourceID: String?
    /// Lifecycle reported by an upstream source. Nil for local/legacy signals; false means
    /// the upstream record disappeared or is no longer active, without changing local workflow state.
    var sourceActive: Bool?
}

enum AuditLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case french = "FR"
    case english = "EN"
    var id: String { rawValue }
}

struct AuditDimensionScore: Codable, Equatable, Sendable {
    var disclosure: Double = 0
    var escalation: Double = 0
    var contextTransfer: Double = 0
    var tone: Double = 0
    var hallucinations: Double = 0

    var weightedTotal: Double {
        disclosure * 0.15 + escalation * 0.30 + contextTransfer * 0.30 + tone * 0.10 + hallucinations * 0.15
    }

    var isValid: Bool { [disclosure, escalation, contextTransfer, tone, hallucinations].allSatisfy { $0.isFinite && (0...100).contains($0) } }
}

struct BAEATranscript: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var transcriptID = ""
    var language: AuditLanguage = .english
    var workflow = ""
    var date = ""
    var scores = AuditDimensionScore()
    var taxonomyCodes = ""
    var notes = ""
    var source = ""
    var sampleCount: Int?
    var scoreFieldsComplete: Bool?
}

struct BilingualAudit: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var client = ""
    var sampleSizeFR = 0
    var sampleSizeEN = 0
    var french = AuditDimensionScore()
    var english = AuditDimensionScore()
    var transcripts: [BAEATranscript] = []
    var findings = ""
    var remediation = ""
    var leadID: UUID?
    var contactID: UUID?
    var companyID: UUID?
    var methodologyVersion = "Lantern v1.0 (BAEA-compatible)"
    var createdAt = Date.now.ISO8601Format()
    /// nil follows imported evidence (or a legacy single assessment). False is
    /// an explicit owner decision to withhold comparison until review is done.
    var frenchScoresComplete: Bool?
    var englishScoresComplete: Bool?

    var frenchAssessmentComplete: Bool { assessmentComplete(.french, declared: frenchScoresComplete, samples: sampleSizeFR, scores: french) }
    var englishAssessmentComplete: Bool { assessmentComplete(.english, declared: englishScoresComplete, samples: sampleSizeEN, scores: english) }
    var languageGap: Double? {
        guard frenchAssessmentComplete && englishAssessmentComplete else { return nil }
        return abs(english.weightedTotal - french.weightedTotal)
    }
    var unscoredReason: String? {
        guard languageGap == nil else { return nil }
        var reasons: [String] = []
        if sampleSizeFR <= 0 { reasons.append("French sample count is missing or zero.") }
        else if !frenchAssessmentComplete { reasons.append("French assessment needs complete scores or review of its source weights.") }
        if sampleSizeEN <= 0 { reasons.append("English sample count is missing or zero.") }
        else if !englishAssessmentComplete { reasons.append("English assessment needs complete scores or review of its source weights.") }
        return reasons.joined(separator: " ")
    }
    private func assessmentComplete(_ language: AuditLanguage, declared: Bool?, samples: Int, scores: AuditDimensionScore) -> Bool {
        guard samples > 0 && scores.isValid else { return false }
        if let declared { return declared }
        let evidence = transcripts.filter { $0.language == language && $0.sampleCount != 0 }
        guard !evidence.isEmpty || transcripts.isEmpty else { return false }
        // Old multi-row exports did not retain row weights and used the final
        // row as the aggregate. Preserve them, but do not endorse that result.
        if evidence.count > 1 && evidence.contains(where: { $0.sampleCount == nil || $0.scoreFieldsComplete == nil }) { return false }
        return evidence.allSatisfy { $0.scoreFieldsComplete != false && $0.scores.isValid && ($0.sampleCount.map { $0 > 0 } ?? true) }
    }
    var priority: String {
        guard let languageGap else { return "Unscored" }
        return switch languageGap {
        case 15...: "Critical"
        case 8..<15: "High"
        case 3..<8: "Moderate"
        default: "Low"
        }
    }
}

enum AutomationTrigger: String, Codable, CaseIterable, Identifiable, Sendable {
    case dueFollowUp = "due_follow_up"
    case highIntentSignal = "high_intent_signal"
    case auditGap = "audit_gap"
    var id: String { rawValue }
    var label: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

struct AutomationRule: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var trigger: AutomationTrigger
    var enabled = true
    var action: String

    static let defaults = [
        AutomationRule(name: "Create a task for due follow-ups", trigger: .dueFollowUp, action: "Create follow-up task"),
        AutomationRule(name: "Route high-intent signals", trigger: .highIntentSignal, action: "Route to workspace owner"),
        AutomationRule(name: "Flag material Lantern gaps", trigger: .auditGap, action: "Create remediation task"),
    ]
}

struct ActivityEvent: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: String
    var message: String
    var sourceID: UUID?
    var createdAt = Date.now.ISO8601Format()
}

struct Contact: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var firstName = ""
    var lastName = ""
    var email = ""
    var phone = ""
    var title = ""
    var companyID: UUID?
    var leadID: UUID?
    var createdAt = Date.now.ISO8601Format()
    var displayName: String { [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ") }
}

struct Company: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var domain = ""
    var industry = ""
    var phone = ""
    var notes = ""
    var createdAt = Date.now.ISO8601Format()
}

enum OpportunityStage: String, Codable, CaseIterable, Identifiable, Sendable {
    case lead, qualified, proposal, negotiation, won, lost
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var isClosed: Bool { self == .won || self == .lost }
}

struct Opportunity: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var amount: Double?
    var stage: OpportunityStage = .lead
    var closeDate: String?
    var contactID: UUID?
    var companyID: UUID?
    var leadID: UUID?
    var notes = ""
    var createdAt = Date.now.ISO8601Format()
}

enum TaskStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case todo, inProgress = "in_progress", done
    var id: String { rawValue }
    var label: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

struct CRMTask: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title = ""
    var details = ""
    var status: TaskStatus = .todo
    var dueDate: String?
    /// Scheduled local reminder instant in ISO-8601; dueDate remains the display/grouping date.
    var reminderAt: String?
    var contactID: UUID?
    var companyID: UUID?
    var opportunityID: UUID?
    var leadID: UUID?
    var createdAt = Date.now.ISO8601Format()
}

struct CRMNote: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title = ""
    var body = ""
    var contactID: UUID?
    var companyID: UUID?
    var opportunityID: UUID?
    var createdAt = Date.now.ISO8601Format()
    var updatedAt = Date.now.ISO8601Format()
}

struct SavedView: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var objectName: String
    var filter: String
    var search: String? = nil

    static let defaults = [
        SavedView(name: "All contacts", objectName: "Contacts", filter: "all"),
        SavedView(name: "Open opportunities", objectName: "Opportunities", filter: "open"),
        SavedView(name: "My tasks", objectName: "Tasks", filter: "open"),
    ]
}

enum PipelineFilter: String, CaseIterable, Identifiable {
    case open = "Open"
    case all = "All"
    case won = "Won"
    case lost = "Lost"

    var id: String { rawValue }
}

enum Industries {
    static let all = [
        "Renovation", "General Contracting", "Plumbing", "Electrical", "HVAC",
        "Landscaping", "Cleaning", "Photography", "Consulting", "Agency", "Other",
    ]
}

enum CalendarCRM {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_CA_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayString(_ date: Date = .now) -> String {
        formatter.string(from: date)
    }

    static func date(from day: String?) -> Date? {
        guard let day else { return nil }
        return formatter.date(from: day)
    }

    static func addDays(_ days: Int, to day: String) -> String? {
        guard let date = date(from: day),
              let result = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: date)
        else { return nil }
        return dayString(result)
    }

    static func display(_ day: String?) -> String {
        guard let day, let date = date(from: day) else { return "-" }
        let today = Calendar.current.startOfDay(for: .now)
        let target = Calendar.current.startOfDay(for: date)
        let distance = Calendar.current.dateComponents([.day], from: today, to: target).day ?? 0
        switch distance {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default:
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

enum FollowUpCadence {
    static let days = [1, 3, 7, 14]
}

// MARK: - Persisted connector records
// Plain data stored in workspace.json. Kept here (not in Integrations.swift) so the model layer
// compiles without the Keychain-backed connector code.

/// Last verified result for a connector. Contains no secrets.
struct ConnectorHealth: Codable, Equatable, Sendable {
    var ok: Bool
    var detail: String
    var checkedAt = Date.now.ISO8601Format()
}

enum TwentyObject: String, CaseIterable, Codable, Sendable {
    // Push order matters: people and opportunities reference companies; opportunities reference people.
    case companies, people, opportunities, tasks

    var singular: String {
        switch self {
        case .companies: "Company"
        case .people: "Person"
        case .opportunities: "Opportunity"
        case .tasks: "Task"
        }
    }

    var label: String { rawValue.capitalized }
}

/// Local record to Twenty record link, stored in the workspace. `payloadHash`
/// lets unchanged records be skipped instead of re-sent.
struct TwentyLink: Codable, Equatable, Sendable {
    var twentyID: String
    var object: TwentyObject
    var payloadHash: String
    var syncedAt = Date.now.ISO8601Format()
    /// A create identity saved before HTTP. Nil is the legacy, completed state.
    var pendingCreate: Bool?
}
