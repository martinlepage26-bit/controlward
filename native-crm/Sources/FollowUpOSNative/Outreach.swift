import Foundation

/// A cold-outreach draft. It is only ever saved as a draft; sending goes through `OutreachSendGate`.
struct OutreachDraft: Codable, Equatable, Identifiable, Sendable {
    var messageID: String
    var prospectID: String
    var to: String
    var from: String
    var subject: String
    var body: String
    var language: String
    /// RFC 2369 header value, e.g. `<mailto:ml@pharos-ai.ca?subject=unsubscribe>`.
    var listUnsubscribe: String?
    var consent: ConsentBasis?
    /// 1 for the first message, 2+ for follow-ups. Follow-ups are drafts only.
    var step: Int = 1
    var parentMessageID: String?
    var id: String { messageID }
}

enum SuppressionFileError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case unreadable(String)
    case unparseable(String)

    var description: String {
        switch self {
        case .missing(let path): "missing \(path)"
        case .unreadable(let path): "unreadable \(path)"
        case .unparseable(let path): "unparseable \(path)"
        }
    }
}

/// Addresses that unsubscribed. Every later draft or send to them is refused (S3-R6).
final class SuppressionList: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var address: String
        var at: Date
        var via: String
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let storageURL: URL?

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL
        if let storageURL, let data = try? Data(contentsOf: storageURL),
           let stored = try? JSONDecoder.iso.decode([Entry].self, from: data) {
            replace(stored)
        }
    }

    /// Lead-gen refuses the draft unless this file exists and parses. Keys are trimmed and lowercased.
    static func requireFile(at url: URL) throws -> SuppressionList {
        guard FileManager.default.fileExists(atPath: url.path) else { throw SuppressionFileError.missing(url.path) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw SuppressionFileError.unreadable(url.path) }
        let stored: [Entry]
        do { stored = try JSONDecoder.iso.decode([Entry].self, from: data) } catch { throw SuppressionFileError.unparseable(url.path) }
        let list = SuppressionList()
        list.replace(stored)
        return list
    }

    func replace(_ stored: [Entry]) {
        lock.withLock {
            var next: [String: Entry] = [:]
            for entry in stored {
                let key = MailAddress.bare(entry.address)
                guard !key.isEmpty, next[key] == nil else { continue }
                next[key] = Entry(address: key, at: entry.at, via: entry.via)
            }
            entries = next
        }
    }

    func contains(_ address: String) -> Bool { lock.withLock { entries[MailAddress.bare(address)] != nil } }

    var all: [Entry] { lock.withLock { entries.values.sorted { $0.address < $1.address } } }

    func record(_ address: String, at: Date, via: String) {
        lock.withLock {
            let key = MailAddress.bare(address)
            guard entries[key] == nil else { return }
            entries[key] = Entry(address: key, at: at, via: via)
            if let storageURL, let data = try? JSONEncoder.iso.encode(Array(entries.values)) {
                try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: storageURL, options: .atomic)
            }
        }
    }

    /// Reply-to-unsubscribe: an inbound message to the unsubscribe mailbox whose subject or first line says
    /// unsubscribe / désabonner records its sender. Returns true when it recorded.
    @discardableResult
    func processReply(from sender: String, to recipient: String, subject: String, firstLine: String, config: ICPConfig, at: Date) -> Bool {
        guard MailAddress.bare(recipient) == MailAddress.bare(config.sender.unsubscribeMailto) else { return false }
        let text = (subject + " " + firstLine).lowercased()
        let words = ["unsubscribe", "désabonner", "desabonner", "désabonnement", "desabonnement", "stop"]
        guard words.contains(where: { text.contains($0) }) else { return false }
        record(sender, at: at, via: "reply-to-unsubscribe")
        return true
    }
}

/// Stored dates keep milliseconds (Water 10:13, live-proof cause 2): the CW-AUDIT log stamps fetches to the millisecond, so a
/// second-precision prospects.json could never match its own fetch and score lines. Files written before this still read.
enum ISODates {
    static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }
    static func string(_ date: Date) -> String { formatter(fractional: true).string(from: date) }
    static func date(_ text: String) -> Date? { formatter(fractional: true).date(from: text) ?? formatter(fractional: false).date(from: text) }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISODates.date(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 date, got \(text)")
            }
            return date
        }
        return decoder
    }
}
extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISODates.string(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// Builds FR/EN drafts with the CASL footer. It never sends.
enum OutreachDraftBuilder {
    static func footer(config: ICPConfig, language: String) -> String {
        let sender = config.sender
        let unsubscribe = "mailto:\(sender.unsubscribeMailto)?subject=\(sender.unsubscribeSubject)"
        if language == "fr" {
            return """
            --
            \(sender.name), \(sender.organization)
            \(sender.mailingAddress)
            Vous recevez ce message parce que votre adresse est publiée sur le site de votre organisation. Pour ne plus recevoir de messages, répondez « unsubscribe » ou écrivez à \(unsubscribe).
            """
        }
        return """
        --
        \(sender.name), \(sender.organization)
        \(sender.mailingAddress)
        You are receiving this because your address is published on your organisation's website. To stop receiving messages, reply "unsubscribe" or write to \(unsubscribe).
        """
    }

    /// A short, signal-first message. No pitch, no pricing, no legal statements, no client data.
    static func build(for prospect: ProspectRecord, config: ICPConfig, language: String, messageID: String, step: Int = 1, parentMessageID: String? = nil) -> OutreachDraft {
        let firstName = prospect.contact?.name.split(separator: " ").first.map(String.init) ?? ""
        // Only an evidenced on-site excerpt is quoted; no conclusions about the prospect.
        let citation = ProspectResearcher.citation(for: prospect)
        let body: String
        let subject: String
        if language == "fr" {
            subject = "Question au sujet de \(prospect.organisation)"
            body = """
            Bonjour \(firstName),

            \(citation.map { "Sur votre site (\($0.url)), j'ai lu : « \($0.excerpt) »" } ?? "")

            J'aide des organisations québécoises à encadrer leurs outils d'IA. Seriez-vous ouvert(e) à un échange de 15 minutes?

            \(footer(config: config, language: "fr"))
            """
        } else {
            subject = "A question about \(prospect.organisation)"
            body = """
            Hello \(firstName),

            \(citation.map { "On your site (\($0.url)) I read: “\($0.excerpt)”" } ?? "")

            I help Québec organisations put guardrails around their AI tools. Would you be open to a 15-minute conversation?

            \(footer(config: config, language: "en"))
            """
        }
        return OutreachDraft(
            messageID: messageID, prospectID: prospect.id, to: prospect.route?.kind == .email ? prospect.route!.value : "",
            from: config.sender.from, subject: subject, body: body, language: language,
            listUnsubscribe: "<mailto:\(config.sender.unsubscribeMailto)?subject=\(config.sender.unsubscribeSubject)>",
            consent: prospect.consent, step: step, parentMessageID: parentMessageID)
    }
}

/// Checks a draft before it is saved (S3-R6, S3-R10, S3-R14, S3-R17c, S3-R8).
enum OutreachDraftGate {
    static func check(_ draft: OutreachDraft, prospect: ProspectRecord, config: ICPConfig, suppression: SuppressionList, now: Date) -> LeadPipelineRefusal? {
        if let refusal = fromAlias(draft.from, config: config) { return refusal }
        if let refusal = holds(prospect, config: config) { return refusal }
        let verdict = LeadDefinition.evaluate(prospect, config: config, now: now)
        if verdict.status != .ready { return LeadPipelineRefusal(code: "refused:lead-def", detail: verdict.reasons.joined(separator: "; ")) }
        if let refusal = AddressProvenance.check(prospect) { return refusal }
        if let refusal = antiSpam(draft, config: config, suppression: suppression) { return refusal }
        if !AddressProvenance.consentFromOwnDomain(prospect) { return LeadPipelineRefusal(code: "refused:anti-spam:consent", detail: "consent not from own domain") }
        if let refusal = content(draft, config: config) { return refusal }
        if let refusal = citations(draft, prospect: prospect) { return refusal }
        return nil
    }

    /// The draft may quote only `observed_facts` / `supporting_evidence` that check out against the stored snapshots,
    /// and only when the assessment does not need manual review. Every URL and quote above the footer must be one of those.
    static func citations(_ draft: OutreachDraft, prospect: ProspectRecord) -> LeadPipelineRefusal? {
        guard let research = prospect.research, !research.assessment.requiresManualReview,
              ProspectResearcher.citation(for: prospect) != nil else {
            return LeadPipelineRefusal(code: "refused:research:manual-review", detail: "no evidence-backed opportunity")
        }
        let citable = ProspectResearcher.citable(prospect)
        let urls = Set(citable.map(\.url))
        let excerpts = Set(citable.map(\.excerpt))
        let message = draft.body.components(separatedBy: "\n--\n").first ?? draft.body
        for url in SiteExtractor.matches(message, "https?://[^\\s)»”\"]+") where !urls.contains(url) {
            return LeadPipelineRefusal(code: "refused:research:unsupported-claim", detail: url)
        }
        for quote in SiteExtractor.matches(message, "«[^»]*»|“[^”]*”") {
            let inner = quote.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if !excerpts.contains(inner) { return LeadPipelineRefusal(code: "refused:research:unsupported-claim", detail: inner) }
        }
        return nil
    }

    static func fromAlias(_ from: String, config: ICPConfig) -> LeadPipelineRefusal? {
        if MailAddress.bare(from) != MailAddress.bare(config.sender.from) { return LeadPipelineRefusal(code: "refused:from-not-alias") }
        return nil
    }

    /// Conflict-area trades and organisations with an open tender are never drafted.
    static func holds(_ prospect: ProspectRecord, config: ICPConfig) -> LeadPipelineRefusal? {
        if prospect.status == .conflictReview
            || LeadDefinition.conflictArea(for: prospect, config: config) != nil
            || LeadDefinition.rbqLicenceUnverified(prospect, config: config) {
            return LeadPipelineRefusal(code: "refused:hold:conflict-review")
        }
        if prospect.openTenderURL != nil { return LeadPipelineRefusal(code: "refused:hold:open-tender") }
        return nil
    }

    /// CASL: identification, mailing address, a working unsubscribe, a consent basis, and no suppressed address.
    static func antiSpam(_ draft: OutreachDraft, config: ICPConfig, suppression: SuppressionList) -> LeadPipelineRefusal? {
        let sender = config.sender
        if suppression.contains(draft.to) { return LeadPipelineRefusal(code: "refused:anti-spam:unsubscribed") }
        let address = sender.mailingAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty || address.uppercased().contains("PLACEHOLDER") {
            return LeadPipelineRefusal(code: "refused:anti-spam:placeholder-address", detail: "sender mailing address is empty or a placeholder")
        }
        if !draft.body.contains(sender.organization) || !draft.body.contains(sender.name) {
            return LeadPipelineRefusal(code: "refused:anti-spam:identification")
        }
        if !draft.body.contains(sender.mailingAddress) { return LeadPipelineRefusal(code: "refused:anti-spam:address") }
        let mailto = "mailto:\(sender.unsubscribeMailto)"
        if !draft.body.contains(mailto) || draft.listUnsubscribe?.contains(mailto) != true {
            return LeadPipelineRefusal(code: "refused:anti-spam:unsubscribe")
        }
        if draft.consent == nil { return LeadPipelineRefusal(code: "refused:anti-spam:consent") }
        return nil
    }

    /// `draft_forbidden` rules from config, checked on subject and body.
    static func content(_ draft: OutreachDraft, config: ICPConfig) -> LeadPipelineRefusal? {
        let text = draft.subject + "\n" + draft.body
        for rule in config.draftForbidden {
            for pattern in rule.patterns {
                if text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    return LeadPipelineRefusal(code: "refused:draft-content:\(rule.rule)")
                }
            }
        }
        return nil
    }
}

/// SHA-256 (FIPS 180-4) as lowercase hex. Written out so the same code runs on macOS and Linux without CryptoKit.
enum SHA256Hex {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func digest(_ data: Data) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(message[b]) << 24 | UInt32(message[b + 1]) << 16 | UInt32(message[b + 2]) << 8 | UInt32(message[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.map { word in (0..<4).map { String(format: "%02x", (word >> UInt32(24 - $0 * 8)) & 0xff) }.joined() }.joined()
    }
}

/// Martin's go-ahead for one exact message (S3-R7).
struct OutreachApproval: Codable, Equatable, Sendable {
    var approver: String
    var approvalID: String
    var messageID: String
    /// SHA-256 over the approved recipient, subject, body and List-Unsubscribe (Argus should-fix 1). The send gate
    /// refuses a draft whose content no longer matches, so an edit after approval needs a new approval.
    var contentHash: String = ""
    var text: String { "approver=\(approver) approval=\(approvalID)" }

    static func contentHash(_ draft: OutreachDraft) -> String {
        // Length-prefixed fields, so moving text from one field to another changes the hash.
        let fields = [draft.to, draft.subject, draft.body, draft.listUnsubscribe ?? ""]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "\n")
        return SHA256Hex.digest(Data(canonical.utf8))
    }

    static func grant(for draft: OutreachDraft, approvalID: String, approver: String = "martin") -> OutreachApproval {
        OutreachApproval(approver: approver, approvalID: approvalID, messageID: draft.messageID, contentHash: contentHash(draft))
    }
}

/// Checks a send before any request (S3-R6, S3-R7, S3-R8, S3-R11).
enum OutreachSendGate {
    static func check(_ draft: OutreachDraft, approval: OutreachApproval?, config: ICPConfig, suppression: SuppressionList) -> LeadPipelineRefusal? {
        if let refusal = OutreachDraftGate.fromAlias(draft.from, config: config) { return refusal }
        guard let approval, approval.approver == "martin", !approval.approvalID.isEmpty, approval.messageID == draft.messageID else {
            return LeadPipelineRefusal(code: "refused:no-approval", detail: "each message needs its own go-ahead")
        }
        guard !approval.contentHash.isEmpty, approval.contentHash == OutreachApproval.contentHash(draft) else {
            return LeadPipelineRefusal(code: "refused:approval-content-mismatch", detail: "the message changed after it was approved")
        }
        if !config.loi25Gate.open, !config.isMartinAddress(draft.to) { return LeadPipelineRefusal(code: "refused:loi25-gate") }
        if let refusal = OutreachDraftGate.antiSpam(draft, config: config, suppression: suppression) { return refusal }
        if let refusal = OutreachDraftGate.content(draft, config: config) { return refusal }
        return nil
    }
}
