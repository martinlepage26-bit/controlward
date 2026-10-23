import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Slice 1 hardening (wind-acceptance-tests.md §1d): every mail action goes through MailActionRunner,
// which refuses before any request and writes exactly one CW-AUDIT v1 line per action.
// Portable: no SwiftUI, AppKit or WebKit, so bin/test-portable compiles it on Linux.

/// Test-mode recipient allowlist (S1-R2, safety §5.2). Off unless CONTROLWARD_MAIL_TEST_ALLOWLIST is set.
/// When it is set (even to an empty list), every To and Cc address of a send must be on it.
struct MailSendPolicy: Equatable, Sendable {
    /// nil means test mode is off.
    var allowlist: Set<String>?

    static let off = MailSendPolicy(allowlist: nil)
    static let environmentKey = "CONTROLWARD_MAIL_TEST_ALLOWLIST"

    static func testMode(_ addresses: [String]) -> MailSendPolicy {
        MailSendPolicy(allowlist: Set(addresses.map { $0.lowercased() }))
    }

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> MailSendPolicy {
        guard let raw = environment[environmentKey] else { return .off }
        return testMode(raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map(String.init).filter { !$0.isEmpty })
    }

    /// Returns the refusal code, or nil when the command may proceed.
    func refusal(for command: MailCommand) -> String? {
        guard let allowlist, command.action.sends else { return nil }
        let fields = (command.compose?.to ?? []) + (command.compose?.cc ?? [])
        for field in fields {
            let addresses = MailComposePrefill.addresses(in: field)
            if addresses.isEmpty || addresses.contains(where: { !allowlist.contains($0.lowercased()) }) {
                return "refused:recipient-not-allowlisted"
            }
        }
        return nil
    }
}

/// Thrown by NoDeleteMailHTTP. Permanent delete is never sent (safety §5.4, D4).
struct MailPermanentDeleteRefused: Error, LocalizedError, Equatable {
    var errorDescription: String? { "Permanent delete is not available. Nothing was changed." }
}

/// Wraps any mail transport and refuses a DELETE before it reaches the network, whatever connector built it.
struct NoDeleteMailHTTP<Inner: MailHTTPSending>: MailHTTPSending {
    var inner: Inner
    func send(_ request: URLRequest) async throws -> MailHTTPResponse {
        if (request.httpMethod ?? "GET").uppercased() == "DELETE" { throw MailPermanentDeleteRefused() }
        return try await inner.send(request)
    }
}

/// The CW-AUDIT `result=` code for a mail error.
enum MailAuditResults {
    static func code(for error: Error) -> String {
        if error is MailPermanentDeleteRefused { return "refused:permanent-delete" }
        switch error as? MailboxError {
        case .confirmationRequired?: return "refused:unconfirmed"
        case .unsupported?: return "refused:unsupported"
        case .invalidCompose?: return "refused:invalid-compose"
        case .needsReconnect?: return "refused:needs-reconnect"
        case .http(let status)?: return "error:\(status)"
        case .bodyUnavailable?: return "refused:body-unavailable"
        case .unreadable?: return "error:unreadable"
        case nil: return "error:transport"
        }
    }
}

struct MailRunResult: Equatable, Sendable {
    /// Text for the message pane.
    var status: String
    /// nil only when every step succeeded.
    var failure: String?
    var receipt: MailCommandReceipt?
    var audit: CWAuditLine
}

/// Runs reads and commands against a connector. Order: policy and gate first (0 requests on refusal),
/// then the connector, then the local step. Each call writes exactly one audit line.
struct MailActionRunner: Sendable {
    var connector: any MailboxConnecting
    var sink: any CWAuditSink
    var policy: MailSendPolicy = .off
    var now: @Sendable () -> Date = { Date() }

    /// Gmail has one register, the API root. Other providers have none.
    var register: String { connector.providerID == "gmail" || connector.providerID == "google-workspace" ? "https://gmail.googleapis.com/gmail/v1/users/me/" : "-" }

    private func line(_ action: String, target: String, result: String, receipt: String = "-") -> CWAuditLine {
        CWAuditLine(ts: now(), surface: "gmail", action: action, register: register, target: target, source: connector.providerID, result: result, receipt: receipt)
    }

    func read(sourceID: String) async -> (body: MailMessageBody?, failure: String?, audit: CWAuditLine) {
        do {
            let body = try await connector.fetchBody(sourceID: sourceID)
            let audit = line("read", target: sourceID, result: "ok")
            sink.write(audit)
            return (body, nil, audit)
        } catch {
            let audit = line("read", target: sourceID, result: MailAuditResults.code(for: error))
            sink.write(audit)
            return (nil, error.localizedDescription, audit)
        }
    }

    /// Phase one: policy, gate and the connector. A refusal or error is final and already audited.
    enum RemoteStep: Sendable {
        case finished(MailRunResult)
        case accepted(MailCommandReceipt)
    }

    func performRemote(_ command: MailCommand) async -> RemoteStep {
        let action = command.action.rawValue
        if let refusal = policy.refusal(for: command) {
            let text = "Test mode: a recipient is not on the allowlist. Nothing was sent."
            let audit = line(action, target: command.sourceID, result: refusal)
            sink.write(audit)
            return .finished(MailRunResult(status: text, failure: text, receipt: nil, audit: audit))
        }
        do {
            try MailCommandGate.validate(command, support: connector.supports())
            return .accepted(try await connector.perform(command))
        } catch {
            let text = error.localizedDescription
            let audit = line(action, target: command.sourceID, result: MailAuditResults.code(for: error))
            sink.write(audit)
            return .finished(MailRunResult(status: text, failure: text, receipt: nil, audit: audit))
        }
    }

    /// Phase two, after the mailbox accepted the command: the local step (Trash only) and the audit line.
    /// The app runs the local step on the main actor and passes its error here.
    func finish(_ command: MailCommand, receipt: MailCommandReceipt, localError: Error?) -> MailRunResult {
        let outcome = MailActionOutcomes.afterRemoteSuccess(command.action) { if let localError { throw localError } }
        let audit = line(command.action.rawValue, target: command.sourceID, result: outcome.auditResult,
                         receipt: receipt.messageID ?? receipt.draftID ?? receipt.location ?? "-")
        sink.write(audit)
        return MailRunResult(status: outcome.status, failure: outcome.failure, receipt: receipt, audit: audit)
    }

    /// Both phases in one call (tests and non-UI callers). `removeLocalRow` runs only for Trash.
    func perform(_ command: MailCommand, removeLocalRow: () throws -> Void) async -> MailRunResult {
        switch await performRemote(command) {
        case .finished(let result):
            return result
        case .accepted(let receipt):
            var localError: Error?
            if command.action == .trash { do { try removeLocalRow() } catch { localError = error } }
            return finish(command, receipt: receipt, localError: localError)
        }
    }
}

/// Checks audit lines against the actions that ran (S1-R5): exactly one parseable line per action,
/// and no line carries a subject, sender, body or token. Returns the problems found.
enum MailAuditCheck {
    static func problems(actions: [(action: String, target: String)], lines: [CWAuditLine], forbidden: [String]) -> [String] {
        var problems: [String] = []
        for (action, target) in actions {
            let matching = lines.filter { $0.action == action && $0.target == target }
            if matching.count != 1 { problems.append("\(action) \(target): \(matching.count) audit lines, expected 1") }
        }
        if lines.count != actions.count { problems.append("\(lines.count) audit lines for \(actions.count) actions") }
        for line in lines {
            let text = line.text
            if CWAuditLine.parse(text) == nil { problems.append("unparseable line: \(line.action)") }
            for secret in forbidden where !secret.isEmpty && text.contains(secret) {
                problems.append("\(line.action) line contains forbidden content")
            }
        }
        return problems
    }
}
