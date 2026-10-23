import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Synthetic mail fixtures for Slices 1, 2 and 4. Every address is on example.test; nothing here is real mail.
enum MailFixture {
    static let subject = "Synthetic subject 7f3a"
    static let sender = "sender-7f3a@example.test"
    static let bodyText = "Synthetic body text 7f3a"
    static let token = "synthetic-access-7f3a"
    static let allowed = "allowed@example.test"
    static let outsider = "outsider@example.test"
    static let sourceID = "gmail:msg7f3a"
    static let allScopes: Set<String> = [GmailScopePolicy.modify, GmailScopePolicy.compose]

    static func compose(to: [String] = [allowed], subject: String = "Re: " + MailFixture.subject) -> MailCompose {
        MailCompose(draftID: nil, to: to, cc: [], subject: subject, body: bodyText)
    }

    static func command(_ action: MailboxAction, confirmed: Bool = true, compose: MailCompose? = nil) -> MailCommand {
        let needsCompose = action.sends || action == .editDraft
        return MailCommand(action: action, sourceID: sourceID, compose: compose ?? (needsCompose ? MailFixture.compose() : nil), confirmed: confirmed)
    }

    /// One JSON answer that satisfies every Gmail call the client makes (message, thread headers, send, draft, modify, trash).
    static var gmailAnswer: Data {
        let encoded = Base64URL.encode(Data(bodyText.utf8))
        let object: [String: Any] = [
            "id": "sent7f3a", "threadId": "thread7f3a",
            "payload": ["mimeType": "text/plain", "body": ["data": encoded], "headers": [["name": "Message-ID", "value": "<m7f3a@example.test>"]]],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }
}

/// Records every request and answers from a script. Thread-safe so connectors can share it.
final class CountingMailHTTP: MailHTTPSending, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    var status: Int
    var body: Data
    init(status: Int = 200, body: Data = MailFixture.gmailAnswer) { self.status = status; self.body = body }
    var requests: [URLRequest] { lock.withLock { stored } }
    var count: Int { requests.count }
    func send(_ request: URLRequest) async throws -> MailHTTPResponse {
        lock.withLock { stored.append(request) }
        return MailHTTPResponse(status: status, body: body)
    }
}

/// A connector that issues a DELETE through whatever transport it is given (planted red: it must be caught).
struct DeletingConnector<HTTP: MailHTTPSending>: MailboxConnecting {
    var providerID = "gmail"
    var accountID = "owner@example.test"
    var http: HTTP
    func supports() -> [MailActionSupport] { GmailScopePolicy.support(granted: MailFixture.allScopes) }
    func fetchBody(sourceID: String) async throws -> MailMessageBody { MailMessageBody(sourceID: sourceID, plain: "", html: "") }
    func perform(_ command: MailCommand) async throws -> MailCommandReceipt {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/msg7f3a")!)
        request.httpMethod = "DELETE"
        _ = try await http.send(request)
        return MailCommandReceipt(action: command.action, sourceID: command.sourceID, draftID: nil, location: "deleted")
    }
}

enum MailControlKit {
    static func gmail(_ http: CountingMailHTTP, scopes: Set<String> = MailFixture.allScopes) -> GmailMailboxConnector<NoDeleteMailHTTP<CountingMailHTTP>> {
        GmailMailboxConnector(providerID: "gmail", accountID: "owner@example.test", scopes: scopes, token: MailFixture.token, from: "owner@example.test", http: NoDeleteMailHTTP(inner: http))
    }

    static let fixedClock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_792_756_800) }

    static func runner(_ connector: any MailboxConnecting, sink: MemoryAuditSink, policy: MailSendPolicy = .off) -> MailActionRunner {
        MailActionRunner(connector: connector, sink: sink, policy: policy, now: fixedClock)
    }

    static var forbidden: [String] { [MailFixture.subject, MailFixture.sender, MailFixture.bodyText, MailFixture.token, MailFixture.allowed] }
}

/// A Project Control bridge stand-in. Counts POSTs (captures) and can answer 409 (duplicate).
final class FakeProjectBridge: @unchecked Sendable {
    private let lock = NSLock()
    var snapshot: ProjectModuleSnapshot
    var duplicate = false
    var failure: String?
    private var posted = 0
    init(register: String = "http://127.0.0.1:8787/register", connected: Bool = true) {
        snapshot = ProjectModuleSnapshot(connected: connected, online: connected, register: register, pulledAt: nil, projects: [])
    }
    var posts: Int { lock.withLock { posted } }
    var bridge: ClosureProjectBridge {
        ClosureProjectBridge(snapshot: { _ in self.snapshot }, send: { item, _ in
            self.lock.withLock { self.posted += 1 }
            if let failure = self.failure { throw BridgeFailure(errorDescription: failure) }
            return ProjectModuleReceipt(id: "item-\(item.sourceID)", duplicate: self.duplicate, register: self.snapshot.register)
        })
    }
}

struct BridgeFailure: LocalizedError { var errorDescription: String? }

/// Local receipt store stand-in (AppStore.recordCapture in the app).
final class ReceiptLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProjectModuleReceipt] = []
    var receipts: [ProjectModuleReceipt] { lock.withLock { stored } }
    func record(_ receipt: ProjectModuleReceipt) { lock.withLock { stored.append(receipt) } }
}

enum ProjectFixture {
    static let loopback = "http://127.0.0.1:8787/register"
    static let remote = "https://register.example.test/api"
    static func item(_ source: String = "controlward-record", id: String = "rec7f3a") -> ProjectCapture {
        ProjectCapture(source: source, sourceID: id, summary: "Synthetic summary 7f3a", metadata: ["record_type": "contacts"])
    }
}
