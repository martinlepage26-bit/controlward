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
    case suppressionUnavailable(String)
    case tokenProof(String)
    case missingFetchedAt

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
        case .postalAddressDenied(let word):
            word == "pinned-hash"
                ? "draft refused: the footer line does not match the pinned hash"
                : "draft refused: the footer address names a denied street (\(word))"
        case .configMissing(let path): "local config missing: \(path) (copy docs/leadgen-slice/leadgen.local.example.json)"
        case .configInvalid(let why): "local config invalid: \(why)"
        case .credentialMissing(let ref): "credential not found: \(ref) (env or Keychain reference only)"
        case .unsafeURL(let why): "url refused: \(why)"
        case .contactNotOnPage(let email): "recipient \(email) was not found on a page fetched from the clinic's own domain"
        case .consentSourceNotFetched(let url): "consent source was not a page fetched from the clinic's own domain: \(url)"
        case .suppressed(let why): "suppressed: \(why)"
        case .suppressionUnavailable(let why): "do-not-contact list unavailable: \(why)"
        case .tokenProof(let why): "token proof refused: \(why)"
        case .missingFetchedAt: "draft refused: evidence has no fetch time"
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
    /// Dentist name taken from a directory fiche. Empty when the page is not a fiche.
    var contactName: String = ""
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

enum LeadgenSHA256 {
    static func hex(_ bytes: [UInt8]) -> String { hash(bytes).map { String(format: "%02x", $0) }.joined() }

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var msg = message
        let bitLength = UInt64(message.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { msg.append(UInt8((bitLength >> UInt64(shift)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var offset = 0
        while offset < msg.count {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let j = offset + i * 4
                w[i] = (UInt32(msg[j]) << 24) | (UInt32(msg[j + 1]) << 16) | (UInt32(msg[j + 2]) << 8) | UInt32(msg[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ (s0 &+ maj)
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
            offset += 64
        }
        var out: [UInt8] = []
        for value in h {
            out.append(UInt8((value >> 24) & 0xff))
            out.append(UInt8((value >> 16) & 0xff))
            out.append(UInt8((value >> 8) & 0xff))
            out.append(UInt8(value & 0xff))
        }
        return out
    }
}

enum LeadgenDraftComposer {
    static let signature = "Martin Lepage, PhD\nPHAROS AI\nml@pharos-ai.ca"
    /// SHA-256 of the NFC UTF-8 bytes of the full footer line. The line itself lives only in local config.
    static let footerLineSHA256 = "e3befc4fae6cdb04461ea60b1633bc6e11e3349df76c1ff7fa738c90f9095f0d"

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
        let nfc = address.precomposedStringWithCanonicalMapping
        guard LeadgenSHA256.hex(Array(nfc.utf8)) == footerLineSHA256 else { throw LeadgenError.postalAddressDenied("pinned-hash") }
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
        let footerLine = try checkAddress(postalAddress)
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
        \(footerLine)
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

struct LeadgenDeclaredPermission: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var accountID: String
}

struct LeadgenDeclaredToken: Codable, Equatable, Sendable {
    var id: String
    var env: String
    var permissions: [LeadgenDeclaredPermission]
}

/// Gitignored record of a token id and its permission list. It never holds the token value.
struct LeadgenDeclaredPolicy: Codable, Equatable, Sendable {
    var tokens: [LeadgenDeclaredToken]
}

struct LeadgenVerifiedToken: Equatable, Sendable {
    var id: String
    var status: String
}

/// Declared-and-captured proof. Verify returns only id and status. The permission list is the saved record, not a live policy read.
enum LeadgenTokenProof {
    static let d1ReadPermissionGroupID = "192192df92ee43ac90f2aeeffce67e35"
    static let d1ReadPermissionGroupName = "D1 Read"
    static let d1WritePermissionGroupID = "09b2857d1c31407795e75e3fed8617a1"
    static let d1WritePermissionGroupName = "D1 Write"
    static let readTokenEnvs = ["LEADGEN_CF_TOKEN_MECOM_READ", "LEADGEN_CF_TOKEN_PHAROS_READ"]
    static let accountIDs = [
        "e1e9fa25-4c6e-476e-bf16-979c0fd9e5b1",
        "959e5bdb-4213-496a-9557-10ec410440d7",
    ]

    static let fileName = "leadgen.token-policy.json"

    static func path(environment: [String: String]) -> String {
        if let named = environment["LEADGEN_TOKEN_POLICY"], !named.isEmpty { return named }
        let config = LeadgenLocalConfig.defaultPath(environment: environment)
        return URL(fileURLWithPath: config).deletingLastPathComponent().appendingPathComponent(fileName).path
    }

    static func load(environment: [String: String]) throws -> LeadgenDeclaredPolicy {
        let file = path(environment: environment)
        guard let data = FileManager.default.contents(atPath: file) else { throw LeadgenError.tokenProof("missing-declaration") }
        guard let saved = try? JSONDecoder().decode(LeadgenDeclaredPolicy.self, from: data) else {
            throw LeadgenError.tokenProof("missing-declaration")
        }
        return saved
    }

    /// Fail closed unless verify's id matches the saved id, status is active, and the saved list is only D1 Read on the two account ids.
    static func admit(saved: LeadgenDeclaredPolicy?, verified: [LeadgenVerifiedToken?]) throws {
        guard let saved, !saved.tokens.isEmpty else { throw LeadgenError.tokenProof("missing-declaration") }
        guard Set(saved.tokens.map(\.env)) == Set(readTokenEnvs) else { throw LeadgenError.tokenProof("missing-declaration") }
        let grants = saved.tokens.flatMap(\.permissions)
        guard !grants.isEmpty else { throw LeadgenError.tokenProof("missing-declaration") }
        let expected = Set(accountIDs.map { "\(d1ReadPermissionGroupID)|\(d1ReadPermissionGroupName)|\($0)" })
        let actual = grants.map { "\($0.id)|\($0.name)|\($0.accountID)" }
        guard Set(actual) == expected, actual.count == expected.count else { throw LeadgenError.tokenProof("not-d1-read") }
        guard verified.count == saved.tokens.count else { throw LeadgenError.tokenProof("unverifiable") }
        for (token, result) in zip(saved.tokens, verified) {
            guard let result else { throw LeadgenError.tokenProof("unverifiable") }
            guard result.status == "active" else { throw LeadgenError.tokenProof("inactive") }
            guard result.id == token.id else { throw LeadgenError.tokenProof("id-mismatch") }
        }
    }
}

protocol LeadgenTokenVerifying: Sendable {
    func verify(bearer: String) async throws -> LeadgenVerifiedToken
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
            if domains.contains(where: { HostMatch.belongs($0, to: host) }) { return "domain \(host)" }
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
    /// The directory page that named the clinic, and when that page was fetched.
    var directoryURL: String = ""
    var directoryFetchedAt: String = ""
    /// The own-site page the address was read from, and when that page was fetched.
    var emailPageURL: String = ""
    var emailFetchedAt: String = ""
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

    /// Picks external clinics linked from a directory page. Two clinics, or none, is a refusal.
    /// A DPQ fiche page yields the clinic name, the dentist name, and that clinic's own site.
    /// Maps, search, and aggregator links are ignored. A fiche with no own-site link is skipped.
    /// Any other HTML keeps the anchor-text scraper.
    static func clinics(in html: String, directory: URL) -> [(name: String, site: URL, dentist: String)] {
        if html.contains("dpqr-fiche") { return fiches(in: html, directory: directory) }
        return anchorClinics(in: html, directory: directory).map { (name: $0.name, site: $0.site, dentist: "") }
    }

    static func fiches(in html: String, directory: URL) -> [(name: String, site: URL, dentist: String)] {
        let pattern = "<article\\b[^>]*\\bdpqr-fiche\\b[^>]*>[\\s\\S]*?</article>"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var byDomain: [String: (name: String, site: URL, dentist: String)] = [:]
        var order: [String] = []
        for match in expression.matches(in: html, range: range) {
            guard let articleRange = Range(match.range, in: html) else { continue }
            let article = String(html[articleRange])
            guard let site = ownSite(in: article, directory: directory) else { continue }
            let domain = LeadgenSourcePolicy.normalize(site.host ?? "")
            let clinic = elementText(article, tag: "p", className: "dpqr-clinique")
            let dentist = elementText(article, tag: "h3", className: "dpqr-nom")
            let label = clinic.isEmpty ? domain : clinic
            if byDomain[domain] == nil {
                byDomain[domain] = (label, site, dentist)
                order.append(domain)
            }
        }
        return order.compactMap { byDomain[$0] }
    }

    /// First https link in a fiche that is the clinic's own site. Maps, search, aggregators, and the directory host are not it.
    static func ownSite(in html: String, directory: URL) -> URL? {
        let directoryHost = LeadgenSourcePolicy.normalize(directory.host ?? "")
        let pattern = "<a\\b[^>]*?href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in expression.matches(in: html, range: range) {
            guard let hrefRange = Range(match.range(at: 1), in: html) else { continue }
            let href = decodeHref(String(html[hrefRange])).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: href, relativeTo: directory)?.absoluteURL, let host = url.host, !host.isEmpty else { continue }
            let domain = LeadgenSourcePolicy.normalize(host)
            if domain == directoryHost || domain.isEmpty { continue }
            if HostSafety.refusal(url: url, resolvedAddresses: nil) != nil { continue }
            if LeadgenSourcePolicy.blockedHostFragments.contains(where: { domain.contains($0) }) { continue }
            if skipHostFragments.contains(where: { domain.contains($0) }) { continue }
            let path = url.path.lowercased()
            if path.contains("/maps") || path.contains("/search") { continue }
            return origin(of: url)
        }
        return nil
    }

    static func decodeHref(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&#038;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func elementText(_ html: String, tag: String, className: String) -> String {
        let pattern = "<\(tag)\\b[^>]*class\\s*=\\s*[\"'][^\"']*\\b\(className)\\b[^\"']*[\"'][^>]*>([\\s\\S]*?)</\(tag)>"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let textRange = Range(match.range(at: 1), in: html) else { return "" }
        return visibleText(String(html[textRange]))
    }

    static func anchorClinics(in html: String, directory: URL) -> [(name: String, site: URL)] {
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
            let href = decodeHref(String(html[hrefRange])).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Role and clinic mailboxes. A personal address is used only when no role address is published.
    static let roleLocals: Set<String> = [
        "info", "contact", "reception", "accueil", "bureau", "admin", "office", "hello", "bonjour",
        "clinique", "clinic", "secretariat", "secretaire", "rendezvous", "appointments",
    ]
    static let noSolicitPhrases = ["no solicitation", "pas de sollicitation", "aucune sollicitation"]

    /// Own-domain address published in the page body. Never constructs an address.
    /// No-solicitation wording on the fetched page refuses the entry.
    static func publishedEmail(on pages: [LeadgenPage], domain: String, clinic: String) throws -> (email: String, url: String) {
        for page in pages {
            let visible = (page.bodyText + "\n" + page.html).lowercased()
            if noSolicitPhrases.contains(where: { visible.contains($0) }) {
                throw LeadgenError.suppressed("no-solicitation")
            }
        }
        var role: (email: String, url: String)?
        var personal: (email: String, url: String)?
        for page in pages {
            for email in emails(in: page.bodyText) {
                guard MailAddress.domain(email).map({ LeadgenSourcePolicy.normalize($0) == domain }) == true else { continue }
                let local = email.split(separator: "@").first.map { String($0) } ?? ""
                let hit = (email, page.url.absoluteString)
                if roleLocals.contains(local) {
                    if role == nil { role = hit }
                } else if personal == nil {
                    personal = hit
                }
            }
        }
        if let role { return role }
        if let personal { return personal }
        throw LeadgenError.contactNotOnPage(clinic)
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
    /// The only directory host. Any other host, including a redirect target, is refused.
    static let directoryHost = "dpq.quebec"

    static func find(directory: URL, paths: [String], consent: LeadgenConsentBasis?, fetcher: LeadgenFetching, dns: any LeadgenResolving, now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }) async throws -> LeadgenDiscoveryResult {
        let host = LeadgenSourcePolicy.normalize(directory.host ?? "")
        guard host == directoryHost else { throw LeadgenError.hostNotAllowed(host) }
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
        let chosen = try publishedEmail(on: own, domain: domain, clinic: clinic.name)
        let prospect = LeadgenProspect(organization: clinic.name, segment: LeadgenProspectPicker.segment, site: clinic.site, publicContactEmail: chosen.email, contactName: clinic.dentist)
        let proven: LeadgenConsentBasis?
        if let consent, !consent.basis.trimmingCharacters(in: .whitespaces).isEmpty, !consent.recordedAt.isEmpty {
            proven = LeadgenConsentBasis(basis: consent.basis, source: chosen.url, recordedAt: consent.recordedAt)
        } else {
            proven = nil
        }
        let fetched = await directoryReader.fetchedURLs + siteReader.fetchedURLs
        let emailFetchedAt = own.first { $0.url.absoluteString == chosen.url }?.fetchedAt ?? ""
        return LeadgenDiscoveryResult(
            prospect: prospect, pages: pages, consent: proven, fetchedURLs: fetched,
            directoryURL: page.url.absoluteString, directoryFetchedAt: page.fetchedAt,
            emailPageURL: chosen.url, emailFetchedAt: emailFetchedAt)
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

    /// `LEADGEN_SUPPRESSION` must name a readable JSON file. Missing, empty, unreadable, or unparseable refuses the draft.
    func activeSuppression() throws -> SuppressionList {
        guard let raw = getenv("LEADGEN_SUPPRESSION") else {
            throw LeadgenError.suppressionUnavailable("LEADGEN_SUPPRESSION is not set")
        }
        let path = String(cString: raw)
        guard !path.isEmpty else { throw LeadgenError.suppressionUnavailable("LEADGEN_SUPPRESSION is empty") }
        do { return try SuppressionList.requireFile(at: URL(fileURLWithPath: path)) }
        catch let error as SuppressionFileError { throw LeadgenError.suppressionUnavailable(error.description) }
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
        let discovery: LeadgenDiscoveryResult?
        if let directory {
            await log.write("directory \(directory.absoluteString)")
            await log.write("discovery source: \(directory.absoluteString)")
            let found = try await LeadgenDiscovery.find(directory: directory, paths: paths, consent: consent, fetcher: fetcher, dns: dns, now: now)
            prospect = found.prospect
            pages = found.pages
            resolvedConsent = found.consent
            fetched = found.fetchedURLs
            discovery = found
        } else {
            discovery = nil
            prospect = try LeadgenProspectPicker.pickOne(candidates)
            let reader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: [prospect.site.host ?? ""]), fetcher: fetcher, dns: dns, now: now)
            pages = try await reader.read(site: prospect.site, paths: paths)
            resolvedConsent = consent
            fetched = await reader.fetchedURLs
        }
        let suppression: SuppressionList
        do { suppression = try activeSuppression() }
        catch {
            await log.write("suppression refused: \(error)")
            throw error
        }
        if let why = LeadgenSuppression.reason(address: prospect.publicContactEmail, siteHost: prospect.site.host ?? "", list: suppression) {
            await log.write("suppressed: \(why)")
            throw LeadgenError.suppressed(why)
        }
        let fit = try LeadgenFitFinder.find(pages: pages, prospect: prospect)
        if fit.evidence.contains(where: { $0.fetchedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            await log.write("fetchedAt refused: empty")
            throw LeadgenError.missingFetchedAt
        }
        var consentForDraft = resolvedConsent
        if let at = fit.evidence.first?.fetchedAt, let basis = consentForDraft {
            consentForDraft = LeadgenConsentBasis(basis: basis.basis, source: basis.source, recordedAt: at)
        }
        let draft: LeadgenDraft
        do {
            draft = try LeadgenDraftComposer.compose(prospect: prospect, fit: fit, consent: consentForDraft, postalAddress: postalAddress, pages: pages)
        } catch {
            if case LeadgenError.missingPostalAddress = error { await log.write("footer refused: \(error)") }
            if case LeadgenError.postalAddressDenied = error { await log.write("footer refused: \(error)") }
            throw error
        }
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
            fitEvidence: {
                var lines = fit.evidence.map { e in "\(e.url) | \(e.fetchedAt) | \(e.quote)" }
                if let discovery {
                    lines.append("\(discovery.directoryURL) | \(discovery.directoryFetchedAt)")
                    lines.append("\(discovery.emailPageURL) | \(discovery.emailFetchedAt)")
                }
                return lines.joined(separator: "\n")
            }(),
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
