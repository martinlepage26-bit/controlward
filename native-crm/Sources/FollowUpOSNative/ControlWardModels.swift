import Foundation
import CryptoKit

struct ControlWardWorkspace: Codable, Equatable, Sendable {
    var mail: [MailMetadata] = []
    var projectLinks: [RecordProjectLink] = []
    var captures: [ProjectCaptureReceipt] = []
    var remediationTasks: [UUID: UUID] = [:]
    init() {}
    private enum CodingKeys: String, CodingKey { case mail, projectLinks, captures, remediationTasks }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mail = try c.decodeIfPresent([MailMetadata].self, forKey: .mail) ?? []
        projectLinks = try c.decodeIfPresent([RecordProjectLink].self, forKey: .projectLinks) ?? []
        captures = try c.decodeIfPresent([ProjectCaptureReceipt].self, forKey: .captures) ?? []
        remediationTasks = try c.decodeIfPresent([UUID: UUID].self, forKey: .remediationTasks) ?? [:]
    }
}

struct MailMetadata: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var sourceID: String
    var subject: String
    var sender: String
    var recipient: String
    var receivedAt: String
    var provider: String
    var accountID: String
    var synthetic: Bool
    var link: String = ""
    var reviewed = false
    var contactID: UUID?
    var companyID: UUID?
    var taskID: UUID?

    static func sourceIdentity(account: String, message: String, synthetic: Bool) -> String {
        // Preserve the Email Aggregator adapter's UUID pair contract. Arbitrary
        // imported IDs are length-prefixed and hashed to avoid delimiter collisions.
        if synthetic, UUID(uuidString: account) != nil, UUID(uuidString: message) != nil { return "\(account):\(message)" }
        let input = Data("\(account.utf8.count):\(account)\(message)".utf8)
        return "mail:" + SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    var capture: ProjectCapture {
        ProjectCapture(source: synthetic ? "email-aggregator-synthetic" : "controlward-email-import",
                       sourceID: Self.sourceIdentity(account: accountID, message: sourceID, synthetic: synthetic), summary: subject, link: link,
                       metadata: ["from": sender, "to": recipient, "date": receivedAt,
                                  "provider": provider, "account_id": accountID,
                                  "synthetic": synthetic ? "true" : "false"])
    }
}

struct RecordProjectLink: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var recordKey: String
    var register: String
    var projectID: String
    var projectTitle: String
}

struct ProjectCapture: Codable, Equatable, Sendable {
    var source: String
    var sourceID: String
    var summary: String
    var link: String = ""
    var metadata: [String: String] = [:]
    enum CodingKeys: String, CodingKey { case source, sourceID = "source_id", summary, link, metadata }
}

struct ProjectCaptureReceipt: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var recordKey: String
    var register: String
    var itemID: String
    var capturedAt = Date.now.ISO8601Format()
}

enum RecordFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    case all, open, completed, overdue
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum RecordSort: String, CaseIterable, Identifiable, Sendable {
    case name, newest, due
    var id: String { rawValue }
    var label: String { switch self { case .name: "Name"; case .newest: "Newest"; case .due: "Due date" } }
}

struct WorkspaceRecord: Identifiable, Equatable, Sendable {
    var recordID: UUID
    var kind: String
    var title: String
    var detail: String
    var status: String = ""
    var date: String = ""
    var createdAt: String = ""
    var completed = false
    var supportsCompletion = false
    var companyID: UUID?
    var id: String { "\(kind):\(recordID.uuidString.lowercased())" }

    static func query(_ records: [WorkspaceRecord], search: String, filter: RecordFilter, sort: RecordSort, today: String) -> [WorkspaceRecord] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return records.filter { record in
            let text = "\(record.title) \(record.detail) \(record.status)"
            guard words.allSatisfy({ text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) else { return false }
            switch filter {
            case .all: return true
            case .open: return record.supportsCompletion && !record.completed
            case .completed: return record.supportsCompletion && record.completed
            case .overdue: return record.supportsCompletion && !record.completed && validDay(record.date) && record.date < today
            }
        }.sorted { lhs, rhs in
            if sort == .newest, lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            if sort == .due, lhs.date != rhs.date { return (lhs.date.isEmpty ? "9999" : lhs.date) < (rhs.date.isEmpty ? "9999" : rhs.date) }
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    static func validDay(_ text: String) -> Bool {
        let values = text.split(separator: "-").compactMap { Int($0) }
        guard text.count == 10, values.count == 3 else { return false }
        let calendar = Calendar(identifier: .gregorian)
        let input = DateComponents(year: values[0], month: values[1], day: values[2])
        guard let date = calendar.date(from: input) else { return false }
        let output = calendar.dateComponents([.year, .month, .day], from: date)
        return input.year == output.year && input.month == output.month && input.day == output.day
    }
}

enum ControlWardError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

/// Accepts metadata exports only. Unknown fields (including bodies and tokens)
/// are never decoded or persisted. Imported identity is provenance, not authentication.
enum MailMetadataImport {
    private struct Export: Decodable { var schema_version: String; var messages: [Message] }
    private struct Message: Decodable {
        var source_id: String; var subject: String; var sender: String; var recipient: String
        var received_at: String; var provider: String; var account_id: String
        var synthetic: Bool; var link: String?
    }
    private struct SyntheticExport: Decodable { var email: SyntheticEmail; var account: SyntheticAccount }
    private struct SyntheticAccount: Decodable { var id: String; var user_id: String; var connection_status: String }
    private struct SyntheticEmail: Decodable {
        var id: String; var user_id: String; var email_account_id: String; var subject: String
        var sender_email: String; var recipient_email: String; var received_at: String; var provider: String
    }

    static func decode(_ data: Data) throws -> [MailMetadata] {
        guard data.count <= 20_000_000 else { throw ControlWardError.invalid("Mail imports must be under 20 MB.") }
        let decoder = JSONDecoder()
        let messages: [Message]
        if let export = try? decoder.decode(Export.self, from: data) {
            guard export.schema_version == "controlward.mail.v1" else { throw ControlWardError.invalid("Unsupported mail metadata format.") }
            messages = export.messages
        } else if let export = try? decoder.decode(SyntheticExport.self, from: data) {
            let email = export.email, account = export.account
            guard account.connection_status == "synthetic", UUID(uuidString: account.id) != nil,
                  UUID(uuidString: email.id) != nil, UUID(uuidString: email.user_id) != nil,
                  email.email_account_id == account.id, email.user_id == account.user_id else {
                throw ControlWardError.invalid("The synthetic message and account do not match.")
            }
            messages = [Message(source_id: email.id, subject: email.subject,
                                sender: email.sender_email, recipient: email.recipient_email,
                                received_at: email.received_at, provider: email.provider,
                                account_id: account.id, synthetic: true, link: nil)]
        } else { throw ControlWardError.invalid("Choose a ControlWard mail metadata export or an Email Aggregator synthetic fixture.") }
        guard messages.count <= 10_000 else { throw ControlWardError.invalid("Mail imports are limited to 10,000 messages.") }
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var seen = Set<String>()
        return try messages.map { m in
            guard !m.source_id.isEmpty, m.source_id.count <= 200, !m.account_id.isEmpty,
                  [m.subject, m.sender, m.recipient, m.received_at, m.provider, m.account_id].allSatisfy({ $0.count <= 1000 }),
                  iso.date(from: m.received_at) != nil || fractional.date(from: m.received_at) != nil,
                  WorkspaceRecord.validDay(String(m.received_at.prefix(10))),
                  !m.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ControlWardError.invalid("A message has invalid or oversized metadata. Nothing was imported.")
            }
            let identity = "\(m.synthetic):" + MailMetadata.sourceIdentity(account: m.account_id, message: m.source_id, synthetic: m.synthetic)
            guard seen.insert(identity).inserted else { throw ControlWardError.invalid("The import repeats a message identity. Nothing was imported.") }
            let link = m.link ?? ""
            if !link.isEmpty {
                guard let u = URL(string: link), u.scheme == "https", u.host != nil, u.user == nil, u.password == nil,
                      link.count <= 2000, EndpointPolicy.sanitize(link)?.removedSecrets == false else {
                    throw ControlWardError.invalid("Message links must be credential-free HTTPS links.")
                }
            }
            return MailMetadata(sourceID: m.source_id, subject: m.subject, sender: m.sender, recipient: m.recipient,
                                receivedAt: m.received_at, provider: m.provider, accountID: m.account_id, synthetic: m.synthetic, link: link)
        }
    }
}
