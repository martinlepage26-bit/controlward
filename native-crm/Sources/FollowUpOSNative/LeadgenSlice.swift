import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// PHAROS lead-gen slice 1 (docs/leadgen-slice/SPEC.md).
// Portable: Foundation only, so bin/test-portable runs it on Linux as well as on the Mac.
// There is no send, read, or delete path for mail anywhere in this file, by design.

enum LeadgenError: Error, Equatable, CustomStringConvertible {
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
    case postalAddressDenied(String)
    case configMissing(String)
    case configInvalid(String)
    case credentialMissing(String)
    case unsafeURL(String)
    case contactNotOnPage(String)
    case consentSourceNotFetched(String)
    case suppressed(String)

    var description: String {
        switch self {
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
        case .postalAddressDenied(let word): "draft refused: the footer address names a denied street (\(word))"
        case .configMissing(let path): "local config missing: \(path) (copy docs/leadgen-slice/leadgen.local.example.json)"
        case .configInvalid(let why): "local config invalid: \(why)"
        case .credentialMissing(let ref): "credential not found: \(ref) (env or Keychain reference only)"
        case .unsafeURL(let why): "url refused: \(why)"
        case .contactNotOnPage(let email): "recipient \(email) was not found on a page fetched from the clinic's own domain"
        case .consentSourceNotFetched(let url): "consent source was not a page fetched from the clinic's own domain: \(url)"
        case .suppressed(let why): "suppressed: \(why)"
        }
    }
}

// MARK: 1. Dry-run default

struct LeadgenRunConfig: Sendable, Equatable {
    let liveFlag: Bool
    let operatorOK: String?

    static let dryRun = LeadgenRunConfig(liveFlag: false, operatorOK: nil)

    /// The exact confirmation the live run needs. It names the new `leads` table in both D1s.
    static let confirmation = "leads in e1e9fa25 and leads in 959e5bdb"

    /// Live only with the explicit `--live` flag AND the confirmation, given as `--confirm <value>`,
    /// `--confirm=<value>`, or env LEADGEN_OPERATOR_OK.
    static func from(arguments: [String], environment: [String: String]) -> LeadgenRunConfig {
        var ok = environment["LEADGEN_OPERATOR_OK"]
        for (i, arg) in arguments.enumerated() {
            if arg == "--confirm", i + 1 < arguments.count { ok = arguments[i + 1] }
            if arg.hasPrefix("--confirm=") { ok = String(arg.dropFirst("--confirm=".count)) }
        }
        let trimmed = ok?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LeadgenRunConfig(liveFlag: arguments.contains("--live"), operatorOK: (trimmed?.isEmpty ?? true) ? nil : trimmed)
    }

    var isLive: Bool { liveFlag && operatorOK == Self.confirmation }

    func authorizeLive() throws {
        guard liveFlag else { throw LeadgenError.liveNotAuthorized("no --live flag") }
        guard let ok = operatorOK else { throw LeadgenError.liveNotAuthorized("no operator OK recorded") }
        guard ok == Self.confirmation else {
            throw LeadgenError.liveNotAuthorized("confirmation must be exactly \"\(Self.confirmation)\"")
        }
    }
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

    func check(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host else { throw LeadgenError.hostNotAllowed(url.absoluteString) }
        let h = LeadgenSourcePolicy.normalize(host)
        if LeadgenSourcePolicy.blockedHostFragments.contains(where: { h.contains($0) }) {
            throw LeadgenError.hostNotAllowed(h)
        }
        guard allowedHosts.contains(h) else { throw LeadgenError.hostNotAllowed(h) }
    }
}

struct LeadgenRobots: Sendable {
    private var allows: [String] = []
    private var disallows: [String] = []

    init(text: String) {
        var inGroup = false
        var lastWasAgent = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            if key == "user-agent" {
                let agent = parts[1].lowercased()
                let matches = agent == "*" || agent.contains("controlward")
                inGroup = lastWasAgent ? (inGroup || matches) : matches
                lastWasAgent = true
                continue
            }
            lastWasAgent = false
            guard inGroup else { continue }
            if key == "disallow", !parts[1].isEmpty { disallows.append(parts[1]) }
            if key == "allow", !parts[1].isEmpty { allows.append(parts[1]) }
        }
    }

    func allows(path: String) -> Bool {
        let p = path.isEmpty ? "/" : path
        let d = disallows.filter { p.hasPrefix($0) }.map(\.count).max() ?? -1
        let a = allows.filter { p.hasPrefix($0) }.map(\.count).max() ?? -1
        return d < 0 || a >= d
    }
}

protocol LeadgenFetching: Sendable {
    /// One response. Must not follow redirects: a 3xx is returned with its headers so the caller can check the next hop.
    func get(_ url: URL) async throws -> (status: Int, headers: [String: String], body: String)
}

protocol LeadgenResolving: Sendable {
    func addresses(for host: String) async -> [String]
}

struct LeadgenSystemDNS: LeadgenResolving {
    func addresses(for host: String) async -> [String] { SystemHostLookup.addresses(host) }
}

struct LeadgenPage: Sendable, Equatable {
    let url: URL
    let bodyText: String
    var html: String = ""
    /// When this body was fetched. Empty only for pages built in tests without a clock.
    var fetchedAt: String = ""
}

actor LeadgenSiteReader {
    private let policy: LeadgenSourcePolicy
    private let fetcher: LeadgenFetching
    private let dns: any LeadgenResolving
    private let now: @Sendable () -> String
    private(set) var fetchedURLs: [String] = []
    static let maxRedirects = 3

    init(policy: LeadgenSourcePolicy, fetcher: LeadgenFetching, dns: any LeadgenResolving = LeadgenSystemDNS(), now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }) {
        self.policy = policy
        self.fetcher = fetcher
        self.dns = dns
        self.now = now
    }

    /// Scheme, SSRF (including DNS), then the allowlist. A redirect hop uses the same checks.
    private func admit(_ url: URL) async throws {
        let resolved = await dns.addresses(for: url.host ?? "")
        if let why = HostSafety.refusal(url: url, resolvedAddresses: resolved) {
            throw LeadgenError.unsafeURL(why)
        }
        try policy.check(url)
    }

    /// Fetches `url`, following a redirect only after the next hop passes `admit`. The returned URL is the final one.
    private func fetch(_ url: URL) async throws -> (status: Int, body: String, finalURL: URL) {
        var current = url
        var hops = 0
        while true {
            try await admit(current)
            fetchedURLs.append(current.absoluteString)
            let response = try await fetcher.get(current)
            let headers = Dictionary(uniqueKeysWithValues: response.headers.map { ($0.key.lowercased(), $0.value) })
            if (300..<400).contains(response.status) {
                let location = headers["location"] ?? ""
                guard let next = URL(string: location, relativeTo: current)?.absoluteURL, !location.isEmpty else {
                    throw LeadgenError.unsafeURL("redirect with no location")
                }
                guard hops < Self.maxRedirects else { throw LeadgenError.unsafeURL("redirect limit") }
                hops += 1
                current = next
                continue
            }
            return (response.status, response.body, current)
        }
    }

    /// Reads robots.txt, then each allowed path on the prospect's own site.
    /// Every hop is admitted. Page URLs are the final URLs the bodies came from.
    func read(site: URL, paths: [String]) async throws -> [LeadgenPage] {
        try await admit(site)
        guard let robotsURL = URL(string: "/robots.txt", relativeTo: site)?.absoluteURL else {
            throw LeadgenError.fetchFailed(site.absoluteString)
        }
        let robotsResponse = try await fetch(robotsURL)
        if robotsResponse.status == 401 || robotsResponse.status == 403 || robotsResponse.status >= 500 {
            throw LeadgenError.robotsDisallowed("/")
        }
        guard (200..<300).contains(robotsResponse.status) || robotsResponse.status == 404 else {
            throw LeadgenError.fetchFailed(robotsURL.absoluteString)
        }
        let robots = LeadgenRobots(text: (200..<300).contains(robotsResponse.status) ? robotsResponse.body : "")
        var pages: [LeadgenPage] = []
        for path in paths {
            guard robots.allows(path: path) else { throw LeadgenError.robotsDisallowed(path) }
            guard let url = URL(string: path, relativeTo: site)?.absoluteURL else { continue }
            let response = try await fetch(url)
            guard response.status == 200 else { continue }
            pages.append(LeadgenPage(url: response.finalURL, bodyText: LeadgenHTML.bodyText(response.body), html: response.body, fetchedAt: now()))
        }
        return pages
    }
}

enum LeadgenHTML {
    /// Visible body text without script, style, nav, header, or footer blocks (LIVE-R4).
    static func bodyText(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "nav", "header", "footer", "noscript"] {
            text = text.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&nbsp;", " "), ("&#39;", "'"), ("&rsquo;", "'"), ("&quot;", "\""), ("&eacute;", "é"), ("&egrave;", "è"), ("&agrave;", "à")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
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

    static func pickOne(_ candidates: [LeadgenProspect]) throws -> LeadgenProspect {
        guard candidates.count == 1, let only = candidates.first else {
            throw LeadgenError.notExactlyOneProspect(candidates.count)
        }
        guard only.segment == segment else { throw LeadgenError.wrongSegment(only.segment) }
        return only
    }
}

// MARK: 4. Fit reason from the prospect's own pages

struct LeadgenFitEvidence: Sendable, Equatable {
    let url: String
    let quote: String
    /// Fetch time of the page the quote came from.
    var fetchedAt: String = ""
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

    static func find(pages: [LeadgenPage], prospect: LeadgenProspect) throws -> LeadgenFit {
        let home = LeadgenSourcePolicy.normalize(prospect.site.host ?? "")
        var evidence: [LeadgenFitEvidence] = []
        for page in pages {
            let host = LeadgenSourcePolicy.normalize(page.url.host ?? "")
            guard host == home else { throw LeadgenError.evidenceOffDomain(page.url.absoluteString) }
            let sentences = page.bodyText
                .replacingOccurrences(of: "([.!?])\\s+", with: "$1\n", options: .regularExpression)
                .components(separatedBy: "\n")
            for sentence in sentences {
                let s = sentence.trimmingCharacters(in: .whitespaces)
                let padded = " " + s.lowercased() + " "
                guard s.count >= 30, aiTerms.contains(where: { padded.contains($0) }) else { continue }
                evidence.append(LeadgenFitEvidence(url: page.url.absoluteString, quote: s, fetchedAt: page.fetchedAt))
                break
            }
        }
        guard let first = evidence.first else { throw LeadgenError.noBodyEvidence }
        let reason = "\(prospect.organization) (\(first.url)): \"\(first.quote)\""
        return LeadgenFit(reason: reason, evidence: evidence)
    }
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
    /// Generated locally, stored as `draft_ref` in the leads row before the draft exists.
    let messageID: String

    var rawMIME: String {
        [
            "From: Martin Lepage, PhD <\(from)>",
            "Message-ID: \(messageID)",
            "To: \(to)",
            "Subject: \(subject)",
            "List-Unsubscribe: <mailto:\(LeadgenDraft.mailbox)?subject=unsubscribe>",
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
    /// The only postal address a slice draft may print.
    static let postalAddress = "2456 rue de Rouen, Montréal QC H2K 1M2"

    /// Street names that belong to other businesses and must never appear in a PHAROS footer.
    /// Street name only: no full address is kept in code.
    static let deniedStreets = ["saint-hubert"]

    static func normalizedAddress(_ text: String) -> String {
        var s = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CA")).lowercased()
        for sep in [" ", "\u{2010}", "\u{2011}", "_"] { s = s.replacingOccurrences(of: "saint\(sep)", with: "saint-") }
        for short in ["st-", "st.-", "st. ", "st "] { s = s.replacingOccurrences(of: " \(short)", with: " saint-") }
        if s.hasPrefix("st-") || s.hasPrefix("st ") { s = "saint-" + s.dropFirst(3) }
        return s
    }

    static func checkAddress(_ postalAddress: String?) throws -> String {
        guard let address = postalAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            throw LeadgenError.missingPostalAddress
        }
        let norm = " " + normalizedAddress(address)
        if let hit = deniedStreets.first(where: { norm.contains($0) }) { throw LeadgenError.postalAddressDenied(hit) }
        return address
    }

    /// The recipient and the consent source must both appear on a page that was fetched from the clinic's own domain.
    static func proveOwnPages(prospect: LeadgenProspect, consent: LeadgenConsentBasis, pages: [LeadgenPage]) throws {
        let domain = LeadgenSourcePolicy.normalize(prospect.site.host ?? "")
        let own = pages.filter { LeadgenSourcePolicy.normalize($0.url.host ?? "") == domain }
        let email = prospect.publicContactEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty, own.contains(where: { $0.bodyText.lowercased().contains(email) }) else {
            throw LeadgenError.contactNotOnPage(email)
        }
        guard let source = URL(string: consent.source),
              LeadgenSourcePolicy.normalize(source.host ?? "") == domain,
              own.contains(where: { $0.url.absoluteString == source.absoluteString }) else {
            throw LeadgenError.consentSourceNotFetched(consent.source)
        }
    }

    static func compose(prospect: LeadgenProspect, fit: LeadgenFit, consent: LeadgenConsentBasis?, postalAddress: String?, pages: [LeadgenPage]) throws -> LeadgenDraft {
        guard let consent, !consent.basis.trimmingCharacters(in: .whitespaces).isEmpty,
              !consent.source.isEmpty, !consent.recordedAt.isEmpty else { throw LeadgenError.missingConsentBasis }
        try proveOwnPages(prospect: prospect, consent: consent, pages: pages)
        _ = try checkAddress(postalAddress)
        let postalAddress = Self.postalAddress
        let quote = fit.evidence.first?.quote ?? ""
        let subject = "Gouvernance de l'IA et Loi 25 pour \(prospect.organization)"
        let body = """
        Bonjour,

        J'ai lu sur votre site : « \(quote) »

        Quand une clinique utilise l'IA avec des renseignements de santé, la Loi 25 demande une évaluation des facteurs relatifs à la vie privée et un avis lorsqu'une décision est automatisée. J'aide les cliniques à mettre cela en place simplement, sans freiner l'outil.

        Seriez-vous ouverts à un appel de 20 minutes dans les prochaines semaines?

        \(signature)

        ---
        Vous recevez ce message parce que votre adresse est publiée sur votre site (\(consent.source)).
        Pour ne plus recevoir de messages de PHAROS AI, répondez « désabonnement » à ce courriel; votre demande sera traitée dans les 10 jours ouvrables.
        To unsubscribe, reply "unsubscribe" to this email.
        PHAROS AI, \(postalAddress)
        """
        for text in [subject, body] where text.contains("\u{2014}") || text.contains("\u{2013}") {
            throw LeadgenError.dashNotAllowed
        }
        let host = LeadgenSourcePolicy.normalize(prospect.site.host ?? "prospect")
        let messageID = "<leadgen-\(host.replacingOccurrences(of: ".", with: "-"))-\(consent.recordedAt.prefix(10))@pharos-ai.ca>"
        return LeadgenDraft(from: LeadgenDraft.mailbox, to: prospect.publicContactEmail, subject: subject, body: body, consent: consent, messageID: messageID)
    }
}

/// The only mail capability ControlWard gets in this slice. No send, read, list, or delete exists.
protocol LeadgenDraftMailbox: Sendable {
    func createDraft(account: String, rawMIME: String) async throws -> String
}

/// Do-not-contact check. An entry is an address, or a domain when it has no `@`.
enum LeadgenSuppression {
    static func reason(address: String, siteHost: String, list: SuppressionList) -> String? {
        let bare = MailAddress.bare(address)
        if !bare.isEmpty, list.contains(bare) { return "address \(bare)" }
        let emailDomain = MailAddress.domain(bare).map(LeadgenSourcePolicy.normalize)
        let siteDomain = LeadgenSourcePolicy.normalize(siteHost)
        var domains: Set<String> = []
        if let emailDomain, !emailDomain.isEmpty { domains.insert(emailDomain) }
        if !siteDomain.isEmpty { domains.insert(siteDomain) }
        for entry in list.all {
            let key = MailAddress.bare(entry.address)
            if key.contains("@") { continue }
            let host = LeadgenSourcePolicy.normalize(key)
            if domains.contains(host) { return "domain \(host)" }
        }
        return nil
    }
}

// MARK: 6. D1: a new `leads` table (additive migration), INSERT into leads plus SELECT, nothing else

enum LeadgenMigration {
    /// Same text as docs/leadgen-slice/migrations/0001_create_leads.sql. Applied only in the live run.
    static let createLeads = """
    CREATE TABLE IF NOT EXISTS leads (id TEXT PRIMARY KEY, organization TEXT NOT NULL, segment TEXT NOT NULL, site TEXT NOT NULL, fit_reason TEXT NOT NULL, fit_evidence TEXT NOT NULL, draft_ref TEXT NOT NULL, consent_basis TEXT NOT NULL, status TEXT NOT NULL, next_action TEXT NOT NULL, origin TEXT NOT NULL, created TEXT NOT NULL)
    """
}

enum LeadgenSQLGuard {
    static func check(_ sql: String, params: [String]) throws {
        let s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = s.uppercased()
        let isRead = upper.hasPrefix("SELECT ")
        let namesCandidate = s.lowercased().contains("candidate") || params.contains(where: { $0.lowercased().contains("candidate") })
        if !isRead && namesCandidate { throw LeadgenError.candidateRefused(s) }
        if s == LeadgenMigration.createLeads { return }
        if upper.contains("PROJECTS") && !upper.hasPrefix("SELECT ") { throw LeadgenError.candidateRefused("no row in projects: \(s)") }
        let forbidden = ["UPDATE ", "DELETE ", "DROP ", "ALTER ", "CREATE ", "REPLACE", "UPSERT", "ON CONFLICT", "PRAGMA", "ATTACH", "VACUUM", ";"]
        if forbidden.contains(where: { upper.contains($0) }) { throw LeadgenError.sqlRefused(s) }
        if upper.hasPrefix("SELECT ") { return }
        guard upper.hasPrefix("INSERT INTO LEADS (") else { throw LeadgenError.sqlRefused(s) }
    }
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

    var columns: [(String, String)] {
        [("id", id), ("organization", organization), ("segment", LeadgenProspectPicker.segment), ("site", site),
         ("fit_reason", fitReason), ("fit_evidence", fitEvidence), ("draft_ref", draftRef), ("consent_basis", consentBasis),
         ("status", LeadgenLeadRow.status),
         ("next_action", "Martin: read the Gmail draft in ml@pharos-ai.ca, then approve or discard"),
         ("origin", "controlward-leadgen"), ("created", createdAt)]
    }
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
    static func of(_ rows: [[String: String]]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for line in rows.map({ row in row.keys.sorted().map { "\($0)=\(row[$0] ?? "")" }.joined(separator: "\u{1f}") }).sorted() {
            for byte in (line + "\u{1e}").utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return String(format: "%016llx", hash)
    }
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
    func snapshot(_ db: String) async throws -> (tables: [String: String], hasLeads: Bool) {
        var out: [String: String] = [:]
        var hasLeads = false
        for t in try await run(db, Self.tablesSQL) {
            guard let name = t["name"] else { continue }
            if name == "leads" { hasLeads = true; continue }
            let rows = try await run(db, Self.allRowsSQL(name))
            out[name] = "rows=\(rows.count) data=\(LeadgenChecksum.of(rows)) schema=\(LeadgenChecksum.of([["sql": t["sql"] ?? ""]]))"
        }
        return (out, hasLeads)
    }

    /// Reads the leads count. Callers send an INSERT only after this returns.
    func precheckCount(_ db: String) async throws -> Int {
        guard let n = Int(try await run(db, Self.countSQL).first?["n"] ?? "") else {
            throw LeadgenError.fetchFailed("precheck \(db)")
        }
        return n
    }

    func insertOne(_ row: LeadgenLeadRow, into target: LeadgenProjectTarget) async throws -> LeadgenWriteReceipt {
        let db = target.databaseID
        await log.write("step checksum-before \(db)")
        let (before, hadLeads) = try await snapshot(db)
        for (t, v) in before.sorted(by: { $0.key < $1.key }) { await log.write("\(db) before \(t) \(v)") }
        await log.write("\(db) projects count before \(before["projects"] ?? "missing")")
        guard !hadLeads else { throw LeadgenError.leadsTableExists(db) }
        await log.write("step apply-0001 \(db)")
        _ = try await run(db, LeadgenMigration.createLeads)
        // The count is the pre-check. A failure here must not send an INSERT.
        let countBefore = try await precheckCount(db)
        let cols = row.columns
        let sql = "INSERT INTO leads (\(cols.map(\.0).joined(separator: ", "))) VALUES (\(cols.map { _ in "?" }.joined(separator: ", ")))"
        await log.write("step insert \(db)")
        _ = try await run(db, sql, cols.map(\.1))
        await log.write("step read-back \(db)")
        let back = try await run(db, Self.readBackSQL, [row.id])
        guard back.count == 1, back[0]["status"] == LeadgenLeadRow.status, back[0]["organization"] == row.organization else {
            throw LeadgenError.readBackMismatch(row.id)
        }
        let countAfter = Int(try await run(db, Self.countSQL).first?["n"] ?? "") ?? -1
        await log.write("step checksum-after \(db)")
        let after = try await snapshot(db).tables
        for (t, v) in after.sorted(by: { $0.key < $1.key }) { await log.write("\(db) after \(t) \(v)") }
        await log.write("\(db) projects before \(before["projects"] ?? "missing") after \(after["projects"] ?? "missing")")
        await log.write("\(db) leads count before=\(countBefore) after=\(countAfter)")
        guard countAfter - countBefore == 1 else { throw LeadgenError.rowCountDelta(countAfter - countBefore) }
        guard before == after else { throw LeadgenError.existingRowsChanged }
        return LeadgenWriteReceipt(databaseID: db, rowID: row.id, countBefore: countBefore, countAfter: countAfter, checksumBefore: before, checksumAfter: after)
    }
}

// MARK: Discovery from one public directory page

struct LeadgenDiscoveryResult: Sendable, Equatable {
    let prospect: LeadgenProspect
    let pages: [LeadgenPage]
    let consent: LeadgenConsentBasis?
    let fetchedURLs: [String]
}

enum LeadgenDiscovery {
    /// Hosts that are never a clinic's own site, on top of the source-policy block list.
    static let skipHostFragments = [
        "linkedin.", "facebook.", "instagram.", "youtube.", "twitter.", "x.com", "tiktok.",
        "bing.", "duckduckgo.", "yahoo.", "google.", "gstatic.", "googleapis.",
    ]

    static func origin(of url: URL) -> URL? {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = "/"
        return components.url
    }

    /// Picks the one external clinic linked from a directory page. Two clinics, or none, is a refusal.
    static func clinics(in html: String, directory: URL) -> [(name: String, site: URL)] {
        let directoryHost = LeadgenSourcePolicy.normalize(directory.host ?? "")
        let pattern = "<a\\b[^>]*?href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var byDomain: [String: (name: String, site: URL)] = [:]
        var order: [String] = []
        for match in expression.matches(in: html, range: range) {
            guard match.numberOfRanges == 3,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else { continue }
            let href = String(html[hrefRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: href, relativeTo: directory)?.absoluteURL,
                  let host = url.host, !host.isEmpty else { continue }
            let domain = LeadgenSourcePolicy.normalize(host)
            if domain == directoryHost || domain.isEmpty { continue }
            if HostSafety.refusal(url: url, resolvedAddresses: nil) != nil { continue }
            if LeadgenSourcePolicy.blockedHostFragments.contains(where: { domain.contains($0) }) { continue }
            if skipHostFragments.contains(where: { domain.contains($0) }) { continue }
            guard let site = origin(of: url), !site.absoluteString.isEmpty else { continue }
            let name = visibleText(String(html[textRange]))
            let label = name.isEmpty ? domain : name
            if byDomain[domain] == nil {
                byDomain[domain] = (label, site)
                order.append(domain)
            }
        }
        return order.compactMap { byDomain[$0] }
    }

    static func visibleText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func emails(in text: String) -> [String] {
        let pattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).lowercased() }
        }
    }

    /// Reads the directory page (robots first), picks the one clinic, then reads that clinic's own site.
    /// The consent source becomes the own-domain page the recipient address was read from.
    static func find(directory: URL, paths: [String], consent: LeadgenConsentBasis?, fetcher: LeadgenFetching, dns: any LeadgenResolving, now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }) async throws -> LeadgenDiscoveryResult {
        guard let origin = origin(of: directory) else { throw LeadgenError.unsafeURL("directory has no host") }
        let directoryReader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: [directory.host ?? ""]), fetcher: fetcher, dns: dns, now: now)
        var path = directory.path.isEmpty ? "/" : directory.path
        if let query = directory.query, !query.isEmpty { path += "?\(query)" }
        let listed = try await directoryReader.read(site: origin, paths: [path])
        guard let page = listed.first(where: { $0.url.path == directory.path || directory.path.isEmpty || $0.url.absoluteString.hasPrefix(directory.absoluteString) || listed.count == 1 }) ?? listed.first else {
            throw LeadgenError.fetchFailed(directory.absoluteString)
        }
        let found = clinics(in: page.html, directory: directory)
        guard found.count == 1, let clinic = found.first else { throw LeadgenError.notExactlyOneProspect(found.count) }
        let siteReader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: [clinic.site.host ?? ""]), fetcher: fetcher, dns: dns, now: now)
        let pages = try await siteReader.read(site: clinic.site, paths: paths)
        let domain = LeadgenSourcePolicy.normalize(clinic.site.host ?? "")
        let own = pages.filter { LeadgenSourcePolicy.normalize($0.url.host ?? "") == domain }
        var chosen: (email: String, url: String)?
        for page in own {
            for email in emails(in: page.bodyText) where MailAddress.domain(email).map({ LeadgenSourcePolicy.normalize($0) == domain }) == true {
                chosen = (email, page.url.absoluteString)
                break
            }
            if chosen != nil { break }
        }
        guard let chosen else { throw LeadgenError.contactNotOnPage(clinic.name) }
        let prospect = LeadgenProspect(organization: clinic.name, segment: LeadgenProspectPicker.segment, site: clinic.site, publicContactEmail: chosen.email)
        let proven: LeadgenConsentBasis?
        if let consent, !consent.basis.trimmingCharacters(in: .whitespaces).isEmpty, !consent.recordedAt.isEmpty {
            proven = LeadgenConsentBasis(basis: consent.basis, source: chosen.url, recordedAt: consent.recordedAt)
        } else {
            proven = nil
        }
        let fetched = await directoryReader.fetchedURLs + siteReader.fetchedURLs
        return LeadgenDiscoveryResult(prospect: prospect, pages: pages, consent: proven, fetchedURLs: fetched)
    }
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
    var dns: any LeadgenResolving = LeadgenSystemDNS()
    var suppression: SuppressionList = SuppressionList()

    /// `LEADGEN_SUPPRESSION` names a JSON file of do-not-contact entries. Otherwise the injected list is used.
    func activeSuppression() -> SuppressionList {
        guard let raw = getenv("LEADGEN_SUPPRESSION") else { return suppression }
        let path = String(cString: raw)
        guard !path.isEmpty else { return suppression }
        return SuppressionList(storageURL: URL(fileURLWithPath: path))
    }

    /// Live order: schema check of both DBs (stop if `leads` exists), then one Gmail create-draft,
    /// then each row with that draft's real id. A failed insert leaves the unsent draft in place and
    /// the log names the draft id and which database failed. No row is written if the draft was not created.
    /// When `directory` is set, the prospect comes from that page, not from `candidates`.
    func run(candidates: [LeadgenProspect], paths: [String], consent: LeadgenConsentBasis?, postalAddress: String?, directory: URL? = nil) async throws -> LeadgenRunReport {
        if config.liveFlag { try config.authorizeLive() }
        let prospect: LeadgenProspect
        let pages: [LeadgenPage]
        let resolvedConsent: LeadgenConsentBasis?
        let fetched: [String]
        if let directory {
            await log.write("directory \(directory.absoluteString)")
            let found = try await LeadgenDiscovery.find(directory: directory, paths: paths, consent: consent, fetcher: fetcher, dns: dns, now: now)
            prospect = found.prospect
            pages = found.pages
            resolvedConsent = found.consent
            fetched = found.fetchedURLs
        } else {
            prospect = try LeadgenProspectPicker.pickOne(candidates)
            let reader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: [prospect.site.host ?? ""]), fetcher: fetcher, dns: dns, now: now)
            pages = try await reader.read(site: prospect.site, paths: paths)
            resolvedConsent = consent
            fetched = await reader.fetchedURLs
        }
        if let why = LeadgenSuppression.reason(address: prospect.publicContactEmail, siteHost: prospect.site.host ?? "", list: activeSuppression()) {
            await log.write("suppressed: \(why)")
            throw LeadgenError.suppressed(why)
        }
        let fit = try LeadgenFitFinder.find(pages: pages, prospect: prospect)
        var consentForDraft = resolvedConsent
        if let at = fit.evidence.first?.fetchedAt, !at.isEmpty, let basis = consentForDraft {
            consentForDraft = LeadgenConsentBasis(basis: basis.basis, source: basis.source, recordedAt: at)
        }
        let draft = try LeadgenDraftComposer.compose(prospect: prospect, fit: fit, consent: consentForDraft, postalAddress: postalAddress, pages: pages)
        guard config.isLive else {
            return LeadgenRunReport(live: false, fetchedURLs: fetched, prospect: prospect, fit: fit, draft: draft, draftID: nil, receipts: [])
        }
        guard draft.from == LeadgenDraft.mailbox else { throw LeadgenError.wrongMailbox(draft.from) }
        let host = LeadgenSourcePolicy.normalize(prospect.site.host ?? "")
        let stamp = now()
        let writer = LeadgenD1Writer(port: d1, log: log)
        let targets = [LeadgenProjectTarget.meCom, .pharos]
        for target in targets {
            await log.write("step schema-check \(target.databaseID)")
            if try await writer.snapshot(target.databaseID).hasLeads {
                await log.write("STOP leads table already exists in \(target.databaseID)")
                throw LeadgenError.leadsTableExists(target.databaseID)
            }
        }
        await log.write("step gmail-create-draft \(LeadgenDraft.mailbox)")
        let draftID = try await mailbox.createDraft(account: LeadgenDraft.mailbox, rawMIME: draft.rawMIME)
        await log.write("draft created id=\(draftID) message-id=\(draft.messageID)")
        let row = LeadgenLeadRow(
            id: "lead-\(host.replacingOccurrences(of: ".", with: "-"))-\(stamp.prefix(10))",
            organization: prospect.organization,
            site: prospect.site.absoluteString,
            fitReason: fit.reason,
            fitEvidence: fit.evidence.map { e in
                e.fetchedAt.isEmpty ? "\(e.url) | \(e.quote)" : "\(e.url) | \(e.fetchedAt) | \(e.quote)"
            }.joined(separator: "\n"),
            draftRef: draftID,
            consentBasis: "\(draft.consent.basis) | \(draft.consent.source) | \(draft.consent.recordedAt)",
            createdAt: stamp
        )
        var receipts: [LeadgenWriteReceipt] = []
        for target in targets {
            do {
                receipts.append(try await writer.insertOne(row, into: target))
            } catch {
                await log.write("draft \(draftID) left in place; row failed for \(target.databaseID)")
                throw error
            }
        }
        await log.write("done rows=\(receipts.count)")
        return LeadgenRunReport(live: true, fetchedURLs: fetched, prospect: prospect, fit: fit, draft: draft, draftID: draftID, receipts: receipts)
    }
}
