import Foundation

// Lead-gen slice 1 tests (docs/leadgen-slice/SPEC.md). Fakes only: no network, no Gmail, no D1.

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

struct LeadgenFakeFetcher: LeadgenFetching {
    let pages: [String: (Int, String)]
    func get(_ url: URL) async throws -> (status: Int, body: String) {
        guard let hit = pages[url.absoluteString] else { return (404, "") }
        return (status: hit.0, body: hit.1)
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
        d1StatementsAtDraft.append(await d1.statementCount())
        return "r-draft-1"
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
    func inserts() -> [(db: String, sql: String)] { statements.filter { $0.sql.hasPrefix("INSERT") } }
    func statementCount() -> Int { statements.count }
    func rows(_ db: String, _ table: String) -> [[String: String]] { tables[db]?[table] ?? [] }

    func query(database db: String, sql: String, params: [String]) async throws -> [[String: String]] {
        statements.append((db, sql))
        if sql == LeadgenD1Writer.tablesSQL {
            return (schemas[db] ?? [:]).keys.sorted().map { ["name": $0, "sql": schemas[db]?[$0] ?? ""] }
        }
        if sql == LeadgenMigration.createLeads {
            if tables[db]?["leads"] == nil { tables[db]?["leads"] = []; schemas[db]?["leads"] = sql }
            return []
        }
        if sql == LeadgenD1Writer.countSQL { return [["n": "\(tables[db]?["leads"]?.count ?? 0)"]] }
        if sql == LeadgenD1Writer.readBackSQL {
            return (tables[db]?["leads"] ?? []).filter { $0["id"] == params.first }.map { r in r.filter { ["id", "organization", "status"].contains($0.key) } }
        }
        if sql.hasPrefix("SELECT * FROM ") {
            let name = sql.dropFirst("SELECT * FROM ".count).replacingOccurrences(of: "\"", with: "")
            return tables[db]?[name] ?? []
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

enum LeadgenFixture {
    static let site = URL(string: "https://www.cliniqueexemple.ca/")!
    static let prospect = LeadgenProspect(organization: "Clinique Exemple", segment: "montreal-clinics", site: site, publicContactEmail: "info@cliniqueexemple.ca")
    static let consent = LeadgenConsentBasis(basis: "CASL s.10(9)(b) conspicuous publication; Loi 25 public business contact", source: "https://www.cliniqueexemple.ca/contact", recordedAt: "2026-10-24T20:00:00Z")
    static let postal = "1000 rue Exemple, Montréal (Québec) H0H 0H0"
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
        ])
    }
    static let liveConfig = LeadgenRunConfig.from(arguments: ["--live"], environment: ["LEADGEN_OPERATOR_OK": LeadgenRunConfig.confirmation])
    static func runner(_ config: LeadgenRunConfig, mailbox: LeadgenRecordingMailbox, d1: LeadgenFakeD1, log: LeadgenMemoryLog = LeadgenMemoryLog(), fetcher: LeadgenFakeFetcher = fetcher()) -> LeadgenSliceRunner {
        LeadgenSliceRunner(config: config, fetcher: fetcher, mailbox: mailbox, d1: d1, log: log, now: { "2026-10-24T20:30:00Z" })
    }
    static let row = LeadgenLeadRow(id: "lead-x", organization: "X", site: "https://x.ca/", fitReason: "r", fitEvidence: "e", draftRef: "d", consentBasis: "c", createdAt: "2026-10-24T20:30:00Z")
    static func live(_ d1: LeadgenFakeD1, _ mailbox: LeadgenRecordingMailbox = LeadgenRecordingMailbox(), log: LeadgenMemoryLog = LeadgenMemoryLog()) async throws -> LeadgenRunReport {
        try await runner(liveConfig, mailbox: mailbox, d1: d1, log: log).run(candidates: [prospect], paths: paths, consent: consent, postalAddress: postal)
    }
    static func tempConfig(postal: String? = postal) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("leadgen-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var obj: [String: Any] = [
            "prospect": ["organization": prospect.organization, "site": site.absoluteString, "publicContactEmail": prospect.publicContactEmail],
            "paths": paths,
            "consent": ["basis": consent.basis, "source": consent.source, "recordedAt": consent.recordedAt],
        ]
        if let postal { obj["postalAddress"] = postal }
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
}

enum LeadgenSliceTests {
    static func run() async -> Bool {
        await PortableCheck.suite("Lead-gen slice 1", [
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
                let reader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: ["cliniqueexemple.ca"]), fetcher: LeadgenFixture.fetcher(robots: "User-agent: *\nDisallow: /services\n"))
                try await expectError(.robotsDisallowed("/services")) { _ = try await reader.read(site: LeadgenFixture.site, paths: LeadgenFixture.paths) }
                let log = await reader.fetchedURLs
                try check(log == ["https://www.cliniqueexemple.ca/robots.txt", "https://www.cliniqueexemple.ca/"], "fetch log \(log)")
                let ok = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: ["cliniqueexemple.ca"]), fetcher: LeadgenFixture.fetcher())
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
                let reader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: ["cliniqueexemple.ca"]), fetcher: LeadgenFixture.fetcher())
                let pages = try await reader.read(site: LeadgenFixture.site, paths: LeadgenFixture.paths)
                let fit = try LeadgenFitFinder.find(pages: pages, prospect: LeadgenFixture.prospect)
                try check(fit.evidence.count >= 1, "no evidence")
                let e = fit.evidence[0]
                try check(e.quote.contains("intelligence artificielle pour trier"), "quote not from body: \(e.quote)")
                try check(URL(string: e.url)?.host == "www.cliniqueexemple.ca", "evidence off domain: \(e.url)")
                try check(fit.reason.contains(e.quote) && fit.reason.contains("Loi 25"), "reason does not cite the quote")
            }),
            ("LG4 footer-link or privacy-only evidence is refused (LIVE-R4)", {
                let reader = LeadgenSiteReader(policy: LeadgenSourcePolicy(allowedHosts: ["cliniqueexemple.ca"]), fetcher: LeadgenFixture.fetcher(home: LeadgenFixture.footerOnly))
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
                let draft = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal)
                let raw = draft.rawMIME
                try check(raw.contains("X-PHAROS-Consent-Basis: CASL") && raw.contains("Loi 25"), "no consent basis header")
                try check(draft.body.contains("désabonnement") && draft.body.contains("unsubscribe") && draft.body.contains(LeadgenFixture.postal), "no CASL footer")
                try check(draft.body.contains("Martin Lepage, PhD") && draft.from == "ml@pharos-ai.ca", "signature or sender wrong")
                try check(!raw.contains("\u{2014}") && !raw.contains("\u{2013}"), "dash in draft")
                try await expectError(.missingConsentBasis) { _ = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: nil, postalAddress: LeadgenFixture.postal) }
                let dashed = LeadgenFit(reason: "r", evidence: [LeadgenFitEvidence(url: "u", quote: "IA \u{2014} partout")])
                try await expectError(.dashNotAllowed) { _ = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: dashed, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal) }
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
                let probe = LeadgenDepsProbe(deps: LeadgenLiveDeps(fetcher: LeadgenFixture.fetcher(), mailbox: mailbox, d1: d1, log: LeadgenMemoryLog(), logPath: "-"))
                let env = ["LEADGEN_CONFIG": try LeadgenFixture.tempConfig()]
                let (code, lines) = await LeadgenCLI.run(arguments: [], environment: env, makeLive: probe.make)
                let calls = await mailbox.calls, statements = await d1.statementCount()
                try check(code == 0, "dry-run exit \(code)")
                try check(lines.first?.contains("DRY RUN") == true, "no DRY RUN banner: \(lines.first ?? "")")
                try check(lines.contains(where: { $0.contains("STOP if a leads table exists") }) && lines.contains(where: { $0.contains(LeadgenRunConfig.confirmation) }), "plan lines missing")
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
            ("LG7 live step order: schema check both, then per DB before/0001/insert/read-back/after, then Gmail draft last, logged", {
                let d1 = LeadgenFakeD1(), log = LeadgenMemoryLog()
                let mailbox = LeadgenOrderMailbox(d1: d1)
                let probe = LeadgenDepsProbe(deps: LeadgenLiveDeps(fetcher: LeadgenFixture.fetcher(), mailbox: mailbox, d1: d1, log: log, logPath: "mem"))
                let env = ["LEADGEN_CONFIG": try LeadgenFixture.tempConfig()]
                let (code, lines) = await LeadgenCLI.run(arguments: ["--live", "--confirm", LeadgenRunConfig.confirmation], environment: env, makeLive: probe.make)
                try check(code == 0, "live exit \(code): \(lines)")
                let me = LeadgenProjectTarget.meCom.databaseID, ph = LeadgenProjectTarget.pharos.databaseID
                let steps = await log.lines.filter { $0.hasPrefix("step ") }
                var expected = ["step schema-check \(me)", "step schema-check \(ph)"]
                for db in [me, ph] { expected += ["checksum-before", "apply-0001", "insert", "read-back", "checksum-after"].map { "step \($0) \(db)" } }
                expected.append("step gmail-create-draft ml@pharos-ai.ca")
                try check(steps == expected, "step order \(steps)")
                let atDraft = await mailbox.d1StatementsAtDraft, total = await d1.statementCount()
                try check(atDraft == [total], "Gmail draft was not last: D1 statements at draft \(atDraft), total \(total)")
                let all = await log.lines
                try check(all.contains(where: { $0.hasPrefix("\(me) projects count before") }) && all.contains(where: { $0.hasPrefix("\(ph) projects count before") }), "projects count before not logged")
                let inserted = await d1.rows(me, "leads")
                try check(inserted.first?["draft_ref"]?.hasPrefix("<leadgen-") == true, "draft_ref is not the local Message-ID")
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
                        _ = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: LeadgenFixture.consent, postalAddress: missing)
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
            }),
            ("LG8 a footer address on the denied street (Saint-Hubert) is refused in every spelling", {
                let fit = try LeadgenFixture.fit()
                for bad in ["1000 rue Saint-Hubert, Montréal", "1000, rue St-Hubert", "1000 SAINT HUBERT", "1000 rue saint-hubert", "1000 rue Saint‑Hubert"] {
                    try await expectError(.postalAddressDenied("saint-hubert")) {
                        _ = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: LeadgenFixture.consent, postalAddress: bad)
                    }
                }
                let ok = try LeadgenDraftComposer.compose(prospect: LeadgenFixture.prospect, fit: fit, consent: LeadgenFixture.consent, postalAddress: LeadgenFixture.postal)
                try check(ok.body.contains(LeadgenFixture.postal), "a clean address was not used")
                try check(LeadgenDraftComposer.deniedStreets == ["saint-hubert"], "denylist must hold the street name only")
            }),
            ("LG8 the repo holds only a placeholder example config and ignores the local one", {
                let root = LeadgenFixture.repoRoot
                let example = try String(contentsOf: root.appendingPathComponent("docs/leadgen-slice/leadgen.local.example.json"), encoding: .utf8)
                let parsed = try JSONDecoder().decode(LeadgenLocalConfig.self, from: Data(example.utf8))
                try check(parsed.postalAddress?.hasPrefix("PLACEHOLDER") == true, "example address is not a placeholder")
                let ignore = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
                try check(ignore.split(separator: "\n").contains("leadgen.local.json"), ".gitignore does not list leadgen.local.json")
                try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/leadgen-slice/leadgen.local.json").path), "a local config sits in the repo tree")
            }),
        ])
    }
}
