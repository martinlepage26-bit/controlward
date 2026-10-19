import AuthenticationServices
import Foundation

@MainActor
enum MailIntakeTests {
    static func run() async -> Bool {
        let tests: [(String, () async throws -> Void)] = [
            ("Mail: PKCE S256 matches RFC 7636 vector", pkceVector),
            ("Mail: client ID is validated and maps to reverse-DNS callback", clientIDValidation),
            ("Mail: authorization URL is read-only, PKCE, offline, login hint", authURL),
            ("Mail: callback rejects wrong state and wrong scheme", callback),
            ("Mail: me.com and pharos-ai.ca are labelled by Delivered-To/To", labeler),
            ("Mail: Gmail metadata maps to the review model without bodies", parsing),
            ("Mail: live intake dedupes by source id and keeps review state", dedupe),
            ("Mail: refresh token round trips; 401 asks to reconnect", tokens),
            ("Mail: Keychain service names are per account", keychainNames),
            ("Mail: sign-in as a different Google account is rejected, nothing stored", mismatch),
            ("Mail: re-intake of existing ids keeps review state, links and task", mergeKeepsState),
            ("Mail: disconnect deletes the token and resets state", disconnect),
            ("Mail: shipped client ID is default, reversed scheme, overridable", shippedClient),
            ("Mail: web sign-in completion runs off the main thread without trapping", offMainCompletion),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS  \(name)") }
            catch { failures += 1; print("FAIL  \(name): \(error)") }
        }
        print("Mail intake tests: \(tests.count - failures)/\(tests.count) passed")
        return failures == 0
    }

    private static func expect(_ c: Bool, _ m: String) throws { if !c { throw SmokeTestFailure.failed(m) } }
    static let clientID = "123456789012-abcdefghijklmnop.apps.googleusercontent.com"

    final class FakeGoogle: HTTPTransport, @unchecked Sendable {
        let lock = NSLock()
        var requests: [URLRequest] = []
        var tokenStatus = 200
        var profile = "ml@infrafabric.io"
        var messages: [[String: Any]]
        init(_ messages: [[String: Any]]) { self.messages = messages }
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            lock.withLock { requests.append(request) }
            let url = request.url!.absoluteString
            func json(_ o: Any, _ s: Int = 200) throws -> HTTPResponse { HTTPResponse(status: s, headers: [:], body: try JSONSerialization.data(withJSONObject: o)) }
            if url.hasPrefix("https://oauth2.googleapis.com/token") {
                let ok: [String: Any] = ["access_token": "synthetic-access", "refresh_token": "synthetic-refresh", "expires_in": 3600]
                let bad: [String: Any] = ["error": "invalid_grant"]
                return try json(tokenStatus == 200 ? ok : bad, tokenStatus)
            }
            if url.hasSuffix("/users/me/profile") { return try json(["emailAddress": profile]) }
            if url.contains("/messages?") { let refs: [[String: Any]] = messages.map { ["id": $0["id"]!] }; return try json(["messages": refs]) }
            if let m = messages.first(where: { url.contains("/messages/\($0["id"] as! String)?") }) { return try json(m) }
            return HTTPResponse(status: 404, headers: [:], body: Data())
        }
    }

    static func message(_ id: String, to: String, delivered: String = "martinlepage.ai@gmail.com") -> [String: Any] {
        ["id": id, "internalDate": "1792309386000", "snippet": "BODY-SHOULD-NOT-APPEAR",
         "payload": ["headers": [["name": "Subject", "value": "Synthetic \(id)"], ["name": "From", "value": "Sender <s@example.com>"],
                                 ["name": "To", "value": to], ["name": "Delivered-To", "value": delivered]]]]
    }

    static func offMainCompletion() async throws {
        // AuthenticationServices calls the completion on an XPC queue; it must not assume main-actor isolation.
        let gate = GoogleWebAuthorizer.ResumeOnce()
        let url = URL(string: "com.example.test:/oauth2redirect?code=x")!
        let got: URL = try await withCheckedThrowingContinuation { c in
            gate.set(c)
            let done = GoogleWebAuthorizer.makeCompletion(gate) {}
            DispatchQueue.global().async { done(url, nil); done(nil, nil) } // second call is ignored
        }
        try expect(got == url, "callback returned")
        let failed = GoogleWebAuthorizer.ResumeOnce()
        do {
            _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                failed.set(c)
                let done = GoogleWebAuthorizer.makeCompletion(failed) {}
                DispatchQueue.global().async { done(nil, NSError(domain: "x", code: 1)) }
            }
            throw SmokeTestFailure.failed("expected error")
        } catch let e as MailIntakeError { try expect(e == .signInFailed, "error path") }
        let cancel = GoogleWebAuthorizer.result(callback: nil, error: ASWebAuthenticationSessionError(.canceledLogin))
        if case .failure(let e as MailIntakeError) = cancel { try expect(e == .cancelled, "cancel") } else { throw SmokeTestFailure.failed("cancel") }
    }
    static func pkceVector() throws {
        try expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "challenge")
        let v = PKCE.verifier(); try expect(v.count >= 43 && !v.contains("=") && v != PKCE.verifier(), "verifier")
    }
    static func clientIDValidation() throws {
        let c = try GoogleOAuthConfig(clientID: " \(clientID) ")
        try expect(c.callbackScheme == "com.googleusercontent.apps.123456789012-abcdefghijklmnop", "scheme")
        try expect(c.redirectURI.hasSuffix(":/oauth2redirect"), "redirect")
        for bad in ["", "abc", "x.apps.googleusercontent.com?a=1", "GOCSPX-secret"] {
            try expect((try? GoogleOAuthConfig(clientID: bad)) == nil, "accepted \(bad)")
        }
    }
    static func authURL() throws {
        let u = try GoogleOAuthConfig(clientID: clientID).authorizationURL(loginHint: "ml@infrafabric.io", state: "s1", challenge: "c1")
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: u, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        try expect(q["scope"] == "https://www.googleapis.com/auth/gmail.readonly", "scope")
        try expect(q["code_challenge_method"] == "S256" && q["code_challenge"] == "c1" && q["state"] == "s1", "pkce")
        try expect(q["access_type"] == "offline" && q["login_hint"] == "ml@infrafabric.io" && q["client_secret"] == nil, "params")
    }
    static func callback() throws {
        let c = try GoogleOAuthConfig(clientID: clientID)
        try expect(try c.code(fromCallback: URL(string: "\(c.callbackScheme):/oauth2redirect?state=s&code=abc")!, expectedState: "s") == "abc", "code")
        do { _ = try c.code(fromCallback: URL(string: "\(c.callbackScheme):/oauth2redirect?state=x&code=abc")!, expectedState: "s"); throw SmokeTestFailure.failed("state") }
        catch MailIntakeError.stateMismatch {}
        do { _ = try c.code(fromCallback: URL(string: "evil:/oauth2redirect?state=s&code=abc")!, expectedState: "s"); throw SmokeTestFailure.failed("scheme") }
        catch MailIntakeError.signInFailed {}
    }
    static func labeler() throws {
        let owner = "martinlepage.ai@gmail.com"
        try expect(MailRecipientLabeler.accountID(owner: owner, deliveredTo: ["martinlepage26@me.com"], to: "x@y.com", cc: "").account == "martinlepage26@me.com", "delivered me.com")
        try expect(MailRecipientLabeler.accountID(owner: owner, deliveredTo: [owner], to: "\"Martin\" <ML@pharos-ai.ca>", cc: "").account == "ml@pharos-ai.ca", "to pharos")
        try expect(MailRecipientLabeler.accountID(owner: owner, deliveredTo: [owner], to: owner, cc: "").account == owner, "owner")
        try expect(MailRecipientLabeler.accountID(owner: "ml@infrafabric.io", deliveredTo: [], to: "martinlepage26@me.com", cc: "").account == "ml@infrafabric.io", "alias belongs to personal gmail only")
    }
    static func parsing() throws {
        let data = try JSONSerialization.data(withJSONObject: message("m1", to: "martinlepage26@me.com", delivered: "martinlepage26@me.com"))
        let m = try JSONDecoder().decode(GmailMessageMetadata.self, from: data).mailMetadata(owner: "martinlepage.ai@gmail.com")
        try expect(m.sourceID == "gmail:m1" && m.accountID == "martinlepage26@me.com" && m.provider == "icloud-forward", "ids")
        try expect(m.subject == "Synthetic m1" && m.sender.contains("s@example.com") && !m.synthetic, "fields")
        try expect(m.receivedAt == "2026-10-18T07:43:06Z" && m.link.contains("#all/m1"), "date/link")
        try expect(!String(describing: m).contains("BODY-SHOULD-NOT-APPEAR"), "snippet leaked")
    }
    static func dedupe() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cw-mail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppStore(storageURL: dir.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore())
        store.createWorkspace(name: "Synthetic", industry: "Consulting")
        let fake = FakeGoogle([message("a", to: "martinlepage.ai@gmail.com"), message("b", to: "ml@pharos-ai.ca")])
        let tokens = InMemoryMailTokenStore(); try tokens.write("synthetic-refresh", for: MailAccount.personalGmail.email)
        let suite = UserDefaults(suiteName: "cw-mail-\(UUID().uuidString)")!
        let mail = MailIntakeController(tokens: tokens, transport: fake, defaults: suite)
        try mail.saveClientID(clientID)
        await mail.refresh(.personalGmail, store: store)
        try expect(store.mail.count == 2, "first pull \(store.mail.count) \(mail.state(.personalGmail))")
        try expect(Set(store.mail.map(\.accountID)) == ["martinlepage.ai@gmail.com", "ml@pharos-ai.ca"], "labels")
        try store.reviewMail(store.mail[0].id, reviewed: true, contactID: nil, companyID: nil)
        await mail.refresh(.personalGmail, store: store)
        try expect(store.mail.count == 2 && store.mail[0].reviewed, "dedupe/review kept")
        try expect(mail.state(.icloudAlias) == mail.state(.personalGmail), "alias mirrors owner state")
        let metadataCalls = fake.requests.filter { $0.url!.absoluteString.contains("format=metadata") }.count
        try expect(metadataCalls == 2, "known ids refetched: \(metadataCalls)")
        try expect(!fake.requests.contains { $0.url!.absoluteString.contains("format=full") || $0.url!.absoluteString.contains("format=raw") }, "body format requested")
        await mail.refresh(.infrafabric, store: store)
        try expect(mail.state(.infrafabric) == .notConnected, "unconnected account untouched")
    }
    static func tokens() async throws {
        let fake = FakeGoogle([]); let tokens = InMemoryMailTokenStore()
        let engine = MailIntakeEngine(config: try GoogleOAuthConfig(clientID: clientID), tokens: tokens, transport: fake)
        try await engine.completeSignIn(email: "ml@infrafabric.io", code: "c", verifier: "v")
        try expect(try tokens.read("ml@infrafabric.io") == "synthetic-refresh", "stored")
        let body = String(data: fake.requests.first { $0.url!.host == "oauth2.googleapis.com" }!.httpBody!, encoding: .utf8)!
        try expect(body.contains("code_verifier=v") && body.contains("grant_type=authorization_code") && !body.contains("client_secret"), "exchange form")
        fake.tokenStatus = 400
        do { _ = try await engine.accessToken(for: "ml@infrafabric.io"); throw SmokeTestFailure.failed("no error") } catch MailIntakeError.reauthorize {}
        do { _ = try await engine.accessToken(for: "nobody@example.com"); throw SmokeTestFailure.failed("no error") } catch MailIntakeError.notConnected {}
        try tokens.delete("ml@infrafabric.io"); try expect(!tokens.exists("ml@infrafabric.io"), "delete")
        do { try tokens.write("", for: "x"); throw SmokeTestFailure.failed("empty") } catch SecretStoreError.empty {}
    }
    static func mismatch() async throws {
        let fake = FakeGoogle([]); fake.profile = "someone.else@gmail.com"; let tokens = InMemoryMailTokenStore()
        let engine = MailIntakeEngine(config: try GoogleOAuthConfig(clientID: clientID), tokens: tokens, transport: fake)
        do { try await engine.completeSignIn(email: "ml@infrafabric.io", code: "c", verifier: "v"); throw SmokeTestFailure.failed("accepted") }
        catch MailIntakeError.accountMismatch(let actual) { try expect(actual == "someone.else@gmail.com", "actual") }
        try expect(!tokens.exists("ml@infrafabric.io") && !tokens.exists("someone.else@gmail.com"), "token stored")
        fake.profile = "ML@Infrafabric.io"
        try await engine.completeSignIn(email: "ml@infrafabric.io", code: "c", verifier: "v")
        try expect(tokens.exists("ml@infrafabric.io"), "case-insensitive match stored")
    }
    static func mergeKeepsState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cw-mail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppStore(storageURL: dir.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore())
        store.createWorkspace(name: "Synthetic", industry: "Consulting")
        let owner = "martinlepage.ai@gmail.com"
        let first = try JSONDecoder().decode(GmailMessageMetadata.self, from: JSONSerialization.data(withJSONObject: message("x1", to: owner))).mailMetadata(owner: owner)
        try expect(try store.mergeMail([first], activity: "Mail intake (test)") == 1, "added")
        let id = store.mail[0].id
        try store.reviewMail(id, reviewed: true, contactID: nil, companyID: nil)
        let task = try store.createMailTask(id)
        var again = first; again.id = UUID(); again.subject = "Synthetic x1 (edited)"
        try expect(try store.mergeMail([again], activity: "Mail intake (test)") == 0, "re-added")
        let m = store.mail[0]
        try expect(store.mail.count == 1 && m.id == id && m.reviewed && m.taskID == task && m.subject == "Synthetic x1 (edited)", "state lost")
    }
    static func disconnect() throws {
        let tokens = InMemoryMailTokenStore(); try tokens.write("synthetic-refresh", for: MailAccount.infrafabric.email)
        let mail = MailIntakeController(tokens: tokens, transport: FakeGoogle([]), defaults: UserDefaults(suiteName: "cw-mail-\(UUID().uuidString)")!)
        try expect(mail.state(.infrafabric) == .idle, "connected")
        mail.disconnect(.infrafabric)
        try expect(!tokens.exists(MailAccount.infrafabric.email) && mail.state(.infrafabric) == .notConnected, "disconnect")
        mail.disconnect(.icloudAlias)
        try expect(mail.state(.icloudAlias) == .notConnected, "alias")
    }
    static func shippedClient() throws {
        let suite = UserDefaults(suiteName: "cw-mail-\(UUID().uuidString)")!
        let mail = MailIntakeController(tokens: InMemoryMailTokenStore(), transport: FakeGoogle([]), defaults: suite)
        let c = try mail.config()
        try expect(c.clientID == "522514188059-qe7qirvdks6ott29v2e8r9ni4tno30k1.apps.googleusercontent.com", "default id")
        try expect(c.callbackScheme == "com.googleusercontent.apps.522514188059-qe7qirvdks6ott29v2e8r9ni4tno30k1", "reversed scheme")
        try expect(c.redirectURI == "com.googleusercontent.apps.522514188059-qe7qirvdks6ott29v2e8r9ni4tno30k1:/oauth2redirect", "redirect")
        try mail.saveClientID(clientID)
        try expect(try mail.config().clientID == clientID, "override")
    }
    static func keychainNames() throws {
        let k = KeychainMailTokenStore()
        try expect(k.service(for: "ML@Infrafabric.io") == "com.pharos.contextward.mail.ml@infrafabric.io", "service")
        try expect(KeychainMailTokenStore.account == "oauth", "account")
        // Real Keychain round trip only when explicitly requested (it can prompt).
        if ProcessInfo.processInfo.environment["CONTEXTWARD_KEYCHAIN_TESTS"] == "1" {
            let t = KeychainMailTokenStore(servicePrefix: "com.pharos.contextward.test.mail")
            try t.write("synthetic", for: "probe@example.com"); defer { try? t.delete("probe@example.com") }
            try expect(try t.read("probe@example.com") == "synthetic" && t.exists("probe@example.com"), "round trip")
            try t.write("synthetic-2", for: "probe@example.com")
            try expect(try t.read("probe@example.com") == "synthetic-2", "update")
            try t.delete("probe@example.com")
            try expect(!t.exists("probe@example.com") && (try t.read("probe@example.com")) == nil, "delete")
            try t.delete("probe@example.com") // idempotent
            print("INFO  Mail: real Keychain round trip + delete ran")
        }
    }
}
