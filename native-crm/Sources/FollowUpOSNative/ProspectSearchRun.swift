import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ControlWard's own prospect search (S3-R16): discovery, own-site fetch, extraction, LEAD_DEF score and a local
/// draft. Every step writes a CW-AUDIT line. It never sends and never writes to Project Control.
struct ProspectSearchRun: Sendable {
    struct Request: Sendable {
        var segmentID: String
        var latitude: Double
        var longitude: Double
        var radiusMeters: Int
        var limit: Int
        var language: String = "fr"
    }

    struct Report: Sendable {
        var runID: String
        var candidates = 0
        var prospects: [ProspectRecord] = []
        var drafts: [OutreachDraft] = []
        var refusals: [String: String] = [:]
        var skipped: [String: String] = [:]
        /// Every place discovery returned (place id + normalized domain only), for the Overview funnel.
        var discovered: [DiscoveredPlace] = []
    }

    let config: ICPConfig
    let transport: GuardedLeadTransport
    let audit: any CWAuditSink
    let clock: any LeadClock
    let suppression: SuppressionList
    var rbq: RBQIndex?
    /// Set when the cached RBQ file exists but could not be read (e.g. refused:open-data-schema).
    var rbqFailure: String?
    var watchItems: [WatchItem] = []
    var runID = UUID().uuidString.lowercased()

    func run(_ request: Request) async -> Report {
        var report = Report(runID: runID)
        guard let segment = config.segment(request.segmentID) else {
            audit.write(CWAuditLine(ts: clock.now, surface: "leads", action: "search", target: request.segmentID, source: "controlward",
                                    result: "refused:unknown-segment", receipt: runID))
            return report
        }
        let (candidates, outcomes) = await LeadDiscovery(transport: transport).searchWithOutcomes(
            selectors: segment.osmSelectors, latitude: request.latitude, longitude: request.longitude,
            radiusMeters: request.radiusMeters, limit: request.limit)
        // One search line per selector naming the provider that actually answered (Earth 8:19); no provider means an error result.
        for outcome in outcomes {
            audit.write(CWAuditLine(ts: clock.now, surface: "leads", action: "search", register: outcome.provider.map { CWAuditLine.register(for: $0) } ?? "-",
                                    target: segment.id, source: "controlward", result: outcome.result, receipt: runID))
        }
        report.candidates = candidates.count
        // Every skipped candidate is audited with its provider, map id and reason (Earth 8:19).
        func skip(_ candidate: LeadCandidate, _ reason: String) {
            report.skipped[candidate.osmID] = reason
            audit.write(CWAuditLine(ts: clock.now, surface: "leads", action: "skip", register: candidate.provider.map { CWAuditLine.register(for: $0) } ?? "-",
                                    target: candidate.osmID, source: candidate.provider?.host?.lowercased() ?? "-",
                                    result: "skipped:" + Self.reasonCode(reason), receipt: runID))
        }
        var seenDomains = Set<String>()
        for candidate in candidates {
            let website = candidate.website.flatMap(Self.siteURL)
            let host = website?.host?.lowercased()
            let normalized = ProspectIdentity.normalizedDomain(host)
            var place = DiscoveredPlace(placeID: candidate.osmID, domain: normalized, usableWebsite: false, closed: candidate.closed)
            defer { report.discovered = DiscoveredPlace.merge([place], into: report.discovered) }
            if candidate.closed {
                skip(candidate, "closed business")
                continue
            }
            guard let siteURL = website, let host else {
                skip(candidate, "no own website on the listing")
                continue
            }
            if config.isNeverFetch(host: host) || config.deniedHost(host) != nil || GuardedLeadTransport.ownSiteHostRefusal(siteURL) != nil {
                skip(candidate, "website host not fetchable")
                continue
            }
            if let normalized, !seenDomains.insert(normalized).inserted {
                skip(candidate, "duplicate domain")
                continue
            }
            let domain = HostMatch.registrable(host)
            let pages = await fetchSite(siteURL, domain: domain, segment: segment)
            guard !pages.isEmpty else { skip(candidate, "own site not readable"); continue }
            if ProspectIdentity.siteSaysClosed(pages) {
                place.closed = true
                skip(candidate, "closed business (own site)")
                continue
            }
            place.usableWebsite = true
            var record = Self.prospect(from: candidate, pages: pages, domain: domain, segment: segment, config: config, runID: runID)
            if let rbqFailure {
                record.rbqCheck = "error:\(rbqFailure)"
            } else if let source = RBQOpenData.source(config), let rbq {
                rbq.enrich(&record, municipality: candidate.city, source: source)
            } else {
                record.rbqCheck = "unavailable"
            }
            if let tender = TenderWatcher.openTender(for: record.organisation, in: watchItems, now: clock.now) { record.openTenderURL = tender.link }
            let verdict = LeadDefinition.evaluate(record, config: config, now: clock.now)
            record.status = verdict.status
            record.reasons = verdict.reasons
            record.risk = LeadDefinition.riskLine(record)
            audit.write(CWAuditLine(ts: clock.now, surface: "leads", action: "score", register: record.sourceURL ?? "-", target: record.id,
                                    source: "controlward", result: "ok",
                                    receipt: "\(record.status.rawValue)@\(record.fetchedAt.map(CWAuditLine.timestamp) ?? "-")"))
            if record.status == .ready {
                let draft = OutreachDraftBuilder.build(for: record, config: config, language: request.language, messageID: "cw-draft-\(runID)-\(report.drafts.count + 1)")
                if let refusal = OutreachDraftGate.check(draft, prospect: record, config: config, suppression: suppression, now: clock.now) {
                    report.refusals[record.id] = refusal.code
                    audit.write(CWAuditLine(ts: clock.now, surface: "leads", action: "draft", register: record.sourceURL ?? "-", target: record.id,
                                            source: "controlward", result: refusal.code))
                } else {
                    report.drafts.append(draft)
                    audit.write(CWAuditLine(ts: clock.now, surface: "leads", action: "draft", register: record.sourceURL ?? "-", target: record.id,
                                            source: "controlward", result: "ok", receipt: draft.messageID))
                }
            }
            report.prospects.append(record)
        }
        return report
    }

    /// A skip reason as an audit result code: lowercase words joined by `-`.
    static func reasonCode(_ reason: String) -> String {
        let words = reason.lowercased().split { !($0.isLetter || $0.isNumber) }
        return words.isEmpty ? "unspecified" : words.joined(separator: "-")
    }

    static func siteURL(_ website: String) -> URL? {
        let trimmed = website.trimmingCharacters(in: .whitespaces)
        let withScheme = trimmed.lowercased().hasPrefix("http") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = "/"
        return components.url
    }

    /// Page kinds the configured own-site paths stand for, with the French and English words a site's own links use.
    /// Order is the crawl priority: people first (team, contact), then trigger pages, then the rest.
    static let pageKinds: [(kind: String, words: [String])] = [
        ("team", ["equipe", "team", "direction", "leadership", "personnel", "staff", "people"]),
        ("contact", ["nous-joindre", "joindre", "contact"]),
        ("news", ["salle-de-presse", "nouvelles", "newsroom", "news", "press", "medias"]),
        ("careers", ["carrieres", "carriere", "emplois", "emploi", "careers", "career", "jobs"]),
        ("about", ["a-propos", "apropos", "about"]),
        ("quote", ["soumission", "quote"]),
        ("privacy", ["politique-de-confidentialite", "confidentialite", "privacy"])
    ]

    static func pageKind(ofPath path: String) -> String? {
        let segments = path.lowercased().folding(options: .diacriticInsensitive, locale: nil).split(separator: "/").map(String.init)
        for (kind, words) in pageKinds where segments.contains(where: { segment in words.contains { segment.contains($0) } }) { return kind }
        return nil
    }

    /// Live-proof cause 1 (Water 10:13): the crawl used to guess the segment's slugs in config order and stop at the page budget,
    /// so a site whose team or contact page lives at another path (e.g. /en/contact-us, /why-us/our-team) yielded no person.
    /// After the home page, it now takes, per page kind the segment asks for, the shortest same-site link the home page itself
    /// shows; configured slugs fill only the kinds no link covered. The page budget is unchanged.
    static func crawlPlan(root: URL, home: SiteExtractor.Page?, segment: ICPConfig.Segment, budget: Int) -> [URL] {
        let wanted = segment.ownSitePaths.compactMap(pageKind(ofPath:))
        let kinds = pageKinds.map(\.kind).filter { wanted.contains($0) }
        let homeURL = home.flatMap { URL(string: $0.url) } ?? root
        let host = (homeURL.host ?? root.host ?? "").lowercased()
        var linked: [String: URL] = [:]
        for link in home?.links ?? [] {
            guard let url = URL(string: link, relativeTo: homeURL)?.absoluteURL, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.lowercased() == host, url.path.count > 1, let kind = pageKind(ofPath: url.path), kinds.contains(kind) else { continue }
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.query = nil
            parts?.fragment = nil
            guard let clean = parts?.url else { continue }
            if let current = linked[kind], (current.path.split(separator: "/").count, current.path.count) <= (clean.path.split(separator: "/").count, clean.path.count) { continue }
            linked[kind] = clean
        }
        var plan: [URL] = kinds.compactMap { linked[$0] }
        for path in segment.ownSitePaths where path != "/" {
            guard let url = URL(string: path, relativeTo: root)?.absoluteURL else { continue }
            if let kind = pageKind(ofPath: path), linked[kind] != nil { continue }
            plan.append(url)
        }
        var seen = Set<String>([homeURL.absoluteString, root.absoluteString])
        plan = plan.filter { seen.insert($0.absoluteString).inserted }
        return Array(plan.prefix(max(budget - 1, 0)))
    }

    func fetchSite(_ root: URL, domain: String, segment: ICPConfig.Segment) async -> [SiteExtractor.Page] {
        var pages: [SiteExtractor.Page] = []
        let budget = config.etiquette.maxPagesPerSite
        let first = segment.ownSitePaths.first.flatMap { URL(string: $0, relativeTo: root)?.absoluteURL } ?? root
        var queue: [URL] = [first]
        var planned = false
        while !queue.isEmpty {
            let url = queue.removeFirst()
            defer {
                if !planned {
                    planned = true
                    queue = Self.crawlPlan(root: root, home: pages.first, segment: segment, budget: budget)
                }
            }
            do {
                let response = try await transport.fetch(url, purpose: .ownSite(domain: domain))
                guard (200..<300).contains(response.status) else { continue }
                let type = response.headers["content-type"]?.lowercased() ?? "text/html"
                guard type.contains("html") else { continue }
                let page = SiteExtractor.read(html: String(decoding: response.body, as: UTF8.self), url: response.url ?? url, fetchedAt: response.fetchedAt)
                transport.registerSensitive(page.emails + page.phones + page.people.map(\.name) + [page.address].compactMap { $0 }
                                            + page.text.components(separatedBy: "\n").filter { $0.count >= 12 })
                pages.append(page)
            } catch let refusal as LeadPipelineRefusal where refusal.code == "refused:bot-challenge" {
                planned = true
                queue = []
            } catch {
                continue
            }
        }
        return pages
    }

    /// Builds the record from own-site pages only. Discovery contributes the name, segment match and OSM tags.
    static func prospect(from candidate: LeadCandidate, pages: [SiteExtractor.Page], domain: String, segment: ICPConfig.Segment,
                         config: ICPConfig, runID: String) -> ProspectRecord {
        var record = ProspectRecord(id: "cw:\(candidate.osmID)", organisation: candidate.name, segment: segment.id)
        record.provenance = .controlWardSearch
        record.fetcher = "controlward:\(runID)"
        record.businessDomain = domain
        record.osmTags = candidate.tags
        record.town = candidate.city
        record.snapshots = pages.map { SiteSnapshot(url: $0.url, fetchedAt: $0.fetchedAt, text: $0.text, links: $0.links) }
        if let page = pages.first(where: { $0.address != nil }) {
            record.address = page.address
            record.addressSource = .ownSite
            record.addressSourceURL = page.url
        }
        if let page = pages.first(where: { !$0.people.isEmpty }), let person = page.people.first {
            record.contact = ProspectContact(name: person.name, title: person.title, titleSource: .checkedDirect, source: .ownSite, sourceURL: page.url)
        }
        let emailPage = pages.first { page in page.emails.contains { MailAddress.domain($0).map { HostMatch.belongs($0, to: domain) } == true } }
            ?? pages.first { !$0.emails.isEmpty }
        if let page = emailPage, let email = page.emails.first(where: { MailAddress.domain($0).map { HostMatch.belongs($0, to: domain) } == true }) ?? page.emails.first {
            record.email = email
            record.route = ProspectRoute(kind: .email, value: email, sourceURL: page.url, source: .ownSite)
            if !page.refusesSolicitation { record.consent = .conspicuousPublication(page.url) }
        } else if let page = pages.first(where: { !$0.phones.isEmpty }), let phone = page.phones.first {
            record.phone = phone
            record.route = ProspectRoute(kind: .phone, value: phone, sourceURL: page.url, source: .ownSite)
        }
        if record.phone == nil { record.phone = pages.lazy.compactMap(\.phones.first).first }
        let triggers = pages.flatMap { SiteExtractor.triggers(in: $0, segment: segment, config: config) }
        if let trigger = triggers.first {
            record.trigger = trigger
            record.fit = "\(segment.label): \(trigger.summary)"
            record.sourceURL = trigger.url
            record.fetchedAt = trigger.fetchedAt
        } else {
            record.sourceURL = pages[0].url
            record.fetchedAt = pages[0].fetchedAt
        }
        if pages.contains(where: { !$0.linkedinURLs.isEmpty }) { record.linkedinNote = config.etiquette.linkedinNote }
        record.research = ProspectResearcher.research(name: candidate.name, pages: pages, segment: segment, triggers: triggers, config: config)
        return record
    }
}
