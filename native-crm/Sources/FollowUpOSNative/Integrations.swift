import CryptoKit
import Foundation
import Security

// MARK: - API keys (Keychain)

/// Stores connector API keys outside workspace data. Keys are never persisted
/// in workspace.json, exchange exports, activity, or logs.
protocol SecretStore: Sendable {
    func read(_ target: SyncTarget) throws -> String?
    func write(_ secret: String, for target: SyncTarget) throws
    func delete(_ target: SyncTarget) throws
    func exists(_ target: SyncTarget) -> Bool
}

enum SecretStoreError: LocalizedError, Equatable {
    case keychain(OSStatus)
    case empty

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        case .empty:
            return "The key is empty. Nothing was saved."
        }
    }
}

/// Generic-password items in the login keychain: service `com.pharos.contextward.<target>`, account `api`.
/// Uses the Security framework directly, which works inside the App Sandbox without a keychain access group.
struct KeychainSecretStore: SecretStore {
    static let account = "api"
    let servicePrefix: String

    init(servicePrefix: String = "com.pharos.contextward") { self.servicePrefix = servicePrefix }

    func service(for target: SyncTarget) -> String { "\(servicePrefix).\(target.rawValue)" }

    private func query(_ target: SyncTarget) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service(for: target),
         kSecAttrAccount as String: Self.account]
    }

    func read(_ target: SyncTarget) throws -> String? {
        var request = query(target)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecretStoreError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    func write(_ secret: String, for target: SyncTarget) throws {
        guard !secret.isEmpty else { throw SecretStoreError.empty }
        let data = Data(secret.utf8)
        let update = SecItemUpdate(query(target) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError.keychain(update) }
        var item = query(target)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Contextward \(target.label) API key"
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw SecretStoreError.keychain(add) }
    }

    func delete(_ target: SyncTarget) throws {
        let status = SecItemDelete(query(target) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }

    /// Reads attributes only, so it never needs the item's data or triggers an access prompt.
    func exists(_ target: SyncTarget) -> Bool {
        var request = query(target)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        return SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess
    }
}

/// Test and preview store. Never used by the shipping app.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SyncTarget: String] = [:]
    init(_ initial: [SyncTarget: String] = [:]) { values = initial }
    func read(_ target: SyncTarget) throws -> String? { lock.withLock { values[target] } }
    func write(_ secret: String, for target: SyncTarget) throws {
        guard !secret.isEmpty else { throw SecretStoreError.empty }
        lock.withLock { values[target] = secret }
    }
    func delete(_ target: SyncTarget) throws { _ = lock.withLock { values.removeValue(forKey: target) } }
    func exists(_ target: SyncTarget) -> Bool { lock.withLock { values[target] != nil } }
}

// MARK: - HTTP

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data
}

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// Ephemeral session: no cookies, no URL cache, so no response bodies (PII) land on disk.
struct URLSessionTransport: HTTPTransport {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw IntegrationError.unexpected("response was not HTTP") }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

/// Errors carry status codes and server error codes only, never response bodies or record values.
enum IntegrationError: LocalizedError, Equatable {
    case missingEndpoint
    case missingKey
    case invalidEndpoint
    case http(status: Int, code: String?, context: String)
    case transport(String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .missingEndpoint: "No endpoint URL is saved."
        case .missingKey: "No API key is saved in the Keychain."
        case .invalidEndpoint: "The endpoint is not a valid http(s) URL."
        case .http(let status, let code, let context):
            "\(context) returned HTTP \(status)\(code.map { " (\($0))" } ?? "")\(status == 401 || status == 403 ? ": the API key was rejected" : "")."
        case .transport(let message): "Network error: \(message)"
        case .unexpected(let message): "Unexpected response: \(message)"
        }
    }

    static func from(_ response: HTTPResponse, context: String) -> IntegrationError {
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        let code = (object?["error"] as? String).map { String($0.prefix(60)) }
        return .http(status: response.status, code: code, context: context)
    }
}

/// Spaces requests out so bulk pushes stay under server rate limits.
actor RequestPacer {
    private let interval: Duration
    private var next = ContinuousClock.now

    init(interval: Duration) { self.interval = interval }

    func wait() async {
        let now = ContinuousClock.now
        let start = max(now, next)
        next = start + interval
        if start > now { try? await Task.sleep(until: start, clock: .continuous) }
    }
}

enum EndpointBase {
    /// Normalizes a saved endpoint to its base URL by removing known route suffixes.
    static func url(from endpoint: String, strippingSuffixes suffixes: [String]) throws -> URL {
        guard !endpoint.trimmingCharacters(in: .whitespaces).isEmpty else { throw IntegrationError.missingEndpoint }
        guard let clean = EndpointPolicy.sanitize(endpoint), !clean.removedSecrets,
              var components = URLComponents(string: clean.url) else { throw IntegrationError.invalidEndpoint }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in suffixes where path.hasSuffix(suffix) { path.removeLast(suffix.count); break }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw IntegrationError.invalidEndpoint }
        return url
    }
}

// MARK: - PHAROS backend

struct PharosReceipt: Decodable, Equatable, Sendable {
    var accepted: Bool
    var persisted: Bool
    var duplicate: Bool?
    var receipt: String?
}

/// Client for the pharos-contextward-api Worker: GET /v1/health, GET /v1/auth/check,
/// POST /v1/exchange/push (Bearer key + Idempotency-Key, contextward.exchange.v1 body).
struct PharosClient: Sendable {
    let baseURL: URL
    let apiKey: String
    let transport: HTTPTransport

    init(endpoint: String, apiKey: String, transport: HTTPTransport) throws {
        baseURL = try EndpointBase.url(from: endpoint, strippingSuffixes: ["/v1/exchange/push", "/v1/health", "/v1/auth/check", "/v1/leads", "/v1"])
        guard !apiKey.isEmpty else { throw IntegrationError.missingKey }
        self.apiKey = apiKey
        self.transport = transport
    }

    private func request(_ path: String, method: String = "GET", authenticated: Bool) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func send(_ request: URLRequest) async throws -> HTTPResponse {
        do { return try await transport.send(request) }
        catch let error as IntegrationError { throw error }
        catch { throw IntegrationError.transport(error.localizedDescription) }
    }

    /// Health check plus an authenticated key check. Succeeds only when both pass.
    func verify() async throws {
        let health = try await send(request("v1/health", authenticated: false))
        guard health.status == 200 else { throw IntegrationError.from(health, context: "PHAROS health check") }
        let body = (try? JSONSerialization.jsonObject(with: health.body)) as? [String: Any]
        guard body?["ok"] as? Bool == true else { throw IntegrationError.unexpected("health check did not report ok") }
        let auth = try await send(request("v1/auth/check", authenticated: true))
        guard auth.status == 200 else { throw IntegrationError.from(auth, context: "PHAROS key check") }
    }

    func push(_ body: Data, idempotencyKey: String) async throws -> PharosReceipt {
        var push = request("v1/exchange/push", method: "POST", authenticated: true)
        push.setValue("application/json", forHTTPHeaderField: "Content-Type")
        push.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        push.httpBody = body
        let response = try await send(push)
        guard response.status == 200 || response.status == 202 else { throw IntegrationError.from(response, context: "PHAROS push") }
        guard let receipt = try? JSONDecoder().decode(PharosReceipt.self, from: response.body) else {
            throw IntegrationError.unexpected("PHAROS push receipt could not be read")
        }
        guard receipt.accepted, receipt.persisted else { throw IntegrationError.unexpected("PHAROS accepted the push but did not persist it") }
        return receipt
    }

    static let inboxPageSize = 100

    /// GET /v1/leads?since=<cursor>: qualified leads pushed by LeadGen OS and not yet acked.
    func pullLeads(since: Int, limit: Int = PharosClient.inboxPageSize) async throws -> LeadInboxPage {
        var pull = request("v1/leads", authenticated: true)
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/leads"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "since", value: String(since)), URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else { throw IntegrationError.invalidEndpoint }
        pull.url = url
        let response = try await send(pull)
        guard response.status == 200 else { throw IntegrationError.from(response, context: "PHAROS lead pull") }
        guard let page = try? JSONDecoder().decode(LeadInboxPage.self, from: response.body),
              page.schemaVersion == LeadInboxPage.schema else {
            throw IntegrationError.unexpected("PHAROS lead inbox page could not be read")
        }
        for item in page.leads where !LeadGenEvent.supportedVersions.contains(item.event.schemaVersion ?? "leadgen.event.v1") {
            throw IntegrationError.unexpected("PHAROS lead inbox sent an unsupported lead schema")
        }
        return page
    }

    /// POST /v1/leads/ack: marks the exact pulled versions as received.
    func ackLeads(_ items: [LeadInboxItem]) async throws -> LeadAckResult {
        var ack = request("v1/leads/ack", method: "POST", authenticated: true)
        ack.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ack.httpBody = try JSONSerialization.data(withJSONObject: ["acks": items.map { ["source_id": $0.sourceID, "seq": $0.seq] }])
        let response = try await send(ack)
        guard response.status == 200 else { throw IntegrationError.from(response, context: "PHAROS lead ack") }
        guard let result = try? JSONDecoder().decode(LeadAckResult.self, from: response.body) else {
            throw IntegrationError.unexpected("PHAROS lead ack could not be read")
        }
        return result
    }
}

// MARK: - PHAROS lead inbox

struct LeadInboxItem: Decodable, Sendable {
    var sourceID: String
    var seq: Int
    var event: LeadGenEvent
    enum CodingKeys: String, CodingKey { case sourceID = "source_id", seq, event }
}

struct LeadInboxPage: Decodable, Sendable {
    static let schema = "contextward.lead-inbox.v1"
    var schemaVersion: String
    var leads: [LeadInboxItem]
    var cursor: Int
    var hasMore: Bool
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", leads, cursor, hasMore = "has_more" }
}

struct LeadAckResult: Decodable, Sendable {
    var acked: Int
    var stale: Int
}

/// Counts only. This is all a lead pull ever writes to activity, jobs, or logs.
struct LeadPullCounts: Equatable, Sendable {
    enum Outcome { case created, updated, unchanged, skipped }
    var created = 0, updated = 0, unchanged = 0, skipped = 0, acked = 0

    mutating func add(_ outcome: Outcome) {
        switch outcome {
        case .created: created += 1
        case .updated: updated += 1
        case .unchanged: unchanged += 1
        case .skipped: skipped += 1
        }
    }

    var total: Int { created + updated + unchanged + skipped }
    var summary: String {
        "\(created) new, \(updated) updated, \(unchanged) unchanged\(skipped > 0 ? ", \(skipped) skipped" : ""); \(acked) acked."
    }
}

enum LeadMatching {
    /// Digits only; for numbers with 10+ digits, the last 10 (so +1 and national formats match).
    static func phoneKey(_ phone: String) -> String? {
        let digits = phone.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        return digits.count >= 10 ? String(digits.suffix(10)) : digits
    }
}

enum ExchangeFingerprint {
    private struct Content: Encodable {
        var schemaVersion: String
        var business: BusinessProfile
        var leads: [Lead]
        var contacts: [Contact]
        var companies: [Company]
        var opportunities: [Opportunity]
        var tasks: [CRMTask]
        var notes: [CRMNote]
        var signals: [Signal]
        var audits: [BilingualAudit]
        var exposureFindings: [ExposureFinding]
    }

    /// Derived from record content only (not export time, activity, or sync history),
    /// so re-sending unchanged data reuses the key and the backend deduplicates it.
    static func idempotencyKey(for exchange: WorkspaceExchange) -> String {
        let content = Content(schemaVersion: exchange.schemaVersion, business: exchange.business, leads: exchange.leads,
                              contacts: exchange.contacts, companies: exchange.companies, opportunities: exchange.opportunities,
                              tasks: exchange.tasks, notes: exchange.notes, signals: exchange.signals, audits: exchange.audits,
                              exposureFindings: exchange.exposureFindings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(content)) ?? Data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "ctx_\(digest.prefix(40))"
    }
}

// MARK: - Connector status

/// Last verified result for a connector. Contains no secrets.
struct ConnectorHealth: Codable, Equatable, Sendable {
    var ok: Bool
    var detail: String
    var checkedAt = Date.now.ISO8601Format()
}

enum ConnectorStatus: Equatable {
    case needsSetup(String)
    case notVerified
    case active(String)
    case error(String)

    var label: String {
        switch self {
        case .needsSetup: "Needs setup"
        case .notVerified: "Not verified"
        case .active: "Active"
        case .error: "Error"
        }
    }

    var detail: String {
        switch self {
        case .needsSetup(let reason), .active(let reason), .error(let reason): reason
        case .notVerified: "Configured. Run Verify to confirm the endpoint accepts the key."
        }
    }

    static func resolve(endpoint: String, hasKey: Bool, health: ConnectorHealth?) -> ConnectorStatus {
        let missingURL = endpoint.trimmingCharacters(in: .whitespaces).isEmpty
        switch (missingURL, hasKey) {
        case (true, false): return .needsSetup("Save the endpoint URL and the API key.")
        case (true, true): return .needsSetup("Save the endpoint URL.")
        case (false, false): return .needsSetup("Save the API key in Settings.")
        default: break
        }
        guard let health else { return .notVerified }
        return health.ok ? .active(health.detail) : .error(health.detail)
    }
}

// MARK: - JSON values

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? { if case .string(let value) = self { return value }; return nil }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}

// MARK: - Twenty

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
}

/// REST client for Twenty (`/rest/<objectPlural>`). Create returns
/// `{"data":{"create<Singular>":{...}}}`, update returns `{"data":{"update<Singular>":{...}}}`.
/// It never issues DELETE.
struct TwentyClient: Sendable {
    let baseURL: URL
    let apiKey: String
    let transport: HTTPTransport
    let pacer: RequestPacer
    let maxRetries: Int
    let maxBackoffSeconds: Double

    /// Default pacing (~85 requests per minute) stays under Twenty's default API rate limit.
    init(endpoint: String, apiKey: String, transport: HTTPTransport, interval: Duration = .milliseconds(700), maxRetries: Int = 3, maxBackoffSeconds: Double = 30) throws {
        baseURL = try EndpointBase.url(from: endpoint, strippingSuffixes: ["/rest"])
        guard !apiKey.isEmpty else { throw IntegrationError.missingKey }
        self.apiKey = apiKey
        self.transport = transport
        self.pacer = RequestPacer(interval: interval)
        self.maxRetries = maxRetries
        self.maxBackoffSeconds = maxBackoffSeconds
    }

    private func url(_ object: TwentyObject, id: String? = nil, query: String? = nil) -> URL {
        var url = baseURL.appendingPathComponent("rest").appendingPathComponent(object.rawValue)
        if let id { url.appendPathComponent(id) }
        if let query, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = query
            url = components.url ?? url
        }
        return url
    }

    private func send(_ method: String, _ url: URL, body: JSONValue? = nil) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.encoded()
        }
        var attempt = 0
        while true {
            await pacer.wait()
            let response: HTTPResponse
            do { response = try await transport.send(request) }
            catch let error as IntegrationError { throw error }
            catch { throw IntegrationError.transport(error.localizedDescription) }
            let retryable = response.status == 429 || response.status == 503
            guard retryable, attempt < maxRetries else { return response }
            attempt += 1
            let hinted = response.headers["retry-after"].flatMap(Double.init) ?? pow(2, Double(attempt))
            let wait = min(hinted, maxBackoffSeconds)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
    }

    /// Authenticated read of one company. Proves the URL and key work without writing.
    func verify() async throws {
        let response = try await send("GET", url(.companies, query: "limit=1"))
        guard response.status == 200 else { throw IntegrationError.from(response, context: "Twenty key check") }
    }

    func create(_ object: TwentyObject, _ payload: JSONValue) async throws -> String {
        let context = "Twenty \(object.rawValue) create"
        let response = try await send("POST", url(object), body: payload)
        guard response.status == 200 || response.status == 201 else { throw IntegrationError.from(response, context: context) }
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: response.body)
        guard let id = decoded?["data"]?["create\(object.singular)"]?["id"]?.stringValue else {
            throw IntegrationError.unexpected("\(context) response had no record id")
        }
        return id
    }

    /// Returns false when the record no longer exists in Twenty (HTTP 404).
    func update(_ object: TwentyObject, id: String, _ payload: JSONValue) async throws -> Bool {
        let context = "Twenty \(object.rawValue) update"
        let response = try await send("PATCH", url(object, id: id), body: payload)
        if response.status == 404 { return false }
        guard response.status == 200 else { throw IntegrationError.from(response, context: context) }
        return true
    }
}

struct TwentyOperation: Equatable, Sendable {
    enum Kind: String, Sendable { case create, update }
    var object: TwentyObject
    var localKey: String
    var kind: Kind
    var twentyID: String?
    var payload: JSONValue
    var payloadHash: String
}

struct TwentyPlan: Equatable, Sendable {
    var operations: [TwentyOperation] = []
    var unchanged: [TwentyObject: Int] = [:]

    func count(_ kind: TwentyOperation.Kind, _ object: TwentyObject) -> Int {
        operations.filter { $0.kind == kind && $0.object == object }.count
    }
    var creates: Int { operations.filter { $0.kind == .create }.count }
    var updates: Int { operations.filter { $0.kind == .update }.count }
    var unchangedTotal: Int { unchanged.values.reduce(0, +) }

    var summary: String {
        TwentyObject.allCases.map { object in
            "\(object.label): \(count(.create, object)) new, \(count(.update, object)) update, \(unchanged[object, default: 0]) unchanged"
        }.joined(separator: " · ")
    }
}

/// Maps Contextward records to Twenty standard objects (Twenty v2 field names).
enum TwentyMapper {
    static let currencyCode = "CAD"

    static func key(_ prefix: String, _ id: UUID) -> String { "\(prefix):\(id.uuidString)" }

    /// Plans creates and updates. In a dry run, records scheduled for creation get
    /// placeholder ids so dependent records are counted accurately. Pass `only`
    /// to plan a single object type against the current links during a push.
    static func plan(_ workspace: PersistentWorkspace, links: [String: TwentyLink], only: TwentyObject? = nil) -> TwentyPlan {
        var plan = TwentyPlan()
        var resolved = links.mapValues(\.twentyID)
        func resolve(_ key: String) -> JSONValue? { resolved[key].map(JSONValue.string) }

        func add(_ object: TwentyObject, _ key: String, _ fields: [String: JSONValue?]) {
            let payload = JSONValue.object(fields.compactMapValues { $0 })
            let hash = SHA256.hash(data: payload.encoded()).map { String(format: "%02x", $0) }.joined()
            if let link = links[key] {
                if link.payloadHash == hash { plan.unchanged[object, default: 0] += 1; return }
                plan.operations.append(TwentyOperation(object: object, localKey: key, kind: .update, twentyID: link.twentyID, payload: payload, payloadHash: hash))
            } else {
                plan.operations.append(TwentyOperation(object: object, localKey: key, kind: .create, twentyID: nil, payload: payload, payloadHash: hash))
                resolved[key] = "pending:\(key)"
            }
        }
        func include(_ object: TwentyObject) -> Bool { only == nil || only == object }

        if include(.companies) {
            for company in workspace.companies {
                add(.companies, key("company", company.id), [
                    "name": .string(company.name),
                    "domainName": company.domain.isEmpty ? nil : .object(["primaryLinkUrl": .string(linkURL(company.domain))]),
                ])
            }
        }
        if include(.people) {
            for contact in workspace.contacts {
                add(.people, key("contact", contact.id), [
                    "name": .object(["firstName": .string(contact.firstName), "lastName": .string(contact.lastName)]),
                    "emails": contact.email.isEmpty ? nil : .object(["primaryEmail": .string(contact.email)]),
                    "phones": contact.phone.isEmpty ? nil : .object(["primaryPhoneNumber": .string(contact.phone)]),
                    "jobTitle": contact.title.isEmpty ? nil : .string(contact.title),
                    "companyId": contact.companyID.flatMap { resolve(key("company", $0)) },
                ])
            }
        }
        if include(.opportunities) {
            for lead in workspace.leads {
                let company = workspace.companies.first { !lead.company.isEmpty && $0.name.caseInsensitiveCompare(lead.company) == .orderedSame }
                let contact = workspace.contacts.first { $0.leadID == lead.id }
                add(.opportunities, key("lead", lead.id), [
                    "name": .string([lead.name, lead.service].filter { !$0.isEmpty }.joined(separator: ": ")),
                    "amount": lead.quoteAmount.map(amount),
                    "stage": stage(for: lead.status).map(JSONValue.string),
                    "companyId": company.flatMap { resolve(key("company", $0.id)) },
                    "pointOfContactId": contact.flatMap { resolve(key("contact", $0.id)) },
                ])
            }
            for opportunity in workspace.opportunities {
                add(.opportunities, key("opportunity", opportunity.id), [
                    "name": .string(opportunity.name),
                    "amount": opportunity.amount.map(amount),
                    "stage": stage(for: opportunity.stage).map(JSONValue.string),
                    "closeDate": isoDate(opportunity.closeDate),
                    "companyId": opportunity.companyID.flatMap { resolve(key("company", $0)) },
                    "pointOfContactId": opportunity.contactID.flatMap { resolve(key("contact", $0)) },
                ])
            }
        }
        if include(.tasks) {
            for task in workspace.tasks {
                add(.tasks, key("task", task.id), [
                    "title": .string(task.title),
                    "bodyV2": task.details.isEmpty ? nil : .object(["markdown": .string(task.details)]),
                    "status": .string(status(for: task.status)),
                    "dueAt": isoDate(task.dueDate),
                ])
            }
        }
        return plan
    }

    static func amount(_ value: Double) -> JSONValue {
        .object(["amountMicros": .int(Int((value * 1_000_000).rounded())), "currencyCode": .string(currencyCode)])
    }

    /// Twenty's default opportunity stages are NEW, SCREENING, MEETING, PROPOSAL, CUSTOMER.
    /// It has no default "lost" stage, so lost records keep whatever stage Twenty has.
    static func stage(for status: LeadStatus) -> String? {
        switch status {
        case .new: "NEW"
        case .contacted: "SCREENING"
        case .quoteSent: "PROPOSAL"
        case .won: "CUSTOMER"
        case .lost: nil
        }
    }

    static func stage(for stage: OpportunityStage) -> String? {
        switch stage {
        case .lead: "NEW"
        case .qualified: "SCREENING"
        case .proposal: "PROPOSAL"
        case .negotiation: "MEETING"
        case .won: "CUSTOMER"
        case .lost: nil
        }
    }

    static func status(for status: TaskStatus) -> String {
        switch status {
        case .todo: "TODO"
        case .inProgress: "IN_PROGRESS"
        case .done: "DONE"
        }
    }

    static func isoDate(_ day: String?) -> JSONValue? {
        guard let day, CalendarCRM.date(from: day) != nil else { return nil }
        return .string("\(day)T12:00:00.000Z")
    }

    static func linkURL(_ domain: String) -> String {
        domain.lowercased().hasPrefix("http://") || domain.lowercased().hasPrefix("https://") ? domain : "https://\(domain)"
    }
}
