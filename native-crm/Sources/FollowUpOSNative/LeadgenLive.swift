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
        /// OAuth access token for ml@pharos-ai.ca with the gmail.compose scope only.
        let gmailToken: SecretRef
    }

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
            fm.createFile(atPath: url.path, contents: data)
        }
    }
}

// MARK: Live adapters (used only by the CLI live path; tests use fakes)

struct LeadgenHTTPFetcher: LeadgenFetching {
    func get(_ url: URL) async throws -> (status: Int, body: String) {
        var req = URLRequest(url: url)
        req.setValue("ControlWard-leadgen/1 (+mailto:ml@pharos-ai.ca)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }
}

/// Cloudflare D1 HTTP query API. One account and token per database.
struct LeadgenCloudflareD1: LeadgenD1Port {
    struct Binding: Sendable { let accountID: String; let token: String }
    let bindings: [String: Binding]

    func query(database: String, sql: String, params: [String]) async throws -> [[String: String]] {
        guard let b = bindings[database] else { throw LeadgenError.credentialMissing("D1 binding for \(database)") }
        var req = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/accounts/\(b.accountID)/d1/database/\(database)/query")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(b.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["sql": sql, "params": params])
        let (data, resp) = try await URLSession.shared.data(for: req)
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
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["message": ["raw": raw]])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = obj["id"] as? String else {
            throw LeadgenError.fetchFailed("gmail drafts.create: \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return id
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

    static func plan(config: LeadgenLocalConfig?, configPath: String, configError: String?) -> [String] {
        let prospect = config?.prospectValue
        let address: String
        do { _ = try LeadgenDraftComposer.checkAddress(config?.postalAddress); address = "set (local config)" } catch { address = "REFUSED: \(error)" }
        return [
            "ControlWard lead-gen slice 1: DRY RUN (nothing was fetched, written, or drafted)",
            "config: \(configPath) \(configError.map { "[\($0)]" } ?? "[loaded]")",
            "prospect: \(prospect.map { "\($0.organization) \($0.site.absoluteString)" } ?? "not configured")",
            "pages to read (robots.txt first): \((config?.paths ?? []).joined(separator: " "))",
            "CASL footer address: \(address)",
            "consent basis: \(config?.consent == nil ? "not configured" : "set")",
            "live plan, in order:",
            "  1. read-only schema check of D1 \(LeadgenProjectTarget.meCom.databaseID) and \(LeadgenProjectTarget.pharos.databaseID); STOP if a leads table exists",
            "  2. per DB: checksum (rows + sqlite_master.sql) of every table and projects count, before",
            "  3. per DB: apply docs/leadgen-slice/migrations/0001_create_leads.sql (CREATE TABLE IF NOT EXISTS leads)",
            "  4. per DB: INSERT one row into leads, status \(LeadgenLeadRow.status)",
            "  5. per DB: read the row back",
            "  6. per DB: checksum and counts after; any change outside leads fails the run",
            "  7. Gmail create-draft only, on \(LeadgenDraft.mailbox) (no send, no read, no delete)",
            "  8. run log under ~/Library/Logs/ControlWard/leadgen/",
            "to run live: leadgen --live --confirm \"\(LeadgenRunConfig.confirmation)\"",
        ]
    }

    /// Returns (exit code, output lines). Dry-run never builds live adapters.
    static func run(arguments: [String], environment: [String: String],
                    makeLive: (LeadgenLocalConfig) throws -> LeadgenLiveDeps) async -> (Int32, [String]) {
        let config = LeadgenRunConfig.from(arguments: arguments, environment: environment)
        let path = LeadgenLocalConfig.defaultPath(environment: environment)
        var local: LeadgenLocalConfig?
        var loadError: String?
        do { local = try LeadgenLocalConfig.load(path: path) } catch { loadError = "\(error)" }

        guard config.liveFlag else { return (0, plan(config: local, configPath: path, configError: loadError)) }
        do { try config.authorizeLive() } catch { return (2, ["refused: \(error)"]) }
        guard let local else { return (2, ["refused: \(loadError ?? "no local config")"]) }
        guard let prospect = local.prospectValue, let paths = local.paths, !paths.isEmpty else {
            return (2, ["refused: local config has no prospect or paths"])
        }
        do {
            _ = try LeadgenDraftComposer.checkAddress(local.postalAddress)
            let deps = try makeLive(local)
            let stamp = ISO8601DateFormatter().string(from: Date())
            await deps.log.write("leadgen live run \(stamp) confirmation=\"\(config.operatorOK ?? "")\"")
            let runner = LeadgenSliceRunner(config: config, fetcher: deps.fetcher, mailbox: deps.mailbox, d1: deps.d1, log: deps.log, now: { stamp })
            let report = try await runner.run(candidates: [prospect], paths: paths, consent: local.consentValue, postalAddress: local.postalAddress)
            var out = ["live run done: draft \(report.draftID ?? "-") on \(LeadgenDraft.mailbox)"]
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
            let gmail = try LeadgenCredentials.resolve(c.gmailToken, environment: environment, keychain: keychain)
            let log = LeadgenFileLog(directory: LeadgenFileLog.directory(environment: environment), stamp: ISO8601DateFormatter().string(from: Date()))
            return LeadgenLiveDeps(
                fetcher: LeadgenHTTPFetcher(),
                mailbox: LeadgenGmailDrafts(token: gmail),
                d1: LeadgenCloudflareD1(bindings: [
                    LeadgenProjectTarget.meCom.databaseID: .init(accountID: c.meComAccountID, token: me),
                    LeadgenProjectTarget.pharos.databaseID: .init(accountID: c.pharosAccountID, token: ph),
                ]),
                log: log,
                logPath: log.url.path
            )
        }
    }
}
