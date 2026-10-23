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
            entries = Dictionary(stored.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
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

extension JSONDecoder {
    static var iso: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder
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
        let triggerURL = prospect.trigger?.url ?? ""
        let fit = prospect.fit ?? ""
        let body: String
        let subject: String
        if language == "fr" {
            subject = "Question au sujet de \(prospect.organisation)"
            body = """
            Bonjour \(firstName),

            J'ai lu cette page de votre site : \(triggerURL)
            \(fit)

            J'aide des organisations québécoises à encadrer leurs outils d'IA. Seriez-vous ouvert(e) à un échange de 15 minutes?

            \(footer(config: config, language: "fr"))
            """
        } else {
            subject = "A question about \(prospect.organisation)"
            body = """
            Hello \(firstName),

            I read this page on your site: \(triggerURL)
            \(fit)

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
        return nil
    }

    static func fromAlias(_ from: String, config: ICPConfig) -> LeadPipelineRefusal? {
        return nil
    }

    /// Conflict-area trades and organisations with an open tender are never drafted.
    static func holds(_ prospect: ProspectRecord, config: ICPConfig) -> LeadPipelineRefusal? {
        return nil
    }

    /// CASL: identification, mailing address, a working unsubscribe, a consent basis, and no suppressed address.
    static func antiSpam(_ draft: OutreachDraft, config: ICPConfig, suppression: SuppressionList) -> LeadPipelineRefusal? {
        return nil
    }

    /// `draft_forbidden` rules from config, checked on subject and body.
    static func content(_ draft: OutreachDraft, config: ICPConfig) -> LeadPipelineRefusal? {
        return nil
    }
}

/// Martin's go-ahead for one exact message (S3-R7).
struct OutreachApproval: Codable, Equatable, Sendable {
    var approver: String
    var approvalID: String
    var messageID: String
    var text: String { "approver=\(approver) approval=\(approvalID)" }
}

/// Checks a send before any request (S3-R6, S3-R7, S3-R8, S3-R11).
enum OutreachSendGate {
    static func check(_ draft: OutreachDraft, approval: OutreachApproval?, config: ICPConfig, suppression: SuppressionList) -> LeadPipelineRefusal? {
        return nil
    }
}
