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
        OutreachApproval(approver: "martin", approvalID: id, messageID: draft.messageID)
    }
}

/// Records every request and answers from a script keyed by URL (path + query). Unknown URLs get a 404.
final class FakeLeadTransport: LeadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [String: LeadHTTPResponse] = [:]
    private var seen: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { seen } }
    var urls: [String] { requests.compactMap { $0.url?.absoluteString } }

    func respond(_ url: String, status: Int = 200, body: String, headers: [String: String] = ["content-type": "text/html; charset=utf-8"]) {
        lock.withLock { script[url] = LeadHTTPResponse(status: status, headers: headers, body: Data(body.utf8)) }
    }

    func send(_ request: URLRequest) async throws -> LeadHTTPResponse {
        lock.withLock { seen.append(request) }
        let key = request.url?.absoluteString ?? ""
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
