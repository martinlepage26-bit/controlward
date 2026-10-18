import CryptoKit
import Foundation
import Security

// MARK: - Accounts

/// Live mail intake reads metadata only (gmail.readonly, format=metadata). Bodies are never requested.
/// Two Google sign-ins; me.com and pharos-ai.ca forward into the personal Gmail and are labelled
/// by recipient (Delivered-To, then To/Cc), not signed in separately.
struct MailAccount: Identifiable, Hashable, Sendable {
    var id: String { email }
    let email: String
    let provider: String
    /// nil for a Google sign-in; otherwise the signed-in account this alias forwards into.
    let forwardsInto: String?

    var isSignIn: Bool { forwardsInto == nil }

    static let personalGmail = MailAccount(email: "martinlepage.ai@gmail.com", provider: "gmail", forwardsInto: nil)
    static let infrafabric = MailAccount(email: "ml@infrafabric.io", provider: "google-workspace", forwardsInto: nil)
    static let icloudAlias = MailAccount(email: "martinlepage26@me.com", provider: "icloud-forward", forwardsInto: personalGmail.email)
    static let pharosAlias = MailAccount(email: "ml@pharos-ai.ca", provider: "cloudflare-forward", forwardsInto: personalGmail.email)

    static let all: [MailAccount] = [personalGmail, infrafabric, icloudAlias, pharosAlias]
    static var signIns: [MailAccount] { all.filter(\.isSignIn) }
    static func aliases(of email: String) -> [MailAccount] { all.filter { $0.forwardsInto == email } }
}

enum MailRecipientLabeler {
    /// Returns the account a message belongs to. Delivered-To wins, then To/Cc, then the signed-in owner.
    static func accountID(owner: String, deliveredTo: [String], to: String, cc: String) -> (account: String, provider: String) {
        let aliases = MailAccount.aliases(of: owner)
        let delivered = deliveredTo.flatMap(addresses(in:))
        let visible = addresses(in: to) + addresses(in: cc)
        for list in [delivered, visible] {
            if let alias = aliases.first(where: { list.contains($0.email) }) { return (alias.email, alias.provider) }
        }
        let provider = MailAccount.all.first { $0.email == owner }?.provider ?? "gmail"
        return (owner, provider)
    }

    /// Lowercased addresses from a header value such as `"Name" <a@b.c>, d@e.f`.
    static func addresses(in header: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}")
        let range = NSRange(header.startIndex..., in: header)
        return pattern.matches(in: header, range: range).compactMap { Range($0.range, in: header).map { header[$0].lowercased() } }
    }
}

// MARK: - OAuth (PKCE, installed-app flow)

enum PKCE {
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }
    static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct GoogleOAuthConfig: Sendable, Equatable {
    static let scope = "https://www.googleapis.com/auth/gmail.readonly"
    static let defaultsKey = "ControlWardGoogleOAuthClientID"
    /// ControlWard's iOS-type installed-app client (bundle com.pharos.contextward). Public, not a secret.
    static let defaultClientID = "522514188059-qe7qirvdks6ott29v2e8r9ni4tno30k1.apps.googleusercontent.com"
    let clientID: String

    /// Accepts only a Google installed-app client ID (`<n>-<hash>.apps.googleusercontent.com`). Not a secret.
    init(clientID raw: String) throws {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(".apps.googleusercontent.com"), id.count <= 200,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else {
            throw MailIntakeError.invalidClientID
        }
        clientID = id
    }

    /// Reverse-DNS scheme Google issues for iOS/macOS clients.
    var callbackScheme: String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }
    var redirectURI: String { callbackScheme + ":/oauth2redirect" }

    func authorizationURL(loginHint: String, state: String, challenge: String) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state), .init(name: "login_hint", value: loginHint),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
        ]
        return c.url!
    }

    /// Extracts the code from the callback after checking state. Provider error text is not surfaced.
    func code(fromCallback url: URL, expectedState: String) throws -> String {
        guard url.scheme == callbackScheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { throw MailIntakeError.signInFailed }
        guard items.first(where: { $0.name == "state" })?.value == expectedState else { throw MailIntakeError.stateMismatch }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw MailIntakeError.signInFailed }
        return code
    }

    func tokenRequest(form: [String: String]) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        r.httpMethod = "POST"; r.timeoutInterval = 20
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        r.httpBody = Data(form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        return r
    }
    func exchangeRequest(code: String, verifier: String) -> URLRequest {
        tokenRequest(form: ["client_id": clientID, "code": code, "code_verifier": verifier,
                            "grant_type": "authorization_code", "redirect_uri": redirectURI])
    }
    func refreshRequest(refreshToken: String) -> URLRequest {
        tokenRequest(form: ["client_id": clientID, "refresh_token": refreshToken, "grant_type": "refresh_token"])
    }
}

struct GoogleTokenResponse: Decodable, Sendable {
    var access_token: String
    var refresh_token: String?
    var expires_in: Int?
}

enum MailIntakeError: LocalizedError, Equatable {
    case invalidClientID, missingClientID, notConnected, signInFailed, stateMismatch, cancelled
    case reauthorize, http(Int), unreadable(String), accountMismatch(String)
    var errorDescription: String? {
        switch self {
        case .invalidClientID: "Enter a Google OAuth client ID ending in .apps.googleusercontent.com."
        case .missingClientID: "Add the Google OAuth client ID in Mail accounts first."
        case .notConnected: "Not connected. Choose Connect to sign in with Google."
        case .signInFailed: "Google sign-in did not complete. Try Connect again."
        case .stateMismatch: "Google sign-in response did not match this request. Nothing was saved."
        case .cancelled: "Sign-in was cancelled."
        case .reauthorize: "Google ended this sign-in. Choose Connect to sign in again."
        case .http(let status): "Gmail returned HTTP \(status)."
        case .unreadable(let what): "\(what) could not be read."
        case .accountMismatch(let actual): "You signed in as \(actual), not this account. Nothing was saved. Choose Connect and pick the matching Google account."
        }
    }
}

// MARK: - Keychain

/// Refresh tokens only. Service `com.pharos.contextward.mail.<email>`, account `oauth`.
protocol MailTokenStore: Sendable {
    func read(_ email: String) throws -> String?
    func write(_ token: String, for email: String) throws
    func delete(_ email: String) throws
    func exists(_ email: String) -> Bool
}

struct KeychainMailTokenStore: MailTokenStore {
    static let account = "oauth"
    let servicePrefix: String
    init(servicePrefix: String = "com.pharos.contextward.mail") { self.servicePrefix = servicePrefix }
    func service(for email: String) -> String { "\(servicePrefix).\(email.lowercased())" }
    private func query(_ email: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(for: email),
         kSecAttrAccount as String: Self.account]
    }
    func read(_ email: String) throws -> String? {
        var q = query(email); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecretStoreError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }
    func write(_ token: String, for email: String) throws {
        guard !token.isEmpty else { throw SecretStoreError.empty }
        let data = Data(token.utf8)
        let update = SecItemUpdate(query(email) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError.keychain(update) }
        var item = query(email); item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "ControlWard mail sign-in (\(email))"
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw SecretStoreError.keychain(add) }
    }
    func delete(_ email: String) throws {
        let status = SecItemDelete(query(email) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }
    func exists(_ email: String) -> Bool {
        var q = query(email); q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess
    }
}

final class InMemoryMailTokenStore: MailTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func read(_ email: String) throws -> String? { lock.withLock { values[email] } }
    func write(_ token: String, for email: String) throws {
        guard !token.isEmpty else { throw SecretStoreError.empty }
        lock.withLock { values[email] = token }
    }
    func delete(_ email: String) throws { _ = lock.withLock { values.removeValue(forKey: email) } }
    func exists(_ email: String) -> Bool { lock.withLock { values[email] != nil } }
}

// MARK: - Gmail metadata

struct GmailMessageMetadata: Decodable, Sendable {
    struct Header: Decodable, Sendable { var name: String; var value: String }
    struct Payload: Decodable, Sendable { var headers: [Header]? }
    var id: String
    var internalDate: String?
    var payload: Payload?

    func header(_ name: String) -> [String] {
        (payload?.headers ?? []).filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// Maps to the local review model. Subject and addresses are capped like file imports.
    func mailMetadata(owner: String) throws -> MailMetadata {
        guard !id.isEmpty, id.count <= 200, let ms = internalDate.flatMap(Double.init) else { throw MailIntakeError.unreadable("Gmail message") }
        let to = header("To").first ?? "", cc = header("Cc").first ?? ""
        let label = MailRecipientLabeler.accountID(owner: owner, deliveredTo: header("Delivered-To") + header("X-Forwarded-To"), to: to, cc: cc)
        func cap(_ s: String) -> String { String(s.prefix(1000)) }
        let received = Date(timeIntervalSince1970: ms / 1000).ISO8601Format()
        let link = "https://mail.google.com/mail/?authuser=\(owner)#all/\(id)"
        return MailMetadata(sourceID: "gmail:\(id)", subject: cap(header("Subject").first ?? "(no subject)"),
                            sender: cap(header("From").first ?? ""), recipient: cap(to.isEmpty ? label.account : to),
                            receivedAt: received, provider: label.provider, accountID: label.account,
                            synthetic: false, link: link)
    }
}

struct GmailMetadataClient: Sendable {
    static let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!
    let accessToken: String
    let transport: HTTPTransport

    private func get(_ url: URL) async throws -> Data {
        var r = URLRequest(url: url); r.httpMethod = "GET"; r.timeoutInterval = 20
        r.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport.send(r)
        if response.status == 401 { throw MailIntakeError.reauthorize }
        guard response.status == 200 else { throw MailIntakeError.http(response.status) }
        return response.body
    }

    func profileEmail() async throws -> String {
        struct Profile: Decodable { var emailAddress: String }
        guard let p = try? JSONDecoder().decode(Profile.self, from: try await get(Self.base.appendingPathComponent("profile"))),
              !p.emailAddress.isEmpty else { throw MailIntakeError.unreadable("Gmail profile") }
        return p.emailAddress.lowercased()
    }

    func listMessageIDs(query: String, max: Int) async throws -> [String] {
        struct List: Decodable { struct Ref: Decodable { var id: String }; var messages: [Ref]? }
        var c = URLComponents(url: Self.base.appendingPathComponent("messages"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "q", value: query), .init(name: "maxResults", value: String(max))]
        guard let list = try? JSONDecoder().decode(List.self, from: try await get(c.url!)) else { throw MailIntakeError.unreadable("Gmail message list") }
        return (list.messages ?? []).map(\.id)
    }

    func metadata(id: String) async throws -> GmailMessageMetadata {
        var c = URLComponents(url: Self.base.appendingPathComponent("messages").appendingPathComponent(id), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "format", value: "metadata")] +
            ["Subject", "From", "To", "Cc", "Delivered-To", "X-Forwarded-To"].map { .init(name: "metadataHeaders", value: $0) }
        guard let m = try? JSONDecoder().decode(GmailMessageMetadata.self, from: try await get(c.url!)) else { throw MailIntakeError.unreadable("Gmail message") }
        return m
    }
}

// MARK: - Intake engine

struct MailIntakeEngine: Sendable {
    static let query = "newer_than:14d -in:chats -in:spam -in:trash"
    static let maxPerPull = 100
    let config: GoogleOAuthConfig
    let tokens: MailTokenStore
    let transport: HTTPTransport

    func accessToken(for email: String) async throws -> String {
        guard let refresh = try tokens.read(email) else { throw MailIntakeError.notConnected }
        let response = try await transport.send(config.refreshRequest(refreshToken: refresh))
        if response.status == 400 || response.status == 401 { throw MailIntakeError.reauthorize }
        guard response.status == 200, let token = try? JSONDecoder().decode(GoogleTokenResponse.self, from: response.body) else {
            throw MailIntakeError.http(response.status)
        }
        return token.access_token
    }

    /// Exchanges an authorization code and stores the refresh token. Returns nothing secret.
    func completeSignIn(email: String, code: String, verifier: String) async throws {
        let response = try await transport.send(config.exchangeRequest(code: code, verifier: verifier))
        guard response.status == 200, let token = try? JSONDecoder().decode(GoogleTokenResponse.self, from: response.body),
              let refresh = token.refresh_token, !refresh.isEmpty else { throw MailIntakeError.signInFailed }
        // login_hint is only a hint: confirm the signed-in mailbox before storing anything.
        let actual = try await GmailMetadataClient(accessToken: token.access_token, transport: transport).profileEmail()
        guard actual.caseInsensitiveCompare(email) == .orderedSame else { throw MailIntakeError.accountMismatch(actual) }
        try tokens.write(refresh, for: email)
    }

    /// Pulls metadata for messages not already in `known` (source IDs).
    func pull(email: String, known: Set<String>) async throws -> [MailMetadata] {
        let client = GmailMetadataClient(accessToken: try await accessToken(for: email), transport: transport)
        let ids = try await client.listMessageIDs(query: Self.query, max: Self.maxPerPull)
        var out: [MailMetadata] = []
        for id in ids where !known.contains("gmail:\(id)") {
            out.append(try await client.metadata(id: id).mailMetadata(owner: email))
        }
        return out
    }
}

// MARK: - Store merge

@MainActor
extension AppStore {
    /// Shared by file import and live intake. Dedupe by source identity; local review state is kept.
    @discardableResult
    func mergeMail(_ incoming: [MailMetadata], activity: String) throws -> Int {
        var count = 0
        try commitWorkspace { next in
            for message in incoming {
                let existing = next.controlWard.mail.firstIndex {
                    $0.sourceID == message.sourceID && $0.synthetic == message.synthetic &&
                    ($0.accountID == message.accountID || message.sourceID.hasPrefix("gmail:"))
                }
                if let index = existing {
                    var updated = message
                    let previous = next.controlWard.mail[index]
                    updated.id = previous.id; updated.reviewed = previous.reviewed
                    updated.contactID = previous.contactID; updated.companyID = previous.companyID; updated.taskID = previous.taskID
                    next.controlWard.mail[index] = updated
                } else { next.controlWard.mail.append(message); count += 1 }
            }
            if !incoming.isEmpty || !activity.hasPrefix("Mail intake") {
                next.activity.insert(ActivityEvent(kind: "mail_import", message: "\(activity): \(count) new, \(incoming.count - count) refreshed."), at: 0)
            }
        }
        return count
    }
}

// MARK: - Controller

enum MailAccountState: Equatable, Sendable {
    case notConnected, idle, syncing, synced(at: Date, added: Int), failed(String)
    var label: String {
        switch self {
        case .notConnected: "Not connected"
        case .idle: "Connected"
        case .syncing: "Refreshing…"
        case .synced(let at, let added): "Updated \(at.formatted(date: .omitted, time: .shortened)) · \(added) new"
        case .failed(let message): message
        }
    }
}

@MainActor
final class MailIntakeController: ObservableObject {
    static let interval: TimeInterval = 10 * 60
    @Published private(set) var states: [String: MailAccountState] = [:]
    @Published var clientID: String
    let tokens: MailTokenStore
    let transport: HTTPTransport
    private let defaults: UserDefaults
    private var timer: Timer?

    init(tokens: MailTokenStore = KeychainMailTokenStore(), transport: HTTPTransport = URLSessionTransport(), defaults: UserDefaults = .standard) {
        self.tokens = tokens; self.transport = transport; self.defaults = defaults
        clientID = defaults.string(forKey: GoogleOAuthConfig.defaultsKey) ?? GoogleOAuthConfig.defaultClientID
        for account in MailAccount.signIns { states[account.email] = tokens.exists(account.email) ? .idle : .notConnected }
    }

    func state(_ account: MailAccount) -> MailAccountState { states[account.forwardsInto ?? account.email] ?? .notConnected }
    var anyConnected: Bool { MailAccount.signIns.contains { tokens.exists($0.email) } }

    func saveClientID(_ raw: String) throws {
        let config = try GoogleOAuthConfig(clientID: raw)
        defaults.set(config.clientID, forKey: GoogleOAuthConfig.defaultsKey); clientID = config.clientID
    }
    func config() throws -> GoogleOAuthConfig {
        guard !clientID.isEmpty else { throw MailIntakeError.missingClientID }
        return try GoogleOAuthConfig(clientID: clientID)
    }
    private func engine() throws -> MailIntakeEngine { MailIntakeEngine(config: try config(), tokens: tokens, transport: transport) }

    /// `authorize` opens the system browser sheet and returns the callback URL.
    func connect(_ account: MailAccount, store: AppStore, authorize: (URL, String) async throws -> URL) async {
        guard account.isSignIn else { return }
        do {
            let engine = try engine()
            let verifier = PKCE.verifier(), state = UUID().uuidString
            let url = engine.config.authorizationURL(loginHint: account.email, state: state, challenge: PKCE.challenge(for: verifier))
            let callback = try await authorize(url, engine.config.callbackScheme)
            let code = try engine.config.code(fromCallback: callback, expectedState: state)
            try await engine.completeSignIn(email: account.email, code: code, verifier: verifier)
            states[account.email] = .idle
            await refresh(account, store: store)
        } catch { states[account.email] = .failed(message(error)) }
    }

    func disconnect(_ account: MailAccount) {
        guard account.isSignIn else { return }
        do { try tokens.delete(account.email); states[account.email] = .notConnected }
        catch { states[account.email] = .failed(message(error)) }
    }

    func refresh(_ account: MailAccount, store: AppStore) async {
        guard account.isSignIn, tokens.exists(account.email), states[account.email] != .syncing else { return }
        states[account.email] = .syncing
        do {
            let known = Set(store.mail.map(\.sourceID))
            let pulled = try await engine().pull(email: account.email, known: known)
            let added = try store.mergeMail(pulled, activity: "Mail intake (\(account.email))")
            states[account.email] = .synced(at: .now, added: added)
        } catch { states[account.email] = .failed(message(error)) }
    }

    func refreshAll(store: AppStore) async {
        for account in MailAccount.signIns { await refresh(account, store: store) }
    }

    func startPeriodic(store: AppStore) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self, weak store] _ in
            Task { @MainActor in if let self, let store { await self.refreshAll(store: store) } }
        }
        Task { await refreshAll(store: store) }
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Mail refresh failed."
    }
}
