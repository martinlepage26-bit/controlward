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
        audit.write(CWAuditLine(ts: clock.now, surface: "leads", action: "search", register: CWAuditLine.register(for: LeadDiscovery.overpass),
                                target: segment.id, source: "controlward", result: "ok", receipt: runID))
        let candidates = await LeadDiscovery(transport: transport).search(selectors: segment.osmSelectors, latitude: request.latitude,
                                                                          longitude: request.longitude, radiusMeters: request.radiusMeters,
                                                                          limit: request.limit)
        report.candidates = candidates.count
        var seenDomains = Set<String>()
        for candidate in candidates {
            let website = candidate.website.flatMap(Self.siteURL)
            let host = website?.host?.lowercased()
            let normalized = ProspectIdentity.normalizedDomain(host)
            var place = DiscoveredPlace(placeID: candidate.osmID, domain: normalized, usableWebsite: false, closed: candidate.closed)
            defer { report.discovered = DiscoveredPlace.merge([place], into: report.discovered) }
            if candidate.closed {
                report.skipped[candidate.osmID] = "closed business"
                continue
            }
            guard let siteURL = website, let host else {
                report.skipped[candidate.osmID] = "no own website on the listing"
                continue
            }
            if config.isNeverFetch(host: host) || config.deniedHost(host) != nil || GuardedLeadTransport.ownSiteHostRefusal(siteURL) != nil {
                report.skipped[candidate.osmID] = "website host not fetchable"
                continue
            }
            if let normalized, !seenDomains.insert(normalized).inserted {
                report.skipped[candidate.osmID] = "duplicate domain"
                continue
            }
            let domain = HostMatch.registrable(host)
            let pages = await fetchSite(siteURL, domain: domain, segment: segment)
            guard !pages.isEmpty else { report.skipped[candidate.osmID] = "own site not readable"; continue }
            if ProspectIdentity.siteSaysClosed(pages) {
                place.closed = true
                report.skipped[candidate.osmID] = "closed business (own site)"
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

    func fetchSite(_ root: URL, domain: String, segment: ICPConfig.Segment) async -> [SiteExtractor.Page] {
        var pages: [SiteExtractor.Page] = []
        for path in segment.ownSitePaths.prefix(config.etiquette.maxPagesPerSite) {
            guard let url = URL(string: path, relativeTo: root)?.absoluteURL else { continue }
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
                break
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
