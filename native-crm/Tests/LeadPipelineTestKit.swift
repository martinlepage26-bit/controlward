import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Synthetic fixtures for the lead-pipeline tests. Every name, domain and address here is made up;
/// `.test` domains never resolve. No real prospect data is used (heads-up, Oct 23).
enum LeadKit {
    static let configDirectory: URL = {
        if let env = ProcessInfo.processInfo.environment["CONTROLWARD_CONFIG_DIR"] { return URL(fileURLWithPath: env) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FollowUpOSNative/Resources/config")
    }()

    static let sourcesDirectory: URL = configDirectory.deletingLastPathComponent().deletingLastPathComponent()

    /// One synthetic clinic as an Overpass answer (made-up name, .test domain).
    static let overpassOneClinic = """
    {"elements":[{"type":"node","id":2001,"lat":45.5,"lon":-73.6,"tags":{"name":"Clinique Exemple Sud","healthcare":"clinic","website":"https://www.clinique-sud.test"}}]}
    """

    static func config() throws -> ICPConfig { try ICPConfig.load(directory: configDirectory) }

    static func confirmed() throws -> ICPConfirmed {
        try ICPConfirmed.decode(Data(contentsOf: configDirectory.appendingPathComponent("icp.confirmed.json")))
    }

    /// 2026-10-23 14:00 UTC (10:00 AM in Montréal).
    static let now = Date(timeIntervalSince1970: 1_792_764_000)

    static let clinicDomain = "clinique-exemple.test"
    static let clinicAddress = "1234, rue Imaginaire, Montréal (Québec) H0H 0H0"
    static let contactPage = "https://www.clinique-exemple.test/nous-joindre"
    static let teamPage = "https://www.clinique-exemple.test/equipe"
    static let homePage = "https://www.clinique-exemple.test/"

    /// A clinic prospect that passes LEAD_DEF, address provenance, consent and every draft rule.
    static func readyClinic(id: String = "cw:osm:node/1001", email: String = "info@clinique-exemple.test") -> ProspectRecord {
        var record = ProspectRecord(id: id, organisation: "Clinique Exemple Nord", segment: "clinic")
        record.sourceURL = homePage
        record.fetchedAt = now.addingTimeInterval(-3600)
        record.fetcher = "controlward:test-run"
        record.businessDomain = clinicDomain
        record.address = clinicAddress
        record.addressSource = .ownSite
        record.addressSourceURL = contactPage
        record.snapshots = [
            SiteSnapshot(url: homePage, fetchedAt: now.addingTimeInterval(-3600), text: "Clinique Exemple Nord\nPrendre rendez-vous en ligne"),
            SiteSnapshot(url: contactPage, fetchedAt: now.addingTimeInterval(-3500), text: "Nous joindre\n\(clinicAddress)\n\(email)"),
            SiteSnapshot(url: teamPage, fetchedAt: now.addingTimeInterval(-3400), text: "Équipe\nAlex Fictif, directrice générale")
        ]
        record.contact = ProspectContact(name: "Alex Fictif", title: "directrice générale", titleSource: .checkedDirect, source: .ownSite, sourceURL: teamPage)
        record.route = ProspectRoute(kind: .email, value: email, sourceURL: contactPage, source: .ownSite)
        record.email = email
        record.trigger = ProspectTrigger(kind: "ai_tool_on_own_site", url: homePage, fetchedAt: now.addingTimeInterval(-3600), origin: .pageFetch,
                                         summary: "online booking on /")
        record.fit = "Clinic with online booking: AI-tool guardrails"
        record.consent = .conspicuousPublication(contactPage)
        var facts = ObservedFacts(companyName: "Clinique Exemple Nord", serviceCategories: ["clinique"], languagesSeen: ["fr"], contactPageURL: contactPage)
        facts.evidence = ["company_name": [FactEvidence(url: homePage, excerpt: "Clinique Exemple Nord")],
                          "service_categories": [FactEvidence(url: homePage, excerpt: "Clinique Exemple Nord")],
                          "languages_seen": [FactEvidence(url: contactPage, excerpt: "Nous joindre")],
                          "contact_page_url": [FactEvidence(url: contactPage, excerpt: "Nous joindre")]]
        record.research = ProspectResearch(observedFacts: facts, assessment: ResearchAssessment(
            potentialOffer: "Clinics: AI-use guardrails review (signal: ai_tool_on_own_site)",
            supportingEvidence: [FactEvidence(url: homePage, excerpt: "Prendre rendez-vous en ligne")],
            unknowns: ["service areas", "booking URL"], requiresManualReview: false))
        return record
    }

    static func university(fetchedDaysAgo days: Double) -> ProspectRecord {
        var record = readyClinic(id: "cw:osm:way/2002")
        record.organisation = "Université Fictive"
        record.segment = "university"
        record.trigger = ProspectTrigger(kind: "newsroom", url: homePage, fetchedAt: now.addingTimeInterval(-days * 86_400), origin: .pageFetch,
                                         summary: "newsroom item on AI governance")
        return record
    }

    static func draft(for record: ProspectRecord, config: ICPConfig, messageID: String = "cw-draft-1", language: String = "fr") -> OutreachDraft {
        OutreachDraftBuilder.build(for: record, config: config, language: language, messageID: messageID)
    }

    static func approval(_ draft: OutreachDraft, id: String = "A-1") -> OutreachApproval {
        OutreachApproval.grant(for: draft, approvalID: id)
    }
}

/// Records every request and answers from a script keyed by URL (path + query). Unknown URLs get a 404.
final class FakeLeadTransport: LeadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [String: LeadHTTPResponse] = [:]
    private var seen: [URLRequest] = []
    private var failures: [String: any Error] = [:]
    private var queued: [String: [LeadHTTPResponse]] = [:]

    var requests: [URLRequest] { lock.withLock { seen } }
    var urls: [String] { requests.compactMap { $0.url?.absoluteString } }

    func respond(_ url: String, status: Int = 200, body: String, headers: [String: String] = ["content-type": "text/html; charset=utf-8"]) {
        lock.withLock { script[url] = LeadHTTPResponse(status: status, headers: headers, body: Data(body.utf8)) }
    }

    /// The transport answers `url` with a body that came from `finalURL` (as if it had followed a redirect itself).
    func respondFrom(_ url: String, finalURL: String, body: String) {
        lock.withLock { script[url] = LeadHTTPResponse(status: 200, headers: ["content-type": "text/html"], body: Data(body.utf8), url: URL(string: finalURL)) }
    }

    /// The URL throws `error` (e.g. a timeout) instead of answering.
    func fail(_ url: String, _ error: any Error) { lock.withLock { failures[url] = error } }

    /// One-shot answer served before the scripted one (e.g. a 429, then success).
    func enqueue(_ url: String, status: Int, body: String, headers: [String: String] = [:]) {
        lock.withLock { queued[url, default: []].append(LeadHTTPResponse(status: status, headers: headers, body: Data(body.utf8))) }
    }

    func send(_ request: URLRequest) async throws -> LeadHTTPResponse {
        lock.withLock { seen.append(request) }
        let key = request.url?.absoluteString ?? ""
        if let error = lock.withLock({ failures[key] }) { throw error }
        if let next = lock.withLock({ () -> LeadHTTPResponse? in
            guard var list = queued[key], !list.isEmpty else { return nil }
            let first = list.removeFirst(); queued[key] = list; return first
        }) { return next }
        return lock.withLock { script[key] } ?? LeadHTTPResponse(status: 404, headers: [:], body: Data())
    }
}

/// A clock that only moves when the code sleeps (rate limit) or the test advances it.
final class FakeLeadClock: LeadClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var slept: [Double] = []
    init(_ start: Date = LeadKit.now) { current = start }
    var now: Date { lock.withLock { current } }
    var sleeps: [Double] { lock.withLock { slept } }
    func advance(_ seconds: Double) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    func sleep(seconds: Double) async { lock.withLock { slept.append(seconds); current = current.addingTimeInterval(seconds) } }
}

/// RBQ fixtures. The header row is copied byte for byte from a real RBQ CSV download (Air, 2026-10-23 06:47 EDT,
/// map section 10a); the JSON record shape is copied from the real JSON file. Every data value is synthetic.
enum RBQFixture {
    static let csvHeader = #""Numéro de licence","Statut de la licence","Type de licence","Date de délivrance","Restriction","Date de début de la restriction","Date de fin de la restriction","Association ou compagnie fournissant le cautionnement","Montant de la caution","Date du paiement annuel","Mandataire","Courriel","Adresse","NEQ","Nom de l'intervenant","Numéro de téléphone","Municipalité","Statut juridique","Code de région administrative","Région administrative","Nombre de sous-catégorie autorisées","Categorie","Sous-catégories","Autre nom""#

    /// Keys of one real JSON licence record (Air's map 10b, checked against a real download 2026-10-23): the CSV header
    /// without 'Categorie' and 'Sous-catégories', which are nested in 'Catégories et sous-catégories'.
    static var jsonKeys: [String] {
        csvHeader.dropFirst().dropLast().components(separatedBy: "\",\"").filter { $0 != "Categorie" && $0 != "Sous-catégories" }
            + ["Catégories et sous-catégories"]
    }

    /// One CSV row (one licence x one sub-category), all values synthetic. Only used to prove a CSV file is refused.
    static func csvRow(licence: String, name: String, town: String, category: String, code: String, otherName: String = "") -> String {
        let values = [licence, "Valide", "Entrepreneur", "2001-01-01", "", "", "", "", "", "2026-01-01", "Mandataire Fictif",
                      "secret@exemple-rbq.test", "1 rue Nulle", "0000000000", name, "514-555-0100", town, "Société par actions",
                      "06", "Montréal (06)", "3", category, code, otherName]
        return values.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
    }

    static func csv(_ rows: [String], header: String = csvHeader) -> Data { Data(([header] + rows).joined(separator: "\n").appending("\n").utf8) }

    /// One JSON record in the real file's shape: {"Licence":{..., "Catégories et sous-catégories":[{"Categorie":..,"Sous-catégories":..}]}}.
    static func jsonRecord(licence: String, name: String, town: String, codes: [(String?, String)], dropping: String? = nil,
                           otherNames: String = "null", renaming: (String, String)? = nil, extra: (String, String)? = nil) -> String {
        let list = codes.map { category, code in
            category.map { #"{"Categorie":"\#($0)","Sous-catégories":"\#(code)"}"# } ?? #"{"Sous-catégories":"\#(code)"}"#
        }.joined(separator: ",")
        var fields: [(String, String)] = [
            ("Numéro de licence", "\"\(licence)\""), ("Statut de la licence", "\"Valide\""), ("Type de licence", "\"Entrepreneur\""),
            ("Date de délivrance", "\"2001-01-01\""), ("Restriction", "\"\""), ("Date de début de la restriction", "\"\""),
            ("Date de fin de la restriction", "\"\""), ("Association ou compagnie fournissant le cautionnement", "null"), ("Montant de la caution", "null"),
            ("Date du paiement annuel", "\"2026-01-01\""), ("Mandataire", "\"Mandataire Fictif\""), ("Courriel", "\"secret@exemple-rbq.test\""),
            ("Adresse", "\"1 rue Nulle\""), ("NEQ", "\"0000000000\""), ("Nom de l'intervenant", "\"\(name)\""), ("Numéro de téléphone", "\"514-555-0100\""),
            ("Municipalité", "\"\(town)\""), ("Statut juridique", "\"Société par actions\""), ("Code de région administrative", "\"06\""),
            ("Région administrative", "\"Montréal (06)\""), ("Nombre de sous-catégorie autorisées", "\(codes.count)"),
            ("Catégories et sous-catégories", "[\(list)]"), ("Autre nom", otherNames)
        ]
        if let dropping { fields.removeAll { $0.0 == dropping } }
        if let (from, to) = renaming { fields = fields.map { $0.0 == from ? (to, $0.1) : $0 } }
        if let extra { fields.append(extra) }
        return #"{"Licence":{"# + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}}"
    }

    static func json(_ records: [String]) -> Data { Data((#"{"Liste Licence":["# + records.joined(separator: ",") + "]}").utf8) }

    /// Excerpt of RBQ's official sub-category list (annexes II and III), copied from
    /// https://www.rbq.gouv.qc.ca/licence/determiner-vos-sous-categories-de-licence/entrepreneur-specialise/sous-categories-dentrepreneur-specialise/
    /// on 2026-10-23 06:50 EDT. Every code the config holds on must appear here with a plumbing or excavation title.
    static let officialSubcategories: [String: String] = [
        "2.4": "Entrepreneur en systèmes d’assainissement autonome",
        "2.5": "Entrepreneur en excavation et terrassement",
        "2.6": "Entrepreneur en pieux et fondations spéciales",
        "2.7": "Entrepreneur en travaux d’emplacement",
        "11.2": "Entrepreneur en équipements et produits spéciaux",
        "15.4": "Entrepreneur en systèmes de chauffage hydronique",
        "15.5": "Entrepreneur en plomberie",
        "16.0": "Entrepreneur en électricité"
    ]
}

/// Earth 6:59: runs the app path (LeadPipelineEnvironment.searchAndIngest) for the construction_trades segment with the
/// cached RBQ index missing (contents nil) or replaced by the given bytes. Every firm it finds must come back held.
/// Runs the app path (LeadPipelineEnvironment.searchAndIngest) for construction_trades over SearchFixture.constructionBatch,
/// with the cached RBQ file absent (nil) or holding `contents`.
enum EarthRBQ {
    struct Outcome { var prospects: [ProspectRecord]; var drafts: [OutreachDraft]; var audit: [CWAuditLine] }
    static func appRun(contents: Data?) async throws -> Outcome {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cw-earth-rbq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let env = try LeadPipelineEnvironment.load(configDirectory: LeadKit.configDirectory, root: root)
        if let contents {
            try FileManager.default.createDirectory(at: env.rbqDirectory, withIntermediateDirectories: true)
            try contents.write(to: RBQOpenData.cacheFile(in: env.rbqDirectory))
        }
        let fixture = SearchFixture.mixedConstructionBatch(config: env.config)
        let audit = MemoryAuditSink()
        let reports = await env.searchAndIngest([.init(segmentID: "construction_trades", latitude: 45.5, longitude: -73.6, radiusMeters: 3000, limit: 5)],
                                                inner: fixture.inner, audit: audit, clock: fixture.clock)
        return Outcome(prospects: reports.flatMap(\.prospects), drafts: reports.flatMap(\.drafts), audit: audit.lines)
    }
}
