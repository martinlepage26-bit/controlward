import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Lead-gen slice 1 live runner and CLI entry (docs/leadgen-slice/SPEC.md, Q2 and Q3).
// `FollowUpOSNative leadgen` prints the plan and touches nothing.
// `FollowUpOSNative leadgen --live --confirm "<LeadgenRunConfig.confirmation>"` runs the one live run.
// Secrets are never read from this file or from the config: the config only names env variables
// or Keychain items, and LeadgenCredentials resolves them at run time.

// MARK: Local config (not committed; docs/leadgen-slice/leadgen.local.example.json is the template)

struct LeadgenLocalConfig: Codable, Sendable, Equatable {
    struct Prospect: Codable, Sendable, Equatable {
        let organization: String
        let site: String
        let publicContactEmail: String
    }
    struct Consent: Codable, Sendable, Equatable {
        let basis: String
        let source: String
        let recordedAt: String
    }
    /// A credential reference: an env variable name, or a Keychain generic-password service name.
    struct SecretRef: Codable, Sendable, Equatable {
        let env: String?
        let keychainService: String?
    }
    struct Credentials: Codable, Sendable, Equatable {
        /// Cloudflare account IDs (identifiers, not secrets) for each D1.
        let meComAccountID: String
        let pharosAccountID: String
        let meComToken: SecretRef
        let pharosToken: SecretRef
        /// Read-only Cloudflare token used for the snapshot SELECTs. Names an env var or Keychain item. No secret value.
        let meComReadToken: SecretRef?
        let pharosReadToken: SecretRef?
        /// OAuth access token for ml@pharos-ai.ca with the gmail.compose scope only.
        let gmailToken: SecretRef
    }

    /// One public directory page that lists Montréal clinics. Empty until a human chooses the page.
    /// The prospect is read from this page. A hand-supplied clinic URL is not the discovery source.
    let directoryURL: String?
    /// The CASL footer address. Lives only in the local config.
    let postalAddress: String?
    let prospect: Prospect?
    let paths: [String]?
    let consent: Consent?
    let credentials: Credentials?

    static let fileName = "leadgen.local.json"

    static func defaultPath(environment: [String: String]) -> String {
        if let p = environment["LEADGEN_CONFIG"], !p.isEmpty { return p }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return "\(home)/Library/Application Support/ControlWard/\(fileName)"
    }

    static func load(path: String) throws -> LeadgenLocalConfig {
        guard let data = FileManager.default.contents(atPath: path) else { throw LeadgenError.configMissing(path) }
        do { return try JSONDecoder().decode(LeadgenLocalConfig.self, from: data) } catch {
            throw LeadgenError.configInvalid("\(path): \(error)")
        }
    }

    /// The configured directory page, or nil when it is missing or blank (`directory not configured`).
    var directoryValue: URL? {
        guard let raw = directoryURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    var prospectValue: LeadgenProspect? {
        guard let p = prospect, let url = URL(string: p.site) else { return nil }
        return LeadgenProspect(organization: p.organization, segment: LeadgenProspectPicker.segment, site: url, publicContactEmail: p.publicContactEmail)
    }

    var consentValue: LeadgenConsentBasis? {
        consent.map { LeadgenConsentBasis(basis: $0.basis, source: $0.source, recordedAt: $0.recordedAt) }
    }
}

// MARK: Credentials (env or Keychain reference only)

protocol LeadgenSecretSource: Sendable {
    func keychain(service: String) -> String?
}

struct LeadgenSystemKeychain: LeadgenSecretSource {
    func keychain(service: String) -> String? {
        #if os(macOS)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let v = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty ?? true) ? nil : v
        #else
        return nil
        #endif
    }
}

/// Live token, D1, and Gmail calls. Request and resource deadlines are both 20 seconds, so a quiet socket cannot outlive a run.
enum LeadgenLiveHTTP {
    static let requestTimeout: TimeInterval = 20
    static let resourceTimeout: TimeInterval = 20
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    static func request(_ url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: requestTimeout)
        req.httpMethod = method
        return req
    }
}

struct LeadgenCloudflareTokenVerifier: LeadgenTokenVerifying {
    func verify(bearer: String) async throws -> LeadgenVerifiedToken {
        guard !bearer.isEmpty else { throw LeadgenError.tokenProof("unverifiable") }
        var req = LeadgenLiveHTTP.request(URL(string: "https://api.cloudflare.com/client/v4/user/tokens/verify")!, method: "GET")
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await LeadgenLiveHTTP.session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["success"] as? Bool == true,
              let result = obj["result"] as? [String: Any],
              let id = result["id"] as? String,
              let status = result["status"] as? String else {
            throw LeadgenError.tokenProof("unverifiable")
        }
        return LeadgenVerifiedToken(id: id, status: status)
    }
}

extension LeadgenTokenProof {
    static func enforce(config: LeadgenLocalConfig?, environment: [String: String], keychain: any LeadgenSecretSource, verifier: any LeadgenTokenVerifying) async throws {
        let saved = try load(environment: environment)
        var verified: [LeadgenVerifiedToken?] = []
        for token in saved.tokens {
            let secret = try bearer(for: token.env, config: config, environment: environment, keychain: keychain)
            do { verified.append(try await verifier.verify(bearer: secret)) }
            catch let error as LeadgenError { throw error }
            catch { throw LeadgenError.tokenProof("unverifiable") }
        }
        try admit(saved: saved, verified: verified)
    }

    private static func bearer(for envName: String, config: LeadgenLocalConfig?, environment: [String: String], keychain: any LeadgenSecretSource) throws -> String {
        if let value = environment[envName], !value.isEmpty { return value }
        let refs = [config?.credentials?.meComReadToken, config?.credentials?.pharosReadToken].compactMap { $0 }
        if let ref = refs.first(where: { $0.env == envName }) {
            do { return try LeadgenCredentials.resolve(ref, environment: environment, keychain: keychain) }
            catch { throw LeadgenError.tokenProof("unverifiable") }
        }
        throw LeadgenError.tokenProof("unverifiable")
    }
}

enum LeadgenCredentials {
    static func resolve(_ ref: LeadgenLocalConfig.SecretRef, environment: [String: String], keychain: LeadgenSecretSource) throws -> String {
        if let name = ref.env, let v = environment[name], !v.isEmpty { return v }
        if let service = ref.keychainService, let v = keychain.keychain(service: service) { return v }
        throw LeadgenError.credentialMissing(ref.env.map { "env \($0)" } ?? ref.keychainService.map { "keychain \($0)" } ?? "none")
    }
}

// MARK: Run log file under the app's log directory

actor LeadgenFileLog: LeadgenRunLog {
    let url: URL
    private var buffer: [String] = []

    static func directory(environment: [String: String]) -> URL {
        let home = environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/ControlWard/leadgen", isDirectory: true)
    }

    init(directory: URL, stamp: String) {
        let safe = stamp.replacingOccurrences(of: ":", with: "-")
        url = directory.appendingPathComponent("leadgen-run-\(safe).log")
    }

    func write(_ line: String) async {
        buffer.append(line)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            _ = fm.createFile(atPath: url.path, contents: data)
        }
    }
}

// MARK: Live adapters (used only by the CLI live path; tests use fakes)

struct LeadgenHTTPFetcher: LeadgenFetching {
    /// One lookup. Tests pass a fake; the live default is system DNS, called once per request.
    var lookup: @Sendable (String) -> [String] = { SystemHostLookup.addresses($0) }
    /// When set, this receives the pinned request and no socket is opened.
    var transport: (@Sendable (URLRequest) async throws -> (Int, [String: String], String))? = nil
    /// Test-only. Production leaves this false, so loopback is still refused.
    var admitLoopbackForTests = false
    /// DER trust anchors for the test CA. Production leaves this empty: system trust, no override.
    var testTrustAnchorDERs: [Data] = []

    #if !os(macOS)
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()
    #endif

    func get(_ url: URL) async throws -> (status: Int, headers: [String: String], body: String) {
        let resolved = lookup(url.host ?? "")
        if let why = HostSafety.refusal(url: url, resolvedAddresses: resolved, admitLoopback: admitLoopbackForTests) {
            throw LeadgenError.unsafeURL(why)
        }
        guard let plan = LeadgenPinnedRequest.pin(url: url, addresses: resolved, admitLoopback: admitLoopbackForTests) else {
            throw LeadgenError.unsafeURL("unresolved \(url.host ?? "")")
        }
        var req = URLRequest(url: plan.url)
        req.setValue(plan.hostHeader, forHTTPHeaderField: "Host")
        req.setValue("PHAROS AI ControlWard (+https://pharos-ai.ca; ml@pharos-ai.ca)", forHTTPHeaderField: "User-Agent")
        if let transport { return try await transport(req) }
        #if os(macOS)
        let (status, headers, data) = try await LeadgenPinnedHTTPS.exchange(request: req, trustAnchorDERs: testTrustAnchorDERs)
        return (status, headers, String(decoding: data, as: UTF8.self))
        #else
        let (data, resp) = try await Self.session.data(for: req)
        let http = resp as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return (http?.statusCode ?? 0, headers, String(decoding: data, as: UTF8.self))
        #endif
    }
}

/// Cloudflare D1 HTTP query API. One account and token per database.
struct LeadgenCloudflareD1: LeadgenD1Port {
    struct Binding: Sendable { let accountID: String; let token: String; let readToken: String }
    let bindings: [String: Binding]

    /// Snapshot and other reads use the read-only token. Writes use the other token. Neither value is stored in source.
    static func credential(sql: String, read: String, write: String) -> String {
        sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("SELECT ") ? read : write
    }

    func query(database: String, sql: String, params: [String]) async throws -> [[String: String]] {
        guard let b = bindings[database] else { throw LeadgenError.credentialMissing("D1 binding for \(database)") }
        let token = Self.credential(sql: sql, read: b.readToken, write: b.token)
        var req = LeadgenLiveHTTP.request(URL(string: "https://api.cloudflare.com/client/v4/accounts/\(b.accountID)/d1/database/\(database)/query")!, method: "POST")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["sql": sql, "params": params])
        let (data, resp) = try await LeadgenLiveHTTP.session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["success"] as? Bool == true,
              let result = (obj["result"] as? [[String: Any]])?.first,
              let rows = result["results"] as? [[String: Any]] else {
            throw LeadgenError.fetchFailed("D1 \(database): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return rows.map { row in row.mapValues { v in v is NSNull ? "" : "\(v)" } }
    }
}

/// Gmail `users.drafts.create` only. There is no send, read, list, or delete call here.
struct LeadgenGmailDrafts: LeadgenDraftMailbox {
    let token: String

    func createDraft(account: String, rawMIME: String) async throws -> String {
        guard account == LeadgenDraft.mailbox else { throw LeadgenError.wrongMailbox(account) }
        let raw = Data(rawMIME.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var req = LeadgenLiveHTTP.request(URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts")!, method: "POST")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["message": ["raw": raw]])
        let (data, resp) = try await LeadgenLiveHTTP.session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = obj["id"] as? String else {
            throw LeadgenError.fetchFailed("gmail drafts.create: \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return id
    }
}

actor LeadgenMemoryBuffer: LeadgenRunLog {
    private(set) var lines: [String] = []
    func write(_ line: String) async { lines.append(line) }
}

struct LeadgenUnusedMailbox: LeadgenDraftMailbox {
    func createDraft(account: String, rawMIME: String) async throws -> String {
        throw LeadgenError.liveNotAuthorized("dry-run has no mailbox")
    }
}

struct LeadgenUnusedD1: LeadgenD1Port {
    func query(database: String, sql: String, params: [String]) async throws -> [[String: String]] {
        let upper = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if upper.hasPrefix("SELECT ") { return [] }
        throw LeadgenError.liveNotAuthorized("dry-run has no database")
    }
}

// MARK: CLI

/// What the live path is built from. The CLI builds real adapters; tests inject fakes.
struct LeadgenLiveDeps: Sendable {
    let fetcher: LeadgenFetching
    let mailbox: LeadgenDraftMailbox
    let d1: LeadgenD1Port
    let log: LeadgenRunLog
    let logPath: String
}

enum LeadgenCLI {
    static let subcommand = "leadgen"

    static func plan(config: LeadgenLocalConfig?, configPath: String, configError: String?, discovered: String? = nil) -> [String] {
        let address: String
        do { _ = try LeadgenDraftComposer.checkAddress(config?.postalAddress); address = "set (local config)" } catch { address = "REFUSED: \(error)" }
        let directoryLine = config?.directoryValue.map { "directory: \($0.absoluteString)" } ?? "directory not configured"
        return [
            "ControlWard lead-gen slice 1: DRY RUN (nothing was written or drafted)",
            "config: \(configPath) \(configError.map { "[\($0)]" } ?? "[loaded]")",
            directoryLine,
            "prospect: \(discovered ?? "not configured")",
            "pages to read (robots.txt first): \((config?.paths ?? []).joined(separator: " "))",
            "CASL footer address: \(address)",
            "consent basis: \(config?.consent == nil ? "not configured" : "set")",
            "live plan, in order:",
            "  1. read-only schema check of D1 \(LeadgenProjectTarget.meCom.databaseID) and \(LeadgenProjectTarget.pharos.databaseID); STOP if a leads table exists",
            "  2. Gmail create-draft only, on \(LeadgenDraft.mailbox) (no send, no read, no delete)",
            "  3. per DB: checksum (rows + sqlite_master.sql) of every table and projects count, before",
            "  4. per DB: apply docs/leadgen-slice/migrations/0001_create_leads.sql (CREATE TABLE IF NOT EXISTS leads)",
            "  5. per DB: INSERT one row into leads, status \(LeadgenLeadRow.status), draft_ref is the draft id from step 2",
            "  6. per DB: read the row back",
            "  7. per DB: checksum and counts after; any change outside leads fails the run",
            "  8. if a row insert fails, leave the unsent draft and log its id and which database failed",
            "  9. run log under ~/Library/Logs/ControlWard/leadgen/",
            "to run live: leadgen --live --confirm \"\(LeadgenRunConfig.confirmation)\"",
        ]
    }

    /// Returns (exit code, output lines). Dry-run never builds Gmail or D1 adapters.
    /// With a directory URL it fetches that page and the one clinic's own site. Without one it prints
    /// `directory not configured` and does not treat a hand-supplied clinic URL as the prospect.
    static func run(arguments: [String], environment: [String: String],
                    makeFetcher: @escaping () -> LeadgenFetching = { LeadgenHTTPFetcher() },
                    dns: any LeadgenResolving = LeadgenSystemDNS(),
                    verifier: any LeadgenTokenVerifying = LeadgenCloudflareTokenVerifier(),
                    keychain: any LeadgenSecretSource = LeadgenSystemKeychain(),
                    makeLive: (LeadgenLocalConfig) throws -> LeadgenLiveDeps) async -> (Int32, [String]) {
        let config = LeadgenRunConfig.from(arguments: arguments, environment: environment)
        let path = LeadgenLocalConfig.defaultPath(environment: environment)
        var local: LeadgenLocalConfig?
        var loadError: String?
        do { local = try LeadgenLocalConfig.load(path: path) } catch { loadError = "\(error)" }

        guard config.liveFlag else {
            guard let directory = local?.directoryValue else { return (0, plan(config: local, configPath: path, configError: loadError)) }
            do {
                _ = try LeadgenDraftComposer.checkAddress(local?.postalAddress)
                guard let paths = local?.paths, !paths.isEmpty else { return (2, ["refused: local config has no paths"]) }
                let log = LeadgenMemoryBuffer()
                let runner = LeadgenSliceRunner(config: .dryRun, fetcher: makeFetcher(), mailbox: LeadgenUnusedMailbox(), d1: LeadgenUnusedD1(), log: log, now: { "dry-run" }, dns: dns)
                let report = try await runner.run(candidates: [], paths: paths, consent: local?.consentValue, postalAddress: local?.postalAddress, directory: directory)
                var lines = plan(config: local, configPath: path, configError: loadError, discovered: "\(report.prospect.organization) \(report.prospect.site.absoluteString)")
                lines.append("fit: \(report.fit.reason)")
                lines.append("recipient: \(report.prospect.publicContactEmail)")
                lines.append("consent source: \(report.draft.consent.source)")
                lines.append(contentsOf: await log.lines)
                return (0, lines)
            } catch {
                var lines = plan(config: local, configPath: path, configError: loadError)
                lines.append("discovery refused: \(error)")
                return (1, lines)
            }
        }
        do { try config.authorizeLive() } catch { return (2, ["refused: \(error)"]) }
        guard let local else { return (2, ["refused: \(loadError ?? "no local config")"]) }
        guard let directory = local.directoryValue else { return (2, ["refused: directory not configured"]) }
        guard let paths = local.paths, !paths.isEmpty else { return (2, ["refused: local config has no paths"]) }
        do {
            _ = try LeadgenDraftComposer.checkAddress(local.postalAddress)
            try await LeadgenTokenProof.enforce(config: local, environment: environment, keychain: keychain, verifier: verifier)
            let deps = try makeLive(local)
            let stamp = ISO8601DateFormatter().string(from: Date())
            await deps.log.write("leadgen live run \(stamp) confirmation=\"\(config.operatorOK ?? "")\"")
            let runner = LeadgenSliceRunner(config: config, fetcher: deps.fetcher, mailbox: deps.mailbox, d1: deps.d1, log: deps.log, now: { stamp }, dns: dns)
            let report = try await runner.run(candidates: [], paths: paths, consent: local.consentValue, postalAddress: local.postalAddress, directory: directory)
            var out = ["live run done: draft \(report.draftID ?? "-") on \(LeadgenDraft.mailbox)"]
            out.append("prospect: \(report.prospect.organization) \(report.prospect.site.absoluteString)")
            for r in report.receipts { out.append("\(r.databaseID): leads \(r.countBefore) -> \(r.countAfter), existing tables unchanged") }
            out.append("log: \(deps.logPath)")
            return (0, out)
        } catch {
            return (1, ["live run stopped: \(error)"])
        }
    }

    /// Real adapters for the one live run. Called only after the confirmation check passes.
    static func liveDeps(environment: [String: String], keychain: LeadgenSecretSource = LeadgenSystemKeychain()) -> (LeadgenLocalConfig) throws -> LeadgenLiveDeps {
        { local in
            guard let c = local.credentials else { throw LeadgenError.configInvalid("no credentials block") }
            let me = try LeadgenCredentials.resolve(c.meComToken, environment: environment, keychain: keychain)
            let ph = try LeadgenCredentials.resolve(c.pharosToken, environment: environment, keychain: keychain)
            guard let meReadRef = c.meComReadToken, let phReadRef = c.pharosReadToken else {
                throw LeadgenError.credentialMissing("read-only D1 token (LEADGEN_CF_TOKEN_MECOM_READ and LEADGEN_CF_TOKEN_PHAROS_READ)")
            }
            let meRead = try LeadgenCredentials.resolve(meReadRef, environment: environment, keychain: keychain)
            let phRead = try LeadgenCredentials.resolve(phReadRef, environment: environment, keychain: keychain)
            let gmail = try LeadgenCredentials.resolve(c.gmailToken, environment: environment, keychain: keychain)
            let log = LeadgenFileLog(directory: LeadgenFileLog.directory(environment: environment), stamp: ISO8601DateFormatter().string(from: Date()))
            return LeadgenLiveDeps(
                fetcher: LeadgenHTTPFetcher(),
                mailbox: LeadgenGmailDrafts(token: gmail),
                d1: LeadgenCloudflareD1(bindings: [
                    LeadgenProjectTarget.meCom.databaseID: .init(accountID: c.meComAccountID, token: me, readToken: meRead),
                    LeadgenProjectTarget.pharos.databaseID: .init(accountID: c.pharosAccountID, token: ph, readToken: phRead),
                ]),
                log: log,
                logPath: log.url.path
            )
        }
    }
}
