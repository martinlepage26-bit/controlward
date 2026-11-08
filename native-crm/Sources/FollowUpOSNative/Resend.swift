import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ResendPolicy {
    static let sender = "ml@pharos-ai.ca"
    static let account = "martinlepage26@me.com"
    // Leave a margin inside Resend's documented 24-hour deduplication window.
    static let retryWindow: TimeInterval = 23 * 60 * 60

    static func bundledConfig(in main: Bundle = .main) -> ICPConfig? {
        let bundle: Bundle?
        // SwiftPM's generated accessor falls back to an absolute build directory.
        // A sandboxed packaged app must resolve only its signed resource bundle.
        if main.bundleURL.pathExtension == "app" {
            guard let url = main.url(forResource: "FollowUpOSNative_FollowUpOSNative", withExtension: "bundle"),
                  let resources = Bundle(url: url) else { return nil }
            bundle = resources
        } else {
#if SWIFT_PACKAGE
            bundle = Bundle.module
#else
            bundle = nil
#endif
        }
        return ICPConfig.defaultDirectory(bundle: bundle).flatMap { try? ICPConfig.load(directory: $0).interactiveSearch() }
    }

    static func contentHash(recipient: String, subject: String, body: String) -> String {
        let fields = [sender, recipient, subject, body]
        return SHA256Hex.digest(Data(fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "\n").utf8))
    }

    static func issue(recipient: String, subject: String, body: String) -> String? {
        let pattern = #"^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]*[A-Z0-9])?\.[A-Z]{2,63}$"#
        guard recipient.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil,
              !recipient.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return "Use one valid recipient address."
        }
        guard !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              subject.utf8.count <= 998,
              !subject.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.utf8.count <= 200_000 else { return "Check the subject and message before sending." }
        return nil
    }
}

/// Immutable copy of exactly what the owner sees in the confirmation sheet.
struct ResendSendPreview: Equatable, Identifiable, Sendable {
    var id: UUID
    var lead: Lead
    var recipient: String
    var subject: String
    var body: String
    var contentHash: String
    var credentialRevision: UUID
}

enum ResendError: LocalizedError {
    case rejected(Int)
    case unknown
    var errorDescription: String? {
        switch self {
        case .rejected(let status): "Resend refused the request (HTTP \(status)). No sent history was added. Review the connection and message before retrying."
        case .unknown: "The send outcome is unknown. Check Resend before retrying. An exact retry is available only inside the original 23-hour safety window."
        }
    }
}

/// Resend never redirects a credential-bearing request and never automatically retries a send.
final class ResendHTTPTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ResendError.unknown }
        return HTTPResponse(status: http.statusCode, headers: [:], body: data)
    }
}

struct ResendClient: Sendable {
    let transport: any HTTPTransport
    func send(_ dispatch: ResendDispatch, apiKey: String) async throws -> String {
        if let issue = ResendPolicy.issue(recipient: dispatch.recipient, subject: dispatch.subject, body: dispatch.body) {
            throw GTMError.invalid(issue)
        }
        guard apiKey.hasPrefix("re_"), !apiKey.contains(where: \.isWhitespace) else { throw IntegrationError.missingKey }
        var request = URLRequest(url: URL(string: "https://api.resend.com/emails")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("controlward/\(dispatch.id.uuidString.lowercased())", forHTTPHeaderField: "Idempotency-Key")
        struct Payload: Encodable {
            let from: String; let to: [String]; let subject: String; let text: String
            let reply_to: String; let headers: [String: String]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(Payload(from: ResendPolicy.sender, to: [dispatch.recipient],
            subject: dispatch.subject, text: dispatch.body, reply_to: ResendPolicy.sender,
            headers: ["List-Unsubscribe": "<mailto:\(ResendPolicy.sender)?subject=unsubscribe>"]))
        let response: HTTPResponse
        do { response = try await transport.send(request) } catch { throw ResendError.unknown }
        // 408/409/5xx or a malformed success can leave acceptance ambiguous.
        guard (200..<300).contains(response.status) else {
            if (400..<500).contains(response.status), response.status != 408, response.status != 409 {
                throw ResendError.rejected(response.status)
            }
            throw ResendError.unknown
        }
        struct Receipt: Decodable { let id: String }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: response.body),
              UUID(uuidString: receipt.id) != nil else { throw ResendError.unknown }
        return receipt.id
    }
}
