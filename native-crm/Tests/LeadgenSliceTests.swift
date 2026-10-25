import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if os(macOS)
import Network
import Security
#endif

// Lead-gen slice 1 tests (docs/leadgen-slice/SPEC.md). Fakes only: no network, no Gmail, no D1,
// except the macOS pinned-TLS case, which speaks HTTPS to a local server.

/// A test double must return, or fail, inside this bound. An unconfigured response cannot hold the suite open.
enum LeadgenTestClock {
    static let bound: Double = 20

    static func within<T: Sendable>(_ seconds: Double = bound, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                throw PortableCheckFailure(description: "test double timed out")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw PortableCheckFailure(description: "test double timed out")
            }
            return first
        }
    }
}

private struct LeadgenFixedVerifier: LeadgenTokenVerifying {
    var byBearer: [String: LeadgenVerifiedToken]
    func verify(bearer: String) async throws -> LeadgenVerifiedToken {
        let found = byBearer[bearer]
        return try await LeadgenTestClock.within {
            guard let found else { throw LeadgenError.tokenProof("unverifiable") }
            return found
        }
    }
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    try PortableCheck.expect(try condition(), message)
}

private func expectError(_ expected: LeadgenError, _ body: () async throws -> Void) async throws {
    do {
        try await body()
        throw PortableCheckFailure(description: "expected \(expected), got success")
    } catch let error as LeadgenError {
        try check(error == expected, "expected \(expected), got \(error)")
    }
}

final class LeadgenFakeFetcher: LeadgenFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [String: (Int, [String: String], String)]
    private var requestedURLs: [String] = []
    var requested: [String] { lock.withLock { requestedURLs } }

    init(pages: [String: (Int, String)]) {
        var stored: [String: (Int, [String: String], String)] = [:]
        for (url, hit) in pages { stored[url] = (hit.0, [:], hit.1) }
        self.pages = stored
    }

    func set(_ url: String, status: Int, headers: [String: String] = [:], body: String) {
        lock.withLock { pages[url] = (status, headers, body) }
    }

    func get(_ url: URL) async throws -> (status: Int, headers: [String: String], body: String) {
        let url = url
        return try await LeadgenTestClock.within {
            self.lock.withLock {
                self.requestedURLs.append(url.absoluteString)
                guard let hit = self.pages[url.absoluteString] else { return (404, [:], "") }
                return (hit.0, hit.1, hit.2)
            }
        }
    }
}

struct LeadgenMappedDNS: LeadgenResolving {
    var overrides: [String: [String]] = [:]
    func addresses(for host: String) async -> [String] {
        let key = HostSafety.canonicalHost(host)
        if let hit = overrides[key] { return hit }
        if HostSafety.nameRefusal(key) != nil { return [key] }
        return ["1.1.1.1"]
    }
}

/// Records every mail call by name. It has send/read/delete counters that the runner cannot reach,
/// because LeadgenDraftMailbox only declares createDraft.
actor LeadgenRecordingMailbox: LeadgenDraftMailbox {
    private(set) var calls: [String] = []
    private(set) var accounts: [String] = []
    private(set) var raws: [String] = []
    private(set) var sends = 0, reads = 0, deletes = 0
    func createDraft(account: String, rawMIME: String) async throws -> String {
        try await LeadgenTestClock.within { await self.record(account: account, rawMIME: rawMIME) }
    }

    private func record(account: String, rawMIME: String) -> String {
        calls.append("createDraft"); accounts.append(account); raws.append(rawMIME)
        return "r-draft-1"
    }
    func send() { sends += 1; calls.append("send") }
    func read() { reads += 1; calls.append("read") }
    func delete() { deletes += 1; calls.append("delete") }
}

actor LeadgenMemoryLog: LeadgenRunLog {
    private(set) var lines: [String] = []
    func write(_ line: String) async { lines.append(line) }
}

/// Mailbox that records how many D1 statements had run when createDraft was called.
actor LeadgenOrderMailbox: LeadgenDraftMailbox {
    let d1: LeadgenFakeD1
    private(set) var d1StatementsAtDraft: [Int] = []
    init(d1: LeadgenFakeD1) { self.d1 = d1 }
    func createDraft(account: String, rawMIME: String) async throws -> String {
        let d1 = self.d1
        return try await LeadgenTestClock.within {
            let count = await d1.statementCount()
            return await self.note(count)
        }
    }

    private func note(_ count: Int) -> String {
        d1StatementsAtDraft.append(count)
        return "r-draft-1"
    }
}

actor LeadgenRefusingMailbox: LeadgenDraftMailbox {
    func createDraft(account: String, rawMIME: String) async throws -> String {
        try await LeadgenTestClock.within { throw LeadgenError.fetchFailed("draft") }
    }
}

/// Counts how often the CLI asked for live adapters (it must not in dry-run or on refusal).
final class LeadgenDepsProbe: @unchecked Sendable {
    var calls = 0
    let deps: LeadgenLiveDeps
    init(deps: LeadgenLiveDeps) { self.deps = deps }
    func make(_ c: LeadgenLocalConfig) throws -> LeadgenLiveDeps { calls += 1; return deps }
}

/// In-memory stand-in for the two Project Control D1 databases: tables with rows and a schema line each.
actor LeadgenFakeD1: LeadgenD1Port {
    var tables: [String: [String: [[String: String]]]] = [:]
    var schemas: [String: [String: String]] = [:]
    private(set) var statements: [(db: String, sql: String)] = []
    var tamperRows = false, tamperSchema = false
    var failInsertDatabase: String?

    init(withLeads: Bool = false) {
        for (db, prefix) in [(LeadgenProjectTarget.meCom.databaseID, "me"), (LeadgenProjectTarget.pharos.databaseID, "ph")] {
            tables[db] = [
                "projects": (1...3).map { ["id": "\(prefix)-\($0)", "title": "Existing \($0)", "status": "Active"] },
                "notes": [["id": "\(prefix)-n1", "body": "note"]],
            ]
            schemas[db] = ["projects": "CREATE TABLE projects (id TEXT PRIMARY KEY, title TEXT, status TEXT)", "notes": "CREATE TABLE notes (id TEXT PRIMARY KEY, body TEXT)"]
            if withLeads { tables[db]?["leads"] = []; schemas[db]?["leads"] = LeadgenMigration.createLeads }
        }
    }

    func setTamper(rows: Bool, schema: Bool) { tamperRows = rows; tamperSchema = schema }
    func setFailInsert(_ db: String?) { failInsertDatabase = db }
    func occupyProject(_ db: String, domain: String) {
        tables[db]?["projects"]?.append(["id": "p-occupied", "title": "Occupied", "status": "Active", "domain": domain])
    }
    func occupyLead(_ db: String, site: String) {
        installLeads(db)
        tables[db]?["leads"]?.append(["id": "l-occupied", "site": site, "organization": "Already"])
    }
    func installLeads(_ db: String) {
        tables[db]?["leads"] = []
        schemas[db]?["leads"] = LeadgenMigration.createLeads
    }
    func inserts() -> [(db: String, sql: String)] { statements.filter { $0.sql.hasPrefix("INSERT") } }
    func statementCount() -> Int { statements.count }
    func rows(_ db: String, _ table: String) -> [[String: String]] { tables[db]?[table] ?? [] }

    func query(database db: String, sql: String, params: [String]) async throws -> [[String: String]] {
        try await LeadgenTestClock.within { try await self.answer(database: db, sql: sql, params: params) }
    }

    private func answer(database db: String, sql: String, params: [String]) throws -> [[String: String]] {
        statements.append((db, sql))
        if sql == LeadgenD1Writer.tablesSQL {
            return (schemas[db] ?? [:]).keys.sorted().map { ["name": $0, "sql": schemas[db]?[$0] ?? ""] }
        }
        if sql == LeadgenMigration.createLeads {
            if tables[db]?["leads"] == nil { tables[db]?["leads"] = []; schemas[db]?["leads"] = sql }
            return []
        }
        if sql == LeadgenD1Writer.countSQL {
            if failInsertDatabase == db { throw LeadgenError.fetchFailed("precheck \(db)") }
            return [["n": "\(tables[db]?["leads"]?.count ?? 0)"]]
        }
        if sql == LeadgenD1Writer.readBackSQL {
            return (tables[db]?["leads"] ?? []).filter { $0["id"] == params.first }.map { r in r.filter { ["id", "organization", "status"].contains($0.key) } }
        }
        if sql.hasPrefix("SELECT * FROM ") {
            let name = sql.dropFirst("SELECT * FROM ".count).replacingOccurrences(of: "\"", with: "")
            return tables[db]?[name] ?? []
        }
        if sql == "SELECT domain FROM projects" {
            return (tables[db]?["projects"] ?? []).map { ["domain": $0["domain"] ?? ""] }
        }
        if sql == "SELECT site FROM leads" {
            return (tables[db]?["leads"] ?? []).map { ["site": $0["site"] ?? ""] }
        }
        if sql.hasPrefix("INSERT INTO leads (") {
            let open = sql.firstIndex(of: "(")!, close = sql.firstIndex(of: ")")!
            let cols = sql[sql.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var row: [String: String] = [:]
            for (c, v) in zip(cols, params) { row[c] = v }
            tables[db]?["leads"]?.append(row)
            if tamperRows { tables[db]?["projects"]?[0]["title"] = "changed behind our back" }
            if tamperSchema { schemas[db]?["notes"] = "CREATE TABLE notes (id TEXT PRIMARY KEY, body TEXT, extra TEXT)" }
            return []
        }
        tables[db]?["projects"] = []
        return []
    }
}

/// NFD UTF-8 of the full footer line. The plaintext address is not in this file.
enum LeadgenFooterFixture {
    static let nfdUTF8: [UInt8] = [80, 72, 65, 82, 79, 83, 32, 65, 73, 44, 32, 50, 52, 53, 54, 32, 114, 117, 101, 32, 100, 101, 32, 82, 111, 117, 101, 110, 44, 32, 77, 111, 110, 116, 114, 101, 204, 129, 97, 108, 32, 81, 67, 32, 72, 50, 75, 32, 49, 77, 50]
    static var configured: String { String(decoding: nfdUTF8, as: UTF8.self) }
}

enum LeadgenFixture {
    static let site = URL(string: "https://www.cliniqueexemple.ca/")!
    static let directory = URL(string: "https://dpq.quebec/repertoire-des-membres")!
    static let directoryHTML = """
    <html><body><h1>Cliniques de Montréal</h1>
    <p><a href="https://maps.google.com/maps?q=clinique">carte</a></p>
    <ul><li><a href="https://www.cliniqueexemple.ca/">Clinique Exemple</a></li></ul>
    </body></html>
    """
    static let prospect = LeadgenProspect(organization: "Clinique Exemple", segment: "montreal-clinics", site: site, publicContactEmail: "info@cliniqueexemple.ca")
    static let consent = LeadgenConsentBasis(basis: "CASL s.10(9)(b) conspicuous publication; Loi 25 public business contact", source: "https://www.cliniqueexemple.ca/contact", recordedAt: "2026-10-24T20:00:00Z")
    static let postal = LeadgenFooterFixture.configured
    static let paths = ["/", "/services", "/contact"]
    static let home = """
    <html><head><style>.x{}</style></head><body><nav>Accueil Services</nav>
    <main><h1>Clinique Exemple</h1><p>Soins de première ligne à Montréal. Depuis 2025, nous utilisons un outil d'intelligence artificielle pour trier les demandes de rendez-vous et résumer les notes cliniques.</p></main>
    <footer><a href="/confidentialite">Politique de confidentialité</a> intelligence artificielle</footer></body></html>
    """
    static let footerOnly = """
    <html><body><main><p>Bienvenue à la clinique, prenez rendez-vous en ligne avec nos médecins.</p></main>
    <footer><a href="/confidentialite">Politique de confidentialité et utilisation de l'intelligence artificielle par nos partenaires</a></footer></body></html>
    """
    static func fetcher(home body: String = home, robots: String = "User-agent: *\nDisallow: /admin\n") -> LeadgenFakeFetcher {
        LeadgenFakeFetcher(pages: [
            "https://www.cliniqueexemple.ca/robots.txt": (200, robots),
            "https://www.cliniqueexemple.ca/": (200, body),
            "https://www.cliniqueexemple.ca/services": (200, "<html><body><main><p>Médecine familiale et pédiatrie.</p></main></body></html>"),
            "https://www.cliniqueexemple.ca/contact": (200, "<html><body><main><p>Écrivez à info@cliniqueexemple.ca pour nous joindre.</p></main></body></html>"),
            "https://dpq.quebec/robots.txt": (200, "User-agent: *\nAllow: /\n"),
            "https://dpq.quebec/repertoire-des-membres": (200, directoryHTML),
        ])
    }
    static func pages() -> [LeadgenPage] {
        [
            LeadgenPage(url: site, bodyText: LeadgenHTML.bodyText(home), html: home),
            LeadgenPage(url: URL(string: "https://www.cliniqueexemple.ca/contact")!, bodyText: "Écrivez à info@cliniqueexemple.ca pour nous joindre.", html: ""),
        ]
    }
    static let liveConfig = LeadgenRunConfig.from(arguments: ["--live"], environment: ["LEADGEN_OPERATOR_OK": LeadgenRunConfig.confirmation])
    /// An empty do-not-contact file, so tests that are not about suppression can still draft.
    static func allowEmptySuppression() {
        if getenv("LEADGEN_SUPPRESSION") != nil { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("leadgen-sup-empty.json")
        if !FileManager.default.fileExists(atPath: url.path) { try? Data("[]".utf8).write(to: url) }
        setenv("LEADGEN_SUPPRESSION", url.path, 0)
    }
    static func runner(_ config: LeadgenRunConfig, mailbox: LeadgenRecordingMailbox, d1: LeadgenFakeD1, log: LeadgenMemoryLog = LeadgenMemoryLog(), fetcher: LeadgenFakeFetcher = fetcher()) -> LeadgenSliceRunner {
        allowEmptySuppression()
        return LeadgenSliceRunner(config: config, fetcher: fetcher, mailbox: mailbox, d1: d1, log: log, now: { "2026-10-24T20:30:00Z" }, dns: LeadgenMappedDNS())
    }
    static let row = LeadgenLeadRow(id: "lead-x", organization: "X", site: "https://x.ca/", fitReason: "r", fitEvidence: "e", draftRef: "d", consentBasis: "c", createdAt: "2026-10-24T20:30:00Z")
    static func live(_ d1: LeadgenFakeD1, _ mailbox: LeadgenRecordingMailbox = LeadgenRecordingMailbox(), log: LeadgenMemoryLog = LeadgenMemoryLog()) async throws -> LeadgenRunReport {
        try await runner(liveConfig, mailbox: mailbox, d1: d1, log: log).run(candidates: [prospect], paths: paths, consent: consent, postalAddress: postal)
    }
    static func tempConfig(postal: String? = postal, directory: String? = nil) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("leadgen-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var obj: [String: Any] = [
            "prospect": ["organization": prospect.organization, "site": site.absoluteString, "publicContactEmail": prospect.publicContactEmail],
            "paths": paths,
            "consent": ["basis": consent.basis, "source": consent.source, "recordedAt": consent.recordedAt],
        ]
        if let postal { obj["postalAddress"] = postal }
        if let directory { obj["directoryURL"] = directory }
        let url = dir.appendingPathComponent("leadgen.local.json")
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        return url.path
    }
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static func fit() throws -> LeadgenFit {
        let pages = [LeadgenPage(url: site, bodyText: LeadgenHTML.bodyText(home))]
        return try LeadgenFitFinder.find(pages: pages, prospect: prospect)
    }
    /// Directory holding docs/leadgen-slice/migrations, found from this file's path.
    static var migrationsDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/leadgen-slice/migrations")
    }
    /// Fictional DPQ fiche page. No live fetch, and no real member is in this file.
    /// Pages for the fake domain used by the trimmed DPQ fixture.
    static func withOwnSite(_ fetcher: LeadgenFakeFetcher, host: String, contact: String) -> LeadgenFakeFetcher {
        let origin = "https://\(host)"
        fetcher.set("\(origin)/robots.txt", status: 200, body: "User-agent: *\nDisallow: /admin\n")
        fetcher.set("\(origin)/", status: 200, body: home)
        fetcher.set("\(origin)/services", status: 200, body: "<html><body><main><p>Médecine familiale et pédiatrie.</p></main></body></html>")
        fetcher.set("\(origin)/contact", status: 200, body: contact)
        return fetcher
    }
    static func loadDPQ(_ fetcher: LeadgenFakeFetcher) throws {
        let html = try dpqHTML()
        fetcher.set(directory.absoluteString, status: 200, body: html)
        fetcher.set(directory.absoluteString + "/", status: 200, body: html)
    }
    static func withDPQSite(_ fetcher: LeadgenFakeFetcher, contact: String = "<html><body><main><p>Écrivez à info@example-clinic-1.test pour nous joindre.</p></main></body></html>") -> LeadgenFakeFetcher {
        let origin = "https://example-clinic-1.test"
        fetcher.set("\(origin)/robots.txt", status: 200, body: "User-agent: *\nDisallow: /admin\n")
        fetcher.set("\(origin)/", status: 200, body: home)
        fetcher.set("\(origin)/services", status: 200, body: "<html><body><main><p>Médecine familiale et pédiatrie.</p></main></body></html>")
        fetcher.set("\(origin)/contact", status: 200, body: contact)
        return fetcher
    }
    static func dpqHTML() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dpq-repertoire.html")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

#if os(macOS)
/// One-shot HTTPS listener on 127.0.0.1. The certificate's SAN is `pinned.leadgen.test`.
final class LeadgenLocalTLSServer: @unchecked Sendable {
    let root: URL
    let caDER: URL
    private let p12: URL
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "leadgen.tls.server")
    private(set) var port: UInt16 = 0

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("leadgen-tls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        caDER = root.appendingPathComponent("ca.der")
        p12 = root.appendingPathComponent("server.p12")
        try Self.issue(in: root, caDER: caDER, p12: p12)
    }

    func start() async throws {
        let identity = try Self.identity(p12: p12, password: "leadgen-test")
        guard let secIdentity = sec_identity_create(identity) else {
            throw PortableCheckFailure(description: "the test server identity could not be created")
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let listener = try NWListener(using: params, on: 0)
        self.listener = listener
        let ready = OnceResume()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.succeed()
            case .failed(let error): ready.fail(error)
            case .cancelled: ready.fail(PortableCheckFailure(description: "TLS listener cancelled"))
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                let body = "pinned-ok"
                let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 20) {
            ready.fail(PortableCheckFailure(description: "TLS listener timed out"))
        }
        try await ready.wait()
        guard let assigned = listener.port?.rawValue, assigned != 0 else {
            throw PortableCheckFailure(description: "TLS listener did not bind a port")
        }
        port = assigned
    }

    func stop() {
        listener?.cancel()
        try? FileManager.default.removeItem(at: root)
    }

    private static func issue(in dir: URL, caDER: URL, p12: URL) throws {
        let caConf = """
        [req]
        distinguished_name = dn
        x509_extensions = v3
        prompt = no
        [dn]
        CN = Leadgen Test CA
        [v3]
        basicConstraints = critical,CA:TRUE
        keyUsage = critical,keyCertSign,cRLSign
        """
        let serverConf = """
        [req]
        distinguished_name = dn
        req_extensions = v3
        prompt = no
        [dn]
        CN = pinned.leadgen.test
        [v3]
        basicConstraints = critical,CA:FALSE
        keyUsage = digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = DNS:pinned.leadgen.test
        """
        let caPath = dir.appendingPathComponent("ca.cnf")
        let serverPath = dir.appendingPathComponent("server.cnf")
        try caConf.write(to: caPath, atomically: true, encoding: .utf8)
        try serverConf.write(to: serverPath, atomically: true, encoding: .utf8)
        let openssl = "/usr/bin/openssl"
        try run(openssl, ["req", "-x509", "-newkey", "rsa:2048", "-keyout", dir.appendingPathComponent("ca.key").path, "-out", dir.appendingPathComponent("ca.crt").path, "-days", "1", "-nodes", "-config", caPath.path], in: dir)
        try run(openssl, ["req", "-newkey", "rsa:2048", "-keyout", dir.appendingPathComponent("server.key").path, "-out", dir.appendingPathComponent("server.csr").path, "-nodes", "-config", serverPath.path], in: dir)
        try run(openssl, ["x509", "-req", "-in", dir.appendingPathComponent("server.csr").path, "-CA", dir.appendingPathComponent("ca.crt").path, "-CAkey", dir.appendingPathComponent("ca.key").path, "-CAcreateserial", "-out", dir.appendingPathComponent("server.crt").path, "-days", "1", "-extfile", serverPath.path, "-extensions", "v3"], in: dir)
        try run(openssl, ["x509", "-in", dir.appendingPathComponent("ca.crt").path, "-outform", "DER", "-out", caDER.path], in: dir)
        try run(openssl, ["pkcs12", "-export", "-inkey", dir.appendingPathComponent("server.key").path, "-in", dir.appendingPathComponent("server.crt").path, "-certfile", dir.appendingPathComponent("ca.crt").path, "-out", p12.path, "-passout", "pass:leadgen-test"], in: dir)
    }

    private static func identity(p12: URL, password: String) throws -> SecIdentity {
        let data = try Data(contentsOf: p12)
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first, let identity = first[kSecImportItemIdentity as String] else {
            throw PortableCheckFailure(description: "PKCS12 import failed (\(status))")
        }
        return identity as! SecIdentity
    }

    private static func run(_ tool: String, _ args: [String], in dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw PortableCheckFailure(description: "\(tool) \(args.first ?? "") failed: \(text)")
        }
    }
}

private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func succeed() { finish(.success(())) }
    func fail(_ error: Error) { finish(.failure(error)) }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                cont.resume(with: result)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        if self.result != nil { lock.unlock(); return }
        self.result = result
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }
}
#endif

enum LeadgenSliceTests {
    static func ipv6Pin() throws {
        let page = URL(string: "https://www.cliniqueexemple.ca/contact")!
        let plan = LeadgenPinnedRequest.pin(url: page, addresses: ["2606:4700:4700::1111"])
        try check(plan?.url.host == "2606:4700:4700::1111", "IPv6 target \(String(describing: plan?.url))")
        try check(plan?.url.absoluteString.contains("[2606:4700:4700::1111]") == true, "IPv6 literal was not bracketed: \(plan?.url.absoluteString ?? "nil")")
        try check(plan?.hostHeader == "www.cliniqueexemple.ca", "original host was dropped")
    }

    #if os(macOS)
    /// Local TLS server whose certificate names `pinned.leadgen.test`, not the loopback address.
    static func pinnedTLS() async throws {
        let server = try LeadgenLocalTLSServer()
        try await server.start()
        defer { server.stop() }
        let ca = try Data(contentsOf: server.caDER)
        let good = URL(string: "https://pinned.leadgen.test:\(server.port)/pinned")!
        let wrong = URL(string: "https://other.leadgen.test:\(server.port)/pinned")!
        let fetcher = LeadgenHTTPFetcher(
            lookup: { _ in ["127.0.0.1"] },
            admitLoopbackForTests: true,
            testTrustAnchorDERs: [ca]
        )
        let fetched = try await fetcher.get(good)
        try check(fetched.status == 200 && fetched.body.contains("pinned-ok"), "live fetcher did not trust the hostname certificate: \(fetched.status) \(fetched.body)")
        var mismatched = false
        do { _ = try await fetcher.get(wrong) } catch { mismatched = true }
        try check(mismatched, "a certificate for a different hostname was accepted by the live fetcher")
        var transport = URLSessionLeadTransport()
        transport.lookup = { _ in ["127.0.0.1"] }
        transport.admitLoopbackForTests = true
        transport.testTrustAnchorDERs = [ca]
        let sent = try await transport.send(URLRequest(url: good))
        let text = String(decoding: sent.body, as: UTF8.self)
        try check(sent.status == 200 && text.contains("pinned-ok"), "pipeline transport did not trust the hostname certificate: \(sent.status) \(text)")
        var transportMismatch = false
        do { _ = try await transport.send(URLRequest(url: wrong)) } catch { transportMismatch = true }
        try check(transportMismatch, "a certificate for a different hostname was accepted by the pipeline transport")
    }
    #endif

    static func readPolicy() -> LeadgenDeclaredPolicy {
        LeadgenDeclaredPolicy(tokens: [
            LeadgenDeclaredToken(id: "id-me", env: LeadgenTokenProof.readTokenEnvs[0], permissions: [LeadgenDeclaredPermission(id: LeadgenTokenProof.d1ReadPermissionGroupID, name: LeadgenTokenProof.d1ReadPermissionGroupName, accountID: LeadgenTokenProof.accountIDs[0])]),
            LeadgenDeclaredToken(id: "id-ph", env: LeadgenTokenProof.readTokenEnvs[1], permissions: [LeadgenDeclaredPermission(id: LeadgenTokenProof.d1ReadPermissionGroupID, name: LeadgenTokenProof.d1ReadPermissionGroupName, accountID: LeadgenTokenProof.accountIDs[1])]),
        ])
    }

    static func writeScopedPolicy() -> LeadgenDeclaredPolicy {
        LeadgenDeclaredPolicy(tokens: [
            LeadgenDeclaredToken(id: "id-me", env: LeadgenTokenProof.readTokenEnvs[0], permissions: [LeadgenDeclaredPermission(id: LeadgenTokenProof.d1WritePermissionGroupID, name: LeadgenTokenProof.d1WritePermissionGroupName, accountID: LeadgenTokenProof.accountIDs[0])]),
            LeadgenDeclaredToken(id: "id-ph", env: LeadgenTokenProof.readTokenEnvs[1], permissions: [LeadgenDeclaredPermission(id: LeadgenTokenProof.d1WritePermissionGroupID, name: LeadgenTokenProof.d1WritePermissionGroupName, accountID: LeadgenTokenProof.accountIDs[1])]),
        ])
    }

    static func activeVerification() -> [LeadgenVerifiedToken?] {
        [LeadgenVerifiedToken(id: "id-me", status: "active"), LeadgenVerifiedToken(id: "id-ph", status: "active")]
    }

    static func refuseToken(_ saved: LeadgenDeclaredPolicy?, _ verified: [LeadgenVerifiedToken?]) throws {
        do {
            try LeadgenTokenProof.admit(saved: saved, verified: verified)
            throw PortableCheckFailure(description: "token proof admitted a token it must refuse")
        } catch LeadgenError.tokenProof {
            return
        } catch let error as PortableCheckFailure {
            throw error
        } catch {
            throw PortableCheckFailure(description: "token proof failed as \(error)")
        }
    }

    static func emptyFetchedAtRefuses() async throws {
        LeadgenFixture.allowEmptySuppression()
        for clock in ["", "   "] {
            let mailbox = LeadgenRecordingMailbox(), d1 = LeadgenFakeD1()
            var refused = false
            do {
                _ = try await LeadgenSliceRunner(config: LeadgenFixture.liveConfig, fetcher: LeadgenFixture.fetcher(), mailbox: mailbox, d1: d1, log: LeadgenMemoryLog(), now: { clock }, dns: LeadgenMappedDNS()).run(
                    candidates: [LeadgenFixture.prospect], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal)
            } catch LeadgenError.missingFetchedAt {
                refused = true
            } catch {
                throw PortableCheckFailure(description: "empty fetchedAt failed as \(error)")
            }
            let calls = await mailbox.calls, inserts = await d1.inserts()
            try check(refused && calls.isEmpty && inserts.isEmpty, "fetch time \(clock.debugDescription) still drafted: calls \(calls) inserts \(inserts.count)")
        }
    }

    /// A double with no response must fail the case. It must not hold the suite past the bound.
    static func unconfiguredDoubleTimesOut() async throws {
        try check(LeadgenLiveHTTP.requestTimeout == 20 && LeadgenLiveHTTP.resourceTimeout == 20, "live token, D1, or Gmail can outlive the run")
        let started = ContinuousClock.now
        do {
            _ = try await LeadgenTestClock.within(1) {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return "late"
            }
            throw PortableCheckFailure(description: "a double with no response returned")
        } catch let error as PortableCheckFailure where error.description == "test double timed out" {
            let elapsed = ContinuousClock.now - started
            try check(elapsed < .seconds(15), "the suite waited on the double: \(elapsed)")
        }
    }

    static func suppressionFailsClosed() async throws {
        func refuse(path: String?) async throws {
            if let path { setenv("LEADGEN_SUPPRESSION", path, 1) } else { unsetenv("LEADGEN_SUPPRESSION") }
            let mailbox = LeadgenRecordingMailbox(), d1 = LeadgenFakeD1()
            let runner = LeadgenSliceRunner(config: LeadgenFixture.liveConfig, fetcher: LeadgenFixture.fetcher(), mailbox: mailbox, d1: d1, log: LeadgenMemoryLog(), now: { "2026-10-24T20:30:00Z" }, dns: LeadgenMappedDNS())
            var refused = false
            do {
                _ = try await runner.run(candidates: [LeadgenFixture.prospect], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal)
            } catch { refused = true }
            let calls = await mailbox.calls, inserts = await d1.inserts()
            try check(refused && calls.isEmpty && inserts.isEmpty, "do-not-contact failure still drafted (\(path ?? "unset")): calls \(calls) inserts \(inserts.count)")
        }
        unsetenv("LEADGEN_SUPPRESSION")
        try await refuse(path: nil)
        try await refuse(path: "")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("leadgen-missing-\(UUID().uuidString).json").path
        try await refuse(path: missing)
        try await refuse(path: FileManager.default.temporaryDirectory.path)
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("leadgen-bad-\(UUID().uuidString).json")
        try Data("not-json".utf8).write(to: bad)
        defer { unsetenv("LEADGEN_SUPPRESSION"); try? FileManager.default.removeItem(at: bad) }
        try await refuse(path: bad.path)
    }

    static func suppressionMatchesNormalized() async throws {
        func blocked(_ address: String) async throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("leadgen-norm-\(UUID().uuidString).json")
            let json = "[{\"address\":\(address.debugDescription),\"at\":\"2026-01-01T00:00:00Z\",\"via\":\"list\"}]"
            try json.write(to: file, atomically: true, encoding: .utf8)
            setenv("LEADGEN_SUPPRESSION", file.path, 1)
            defer { unsetenv("LEADGEN_SUPPRESSION"); try? FileManager.default.removeItem(at: file) }
            let mailbox = LeadgenRecordingMailbox(), d1 = LeadgenFakeD1()
            var refused = false
            do {
                _ = try await LeadgenSliceRunner(config: LeadgenFixture.liveConfig, fetcher: LeadgenFixture.fetcher(), mailbox: mailbox, d1: d1, log: LeadgenMemoryLog(), now: { "2026-10-24T20:30:00Z" }, dns: LeadgenMappedDNS()).run(
                    candidates: [LeadgenFixture.prospect], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal)
            } catch { refused = true }
            let calls = await mailbox.calls, inserts = await d1.inserts()
            try check(refused && calls.isEmpty && inserts.isEmpty, "\(address) still drafted: calls \(calls) inserts \(inserts.count)")
        }
        try await blocked(" Info@CliniqueExemple.CA ")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("leadgen-domain-\(UUID().uuidString).json")
        try "[{\"address\":\"cliniqueexemple.ca\",\"at\":\"2026-01-01T00:00:00Z\",\"via\":\"list\"}]".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let list = try SuppressionList.requireFile(at: file)
        let covered = LeadgenSuppression.reason(address: "info@team.cliniqueexemple.ca", siteHost: "team.cliniqueexemple.ca", list: list)
        try check(covered?.contains("cliniqueexemple.ca") == true, "a domain entry did not cover the subdomain: \(covered ?? "nil")")
        let parentFile = FileManager.default.temporaryDirectory.appendingPathComponent("leadgen-parent-\(UUID().uuidString).json")
        try "[{\"address\":\"exemple.ca\",\"at\":\"2026-01-01T00:00:00Z\",\"via\":\"list\"}]".write(to: parentFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: parentFile) }
        let parent = try SuppressionList.requireFile(at: parentFile)
        try check(LeadgenSuppression.reason(address: "info@cliniqueexemple.ca", siteHost: "www.cliniqueexemple.ca", list: parent) == nil, "a suffix without a dot boundary matched")
    }

    /// Directory cards are discovery only. Maps, search, and aggregator links are not a clinic site.
    static func dpqOwnSiteOnly() async throws {
        let html = try LeadgenFixture.dpqHTML()
        let directory = URL(string: "https://dpq.quebec/repertoire-des-membres/")!
        let clinics = LeadgenDiscovery.clinics(in: html, directory: directory)
        try check(clinics.count == 6, "DPQ fiches became \(clinics.count) clinics: \(clinics.map(\.name))")
        try check(clinics.first?.name == "Example Clinic 1", "clinic name came from the link text, not the fiche: \(clinics.first?.name ?? "none")")
        try check(LeadgenSourcePolicy.normalize(clinics.first?.site.host ?? "") == "example-clinic-1.test", "own site \(String(describing: clinics.first?.site))")
        try check(clinics.allSatisfy { site in
            let host = (site.site.host ?? "").lowercased()
            return !host.contains("google") && !host.contains("pagesjaunes") && !host.contains("maps")
        }, "a maps or aggregator link was kept: \(clinics)")
        let fetcher = LeadgenFixture.withDPQSite(LeadgenFixture.fetcher())
        fetcher.set(directory.absoluteString, status: 200, body: html)
        fetcher.set("https://dpq.quebec/repertoire-des-membres", status: 200, body: html)
        let found = try await LeadgenDiscovery.find(directory: directory, paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, fetcher: fetcher, dns: LeadgenMappedDNS())
        let reflected = String(reflecting: found.prospect)
        try check(reflected.contains("Alex Exemple"), "dentist name was not kept: \(reflected)")
        try check(!reflected.contains("Noel Exemple") && !reflected.contains("Camille Exemple") && !reflected.contains("Example Clinic Maps"), "a maps-only or duplicate entry was kept: \(reflected)")
        try check(!fetcher.requested.contains { $0.contains("google") || $0.contains("maps") || $0.contains("pagesjaunes") }, "a maps or aggregator URL was fetched: \(fetcher.requested)")
    }

    /// The saved fixture is a trimmed copy of the real DPQ page, with the fetch time and the original sha256, and no real member data.
    static func dpqRealFixture() throws {
        let html = try LeadgenFixture.dpqHTML()
        try check(html.contains("fetched: 2026-10-25T00:20:11Z"), "fixture header has no fetch time of the real page")
        try check(html.contains("sha256: 6d9b82dc0518d93a627cbd7476e376448b7209363e83c351d8b5999fad5880ce"), "fixture header has no sha256 of the original page")
        try check(html.contains("class=\"dpqr-grille\"") && html.contains("dpqr-fiche__corps") && html.contains("dpqr-bouton"), "fixture is not the DPQ fiche markup")
        let ownHrefs = html.components(separatedBy: "example-clinic-1.test").count - 1
        try check(ownHrefs >= 2, "fixture does not contain two entries on one domain: \(ownHrefs)")
        let directory = URL(string: "https://dpq.quebec/repertoire-des-membres/")!
        let clinics = LeadgenDiscovery.clinics(in: html, directory: directory)
        try check(clinics.count == 6, "shared-domain fiches were not one prospect, or a domain was dropped: \(clinics.map(\.name))")
        for n in 1...6 {
            try check(clinics.contains { LeadgenSourcePolicy.normalize($0.site.host ?? "") == "example-clinic-\(n).test" }, "missing example-clinic-\(n).test: \(clinics.map(\.site.host))")
        }
        try check(clinics.first?.name == "Example Clinic 1", "clinic \(clinics.first?.name ?? "none")")
        try check(LeadgenSourcePolicy.normalize(clinics.first?.site.host ?? "") == "example-clinic-1.test", "own site \(String(describing: clinics.first?.site))")
        try check(html.contains("google.com/maps"), "fixture has no Maps entry")
        try check(clinics.allSatisfy { !($0.site.host ?? "").contains("google") }, "a Maps entry was kept")
        let reflected = clinics.map { "\($0.dentist) \($0.name)" }.joined(separator: " ")
        try check(reflected.contains("Alex Exemple") && !reflected.contains("Camille Exemple") && !reflected.contains("Noel Exemple"), "dedup kept the wrong fiche: \(reflected)")
    }

    /// The address is an allowlisted role local-part on the clinic's domain or a subdomain of it. A personal address, no role address, or no-solicitation wording refuses the entry.
    static func roleEmailOnly() async throws {
        func discover(contact: String) async throws -> LeadgenDiscoveryResult {
            let fetcher = LeadgenFixture.fetcher()
            let html = "<html><body><a href=\"https://www.cliniqueexemple.ca/\">Clinique Exemple</a></body></html>"
            fetcher.set(LeadgenFixture.directory.absoluteString, status: 200, body: html)
            fetcher.set("https://www.cliniqueexemple.ca/contact", status: 200, body: contact)
            return try await LeadgenDiscovery.find(directory: LeadgenFixture.directory, paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, fetcher: fetcher, dns: LeadgenMappedDNS())
        }
        let both = """
        <html><body><main>
        <p>Marie Tremblay marie.tremblay@cliniqueexemple.ca</p>
        <p>Réception info@cliniqueexemple.ca</p>
        </main></body></html>
        """
        let picked = try await discover(contact: both)
        try check(picked.prospect.publicContactEmail == "info@cliniqueexemple.ca", "a personal address was chosen: \(picked.prospect.publicContactEmail)")
        let personal = "<html><body><main><p>Écrivez à marie.tremblay@cliniqueexemple.ca.</p></main></body></html>"
        try await expectError(.noRoleAddress("Clinique Exemple")) { _ = try await discover(contact: personal) }
        let subdomain = "<html><body><main><p>Écrivez à info@mail.cliniqueexemple.ca.</p></main></body></html>"
        let sub = try await discover(contact: subdomain)
        try check(sub.prospect.publicContactEmail == "info@mail.cliniqueexemple.ca", "a role address on a subdomain was dropped: \(sub.prospect.publicContactEmail)")
        let french = "<html><body><main><p>Écrivez à administration@cliniqueexemple.ca.</p></main></body></html>"
        let admin = try await discover(contact: french)
        try check(admin.prospect.publicContactEmail == "administration@cliniqueexemple.ca", "administration@ was dropped: \(admin.prospect.publicContactEmail)")
        try await expectError(.noRoleAddress("Clinique Exemple")) {
            _ = try await discover(contact: "<html><body><main><p>Écrivez à info@exemple.ca.</p></main></body></html>")
        }
        for phrase in ["pas de sollicitation", "aucune sollicitation", "No Solicitation"] {
            let page = "<html><body><main><p>Écrivez à info@cliniqueexemple.ca.</p><p>\(phrase).</p></main></body></html>"
            do {
                _ = try await discover(contact: page)
                throw PortableCheckFailure(description: "accepted a page that says \(phrase)")
            } catch let error as LeadgenError {
                guard case .suppressed(let why) = error else { throw PortableCheckFailure(description: "\(phrase) threw \(error)") }
                try check(why.lowercased().contains("sollicit") || why.lowercased().contains("solicit"), "reason did not name the wording: \(why)")
            } catch is PortableCheckFailure {
                throw PortableCheckFailure(description: "accepted a page that says \(phrase)")
            }
        }
        try await expectError(.noRoleAddress("Clinique Exemple")) {
            _ = try await discover(contact: "<html><body><main><p>Écrivez-nous par le formulaire. info chez cliniqueexemple.ca</p></main></body></html>")
        }
    }

    /// Two evidence lines on the lead row: the DPQ page and the clinic page where the address was published, each with the clock time of that fetch.
    static func directoryEvidenceRow() async throws {
        final class Clock: @unchecked Sendable {
            var n = 0
            func next() -> String { n += 1; return String(format: "2026-10-24T21:%02d:00Z", n) }
        }
        let clock = Clock()
        let html = try LeadgenFixture.dpqHTML()
        let fetcher = LeadgenFixture.withDPQSite(LeadgenFixture.fetcher())
        fetcher.set(LeadgenFixture.directory.absoluteString, status: 200, body: html)
        LeadgenFixture.allowEmptySuppression()
        let d1 = LeadgenFakeD1()
        let runner = LeadgenSliceRunner(
            config: LeadgenFixture.liveConfig, fetcher: fetcher, mailbox: LeadgenRecordingMailbox(), d1: d1,
            log: LeadgenMemoryLog(), now: { clock.next() }, dns: LeadgenMappedDNS())
        let report = try await runner.run(
            candidates: [], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent,
            postalAddress: LeadgenFixture.postal, directory: LeadgenFixture.directory)
        let evidence = await d1.rows(LeadgenProjectTarget.meCom.databaseID, "leads").first?["fit_evidence"] ?? ""
        let directoryURL = LeadgenFixture.directory.absoluteString
        try check(evidence.contains(directoryURL), "DPQ entry URL missing from the lead row: \(evidence)")
        try check(evidence.contains("\(directoryURL) | 2026-10-24T21:01:00Z"), "DPQ fetch time is not the clock time of that fetch: \(evidence)")
        try check(evidence.contains("https://example-clinic-1.test/contact | 2026-10-24T21:04:00Z"), "clinic page URL or its fetch time is missing: \(evidence)")
        try check(!evidence.contains(LeadgenFixture.consent.recordedAt), "the config time was stored in place of a fetch time: \(evidence)")
        try check(report.fit.evidence.allSatisfy { !$0.url.contains("dpq.quebec") }, "the fit quote used the directory: \(report.fit.evidence)")
        try check(report.draft.consent.source == "https://example-clinic-1.test/contact", "consent source \(report.draft.consent.source)")
    }

    /// The draft talks about the clinic's obligations, not about a person.
    static func clinicDraft() throws {
        let fit = try LeadgenFixture.fit()
        let draft = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, pages: LeadgenFixture.pages())
        let body = draft.body
        try check(body.contains(LeadgenFixture.prospect.organization), "the draft does not name the clinic: \(body)")
        try check(body.contains("Loi 25"), "the draft does not mention Loi 25")
        try check(body.localizedCaseInsensitiveContains("gouvernance") && body.contains("renseignements de santé"), "the draft is not about the clinic's AI governance and health-data obligations: \(body)")
        for banned in ["patients", "avec des patients", "uses AI with patients", "$", "prix", "avis juridique", "conforme", "Marie", "Bonjour Marie"] {
            try check(!body.localizedCaseInsensitiveContains(banned), "draft contains \(banned)")
        }
        try check(!body.contains(LeadgenFixture.prospect.publicContactEmail) && !body.localizedCaseInsensitiveContains("marie.tremblay"), "the draft names a person or the clinic mailbox: \(body)")
        try check(body.contains("désabonnement") && body.contains("unsubscribe") && body.contains("Martin Lepage, PhD"), "the existing footer was dropped")
        try check(!body.contains("\u{2014}") && !body.contains("\u{2013}"), "dash in draft")
    }

    /// The row keeps the clinic, the dentist, the role address, and the two source records. A rejection is logged and not deleted here.
    static func minimizedLead() async throws {
        final class Clock: @unchecked Sendable {
            var n = 0
            func next() -> String { n += 1; return String(format: "2026-10-24T21:%02d:00Z", n) }
        }
        let html = try LeadgenFixture.dpqHTML()
        let contact = """
        <html><body><main>
        <p>camille.exemple@example-clinic-1.test</p>
        <p>info@example-clinic-1.test</p>
        </main></body></html>
        """
        func prepared() -> LeadgenFakeFetcher {
            let fetcher = LeadgenFixture.withDPQSite(LeadgenFixture.fetcher(), contact: contact)
            fetcher.set(LeadgenFixture.directory.absoluteString, status: 200, body: html)
            return fetcher
        }
        LeadgenFixture.allowEmptySuppression()
        let d1 = LeadgenFakeD1()
        let clock = Clock()
        _ = try await LeadgenSliceRunner(
            config: LeadgenFixture.liveConfig, fetcher: prepared(), mailbox: LeadgenRecordingMailbox(), d1: d1,
            log: LeadgenMemoryLog(), now: { clock.next() }, dns: LeadgenMappedDNS()
        ).run(candidates: [], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, directory: LeadgenFixture.directory)
        let row = await d1.rows(LeadgenProjectTarget.meCom.databaseID, "leads").first ?? [:]
        let stored = row.values.joined(separator: "\n")
        let directoryURL = LeadgenFixture.directory.absoluteString
        try check(stored.contains("Alex Exemple"), "dentist name was not stored: \(stored)")
        try check(stored.contains("Example Clinic 1"), "clinic name missing: \(stored)")
        try check(!stored.contains("Camille Exemple") && !stored.contains("Noel Exemple"), "a duplicate or maps-only name was stored: \(stored)")
        try check(stored.contains("info@example-clinic-1.test"), "role email missing: \(stored)")
        try check(stored.contains("\(directoryURL) | 2026-10-24T21:01:00Z"), "DPQ source record missing: \(stored)")
        try check(stored.contains("https://example-clinic-1.test/contact | 2026-10-24T21:04:00Z"), "clinic source record missing: \(stored)")
        try check(!stored.contains("camille.exemple@"), "a personal mailbox was stored: \(stored)")
        try check(!stored.localizedCaseInsensitiveContains("rue exemple"), "a street address was stored: \(stored)")
        try check(!stored.contains("google.com/maps") && !stored.contains("maps.google"), "a maps link was stored: \(stored)")
        let kept = await d1.statements
        try check(kept.allSatisfy { !$0.sql.uppercased().contains("DELETE") }, "a purge was sent: \(kept.map(\.sql))")

        let refusedContact = "<html><body><main><p>info@example-clinic-1.test</p><p>Aucune sollicitation.</p></main></body></html>"
        let refusedFetcher = LeadgenFixture.withDPQSite(LeadgenFixture.fetcher(), contact: refusedContact)
        refusedFetcher.set(LeadgenFixture.directory.absoluteString, status: 200, body: html)
        let d2 = LeadgenFakeD1(), log = LeadgenMemoryLog()
        do {
            _ = try await LeadgenSliceRunner(
                config: LeadgenFixture.liveConfig, fetcher: refusedFetcher, mailbox: LeadgenRecordingMailbox(), d1: d2,
                log: log, now: { "2026-10-24T21:00:00Z" }, dns: LeadgenMappedDNS()
            ).run(candidates: [], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, directory: LeadgenFixture.directory)
            throw PortableCheckFailure(description: "a no-solicitation entry was drafted")
        } catch is PortableCheckFailure {
            throw PortableCheckFailure(description: "a no-solicitation entry was drafted")
        } catch {}
        let lines = await log.lines, inserts = await d2.inserts(), refusedSQL = await d2.statements
        try check(lines.contains { $0.contains("suppressed:") }, "rejection was not logged as suppressed: \(lines)")
        try check(inserts.isEmpty, "a rejected lead was stored: \(inserts.map(\.db))")
        try check(refusedSQL.allSatisfy { !$0.sql.uppercased().contains("DELETE") && !$0.sql.uppercased().contains("UPDATE") }, "rejection changed a row: \(refusedSQL.map(\.sql))")
        let root = LeadgenFixture.repoRoot
        let spec = try String(contentsOf: root.appendingPathComponent("docs/leadgen-slice/SPEC.md"), encoding: .utf8)
        let source = try String(contentsOf: root.appendingPathComponent("native-crm/Sources/FollowUpOSNative/LeadgenSlice.swift"), encoding: .utf8)
        try check(spec.contains("TODO: Martin purges") || source.contains("TODO: Martin purges"), "purging the lead is not left as a TODO for Martin")
    }

    /// One fetch of the chosen DPQ page, robots first, the named User-Agent, and exactly one own-site prospect.
    static func dpqFetchOnce() async throws {
        let root = LeadgenFixture.repoRoot
        let example = try String(contentsOf: root.appendingPathComponent("docs/leadgen-slice/leadgen.local.example.json"), encoding: .utf8)
        let parsed = try JSONDecoder().decode(LeadgenLocalConfig.self, from: Data(example.utf8))
        let directory = URL(string: "https://dpq.quebec/repertoire-des-membres/")!
        try check(parsed.directoryURL == directory.absoluteString, "directoryURL is \(parsed.directoryURL ?? "nil")")
        final class Box: @unchecked Sendable { var agent: String? }
        let box = Box()
        let http = LeadgenHTTPFetcher(
            lookup: { _ in ["1.1.1.1"] },
            transport: { req in
                box.agent = req.value(forHTTPHeaderField: "User-Agent")
                return (200, [:], "ok")
            })
        _ = try await http.get(URL(string: "https://dpq.quebec/robots.txt")!)
        try check(box.agent == "PHAROS AI ControlWard (+https://pharos-ai.ca; ml@pharos-ai.ca)", "User-Agent \(box.agent ?? "missing")")
        let html = try LeadgenFixture.dpqHTML()
        let fetcher = LeadgenFixture.withDPQSite(LeadgenFixture.fetcher())
        fetcher.set(directory.absoluteString, status: 200, body: html)
        fetcher.set("https://dpq.quebec/repertoire-des-membres", status: 200, body: html)
        _ = try await LeadgenDiscovery.find(directory: directory, paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, fetcher: fetcher, dns: LeadgenMappedDNS())
        let hits = fetcher.requested.filter { $0 == directory.absoluteString }
        try check(hits.count == 1, "the DPQ page was fetched \(hits.count) times: \(fetcher.requested)")
        try check(fetcher.requested.first == "https://dpq.quebec/robots.txt", "robots.txt was not first: \(fetcher.requested)")
        try check(!fetcher.requested.dropFirst().contains("https://dpq.quebec/robots.txt"), "robots.txt was fetched again: \(fetcher.requested)")
        try check(!fetcher.requested.contains { $0.contains("google") || $0.contains("maps") || $0.contains("pagesjaunes") }, "a blocked URL was fetched: \(fetcher.requested)")
        let second = html.replacingOccurrences(of: "</body>", with: """
        <article class="dpqr-fiche"><h3 class="dpqr-nom">Jean Fictif</h3><p class="dpqr-clinique">Autre Clinique</p><a class="dpqr-bouton" href="https://www.autreclinique.ca/">Visiter le site Web</a></article>
        </body>
        """)
        let two = LeadgenFixture.fetcher()
        two.set(directory.absoluteString, status: 200, body: second)
        two.set("https://dpq.quebec/repertoire-des-membres", status: 200, body: second)
        try await expectError(.noRoleAddress("Example Clinic 1")) {
            _ = try await LeadgenDiscovery.find(directory: directory, paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, fetcher: two, dns: LeadgenMappedDNS())
        }
        let clinicHosts = Set(two.requested.compactMap { URL(string: $0)?.host }.filter { $0.contains("example-clinic-") || $0.contains("autreclinique") })
        try check(clinicHosts == Set(["example-clinic-1.test"]), "more than one prospect was fetched: \(two.requested)")
    }

    /// Fiche 1 is the first own-site card in page order. Later domains stay unfetched.
    static func picksFirstFiche() async throws {
        let fetcher = LeadgenFixture.withDPQSite(LeadgenFixture.fetcher())
        try LeadgenFixture.loadDPQ(fetcher)
        let directory = URL(string: "https://dpq.quebec/repertoire-des-membres/")!
        do {
            let found = try await LeadgenDiscovery.find(directory: directory, paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, fetcher: fetcher, dns: LeadgenMappedDNS())
            try check(found.prospect.organization == "Example Clinic 1", "picked \(found.prospect.organization) not fiche 1")
            try check(LeadgenSourcePolicy.normalize(found.prospect.site.host ?? "") == "example-clinic-1.test", "fiche 1 site \(found.prospect.site)")
        } catch let error as PortableCheckFailure {
            throw error
        } catch {
            throw PortableCheckFailure(description: "did not pick fiche 1: \(error)")
        }
        try check(!fetcher.requested.contains { $0.contains("example-clinic-2.test") }, "fiche 2 was fetched: \(fetcher.requested)")
    }

    /// The chosen site's failure stops the run. The next fiche is not fetched, and nothing is written.
    static func firstFicheFailureStops() async throws {
        let empty = "<html><body><main><p>Pas d'adresse publiée.</p></main></body></html>"
        let fetcher = LeadgenFixture.withDPQSite(LeadgenFixture.fetcher(), contact: empty)
        _ = LeadgenFixture.withOwnSite(fetcher, host: "example-clinic-2.test", contact: "<html><body><main><p>Écrivez à info@example-clinic-2.test pour nous joindre.</p></main></body></html>")
        try LeadgenFixture.loadDPQ(fetcher)
        let mailbox = LeadgenRecordingMailbox(), d1 = LeadgenFakeD1(), log = LeadgenMemoryLog()
        do {
            _ = try await LeadgenFixture.runner(LeadgenFixture.liveConfig, mailbox: mailbox, d1: d1, log: log, fetcher: fetcher).run(
                candidates: [], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, directory: LeadgenFixture.directory)
            throw PortableCheckFailure(description: "a failed fiche still drafted")
        } catch is PortableCheckFailure {
            throw PortableCheckFailure(description: "a failed fiche still drafted")
        } catch {}
        let hosts = Set(fetcher.requested.compactMap { URL(string: $0)?.host }.filter { $0.contains("example-clinic-") })
        try check(hosts == Set(["example-clinic-1.test"]), "expected one clinic-site fetch, got \(hosts) from \(fetcher.requested)")
        try check(!fetcher.requested.contains { $0.contains("example-clinic-2.test") }, "fiche 2's site was fetched: \(fetcher.requested)")
        let calls = await mailbox.calls, inserts = await d1.inserts(), statements = await d1.statements, lines = await log.lines
        try check(calls.isEmpty, "Gmail was called: \(calls)")
        try check(inserts.isEmpty, "a row was written: \(inserts.map(\.db))")
        try check(statements.allSatisfy { sql in
            let upper = sql.sql.uppercased()
            return !upper.contains("INSERT") && !upper.contains("UPDATE") && !upper.contains("DELETE")
        }, "a database was written: \(statements.map(\.sql))")
        try check(lines.contains { $0.contains("fiche 1") && $0.contains("refused") }, "the log did not name the refusal and the fiche position: \(lines)")
    }

    /// Success path: the log names fiche 1 and both source URLs.
    static func logNamesFicheAndEvidence() async throws {
        let fetcher = LeadgenFixture.withDPQSite(LeadgenFixture.fetcher())
        try LeadgenFixture.loadDPQ(fetcher)
        let log = LeadgenMemoryLog()
        do {
            _ = try await LeadgenFixture.runner(.dryRun, mailbox: LeadgenRecordingMailbox(), d1: LeadgenFakeD1(), log: log, fetcher: fetcher).run(
                candidates: [], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, directory: LeadgenFixture.directory)
        } catch {
            throw PortableCheckFailure(description: "did not record fiche 1: \(error)")
        }
        let lines = await log.lines
        try check(lines.contains { $0.contains("fiche 1") }, "log has no fiche position: \(lines)")
        try check(lines.contains { $0.contains("dpq.quebec/repertoire-des-membres") }, "log missed the directory evidence URL: \(lines)")
        try check(lines.contains { $0.contains("example-clinic-1.test/contact") }, "log missed the clinic evidence URL: \(lines)")
    }

    /// A domain stored in projects on either database, or in leads, is skipped before its site is fetched.
    static func recordedDomainSkipped() async throws {
        func skipped(_ prepare: (LeadgenFakeD1) async -> Void) async throws {
            let d1 = LeadgenFakeD1()
            await prepare(d1)
            let fetcher = LeadgenFixture.withDPQSite(LeadgenFixture.fetcher())
            _ = LeadgenFixture.withOwnSite(fetcher, host: "example-clinic-2.test", contact: "<html><body><main><p>Écrivez à info@example-clinic-2.test pour nous joindre.</p></main></body></html>")
            try LeadgenFixture.loadDPQ(fetcher)
            do {
                let report = try await LeadgenFixture.runner(.dryRun, mailbox: LeadgenRecordingMailbox(), d1: d1, log: LeadgenMemoryLog(), fetcher: fetcher).run(
                    candidates: [], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, directory: LeadgenFixture.directory)
                try check(report.prospect.organization == "Example Clinic 2", "did not skip the recorded domain: picked \(report.prospect.organization)")
            } catch let error as PortableCheckFailure {
                throw error
            } catch {
                throw PortableCheckFailure(description: "did not skip a domain already recorded: \(error)")
            }
            try check(!fetcher.requested.contains { $0.contains("example-clinic-1.test") }, "fiche 1 was fetched before the skip: \(fetcher.requested)")
            try check(fetcher.requested.contains { $0.contains("example-clinic-2.test") }, "fiche 2 was not fetched after the skip: \(fetcher.requested)")
        }
        try await skipped { await $0.occupyProject(LeadgenProjectTarget.meCom.databaseID, domain: "example-clinic-1.test") }
        try await skipped { await $0.occupyProject(LeadgenProjectTarget.pharos.databaseID, domain: "example-clinic-1.test") }
        try await skipped { await $0.occupyLead(LeadgenProjectTarget.meCom.databaseID, site: "https://www.example-clinic-1.test/") }
    }

    /// A site that publishes only a personal address on its own domain is not a prospect.
    static func personalAddressRefused() async throws {
        let fetcher = LeadgenFixture.fetcher()
        fetcher.set(LeadgenFixture.directory.absoluteString, status: 200, body: "<html><body><a href=\"https://www.cliniqueexemple.ca/\">Clinique Exemple</a></body></html>")
        fetcher.set("https://www.cliniqueexemple.ca/contact", status: 200, body: "<html><body><main><p>Écrivez à marie.tremblay@cliniqueexemple.ca.</p></main></body></html>")
        let mailbox = LeadgenRecordingMailbox(), d1 = LeadgenFakeD1(), log = LeadgenMemoryLog()
        do {
            _ = try await LeadgenFixture.runner(LeadgenFixture.liveConfig, mailbox: mailbox, d1: d1, log: log, fetcher: fetcher).run(
                candidates: [], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, directory: LeadgenFixture.directory)
            throw PortableCheckFailure(description: "a personal-only address was drafted")
        } catch is PortableCheckFailure {
            throw PortableCheckFailure(description: "a personal-only address was drafted")
        } catch {}
        let calls = await mailbox.calls, inserts = await d1.inserts(), statements = await d1.statements, lines = await log.lines
        try check(calls.isEmpty, "Gmail was called: \(calls)")
        try check(inserts.isEmpty, "a row was written: \(inserts.map(\.db))")
        try check(statements.allSatisfy { sql in
            let upper = sql.sql.uppercased()
            return !upper.contains("INSERT") && !upper.contains("UPDATE") && !upper.contains("DELETE")
        }, "a database was written: \(statements.map(\.sql))")
        try check(lines.contains { $0.contains("noRoleAddress") }, "the log did not name noRoleAddress: \(lines)")
    }

    /// The role check is the whole local-part. A longer token on the clinic's own domain is not a role address.
    static func longerLocalPartRefused() async throws {
        for local in ["info.drtremblay", "info.jtremblay", "clinique-jean", "contactjean"] {
            let address = "\(local)@cliniqueexemple.ca"
            let fetcher = LeadgenFixture.fetcher()
            fetcher.set(LeadgenFixture.directory.absoluteString, status: 200, body: "<html><body><a href=\"https://www.cliniqueexemple.ca/\">Clinique Exemple</a></body></html>")
            fetcher.set("https://www.cliniqueexemple.ca/contact", status: 200, body: "<html><body><main><p>Écrivez à \(address).</p></main></body></html>")
            let mailbox = LeadgenRecordingMailbox(), d1 = LeadgenFakeD1(), log = LeadgenMemoryLog()
            do {
                _ = try await LeadgenFixture.runner(LeadgenFixture.liveConfig, mailbox: mailbox, d1: d1, log: log, fetcher: fetcher).run(
                    candidates: [], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, directory: LeadgenFixture.directory)
                throw PortableCheckFailure(description: "a longer local-part was drafted: \(address)")
            } catch is PortableCheckFailure {
                throw PortableCheckFailure(description: "a longer local-part was drafted: \(address)")
            } catch {}
            let calls = await mailbox.calls, inserts = await d1.inserts(), statements = await d1.statements, lines = await log.lines
            try check(calls.isEmpty, "Gmail was called for \(address): \(calls)")
            try check(inserts.isEmpty, "a row was written for \(address): \(inserts.map(\.db))")
            try check(statements.allSatisfy { sql in
                let upper = sql.sql.uppercased()
                return !upper.contains("INSERT") && !upper.contains("UPDATE") && !upper.contains("DELETE")
            }, "a database was written for \(address): \(statements.map(\.sql))")
            try check(lines.contains { $0.contains("noRoleAddress") }, "the log did not name noRoleAddress for \(address): \(lines)")
        }
    }

    /// The allowlist is nine names. These locals are on the clinic's own domain and are still refused.
    static func extraRoleNamesRefused() async throws {
        for local in ["office", "hello", "appointments", "clinic", "secretariat", "secretaire", "bonjour"] {
            let address = "\(local)@cliniqueexemple.ca"
            let fetcher = LeadgenFixture.fetcher()
            fetcher.set(LeadgenFixture.directory.absoluteString, status: 200, body: "<html><body><a href=\"https://www.cliniqueexemple.ca/\">Clinique Exemple</a></body></html>")
            fetcher.set("https://www.cliniqueexemple.ca/contact", status: 200, body: "<html><body><main><p>Écrivez à \(address).</p></main></body></html>")
            let mailbox = LeadgenRecordingMailbox(), d1 = LeadgenFakeD1(), log = LeadgenMemoryLog()
            do {
                _ = try await LeadgenFixture.runner(LeadgenFixture.liveConfig, mailbox: mailbox, d1: d1, log: log, fetcher: fetcher).run(
                    candidates: [], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, directory: LeadgenFixture.directory)
                throw PortableCheckFailure(description: "an extra role name was drafted: \(address)")
            } catch is PortableCheckFailure {
                throw PortableCheckFailure(description: "an extra role name was drafted: \(address)")
            } catch {}
            let calls = await mailbox.calls, inserts = await d1.inserts(), statements = await d1.statements, lines = await log.lines
            try check(calls.isEmpty, "Gmail was called for \(address): \(calls)")
            try check(inserts.isEmpty, "a row was written for \(address): \(inserts.map(\.db))")
            try check(statements.allSatisfy { sql in
                let upper = sql.sql.uppercased()
                return !upper.contains("INSERT") && !upper.contains("UPDATE") && !upper.contains("DELETE")
            }, "a database was written for \(address): \(statements.map(\.sql))")
            try check(lines.contains { $0.contains("noRoleAddress") }, "the log did not name noRoleAddress for \(address): \(lines)")
        }
    }

    static func run() async -> Bool {
        LeadgenFixture.allowEmptySuppression()
        let head = await PortableCheck.suite("Lead-gen slice 1", headCases())
        let tail = await PortableCheck.suite("Lead-gen slice 1", tailCases())
        return head && tail
    }

    static func headCases() -> [(String, () async throws -> Void)] {
        [
            ("LG1 dry-run is the default and makes 0 Gmail and 0 D1 calls", {
                let config = LeadgenRunConfig.from(arguments: [], environment: [:])
                try check(!config.isLive && config == .dryRun, "default config is live")
                let mailbox = LeadgenRecordingMailbox(), d1 = LeadgenFakeD1()
                let report = try await LeadgenFixture.runner(config, mailbox: mailbox, d1: d1).run(candidates: [LeadgenFixture.prospect], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal)
                let calls = await mailbox.calls, statements = await d1.statements
                try check(!report.live && report.draftID == nil && report.receipts.isEmpty, "dry-run reported a live effect")
                try check(calls.isEmpty && statements.isEmpty, "dry-run touched Gmail \(calls.count)x, D1 \(statements.count)x")
            }),
            ("LG1 live needs both the --live flag and a recorded operator OK", {
                try check(!LeadgenRunConfig.from(arguments: ["--live"], environment: [:]).isLive, "--live without OK went live")
                try check(!LeadgenRunConfig.from(arguments: [], environment: ["LEADGEN_OPERATOR_OK": "yes"]).isLive, "OK without --live went live")
                try check(LeadgenFixture.liveConfig.isLive, "flag + OK not live")
                try check(!LeadgenRunConfig.from(arguments: ["--live", "--confirm", "yes"], environment: [:]).isLive, "a vague OK went live")
                try check(LeadgenRunConfig.from(arguments: ["--live", "--confirm", LeadgenRunConfig.confirmation], environment: [:]).isLive, "--confirm with the exact value not live")
                let mailbox = LeadgenRecordingMailbox(), d1 = LeadgenFakeD1()
                let noOK = LeadgenRunConfig.from(arguments: ["--live"], environment: [:])
                try await expectError(.liveNotAuthorized("no operator OK recorded")) {
                    _ = try await LeadgenFixture.runner(noOK, mailbox: mailbox, d1: d1).run(candidates: [LeadgenFixture.prospect], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal)
                }
                let calls = await mailbox.calls
                try check(calls.isEmpty, "refused live run still called Gmail")
            }),
            ("LG2 host allowlist refuses any host but the prospect's own", {
                let policy = LeadgenSourcePolicy(allowedHosts: ["cliniqueexemple.ca"])
                try policy.check(URL(string: "https://www.cliniqueexemple.ca/services")!)
                try await expectError(.hostNotAllowed("autreclinique.ca")) { try policy.check(URL(string: "https://autreclinique.ca/")!) }
            }),
            ("LG2 Google Maps and data-broker hosts are refused even when allowlisted", {
                let blocked = ["maps.google.com", "google.com", "zoominfo.com", "apollo.io", "rocketreach.co", "canada411.ca", "pagesjaunes.ca"]
                let policy = LeadgenSourcePolicy(allowedHosts: blocked)
                for host in blocked {
                    try await expectError(.hostNotAllowed(host)) { try policy.check(URL(string: "https://\(host)/x")!) }
                }
            }),
            ("LG2 robots.txt is fetched first, Disallow is respected, every fetched URL is logged", {
                let reader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: ["cliniqueexemple.ca"]), fetcher: LeadgenFixture.fetcher(robots: "User-agent: *\nDisallow: /services\n"), dns: LeadgenMappedDNS())
                try await expectError(.robotsDisallowed("/services")) { _ = try await reader.read(site: LeadgenFixture.site, paths: LeadgenFixture.paths) }
                let log = await reader.fetchedURLs
                try check(log == ["https://www.cliniqueexemple.ca/robots.txt", "https://www.cliniqueexemple.ca/"], "fetch log \(log)")
                let ok = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: ["cliniqueexemple.ca"]), fetcher: LeadgenFixture.fetcher(), dns: LeadgenMappedDNS())
                let pages = try await ok.read(site: LeadgenFixture.site, paths: LeadgenFixture.paths)
                let okLog = await ok.fetchedURLs
                try check(pages.count == 3 && okLog.count == 4 && okLog.first?.hasSuffix("/robots.txt") == true, "pages \(pages.count), log \(okLog)")
            }),
            ("LG3 exactly one prospect in montreal-clinics; 0, 2, or another segment refused", {
                let p = LeadgenFixture.prospect
                try check(try LeadgenProspectPicker.pickOne([p]) == p, "single prospect not picked")
                try await expectError(.notExactlyOneProspect(2)) { _ = try LeadgenProspectPicker.pickOne([p, p]) }
                try await expectError(.notExactlyOneProspect(0)) { _ = try LeadgenProspectPicker.pickOne([]) }
                let other = LeadgenProspect(organization: "X", segment: "toronto-dentists", site: p.site, publicContactEmail: p.publicContactEmail)
                try await expectError(.wrongSegment("toronto-dentists")) { _ = try LeadgenProspectPicker.pickOne([other]) }
            }),
            ("LG4 fit reason quotes body text from the prospect's own domain (LIVE-R6)", {
                let reader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: ["cliniqueexemple.ca"]), fetcher: LeadgenFixture.fetcher(), dns: LeadgenMappedDNS())
                let pages = try await reader.read(site: LeadgenFixture.site, paths: LeadgenFixture.paths)
                let fit = try LeadgenFitFinder.find(pages: pages, prospect: LeadgenFixture.prospect)
                try check(fit.evidence.count >= 1, "no evidence")
                let e = fit.evidence[0]
                try check(e.quote.contains("intelligence artificielle pour trier"), "quote not from body: \(e.quote)")
                try check(URL(string: e.url)?.host == "www.cliniqueexemple.ca", "evidence off domain: \(e.url)")
                try check(fit.reason == "Clinique Exemple (\(e.url)): \"\(e.quote)\"", "reason adds a claim the quote does not show: \(fit.reason)")
                try check(!fit.reason.localizedCaseInsensitiveContains("uses AI with patients") && !fit.reason.contains("avec des patients"), "reason claims more than the quote: \(fit.reason)")
            }),
            ("LG4 footer-link or privacy-only evidence is refused (LIVE-R4)", {
                let reader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: ["cliniqueexemple.ca"]), fetcher: LeadgenFixture.fetcher(home: LeadgenFixture.footerOnly), dns: LeadgenMappedDNS())
                let pages = try await reader.read(site: LeadgenFixture.site, paths: LeadgenFixture.paths)
                try check(!pages[0].bodyText.lowercased().contains("confidentialité"), "footer text leaked into body: \(pages[0].bodyText)")
                try await expectError(.noBodyEvidence) { _ = try LeadgenFitFinder.find(pages: pages, prospect: LeadgenFixture.prospect) }
                let privacyOnly = [LeadgenPage(url: URL(string: "https://www.cliniqueexemple.ca/vie-privee")!, bodyText: "Politique de confidentialité et protection de la vie privée de nos patients.")]
                try await expectError(.noBodyEvidence) { _ = try LeadgenFitFinder.find(pages: privacyOnly, prospect: LeadgenFixture.prospect) }
            }),
            ("LG4 evidence from another domain is refused", {
                let off = [LeadgenPage(url: URL(string: "https://annuaire-sante.ca/clinique-exemple")!, bodyText: "Cette clinique utilise l'intelligence artificielle pour ses rendez-vous en ligne.")]
                try await expectError(.evidenceOffDomain("https://annuaire-sante.ca/clinique-exemple")) { _ = try LeadgenFitFinder.find(pages: off, prospect: LeadgenFixture.prospect) }
            }),
            ("LG5 live run calls only createDraft, once, on ml@pharos-ai.ca (0 send/read/delete)", {
                let mailbox = LeadgenRecordingMailbox(), d1 = LeadgenFakeD1()
                let report = try await LeadgenFixture.runner(LeadgenFixture.liveConfig, mailbox: mailbox, d1: d1).run(candidates: [LeadgenFixture.prospect], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal)
                let calls = await mailbox.calls, accounts = await mailbox.accounts
                let s = await mailbox.sends, r = await mailbox.reads, d = await mailbox.deletes
                try check(calls == ["createDraft"] && accounts == ["ml@pharos-ai.ca"], "mail calls \(calls) on \(accounts)")
                try check(s == 0 && r == 0 && d == 0, "send \(s) read \(r) delete \(d)")
                try check(report.draftID == "r-draft-1", "draft id \(String(describing: report.draftID))")
            }),
            ("LG5 draft carries consent basis, CASL unsubscribe footer, signature, and no em dash", {
                let fit = LeadgenFit(reason: "r", evidence: [LeadgenFitEvidence(url: "https://www.cliniqueexemple.ca/", quote: "Nous utilisons l'intelligence artificielle pour trier les rendez-vous.")])
                let draft = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, pages: LeadgenFixture.pages())
                let raw = draft.rawMIME
                try check(raw.contains("X-PHAROS-Consent-Basis: CASL") && raw.contains("Loi 25"), "no consent basis header")
                try check(draft.body.contains("désabonnement") && draft.body.contains("unsubscribe") && draft.body.contains(LeadgenFixture.postal), "no CASL footer")
                try check(draft.body.contains("Martin Lepage, PhD") && draft.from == "ml@pharos-ai.ca", "signature or sender wrong")
                try check(!raw.contains("\u{2014}") && !raw.contains("\u{2013}"), "dash in draft")
                try await expectError(.missingConsentBasis) { _ = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: nil, postalAddress: LeadgenFixture.postal, pages: LeadgenFixture.pages()) }
                let dashed = LeadgenFit(reason: "r", evidence: [LeadgenFitEvidence(url: "u", quote: "IA \u{2014} partout")])
                try await expectError(.dashNotAllowed) { _ = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: dashed, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, pages: LeadgenFixture.pages()) }
            }),
            ("LG6 one INSERT into leads per DB, status waiting-on-martin, read back, leads count +1, 0 projects writes", {
                let d1 = LeadgenFakeD1()
                let report = try await LeadgenFixture.live(d1)
                let inserts = await d1.inserts()
                try check(inserts.count == 2 && Set(inserts.map(\.db)) == [LeadgenProjectTarget.meCom.databaseID, LeadgenProjectTarget.pharos.databaseID], "inserts \(inserts.map(\.db))")
                try check(inserts.allSatisfy { $0.sql.hasPrefix("INSERT INTO leads (") }, "insert outside leads")
                let all = await d1.statements
                try check(all.allSatisfy { $0.sql.hasPrefix("INSERT INTO leads") || $0.sql.hasPrefix("SELECT ") || $0.sql == LeadgenMigration.createLeads }, "other statement reached D1")
                try check(report.receipts.count == 2 && report.receipts.allSatisfy { $0.countAfter == $0.countBefore + 1 }, "receipts \(report.receipts)")
                for db in [LeadgenProjectTarget.meCom.databaseID, LeadgenProjectTarget.pharos.databaseID] {
                    let leads = await d1.rows(db, "leads"), projects = await d1.rows(db, "projects")
                    try check(leads.count == 1 && leads[0]["status"] == "waiting-on-martin", "lead in \(db): \(leads)")
                    try check(projects.count == 3 && !projects.contains { $0["id"]?.hasPrefix("lead-") == true }, "projects changed in \(db)")
                }
            }),
            ("LG6 live run logs rows and schema checksum of every existing table, before and after, plus projects count, in both DBs", {
                let log = LeadgenMemoryLog()
                let report = try await LeadgenFixture.live(LeadgenFakeD1(), log: log)
                let lines = await log.lines
                for db in [LeadgenProjectTarget.meCom.databaseID, LeadgenProjectTarget.pharos.databaseID] {
                    for phase in ["before", "after"] {
                        for table in ["projects", "notes"] {
                            try check(lines.contains { $0.hasPrefix("\(db) \(phase) \(table) rows=") && $0.contains(" data=") && $0.contains(" schema=") }, "missing \(phase) \(table) checksum for \(db)")
                        }
                    }
                    try check(lines.contains { $0.hasPrefix("\(db) projects before rows=3") && $0.contains("after rows=3") }, "projects count not logged unchanged for \(db)")
                    try check(lines.contains { $0 == "\(db) leads count before=0 after=1" }, "leads count not logged for \(db)")
                }
                try check(report.receipts.allSatisfy { $0.checksumBefore == $0.checksumAfter && $0.checksumBefore["leads"] == nil }, "checksums differ")
            }),
            ("LG6 a changed existing row or a changed table schema fails the checksum", {
                for (rows, schema) in [(true, false), (false, true)] {
                    let d1 = LeadgenFakeD1()
                    await d1.setTamper(rows: rows, schema: schema)
                    try await expectError(.existingRowsChanged) { _ = try await LeadgenD1Writer(port: d1, log: LeadgenMemoryLog()).insertOne(LeadgenFixture.row, into: .meCom) }
                }
            }),
            ("LG6 an existing leads table in either DB stops the run before any insert", {
                let d1 = LeadgenFakeD1(withLeads: true), mailbox = LeadgenRecordingMailbox()
                try await expectError(.leadsTableExists(LeadgenProjectTarget.meCom.databaseID)) { _ = try await LeadgenFixture.live(d1, mailbox) }
                let inserts = await d1.inserts()
                try check(inserts.isEmpty, "\(inserts.count) inserts despite existing leads table")
            }),
            ("LG6 UPDATE, DELETE, DROP, ALTER, REPLACE, upsert, PRAGMA, other CREATE are refused before reaching D1", {
                try LeadgenSQLGuard.check(LeadgenD1Writer.countSQL, params: [])
                try LeadgenSQLGuard.check(LeadgenMigration.createLeads, params: [])
                try LeadgenSQLGuard.check("INSERT INTO leads (id, status) VALUES (?, ?)", params: ["lead-x", "waiting-on-martin"])
                let d1 = LeadgenFakeD1()
                let writer = LeadgenD1Writer(port: d1, log: LeadgenMemoryLog())
                for sql in ["UPDATE leads SET status = 'x'", "DELETE FROM leads WHERE id = 'x'", "DROP TABLE leads", "ALTER TABLE notes ADD x", "REPLACE INTO leads (id) VALUES (?)", "INSERT OR REPLACE INTO leads (id) VALUES (?)", "INSERT INTO leads (id) VALUES (?) ON CONFLICT(id) DO UPDATE SET id = 'x'", "PRAGMA table_info(leads)", "CREATE TABLE other (id TEXT)", "INSERT INTO notes (id, body) VALUES (?, ?)", "SELECT 1; DELETE FROM leads"] {
                    do { _ = try await writer.run(LeadgenProjectTarget.meCom.databaseID, sql, ["a"]); throw PortableCheckFailure(description: "allowed: \(sql)") } catch is LeadgenError {}
                }
                let n = await d1.statementCount()
                try check(n == 0, "\(n) refused statements reached D1")
            }),
            ("LG6 never a candidate: candidate table, candidate status or kind, and any projects write are refused", {
                let writer = LeadgenD1Writer(port: LeadgenFakeD1(), log: LeadgenMemoryLog())
                let db = LeadgenProjectTarget.pharos.databaseID
                let cases: [(String, [String])] = [
                    ("INSERT INTO candidates (id) VALUES (?)", ["x"]),
                    ("INSERT INTO pc_candidate_queue (id) VALUES (?)", ["x"]),
                    ("INSERT INTO leads (id, status) VALUES (?, ?)", ["x", "Candidate"]),
                    ("INSERT INTO leads (id, kind) VALUES (?, ?)", ["x", "candidate"]),
                    ("INSERT INTO projects (id, status) VALUES (?, ?)", ["x", "Waiting"]),
                ]
                for (sql, params) in cases {
                    do { _ = try await writer.run(db, sql, params); throw PortableCheckFailure(description: "allowed: \(sql) \(params)") } catch LeadgenError.candidateRefused(_) {}
                }
            }),
            ("LG6 migration files hold exactly one CREATE TABLE IF NOT EXISTS leads and 0 ALTER/DROP/UPDATE", {
                let dir = LeadgenFixture.migrationsDir
                let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".sql") }
                try check(files == ["0001_create_leads.sql"], "migration files \(files)")
                let text = try String(contentsOf: dir.appendingPathComponent(files[0]), encoding: .utf8)
                let upper = text.uppercased()
                for word in ["ALTER", "DROP", "UPDATE", "DELETE", "INSERT"] { try check(!upper.contains(word), "migration contains \(word)") }
                try check(upper.components(separatedBy: "CREATE TABLE IF NOT EXISTS LEADS ").count == 2 && upper.components(separatedBy: "CREATE ").count == 2, "not exactly one CREATE")
                try check(text.trimmingCharacters(in: .whitespacesAndNewlines) == LeadgenMigration.createLeads, "Swift migration text differs from the file")
            }),
            ("LG7 CLI dry-run prints the plan and touches nothing (0 fetch, 0 Gmail, 0 D1, no live adapters)", {
                let d1 = LeadgenFakeD1(), mailbox = LeadgenRecordingMailbox()
                let fetcher = LeadgenFixture.fetcher()
                let probe = LeadgenDepsProbe(deps: LeadgenLiveDeps(fetcher: fetcher, mailbox: mailbox, d1: d1, log: LeadgenMemoryLog(), logPath: "-"))
                let env = ["LEADGEN_CONFIG": try LeadgenFixture.tempConfig()]
                let (code, lines) = await LeadgenCLI.run(arguments: [], environment: env, makeFetcher: { fetcher }, dns: LeadgenMappedDNS(), makeLive: probe.make)
                let calls = await mailbox.calls, statements = await d1.statementCount()
                try check(code == 0, "dry-run exit \(code)")
                try check(lines.first?.contains("DRY RUN") == true, "no DRY RUN banner: \(lines.first ?? "")")
                try check(lines.contains("directory not configured"), "missing directory line: \(lines)")
                try check(lines.contains("prospect: not configured"), "a hand-supplied clinic was treated as the prospect: \(lines)")
                try check(lines.contains(where: { $0.contains("STOP if a leads table exists") }) && lines.contains(where: { $0.contains(LeadgenRunConfig.confirmation) }), "plan lines missing")
                try check(fetcher.requested.isEmpty, "dry-run without a directory fetched \(fetcher.requested)")
                try check(probe.calls == 0 && calls.isEmpty && statements == 0, "dry-run built adapters \(probe.calls)x, Gmail \(calls.count)x, D1 \(statements)x")
            }),
            ("LG7 --live without the exact confirmation naming leads in both DBs refuses before any adapter", {
                let d1 = LeadgenFakeD1(), mailbox = LeadgenRecordingMailbox()
                let probe = LeadgenDepsProbe(deps: LeadgenLiveDeps(fetcher: LeadgenFixture.fetcher(), mailbox: mailbox, d1: d1, log: LeadgenMemoryLog(), logPath: "-"))
                let env = ["LEADGEN_CONFIG": try LeadgenFixture.tempConfig()]
                for args in [["--live"], ["--live", "--confirm", "yes"], ["--live", "--confirm", "leads in e1e9fa25"], ["--live", "--confirm=leads"]] {
                    let (code, lines) = await LeadgenCLI.run(arguments: args, environment: env, makeLive: probe.make)
                    try check(code == 2 && lines.first?.hasPrefix("refused:") == true, "\(args) not refused: \(code) \(lines)")
                }
                let calls = await mailbox.calls, statements = await d1.statementCount()
                try check(probe.calls == 0 && calls.isEmpty && statements == 0, "refusal still built adapters \(probe.calls)x, Gmail \(calls.count)x, D1 \(statements)x")
            }),
            ("LG7 live step order: schema check both, then the Gmail draft, then per DB before/0001/insert/read-back/after, logged", {
                let d1 = LeadgenFakeD1(), log = LeadgenMemoryLog()
                let mailbox = LeadgenOrderMailbox(d1: d1)
                let probe = LeadgenDepsProbe(deps: LeadgenLiveDeps(fetcher: LeadgenFixture.fetcher(), mailbox: mailbox, d1: d1, log: log, logPath: "mem"))
                let policyFile = FileManager.default.temporaryDirectory.appendingPathComponent("leadgen-policy-\(UUID().uuidString).json")
                try JSONEncoder().encode(LeadgenSliceTests.readPolicy()).write(to: policyFile)
                var env = ["LEADGEN_CONFIG": try LeadgenFixture.tempConfig(directory: LeadgenFixture.directory.absoluteString)]
                env["LEADGEN_TOKEN_POLICY"] = policyFile.path
                env[LeadgenTokenProof.readTokenEnvs[0]] = "me-read"
                env[LeadgenTokenProof.readTokenEnvs[1]] = "ph-read"
                let verifier = LeadgenFixedVerifier(byBearer: [
                    "me-read": LeadgenVerifiedToken(id: "id-me", status: "active"),
                    "ph-read": LeadgenVerifiedToken(id: "id-ph", status: "active"),
                ])
                let (code, lines) = await LeadgenCLI.run(arguments: ["--live", "--confirm", LeadgenRunConfig.confirmation], environment: env, dns: LeadgenMappedDNS(), verifier: verifier, makeLive: probe.make)
                try check(code == 0, "live exit \(code): \(lines)")
                let me = LeadgenProjectTarget.meCom.databaseID, ph = LeadgenProjectTarget.pharos.databaseID
                let steps = await log.lines.filter { $0.hasPrefix("step ") }
                var expected = ["step schema-check \(me)", "step schema-check \(ph)", "step gmail-create-draft ml@pharos-ai.ca"]
                for db in [me, ph] { expected += ["checksum-before", "apply-0001", "insert", "read-back", "checksum-after"].map { "step \($0) \(db)" } }
                try check(steps == expected, "step order \(steps)")
                let atDraft = await mailbox.d1StatementsAtDraft, total = await d1.statementCount()
                try check(atDraft.count == 1 && atDraft[0] < total, "draft was not created before the row writes: D1 statements at draft \(atDraft), total \(total)")
                let all = await log.lines
                try check(all.contains("directory \(LeadgenFixture.directory.absoluteString)"), "directory URL was not written to the run log: \(all)")
                try check(all.contains(where: { $0.hasPrefix("\(me) projects count before") }) && all.contains(where: { $0.hasPrefix("\(ph) projects count before") }), "projects count before not logged")
                let inserted = await d1.rows(me, "leads")
                try check(inserted.first?["draft_ref"] == "r-draft-1", "draft_ref is not the id returned by createDraft: \(inserted)")
            }),
            ("LG7 the run log is written to a file under the log directory", {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("leadgen-log-\(UUID().uuidString)")
                let env = ["HOME": dir.path]
                try check(LeadgenFileLog.directory(environment: env).path.hasSuffix("Library/Logs/ControlWard/leadgen"), "log dir \(LeadgenFileLog.directory(environment: env).path)")
                let file = LeadgenFileLog(directory: LeadgenFileLog.directory(environment: env), stamp: "2026-10-24T20:30:00Z")
                await file.write("step one")
                await file.write("step two")
                let text = try String(contentsOf: file.url, encoding: .utf8)
                try check(text == "step one\nstep two\n", "log file text \(text)")
            }),
            ("LG8 the draft refuses to build when the address config is missing", {
                let fit = try LeadgenFixture.fit()
                for missing in [nil, "", "   "] as [String?] {
                    try await expectError(.missingPostalAddress) {
                        _ = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: LeadgenFixture.consent, postalAddress: missing, pages: LeadgenFixture.pages())
                    }
                }
                let nowhere = "/nonexistent/leadgen-\(UUID().uuidString)/leadgen.local.json"
                try await expectError(.configMissing(nowhere)) { _ = try LeadgenLocalConfig.load(path: nowhere) }
                let loaded = try LeadgenLocalConfig.load(path: try LeadgenFixture.tempConfig(postal: nil))
                try check(loaded.postalAddress == nil, "config without address decoded one")
                let d1 = LeadgenFakeD1(), mailbox = LeadgenRecordingMailbox()
                let probe = LeadgenDepsProbe(deps: LeadgenLiveDeps(fetcher: LeadgenFixture.fetcher(), mailbox: mailbox, d1: d1, log: LeadgenMemoryLog(), logPath: "-"))
                let (code, _) = await LeadgenCLI.run(arguments: ["--live", "--confirm", LeadgenRunConfig.confirmation], environment: ["LEADGEN_CONFIG": try LeadgenFixture.tempConfig(postal: nil)], makeLive: probe.make)
                let statements = await d1.statementCount(), calls = await mailbox.calls
                try check(code != 0 && probe.calls == 0 && statements == 0 && calls.isEmpty, "live run without address went ahead (exit \(code))")
                let (code2, lines2) = await LeadgenCLI.run(arguments: ["--live", "--confirm", LeadgenRunConfig.confirmation], environment: ["LEADGEN_CONFIG": try LeadgenFixture.tempConfig(postal: nil, directory: LeadgenFixture.directory.absoluteString)], dns: LeadgenMappedDNS(), makeLive: probe.make)
                try check(code2 != 0 && lines2.contains { $0.contains("no sender postal address") }, "missing address with a directory was not refused: \(code2) \(lines2)")
                try check(probe.calls == 0, "missing address still built live adapters")
            }),
            ("LG8 a footer address on the denied street (Saint-Hubert) is refused in every spelling", {
                let fit = try LeadgenFixture.fit()
                for bad in ["1000 rue Saint-Hubert, Montréal", "1000, rue St-Hubert", "1000 SAINT HUBERT", "1000 rue saint-hubert", "1000 rue Saint‑Hubert"] {
                    try await expectError(.postalAddressDenied("saint-hubert")) {
                        _ = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: LeadgenFixture.consent, postalAddress: bad, pages: LeadgenFixture.pages())
                    }
                }
                let ok = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, pages: LeadgenFixture.pages())
                try check(ok.body.contains(LeadgenFixture.postal), "the configured footer line was not rendered")
                try check(LeadgenDraftComposer.deniedStreets == ["saint-hubert"], "denylist must hold the street name only")
            }),
            ("LG8 the repo holds only a placeholder example config and ignores the local one", {
                let root = LeadgenFixture.repoRoot
                let example = try String(contentsOf: root.appendingPathComponent("docs/leadgen-slice/leadgen.local.example.json"), encoding: .utf8)
                let parsed = try JSONDecoder().decode(LeadgenLocalConfig.self, from: Data(example.utf8))
                try check(parsed.postalAddress?.hasPrefix("PLACEHOLDER") == true, "example address is not a placeholder")
                try check(parsed.directoryURL == "https://dpq.quebec/repertoire-des-membres/", "directoryURL is \(parsed.directoryURL ?? "nil")")
                try check(parsed.directoryValue?.absoluteString == "https://dpq.quebec/repertoire-des-membres/", "the DPQ page did not parse")
                let ignore = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
                try check(ignore.split(separator: "\n").contains("leadgen.local.json"), ".gitignore does not list leadgen.local.json")
                try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/leadgen-slice/leadgen.local.json").path), "a local config sits in the repo tree")
            }),
        ]
    }

    static func tailCases() -> [(String, () async throws -> Void)] {
        var cases: [(String, () async throws -> Void)] = [
            ("M1 nested RBQ JSON parses, and zero records or a failed check hold construction trades", {
                let config = try LeadKit.config()
                let source = try LeadPipelineTests.unwrap(RBQOpenData.source(config), "RBQ source missing from icp.json")
                let data = RBQFixture.json([
                    RBQFixture.jsonRecord(licence: "0000-0000-15", name: "Entreprise Fictive", town: "Jonquière", codes: [("Specialisee", "15.5")]),
                ])
                let licences = try RBQOpenData.parse(data: data, source: source)
                try check(licences.count == 1, "nested file parsed \(licences.count) records")
                try check(licences[0].subcategories == ["15.5"] && licences[0].municipality == "Jonquière", "parsed \(licences[0])")
                try check(licences[0].licenceNumber == "0000-0000-15", "licence number dropped")
                func held(_ record: ProspectRecord) -> LeadDefinition.Verdict {
                    LeadDefinition.evaluate(record, config: config, now: LeadKit.now)
                }
                var jonquiere = ProspectRecord(id: "cw:test/rbq-jonquiere", organisation: "Entreprise Fictive", segment: "construction_trades")
                jonquiere.rbqCheck = "matched"
                jonquiere.rbqCategories = ["15.5"]
                jonquiere.rbqMunicipality = "Jonquière"
                let areaHold = held(jonquiere)
                try check(areaHold.status == .conflictReview && !areaHold.isLead, "15.5 in Jonquière was cleared: \(areaHold)")
                var keyword = jonquiere
                keyword.organisation = "Plomberie Fictive Nord"
                keyword.rbqCategories = ["16"]
                keyword.rbqMunicipality = "Saguenay"
                let keywordHold = held(keyword)
                try check(keywordHold.status == .conflictReview && !keywordHold.isLead, "Saguenay plumbing keyword was cleared: \(keywordHold)")
                var montreal = jonquiere
                montreal.organisation = "Entreprise Fictive"
                montreal.rbqCategories = ["15.5"]
                montreal.rbqMunicipality = "Montréal"
                montreal.town = "Montréal"
                let outside = held(montreal)
                try check(outside.status != .conflictReview, "Montréal 15.5 was held by the area rule: \(outside)")
                var failed = montreal
                failed.rbqCheck = "error:refused:open-data-schema"
                failed.rbqCategories = []
                let failClosed = held(failed)
                try check(failClosed.status == .conflictReview && !failClosed.isLead, "a failed RBQ check cleared a construction firm: \(failClosed)")
                do {
                    _ = try RBQOpenData.parse(data: Data(#"{"Liste Licence":[]}"#.utf8), source: source)
                    throw PortableCheckFailure(description: "zero records parsed as success")
                } catch let error as LeadPipelineRefusal {
                    try check(error.code == "refused:open-data-schema", "zero records: \(error)")
                }
            }),
            ("M2 slice fetches refuse loopback, private, link-local, encoded and non-http targets before any request", {
                let literals = [
                    "http://127.0.0.1/", "http://10.0.0.5/", "http://192.168.1.1/", "http://172.16.0.1/",
                    "http://169.254.169.254/", "http://[::1]/", "http://[::ffff:127.0.0.1]/", "http://[fe80::1]/",
                    "http://[fc00::1]/", "http://0x7f000001/", "http://2130706433/", "http://0177.0.0.1/",
                    "http://foo.local/", "http://localhost/", "file:///etc/passwd", "gopher://cliniqueexemple.ca/",
                ]
                for raw in literals {
                    let fetcher = LeadgenFakeFetcher(pages: [:])
                    let reader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: ["cliniqueexemple.ca"]), fetcher: fetcher, dns: LeadgenMappedDNS())
                    do {
                        _ = try await reader.read(site: URL(string: raw)!, paths: ["/"])
                        throw PortableCheckFailure(description: "fetched \(raw)")
                    } catch let error as LeadgenError {
                        guard case .unsafeURL = error else { throw PortableCheckFailure(description: "\(raw) -> \(error)") }
                        try check(fetcher.requested.isEmpty, "\(raw) was requested: \(fetcher.requested)")
                    }
                }
                for addresses in [["10.1.2.3"], ["127.0.0.1"], []] {
                    let fetcher = LeadgenFakeFetcher(pages: ["https://www.cliniqueexemple.ca/robots.txt": (200, "User-agent: *\nAllow: /\n")])
                    let dns = LeadgenMappedDNS(overrides: ["www.cliniqueexemple.ca": addresses, "cliniqueexemple.ca": addresses])
                    let reader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: ["cliniqueexemple.ca"]), fetcher: fetcher, dns: dns)
                    do {
                        _ = try await reader.read(site: LeadgenFixture.site, paths: ["/"])
                        throw PortableCheckFailure(description: "fetched a name that resolves to \(addresses)")
                    } catch let error as LeadgenError {
                        guard case .unsafeURL = error else { throw PortableCheckFailure(description: "dns \(addresses) -> \(error)") }
                        try check(fetcher.requested.isEmpty, "private DNS was still fetched: \(fetcher.requested)")
                    }
                }
                let localhost = SystemHostLookup.addresses("localhost")
                try check(!localhost.isEmpty && localhost.allSatisfy(HostSafety.isNonPublic), "localhost resolved as public: \(localhost)")
            }),
            ("M3 every redirect hop is admitted and evidence records the final URL", {
                let about = "<html><body><main><p>Depuis 2025, nous utilisons un outil d'intelligence artificielle pour trier les demandes de rendez-vous.</p></main></body></html>"
                let fetcher = LeadgenFakeFetcher(pages: [
                    "https://www.cliniqueexemple.ca/robots.txt": (200, "User-agent: *\nAllow: /\n"),
                    "https://www.cliniqueexemple.ca/a-propos": (200, about),
                ])
                fetcher.set("https://www.cliniqueexemple.ca/", status: 302, headers: ["Location": "/a-propos"], body: "")
                let reader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: ["cliniqueexemple.ca"]), fetcher: fetcher, dns: LeadgenMappedDNS())
                let pages = try await reader.read(site: LeadgenFixture.site, paths: ["/"])
                try check(pages.first?.url.absoluteString == "https://www.cliniqueexemple.ca/a-propos", "evidence kept the redirecting URL: \(pages.first?.url.absoluteString ?? "")")
                let fit = try LeadgenFitFinder.find(pages: pages, prospect: LeadgenFixture.prospect)
                try check(fit.evidence.first?.url == "https://www.cliniqueexemple.ca/a-propos", "fit evidence is not the final URL: \(fit.evidence)")
                try check(fit.reason.contains("intelligence artificielle") && !fit.reason.contains("uses AI with patients"), "reason \(fit.reason)")

                let cross = LeadgenFakeFetcher(pages: ["https://www.cliniqueexemple.ca/robots.txt": (200, "User-agent: *\nAllow: /\n")])
                cross.set("https://www.cliniqueexemple.ca/", status: 302, headers: ["Location": "https://cdn.example/secret"], body: "")
                let crossReader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: ["cliniqueexemple.ca"]), fetcher: cross, dns: LeadgenMappedDNS())
                try await expectError(.hostNotAllowed("cdn.example")) { _ = try await crossReader.read(site: LeadgenFixture.site, paths: ["/"]) }
                try check(!cross.requested.contains("https://cdn.example/secret"), "cross-domain hop was fetched: \(cross.requested)")

                let loop = LeadgenFakeFetcher(pages: ["https://www.cliniqueexemple.ca/robots.txt": (200, "User-agent: *\nAllow: /\n")])
                loop.set("https://www.cliniqueexemple.ca/", status: 302, headers: ["Location": "http://127.0.0.1/"], body: "")
                let loopReader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: ["cliniqueexemple.ca", "127.0.0.1"]), fetcher: loop, dns: LeadgenMappedDNS())
                try await expectError(.unsafeURL("IP literal")) { _ = try await loopReader.read(site: LeadgenFixture.site, paths: ["/"]) }
                try check(!loop.requested.contains { $0.contains("127.0.0.1") }, "redirect to loopback was fetched: \(loop.requested)")

                let rebound = LeadgenFakeFetcher(pages: ["https://www.cliniqueexemple.ca/robots.txt": (200, "User-agent: *\nAllow: /\n")])
                rebound.set("https://www.cliniqueexemple.ca/", status: 302, headers: ["Location": "https://cdn.cliniqueexemple.ca/secret"], body: "")
                let reboundDNS = LeadgenMappedDNS(overrides: ["cdn.cliniqueexemple.ca": ["10.0.0.1"]])
                let reboundReader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: ["cliniqueexemple.ca"]), fetcher: rebound, dns: reboundDNS)
                try await expectError(.unsafeURL("resolved 10.0.0.1 (non-public)")) { _ = try await reboundReader.read(site: LeadgenFixture.site, paths: ["/"]) }
                try check(!rebound.requested.contains("https://cdn.cliniqueexemple.ca/secret"), "rebinding hop was fetched: \(rebound.requested)")
            }),
            ("E1 the Gmail draft is not created when the second database already has leads", {
                let d1 = LeadgenFakeD1()
                await d1.installLeads(LeadgenProjectTarget.pharos.databaseID)
                let mailbox = LeadgenRecordingMailbox()
                let log = LeadgenMemoryLog()
                try await expectError(.leadsTableExists(LeadgenProjectTarget.pharos.databaseID)) {
                    _ = try await LeadgenFixture.runner(LeadgenFixture.liveConfig, mailbox: mailbox, d1: d1, log: log).run(
                        candidates: [LeadgenFixture.prospect], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal)
                }
                let calls = await mailbox.calls
                let inserts = await d1.inserts()
                let lines = await log.lines
                try check(calls.isEmpty && inserts.isEmpty, "draft or insert ran anyway: calls \(calls), inserts \(inserts)")
                try check(lines.contains("step schema-check \(LeadgenProjectTarget.meCom.databaseID)"), "first database was not checked")
                try check(!lines.contains { $0.contains("gmail-create-draft") }, "draft step was logged: \(lines)")
            }),
            ("E3 recipient address and consent source must come from a fetched own-domain page", {
                let fit = try LeadgenFixture.fit()
                let home = LeadgenPage(url: LeadgenFixture.site, bodyText: LeadgenHTML.bodyText(LeadgenFixture.home), html: LeadgenFixture.home)
                try await expectError(.contactNotOnPage("info@cliniqueexemple.ca")) {
                    _ = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, pages: [home])
                }
                let thirdParty = LeadgenPage(url: URL(string: "https://www.cliniqueexemple.ca/contact")!, bodyText: "Écrivez à bureau@gmail.com.", html: "")
                try await expectError(.contactNotOnPage("info@cliniqueexemple.ca")) {
                    _ = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, pages: [home, thirdParty])
                }
                let offDomain = LeadgenPage(url: URL(string: "https://broker.example/contact")!, bodyText: "info@cliniqueexemple.ca", html: "")
                try await expectError(.contactNotOnPage("info@cliniqueexemple.ca")) {
                    _ = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, pages: [home, offDomain])
                }
                let broker = LeadgenConsentBasis(basis: LeadgenFixture.consent.basis, source: "https://broker.example/contact", recordedAt: LeadgenFixture.consent.recordedAt)
                try await expectError(.consentSourceNotFetched(broker.source)) {
                    _ = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: broker, postalAddress: LeadgenFixture.postal, pages: LeadgenFixture.pages())
                }
                let unfetched = LeadgenConsentBasis(basis: LeadgenFixture.consent.basis, source: "https://www.cliniqueexemple.ca/mentions", recordedAt: LeadgenFixture.consent.recordedAt)
                try await expectError(.consentSourceNotFetched(unfetched.source)) {
                    _ = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: unfetched, postalAddress: LeadgenFixture.postal, pages: LeadgenFixture.pages())
                }
            }),
            ("Discovery dry-run reads one clinic from the configured directory page and not from the hand-supplied prospect", {
                let fetcher = LeadgenFixture.fetcher()
                let listed = """
                <html><body>
                <a href="https://maps.google.com/maps?q=clinique">carte</a>
                <a href="https://www.google.com/search?q=clinique+montreal">chercher</a>
                <a href="https://dpq.quebec/a-propos">cet annuaire</a>
                <a href="https://www.cliniqueexemple.ca/a-propos">Clinique du Parc</a>
                <a href="https://cliniqueexemple.ca/equipe">même clinique</a>
                </body></html>
                """
                fetcher.set(LeadgenFixture.directory.absoluteString, status: 200, body: listed)
                let d1 = LeadgenFakeD1(), mailbox = LeadgenRecordingMailbox()
                let probe = LeadgenDepsProbe(deps: LeadgenLiveDeps(fetcher: fetcher, mailbox: mailbox, d1: d1, log: LeadgenMemoryLog(), logPath: "-"))
                let env = ["LEADGEN_CONFIG": try LeadgenFixture.tempConfig(directory: LeadgenFixture.directory.absoluteString)]
                let (code, lines) = await LeadgenCLI.run(arguments: [], environment: env, makeFetcher: { fetcher }, dns: LeadgenMappedDNS(), makeLive: probe.make)
                let calls = await mailbox.calls, statements = await d1.statementCount()
                try check(code == 0, "discovery dry-run exit \(code): \(lines)")
                try check(lines.contains("directory: \(LeadgenFixture.directory.absoluteString)"), "plan did not name the directory: \(lines)")
                try check(lines.contains("directory \(LeadgenFixture.directory.absoluteString)"), "run log missed the directory URL: \(lines)")
                try check(lines.contains("prospect: Clinique du Parc https://www.cliniqueexemple.ca/"), "prospect was not taken from the directory page: \(lines)")
                try check(!lines.contains("prospect: Clinique Exemple"), "hand-supplied organization was used: \(lines)")
                try check(lines.contains { $0.hasPrefix("fit:") && $0.contains("intelligence artificielle") && !$0.contains("uses AI with patients") }, "fit line: \(lines)")
                try check(lines.contains("recipient: info@cliniqueexemple.ca"), "recipient was not read from the clinic site: \(lines)")
                try check(lines.contains("consent source: https://www.cliniqueexemple.ca/contact"), "consent source was not the fetched page: \(lines)")
                try check(probe.calls == 0 && calls.isEmpty && statements == 0, "dry-run discovery built live adapters")
                try check(fetcher.requested.first == "https://dpq.quebec/robots.txt", "robots was not first: \(fetcher.requested)")
                try check(!fetcher.requested.contains { $0.contains("maps.google") || $0.contains("google.com/search") }, "a blocked source was fetched: \(fetcher.requested)")
                let expectedOrder = [
                    "https://dpq.quebec/robots.txt",
                    "https://dpq.quebec/repertoire-des-membres",
                    "https://www.cliniqueexemple.ca/robots.txt",
                    "https://www.cliniqueexemple.ca/",
                    "https://www.cliniqueexemple.ca/services",
                    "https://www.cliniqueexemple.ca/contact",
                ]
                try check(fetcher.requested == expectedOrder, "fetch order \(fetcher.requested)")
            }),
            ("Discovery picks the first clinic, and refuses maps-only, a disallowed directory, and an address that is not on the clinic domain", {
                func discover(_ html: String, robots: String = "User-agent: *\nAllow: /\n", robotsStatus: Int = 200, contact: String = "<html><body><main><p>Écrivez à info@cliniqueexemple.ca pour nous joindre.</p></main></body></html>") async throws -> LeadgenDiscoveryResult {
                    let fetcher = LeadgenFixture.fetcher()
                    fetcher.set("https://dpq.quebec/robots.txt", status: robotsStatus, body: robots)
                    fetcher.set(LeadgenFixture.directory.absoluteString, status: 200, body: html)
                    fetcher.set("https://www.cliniqueexemple.ca/contact", status: 200, body: contact)
                    let configured = LeadgenConsentBasis(basis: LeadgenFixture.consent.basis, source: "https://www.cliniqueexemple.ca/not-the-page", recordedAt: LeadgenFixture.consent.recordedAt)
                    return try await LeadgenDiscovery.find(directory: LeadgenFixture.directory, paths: LeadgenFixture.paths, consent: configured, fetcher: fetcher, dns: LeadgenMappedDNS())
                }
                let two = """
                <html><body>
                <a href="https://www.cliniqueexemple.ca/">Clinique Exemple</a>
                <a href="https://www.autreclinique.ca/">Autre Clinique</a>
                </body></html>
                """
                let twoFetcher = LeadgenFixture.fetcher()
                twoFetcher.set(LeadgenFixture.directory.absoluteString, status: 200, body: two)
                let first = try await LeadgenDiscovery.find(directory: LeadgenFixture.directory, paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, fetcher: twoFetcher, dns: LeadgenMappedDNS())
                try check(first.prospect.organization == "Clinique Exemple", "did not pick the first clinic: \(first.prospect.organization)")
                try check(!twoFetcher.requested.contains { $0.contains("autreclinique") }, "the second clinic was fetched: \(twoFetcher.requested)")
                let mapsOnly = "<html><body><a href=\"https://maps.google.com/maps?q=clinique\">carte</a></body></html>"
                try await expectError(.notExactlyOneProspect(0)) { _ = try await discover(mapsOnly) }
                try await expectError(.robotsDisallowed("/repertoire-des-membres")) {
                    _ = try await discover("<html></html>", robots: "User-agent: *\nDisallow: /repertoire-des-membres\n")
                }
                try await expectError(.robotsDisallowed("/")) {
                    _ = try await discover("<html></html>", robots: "", robotsStatus: 503)
                }
                try await expectError(.noRoleAddress("Clinique Exemple")) {
                    _ = try await discover(
                        "<html><body><a href=\"https://www.cliniqueexemple.ca/\">Clinique Exemple</a></body></html>",
                        contact: "<html><body><main><p>Écrivez à bureau@gmail.com.</p></main></body></html>")
                }
                let one = try await discover("<html><body><a href=\"https://www.cliniqueexemple.ca/\">Clinique Exemple</a></body></html>")
                try check(one.prospect.organization == "Clinique Exemple" && one.prospect.publicContactEmail == "info@cliniqueexemple.ca", "picked \(one.prospect)")
                try check(one.consent?.source == "https://www.cliniqueexemple.ca/contact", "consent source stayed on the config value: \(one.consent?.source ?? "")")
            }),
            ("A suppressed address or domain means no draft and no lead rows", {
                let blocked = [LeadgenFixture.prospect.publicContactEmail, "cliniqueexemple.ca"]
                for entry in blocked {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("leadgen-sup-\(UUID().uuidString).json")
                    let list = SuppressionList(storageURL: file)
                    list.record(entry, at: Date(timeIntervalSince1970: 1_700_000_000), via: "do-not-contact")
                    setenv("LEADGEN_SUPPRESSION", file.path, 1)
                    defer {
                        unsetenv("LEADGEN_SUPPRESSION")
                        try? FileManager.default.removeItem(at: file)
                    }
                    let mailbox = LeadgenRecordingMailbox(), d1 = LeadgenFakeD1(), log = LeadgenMemoryLog()
                    var threw = false
                    do {
                        _ = try await LeadgenFixture.runner(LeadgenFixture.liveConfig, mailbox: mailbox, d1: d1, log: log).run(
                            candidates: [LeadgenFixture.prospect], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal)
                    } catch {
                        threw = true
                    }
                    let calls = await mailbox.calls, inserts = await d1.inserts(), lines = await log.lines
                    try check(threw, "suppressed \(entry) still drafted")
                    try check(calls.isEmpty && inserts.isEmpty, "suppressed \(entry) wrote a draft or a row: calls \(calls) inserts \(inserts.count)")
                    try check(lines.contains { $0.contains("suppressed") && $0.contains(entry.lowercased()) }, "log did not name the suppression: \(lines)")
                }
            }),
            ("The lead row stores the evidence URL and its fetch time, and consent.recordedAt is that time", {
                let d1 = LeadgenFakeD1()
                let report = try await LeadgenFixture.live(d1)
                let row = await d1.rows(LeadgenProjectTarget.meCom.databaseID, "leads").first
                let evidence = row?["fit_evidence"] ?? ""
                let basis = row?["consent_basis"] ?? ""
                let fetchedAt = "2026-10-24T20:30:00Z"
                try check(evidence.contains("https://www.cliniqueexemple.ca/"), "evidence URL missing: \(evidence)")
                try check(evidence.contains(fetchedAt), "fetch time missing from the lead row: \(evidence)")
                try check(basis.contains(fetchedAt), "consent recordedAt is not the fetch time: \(basis)")
                try check(!basis.contains(LeadgenFixture.consent.recordedAt), "consent recordedAt stayed the config value: \(basis)")
                try check(report.draft.consent.recordedAt == fetchedAt, "draft recordedAt \(report.draft.consent.recordedAt)")
            }),
            ("An NFD footer line passes and is rendered as configured; a wrong line fails closed", {
                let fit = try LeadgenFixture.fit()
                let line = LeadgenFooterFixture.configured
                let draft = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: LeadgenFixture.consent, postalAddress: line, pages: LeadgenFixture.pages())
                try check(draft.body.contains(line), "the configured footer line was not rendered as-is")
                try check(draft.body.components(separatedBy: line).count == 2, "the footer line was repeated: \(draft.body)")
                try check(!draft.body.contains("PHAROS AI, PHAROS AI"), "the code prepended PHAROS AI to the full footer line")
                try await expectError(.postalAddressDenied("pinned-hash")) {
                    _ = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: LeadgenFixture.consent, postalAddress: "PHAROS AI, somewhere else", pages: LeadgenFixture.pages())
                }
            }),
            ("The draft carries a List-Unsubscribe header", {
                let fit = try LeadgenFixture.fit()
                let draft = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, pages: LeadgenFixture.pages())
                try check(draft.rawMIME.contains("List-Unsubscribe: <mailto:ml@pharos-ai.ca?subject=unsubscribe>"), "missing List-Unsubscribe header: \(draft.rawMIME)")
            }),
            ("NAT64, IPv4-compatible, 6to4 and Teredo addresses are not public targets", {
                let blocked = [
                    "64:ff9b::808:808",
                    "::808:808",
                    "2002:808:808::",
                    "2001:0:4136:e378:8000:63bf:3fff:fdd2",
                ]
                for address in blocked {
                    try check(HostSafety.ipv6Bytes(address) != nil, "\(address) did not parse")
                    try check(HostSafety.isNonPublic(address), "\(address) was treated as a public address")
                }
                try check(HostSafety.ipv6Bytes("2606:4700:4700::1111") != nil && !HostSafety.isNonPublic("2606:4700:4700::1111"), "a public address was blocked")
                try check(HostSafety.ipv6Bytes("::ffff:8.8.8.8") != nil && !HostSafety.isNonPublic("::ffff:8.8.8.8"), "a public IPv4-mapped address was blocked")
            }),
            ("Snapshot SELECTs use a read-only token named in config, not a secret in code", {
                let root = LeadgenFixture.repoRoot
                let example = try String(contentsOf: root.appendingPathComponent("docs/leadgen-slice/leadgen.local.example.json"), encoding: .utf8)
                try check(example.contains("LEADGEN_CF_TOKEN_MECOM_READ"), "me.com snapshot has no read-only token env name")
                try check(example.contains("LEADGEN_CF_TOKEN_PHAROS_READ"), "PHAROS snapshot has no read-only token env name")
                let live = try String(contentsOf: root.appendingPathComponent("native-crm/Sources/FollowUpOSNative/LeadgenLive.swift"), encoding: .utf8)
                try check(live.contains("readToken"), "the D1 adapter has no read-only token")
                try check(!live.contains("Bearer ey") && !example.contains("Bearer "), "a token value is hard-coded")
                try check(LeadgenCloudflareD1.credential(sql: LeadgenD1Writer.tablesSQL, read: "read-token", write: "write-token") == "read-token", "snapshot SELECT did not use the read token")
                try check(LeadgenCloudflareD1.credential(sql: LeadgenD1Writer.countSQL, read: "read-token", write: "write-token") == "read-token", "count SELECT did not use the read token")
                try check(LeadgenCloudflareD1.credential(sql: LeadgenD1Writer.readBackSQL, read: "read-token", write: "write-token") == "read-token", "read-back SELECT did not use the read token")
                try check(LeadgenCloudflareD1.credential(sql: "INSERT INTO leads (id) VALUES (?)", read: "read-token", write: "write-token") == "write-token", "INSERT used the read token")
                try check(LeadgenCloudflareD1.credential(sql: LeadgenMigration.createLeads, read: "read-token", write: "write-token") == "write-token", "migration used the read token")
            }),
            ("The connection uses the address that passed the check", {
                let page = URL(string: "https://www.cliniqueexemple.ca/contact")!
                let plan = LeadgenPinnedRequest.pin(url: page, addresses: ["1.1.1.1", "8.8.8.8"])
                try check(plan?.url.host == "1.1.1.1", "connection target \(String(describing: plan?.url.host))")
                try check(plan?.hostHeader == "www.cliniqueexemple.ca", "original host was dropped: \(String(describing: plan?.hostHeader))")
                try check(LeadgenPinnedRequest.pin(url: page, addresses: ["8.8.8.8"])?.url.host == "8.8.8.8", "a different admitted address was not kept")
                try check(LeadgenPinnedRequest.pin(url: page, addresses: ["10.0.0.1"]) == nil, "a private address was pinned")
                final class Box: @unchecked Sendable {
                    var request: URLRequest?
                    var lookups = 0
                }
                let box = Box()
                let fetcher = LeadgenHTTPFetcher(
                    lookup: { _ in box.lookups += 1; return ["1.1.1.1"] },
                    transport: { req in box.request = req; return (200, [:], "ok") }
                )
                let response = try await fetcher.get(page)
                try check(response.status == 200, "status \(response.status)")
                try check(box.lookups == 1, "lookup ran \(box.lookups) times")
                try check(box.request?.url?.host == "1.1.1.1", "request went to \(String(describing: box.request?.url))")
                try check(box.request?.value(forHTTPHeaderField: "Host") == "www.cliniqueexemple.ca", "Host header \(String(describing: box.request?.allHTTPHeaderFields))")
            }),
            ("A failed lead row leaves the unsent draft in place and the log names it", {
                LeadgenFixture.allowEmptySuppression()
                let me = LeadgenProjectTarget.meCom.databaseID
                let ph = LeadgenProjectTarget.pharos.databaseID
                let d1 = LeadgenFakeD1()
                await d1.setFailInsert(ph)
                let mailbox = LeadgenRecordingMailbox()
                let log = LeadgenMemoryLog()
                let runner = LeadgenSliceRunner(config: LeadgenFixture.liveConfig, fetcher: LeadgenFixture.fetcher(), mailbox: mailbox, d1: d1, log: log, now: { "2026-10-24T20:30:00Z" }, dns: LeadgenMappedDNS())
                do {
                    _ = try await runner.run(candidates: [LeadgenFixture.prospect], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal)
                    throw PortableCheckFailure(description: "row failure was ignored")
                } catch is PortableCheckFailure {
                    throw PortableCheckFailure(description: "row failure was ignored")
                } catch {}
                let calls = await mailbox.calls, deletes = await mailbox.deletes, lines = await log.lines
                try check(calls == ["createDraft"] && deletes == 0, "draft calls \(calls), deletes \(deletes)")
                try check(lines.contains { $0.contains("draft r-draft-1 left in place") && $0.contains(ph) }, "log did not name the draft and the failed row: \(lines)")
                let meRows = await d1.rows(me, "leads"), phRows = await d1.rows(ph, "leads")
                try check(meRows.count == 1 && meRows[0]["draft_ref"] == "r-draft-1", "surviving row does not point at the real draft: \(meRows)")
                try check(phRows.isEmpty, "failed database still has a row: \(phRows)")
            }),
            ("A failed first lead row leaves the unsent draft and writes no row", {
                LeadgenFixture.allowEmptySuppression()
                let d1 = LeadgenFakeD1()
                await d1.setFailInsert(LeadgenProjectTarget.meCom.databaseID)
                let mailbox = LeadgenRecordingMailbox(), log = LeadgenMemoryLog()
                let runner = LeadgenSliceRunner(config: LeadgenFixture.liveConfig, fetcher: LeadgenFixture.fetcher(), mailbox: mailbox, d1: d1, log: log, now: { "2026-10-24T20:30:00Z" }, dns: LeadgenMappedDNS())
                do {
                    _ = try await runner.run(candidates: [LeadgenFixture.prospect], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal)
                    throw PortableCheckFailure(description: "first row failure was ignored")
                } catch is PortableCheckFailure { throw PortableCheckFailure(description: "first row failure was ignored") } catch {}
                let calls = await mailbox.calls, deletes = await mailbox.deletes, lines = await log.lines, inserts = await d1.inserts()
                try check(calls == ["createDraft"] && deletes == 0, "draft calls \(calls), deletes \(deletes)")
                try check(inserts.isEmpty, "a pre-check failure still attempted an insert: \(inserts.map(\.db))")
                try check(lines.contains { $0.contains("draft r-draft-1 left in place") && $0.contains(LeadgenProjectTarget.meCom.databaseID) }, "log \(lines)")
            }),
            ("No lead row is written when the draft is not created", {
                LeadgenFixture.allowEmptySuppression()
                let d1 = LeadgenFakeD1()
                let mailbox = LeadgenRefusingMailbox()
                let runner = LeadgenSliceRunner(config: LeadgenFixture.liveConfig, fetcher: LeadgenFixture.fetcher(), mailbox: mailbox, d1: d1, log: LeadgenMemoryLog(), now: { "2026-10-24T20:30:00Z" }, dns: LeadgenMappedDNS())
                do {
                    _ = try await runner.run(candidates: [LeadgenFixture.prospect], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal)
                    throw PortableCheckFailure(description: "a missing draft still finished the run")
                } catch is PortableCheckFailure { throw PortableCheckFailure(description: "a missing draft still finished the run") } catch {}
                let inserts = await d1.inserts()
                try check(inserts.isEmpty, "a row points at a draft that does not exist: \(inserts.map(\.db))")
            }),
            ("E1 the Gmail draft is not created when only the first database already has leads", {
                LeadgenFixture.allowEmptySuppression()
                let d1 = LeadgenFakeD1()
                await d1.installLeads(LeadgenProjectTarget.meCom.databaseID)
                let mailbox = LeadgenRecordingMailbox()
                let log = LeadgenMemoryLog()
                try await expectError(.leadsTableExists(LeadgenProjectTarget.meCom.databaseID)) {
                    _ = try await LeadgenSliceRunner(config: LeadgenFixture.liveConfig, fetcher: LeadgenFixture.fetcher(), mailbox: mailbox, d1: d1, log: log, now: { "2026-10-24T20:30:00Z" }, dns: LeadgenMappedDNS()).run(
                        candidates: [LeadgenFixture.prospect], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal)
                }
                let calls = await mailbox.calls, inserts = await d1.inserts(), lines = await log.lines
                try check(calls.isEmpty && inserts.isEmpty, "draft or insert ran anyway: calls \(calls), inserts \(inserts)")
                try check(lines.contains("step schema-check \(LeadgenProjectTarget.meCom.databaseID)"), "first database was not checked")
                try check(!lines.contains { $0.contains("gmail-create-draft") }, "draft step was logged: \(lines)")
            }),
            ("Several directory entries on one own domain are one prospect", {
                let html = """
                <html><body>
                <a href="https://www.cliniqueexemple.ca/a">Installation A</a>
                <a href="https://cliniqueexemple.ca/b">Installation B</a>
                <a href="https://www.cliniqueexemple.ca/c">Installation C</a>
                </body></html>
                """
                let fetcher = LeadgenFixture.fetcher()
                fetcher.set(LeadgenFixture.directory.absoluteString, status: 200, body: html)
                let found = try await LeadgenDiscovery.find(directory: LeadgenFixture.directory, paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, fetcher: fetcher, dns: LeadgenMappedDNS())
                try check(found.prospect.organization == "Installation A", "picked \(found.prospect.organization)")
                try check(LeadgenSourcePolicy.normalize(found.prospect.site.host ?? "") == "cliniqueexemple.ca", "site \(found.prospect.site)")
                try check(found.prospect.publicContactEmail == "info@cliniqueexemple.ca", "email \(found.prospect.publicContactEmail)")
                try check(found.consent?.source == "https://www.cliniqueexemple.ca/contact", "consent source \(found.consent?.source ?? "")")
                try check(!fetcher.requested.contains { $0.contains("autreclinique") }, "another domain was fetched: \(fetcher.requested)")
            }),
            ("The directory host is only dpq.quebec", {
                let other = URL(string: "https://annuaire.example/montreal-clinics")!
                try await expectError(.hostNotAllowed("annuaire.example")) {
                    _ = try await LeadgenDiscovery.find(directory: other, paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, fetcher: LeadgenFixture.fetcher(), dns: LeadgenMappedDNS())
                }
            }),
            ("A redirect from dpq.quebec to any other host fails closed", {
                let directory = URL(string: "https://dpq.quebec/repertoire-des-membres")!
                let fetcher = LeadgenFakeFetcher(pages: [:])
                fetcher.set("https://dpq.quebec/robots.txt", status: 200, body: "User-agent: *\nAllow: /\n")
                fetcher.set(directory.absoluteString, status: 302, headers: ["Location": "https://dentistesproprietaires.quebec/repertoire-des-membres/"], body: "")
                try await expectError(.hostNotAllowed("dentistesproprietaires.quebec")) {
                    _ = try await LeadgenDiscovery.find(directory: directory, paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, fetcher: fetcher, dns: LeadgenMappedDNS())
                }
                try check(!fetcher.requested.contains { $0.contains("dentistesproprietaires.quebec") }, "redirect target was fetched: \(fetcher.requested)")
            }),
            ("A rejected candidate writes no row, no suppressed row, and no UPDATE", {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("leadgen-rej-\(UUID().uuidString).json")
                let list = SuppressionList(storageURL: file)
                list.record(LeadgenFixture.prospect.publicContactEmail, at: Date(timeIntervalSince1970: 1_700_000_000), via: "do-not-contact")
                setenv("LEADGEN_SUPPRESSION", file.path, 1)
                defer { unsetenv("LEADGEN_SUPPRESSION"); try? FileManager.default.removeItem(at: file) }
                let d1 = LeadgenFakeD1(), mailbox = LeadgenRecordingMailbox(), log = LeadgenMemoryLog()
                do {
                    _ = try await LeadgenFixture.runner(LeadgenFixture.liveConfig, mailbox: mailbox, d1: d1, log: log).run(
                        candidates: [LeadgenFixture.prospect], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal)
                    throw PortableCheckFailure(description: "a rejected candidate was drafted")
                } catch is PortableCheckFailure { throw PortableCheckFailure(description: "a rejected candidate was drafted") } catch {}
                let inserts = await d1.inserts(), statements = await d1.statements, lines = await log.lines
                let me = await d1.rows(LeadgenProjectTarget.meCom.databaseID, "leads")
                let ph = await d1.rows(LeadgenProjectTarget.pharos.databaseID, "leads")
                try check(inserts.isEmpty && me.isEmpty && ph.isEmpty, "a rejected candidate wrote a row: \(inserts) \(me) \(ph)")
                try check(!me.contains { $0["status"] == "suppressed" } && !ph.contains { $0["status"] == "suppressed" }, "a suppressed row was stored")
                try check(statements.allSatisfy { !$0.sql.uppercased().contains("UPDATE") }, "an UPDATE was sent: \(statements.map(\.sql))")
                try check(lines.contains { $0.contains("suppressed") && $0.contains(LeadgenFixture.prospect.publicContactEmail.lowercased()) }, "the run log did not name the rejection: \(lines)")
            }),
            ("A successful run writes exactly one lead row per database", {
                let d1 = LeadgenFakeD1()
                let report = try await LeadgenFixture.live(d1)
                for db in [LeadgenProjectTarget.meCom.databaseID, LeadgenProjectTarget.pharos.databaseID] {
                    let leads = await d1.rows(db, "leads")
                    let receipt = report.receipts.first { $0.databaseID == db }
                    try check(leads.count == 1 && receipt?.countAfter == (receipt?.countBefore ?? -1) + 1, "\(db) count \(leads.count) receipt \(String(describing: receipt))")
                }
                let statements = await d1.statements
                try check(statements.allSatisfy { !$0.sql.uppercased().contains("UPDATE") }, "success sent an UPDATE")
            }),
            ("The directory URL is only the discovery source; consent and evidence stay on the clinic page", {
                let log = LeadgenMemoryLog()
                let report = try await LeadgenFixture.runner(LeadgenRunConfig.dryRun, mailbox: LeadgenRecordingMailbox(), d1: LeadgenFakeD1(), log: log).run(
                    candidates: [LeadgenFixture.prospect], paths: LeadgenFixture.paths, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal, directory: LeadgenFixture.directory)
                let lines = await log.lines
                let directory = LeadgenFixture.directory.absoluteString
                try check(lines.contains { $0 == "discovery source: \(directory)" }, "discovery source was not recorded: \(lines)")
                try check(report.draft.consent.source == "https://www.cliniqueexemple.ca/contact", "consent source \(report.draft.consent.source)")
                try check(report.fit.evidence.allSatisfy { !$0.url.contains("dpq.quebec") && !$0.url.contains("annuaire.example") }, "evidence used the directory: \(report.fit.evidence)")
                try check(!report.draft.consent.source.contains("dpq.quebec") && !report.draft.consent.source.contains("annuaire.example"), "consent used the directory")
            }),
            ("An admitted IPv6 address is bracketed in the pinned URL", {
                try LeadgenSliceTests.ipv6Pin()
            }),
            ("The slice source has no Gmail send path", {
                let root = LeadgenFixture.repoRoot
                for name in ["native-crm/Sources/FollowUpOSNative/LeadgenSlice.swift", "native-crm/Sources/FollowUpOSNative/LeadgenLive.swift"] {
                    let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
                    try check(!text.contains("messages/send") && !text.contains("drafts/send"), "send path in \(name)")
                }
            }),
        ]
        cases.append(("A write-scoped token declaration is refused", { try LeadgenSliceTests.refuseToken(LeadgenSliceTests.writeScopedPolicy(), LeadgenSliceTests.activeVerification()) }))
        cases.append(("A missing token declaration is refused", { try LeadgenSliceTests.refuseToken(nil, []) }))
        cases.append(("An inactive or unverifiable token is refused", {
            try LeadgenSliceTests.refuseToken(LeadgenSliceTests.readPolicy(), [LeadgenVerifiedToken(id: "id-me", status: "disabled"), LeadgenVerifiedToken(id: "id-ph", status: "active")])
            try LeadgenSliceTests.refuseToken(LeadgenSliceTests.readPolicy(), [nil, LeadgenVerifiedToken(id: "id-ph", status: "active")])
        }))
        cases.append(("A saved D1-read policy is admitted when verify returns that id and active", {
            try LeadgenTokenProof.admit(saved: LeadgenSliceTests.readPolicy(), verified: LeadgenSliceTests.activeVerification())
            let root = LeadgenFixture.repoRoot
            let example = try String(contentsOf: root.appendingPathComponent("docs/leadgen-slice/leadgen.token-policy.example.json"), encoding: .utf8)
            try check(example.contains(LeadgenTokenProof.d1ReadPermissionGroupID), "example policy has no D1 Read group id")
            try check(!example.contains("Bearer "), "example policy contains a token value")
            let ignore = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
            try check(ignore.contains("leadgen.token-policy.json"), "gitignore does not list the policy record")
            let note = try String(contentsOf: root.appendingPathComponent("docs/leadgen-slice/d1-read-token-policy.md"), encoding: .utf8)
            try check(note.contains("not live policy introspection"), "the policy note does not say this is a captured proof")
        }))
        cases.append(("A verify id that does not match the saved token id is refused", {
            try LeadgenSliceTests.refuseToken(LeadgenSliceTests.readPolicy(), [LeadgenVerifiedToken(id: "someone-else", status: "active"), LeadgenVerifiedToken(id: "id-ph", status: "active")])
        }))
        cases.append(("DPQ discovery keeps the clinic name, the dentist name, and the clinic's own site, and never follows a maps link", { try await LeadgenSliceTests.dpqOwnSiteOnly() }))
        cases.append(("The DPQ fixture is a trimmed real page with a fetch time, the original sha256, and one deduped domain", { try LeadgenSliceTests.dpqRealFixture() }))
        cases.append(("Email is a published role address on the clinic site; no-solicitation or no address refuses the entry", { try await LeadgenSliceTests.roleEmailOnly() }))
        cases.append(("The lead row stores the DPQ entry URL and the clinic page URL, each with its fetch time", { try await LeadgenSliceTests.directoryEvidenceRow() }))
        cases.append(("The draft is about the clinic's AI governance and Law 25 obligations, not a person", { try LeadgenSliceTests.clinicDraft() }))
        cases.append(("A directory lead keeps only the clinic, the dentist, the role email, and the two source records; rejection is logged, not purged", { try await LeadgenSliceTests.minimizedLead() }))
        cases.append(("The DPQ page is fetched once, after robots.txt, with the ControlWard User-Agent, for exactly one prospect", { try await LeadgenSliceTests.dpqFetchOnce() }))
        cases.append(("An empty fetchedAt is refused and is not replaced with the quote or the config time", { try await LeadgenSliceTests.emptyFetchedAtRefuses() }))
        cases.append(("A missing, unreadable, or unparseable do-not-contact list means no draft", { try await LeadgenSliceTests.suppressionFailsClosed() }))
        cases.append(("A stored address is matched trimmed and lowercased, and a domain covers subdomains", { try await LeadgenSliceTests.suppressionMatchesNormalized() }))
        cases.append(("The first fiche in page order is the one clinic fetched", { try await LeadgenSliceTests.picksFirstFiche() }))
        cases.append(("A failed first fiche stops the run with one site fetch and no draft", { try await LeadgenSliceTests.firstFicheFailureStops() }))
        cases.append(("The log records the fiche position and both evidence URLs", { try await LeadgenSliceTests.logNamesFicheAndEvidence() }))
        cases.append(("A domain already in projects on either database is skipped before fetch", { try await LeadgenSliceTests.recordedDomainSkipped() }))
        cases.append(("A site that publishes only a personal address on its own domain is refused", { try await LeadgenSliceTests.personalAddressRefused() }))
        cases.append(("info.drtremblay@, info.jtremblay@, clinique-jean@, and contactjean@ are refused", { try await LeadgenSliceTests.longerLocalPartRefused() }))
        cases.append(("office@, hello@, appointments@, clinic@, secretariat@, secretaire@, and bonjour@ are refused", { try await LeadgenSliceTests.extraRoleNamesRefused() }))
        cases.append(("An unconfigured test double fails inside its bound", { try await LeadgenSliceTests.unconfiguredDoubleTimesOut() }))
        #if os(macOS)
        cases.append(("A pinned HTTPS fetch checks the certificate against the hostname, and a mismatched name fails", { try await LeadgenSliceTests.pinnedTLS() }))
        #endif
        return cases
    }
}
