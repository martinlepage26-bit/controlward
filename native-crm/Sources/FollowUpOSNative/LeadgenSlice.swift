import Foundation

// PHAROS lead-gen slice 1 (docs/leadgen-slice/SPEC.md).
// Portable: Foundation only, so bin/test-portable runs it on Linux as well as on the Mac.
// RED COMMIT: declarations only; every behaviour is a stub so the tests compile and fail.
// There is no send, read, or delete path for mail anywhere in this file, by design.

enum LeadgenError: Error, Equatable, CustomStringConvertible {
    case notImplemented
    case liveNotAuthorized(String)
    case hostNotAllowed(String)
    case robotsDisallowed(String)
    case fetchFailed(String)
    case notExactlyOneProspect(Int)
    case wrongSegment(String)
    case noBodyEvidence
    case evidenceOffDomain(String)
    case missingConsentBasis
    case missingPostalAddress
    case dashNotAllowed
    case wrongMailbox(String)
    case sqlRefused(String)
    case candidateRefused(String)
    case readBackMismatch(String)
    case rowCountDelta(Int)
    case existingRowsChanged
    case leadsTableExists(String)

    var description: String {
        switch self {
        case .notImplemented: "not implemented (red commit)"
        case .liveNotAuthorized(let why): "live run refused: \(why)"
        case .hostNotAllowed(let host): "host not allowed: \(host)"
        case .robotsDisallowed(let path): "robots.txt disallows \(path)"
        case .fetchFailed(let url): "fetch failed: \(url)"
        case .notExactlyOneProspect(let n): "exactly one prospect required, got \(n)"
        case .wrongSegment(let s): "segment not in scope: \(s)"
        case .noBodyEvidence: "no AI evidence quoted from page body text"
        case .evidenceOffDomain(let url): "evidence is not on the prospect's own domain: \(url)"
        case .missingConsentBasis: "draft refused: no recorded consent basis"
        case .missingPostalAddress: "draft refused: no sender postal address for the CASL footer"
        case .dashNotAllowed: "draft refused: em or en dash in text"
        case .wrongMailbox(let m): "draft refused: mailbox must be ml@pharos-ai.ca, got \(m)"
        case .sqlRefused(let sql): "SQL refused (INSERT into projects or SELECT only): \(sql)"
        case .candidateRefused(let what): "candidate write refused: \(what)"
        case .readBackMismatch(let id): "read-back did not match the written row \(id)"
        case .rowCountDelta(let d): "row count changed by \(d), expected exactly 1"
        case .existingRowsChanged: "checksum of existing rows or schema changed"
        case .leadsTableExists(let db): "stopped before any insert: a leads table already exists in \(db); ask Martin"
        }
    }
}

// MARK: 1. Dry-run default

struct LeadgenRunConfig: Sendable, Equatable {
    let liveFlag: Bool
    let operatorOK: String?

    static let dryRun = LeadgenRunConfig(liveFlag: false, operatorOK: nil)

    /// Live only with the explicit `--live` flag AND a recorded operator OK (env LEADGEN_OPERATOR_OK).
    static func from(arguments: [String], environment: [String: String]) -> LeadgenRunConfig { return .dryRun }

    var isLive: Bool { false }

    func authorizeLive() throws { throw LeadgenError.notImplemented }
}

// MARK: 2. Sources

struct LeadgenSourcePolicy: Sendable {
    let allowedHosts: Set<String>

    static let blockedHostFragments = [
        "maps.google.", "google.com", "goo.gl", "maps.app", "googleapis.com",
        "zoominfo", "apollo.io", "rocketreach", "lusha", "clearbit", "hunter.io", "seamless.ai",
        "yellowpages", "pagesjaunes", "canada411", "411.ca", "spokeo", "whitepages", "dnb.com", "data.com",
    ]

    init(allowedHosts: [String]) {
        self.allowedHosts = Set(allowedHosts.map(LeadgenSourcePolicy.normalize))
    }

    static func normalize(_ host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    func check(_ url: URL) throws { throw LeadgenError.notImplemented }
}

struct LeadgenRobots: Sendable {
    private var allows: [String] = []
    private var disallows: [String] = []

    init(text: String) {  }

    func allows(path: String) -> Bool { false }
}

protocol LeadgenFetching: Sendable {
    func get(_ url: URL) async throws -> (status: Int, body: String)
}

struct LeadgenPage: Sendable, Equatable {
    let url: URL
    let bodyText: String
}

actor LeadgenSiteReader {
    private let policy: LeadgenSourcePolicy
    private let fetcher: LeadgenFetching
    private(set) var fetchedURLs: [String] = []

    init(policy: LeadgenSourcePolicy, fetcher: LeadgenFetching) {
        self.policy = policy
        self.fetcher = fetcher
    }

    private func fetch(_ url: URL) async throws -> (status: Int, body: String) {
        try policy.check(url)
        fetchedURLs.append(url.absoluteString)
        return try await fetcher.get(url)
    }

    /// Reads robots.txt, then each allowed path on the prospect's own site.
    func read(site: URL, paths: [String]) async throws -> [LeadgenPage] { throw LeadgenError.notImplemented }
}

enum LeadgenHTML {
    /// Visible body text without script, style, nav, header, or footer blocks (LIVE-R4).
    static func bodyText(_ html: String) -> String { html }
}

// MARK: 3. Exactly one prospect, one segment

struct LeadgenProspect: Sendable, Equatable {
    let organization: String
    let segment: String
    let site: URL
    let publicContactEmail: String
}

enum LeadgenProspectPicker {
    static let segment = "montreal-clinics"

    static func pickOne(_ candidates: [LeadgenProspect]) throws -> LeadgenProspect { throw LeadgenError.notImplemented }
}

// MARK: 4. Fit reason from the prospect's own pages

struct LeadgenFitEvidence: Sendable, Equatable {
    let url: String
    let quote: String
}

struct LeadgenFit: Sendable, Equatable {
    let reason: String
    let evidence: [LeadgenFitEvidence]
}

enum LeadgenFitFinder {
    static let aiTerms = [
        "intelligence artificielle", "artificial intelligence", "apprentissage automatique", "machine learning",
        "algorithme", "algorithm", "chatbot", "agent conversationnel", "assistant virtuel", "virtual assistant",
        " ia ", "(ia)", "l'ia ", "d'ia ", " ai ", "(ai)", "ai-powered",
    ]

    static func find(pages: [LeadgenPage], prospect: LeadgenProspect) throws -> LeadgenFit { throw LeadgenError.notImplemented }
}

// MARK: 5. One draft, create-draft only

struct LeadgenConsentBasis: Sendable, Equatable {
    /// e.g. "CASL s.10(9)(b) conspicuous publication; Loi 25 art. 4 (public business contact)".
    let basis: String
    /// Where the address was published (a URL on the prospect's own domain).
    let source: String
    let recordedAt: String
}

struct LeadgenDraft: Sendable, Equatable {
    static let mailbox = "ml@pharos-ai.ca"
    let from: String
    let to: String
    let subject: String
    let body: String
    let consent: LeadgenConsentBasis

    var rawMIME: String {
        [
            "From: Martin Lepage, PhD <\(from)>",
            "To: \(to)",
            "Subject: \(subject)",
            "X-PHAROS-Consent-Basis: \(consent.basis)",
            "X-PHAROS-Consent-Source: \(consent.source)",
            "X-PHAROS-Consent-Recorded: \(consent.recordedAt)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "",
            body,
        ].joined(separator: "\r\n")
    }
}

enum LeadgenDraftComposer {
    static let signature = "Martin Lepage, PhD\nPHAROS AI\nml@pharos-ai.ca"

    static func compose(prospect: LeadgenProspect, fit: LeadgenFit, consent: LeadgenConsentBasis?, postalAddress: String) throws -> LeadgenDraft { throw LeadgenError.notImplemented }
}

/// The only mail capability ControlWard gets in this slice. No send, read, list, or delete exists.
protocol LeadgenDraftMailbox: Sendable {
    func createDraft(account: String, rawMIME: String) async throws -> String
}

// MARK: 6. D1: a new `leads` table (additive migration), INSERT into leads plus SELECT, nothing else

enum LeadgenMigration {
    /// Same text as docs/leadgen-slice/migrations/0001_create_leads.sql. Applied only in the live run.
    static let createLeads = """
    CREATE TABLE IF NOT EXISTS leads (id TEXT PRIMARY KEY, organization TEXT NOT NULL, segment TEXT NOT NULL, site TEXT NOT NULL, fit_reason TEXT NOT NULL, fit_evidence TEXT NOT NULL, draft_ref TEXT NOT NULL, consent_basis TEXT NOT NULL, status TEXT NOT NULL, next_action TEXT NOT NULL, origin TEXT NOT NULL, created TEXT NOT NULL)
    """
}

enum LeadgenSQLGuard {
    static func check(_ sql: String, params: [String]) throws { throw LeadgenError.notImplemented }
}

protocol LeadgenD1Port: Sendable {
    func query(database: String, sql: String, params: [String]) async throws -> [[String: String]]
}

/// Where the live run writes its checksum and count log (a file in the live runner, memory in tests).
protocol LeadgenRunLog: Sendable {
    func write(_ line: String) async
}

struct LeadgenProjectTarget: Sendable, Equatable {
    let databaseID: String
    static let meCom = LeadgenProjectTarget(databaseID: "e1e9fa25-4c6e-476e-bf16-979c0fd9e5b1")
    static let pharos = LeadgenProjectTarget(databaseID: "959e5bdb-4213-496a-9557-10ec410440d7")
}

struct LeadgenLeadRow: Sendable, Equatable {
    let id: String
    let organization: String
    let site: String
    let fitReason: String
    let fitEvidence: String
    let draftRef: String
    let consentBasis: String
    let createdAt: String

    static let status = "waiting-on-martin"

    var columns: [(String, String)] { [] }
}

struct LeadgenWriteReceipt: Sendable, Equatable {
    let databaseID: String
    let rowID: String
    let countBefore: Int
    let countAfter: Int
    let checksumBefore: [String: String]
    let checksumAfter: [String: String]
}

enum LeadgenChecksum {
    /// FNV-1a 64 over a canonical rendering of rows (portable, no CryptoKit).
    static func of(_ rows: [[String: String]]) -> String { "" }
}

/// Every statement passes LeadgenSQLGuard before it reaches the port.
struct LeadgenD1Writer: Sendable {
    let port: LeadgenD1Port
    let log: LeadgenRunLog

    static let tablesSQL = "SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name"
    static let countSQL = "SELECT COUNT(*) AS n FROM leads"
    static let readBackSQL = "SELECT id, organization, status FROM leads WHERE id = ?"
    static func allRowsSQL(_ table: String) -> String { "SELECT * FROM \"\(table)\"" }

    func run(_ db: String, _ sql: String, _ params: [String] = []) async throws -> [[String: String]] {
        try LeadgenSQLGuard.check(sql, params: params)
        return try await port.query(database: db, sql: sql, params: params)
    }

    /// Row count, row checksum, and schema (`sqlite_master.sql`) checksum of every table except `leads`.
    func snapshot(_ db: String) async throws -> (tables: [String: String], hasLeads: Bool) { throw LeadgenError.notImplemented }

    func insertOne(_ row: LeadgenLeadRow, into target: LeadgenProjectTarget) async throws -> LeadgenWriteReceipt { throw LeadgenError.notImplemented }
}

// MARK: Runner

struct LeadgenRunReport: Sendable {
    let live: Bool
    let fetchedURLs: [String]
    let prospect: LeadgenProspect
    let fit: LeadgenFit
    let draft: LeadgenDraft
    let draftID: String?
    let receipts: [LeadgenWriteReceipt]
}

struct LeadgenSliceRunner: Sendable {
    let config: LeadgenRunConfig
    let fetcher: LeadgenFetching
    let mailbox: LeadgenDraftMailbox
    let d1: LeadgenD1Port
    let log: LeadgenRunLog
    let now: @Sendable () -> String

    func run(candidates: [LeadgenProspect], paths: [String], consent: LeadgenConsentBasis?, postalAddress: String) async throws -> LeadgenRunReport { throw LeadgenError.notImplemented }
}
