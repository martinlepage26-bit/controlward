import Foundation

/// Counts actual public discovery and research across both native discovery paths and saved CRM
/// evidence. A business is counted once by its own domain (or source ID when no domain is known).
/// The last stage means a draft passes the existing gates now, not that a sale or opportunity exists.
struct ProspectingOverviewSnapshot: Equatable, Sendable {
    var funnel = LeadFunnel()
    var warnings: [String] = []
    static let labels = ["Businesses discovered", "With a website", "Sourced contact found", "Draft-ready businesses"]
    var stages: [(label: String, value: Int)] { Array(zip(Self.labels, funnel.values)).map { ($0.0, $0.1) } }

    private struct Business {
        var website = false
        var closed = false
        var record: ProspectRecord?
        var research: QuickScanResearchResult?
        var checkedAt = Date.distantPast
    }

    static func make(places: [DiscoveredPlace], records: [ProspectRecord], cache: WebsiteResearchCache,
                     leads: [Lead], config: ICPConfig, suppression: SuppressionList, now: Date) -> Self {
        var businesses: [String: Business] = [:]
        func key(_ id: String, _ domain: String?) -> String {
            if let domain = ProspectIdentity.normalizedDomain(domain) { return "domain:" + domain }
            return "source:" + (id.hasPrefix("cw:") ? String(id.dropFirst(3)) : id).lowercased()
        }
        func websiteDomain(_ website: String?) -> String? {
            guard let website, let url = ProspectSearchRun.siteURL(website),
                  GuardedLeadTransport.ownSiteHostRefusal(url) == nil else { return nil }
            return url.host.map(HostMatch.registrable)
        }
        func add(_ record: ProspectRecord, research: QuickScanResearchResult? = nil) {
            guard !record.isTest, record.provenance != .test else { return }
            let id = key(record.id, record.businessDomain)
            var business = businesses[id] ?? Business()
            business.website = business.website || websiteDomain(record.sourceURL) != nil
            business.closed = business.closed || record.reasons.contains("closed business")
            // checkedAt marks a research run's start; its pages can be fetched later. Compare the
            // latest evidence time first, then run start, so a CRM copy cannot mask a newer finding.
            let checked = max(research?.checkedAt ?? .distantPast, record.fetchedAt ?? .distantPast)
            let laterAssessment = research != nil && (research?.checkedAt ?? .distantPast) >= (business.research?.checkedAt ?? .distantPast)
            if business.record == nil || checked > business.checkedAt || (checked == business.checkedAt && laterAssessment) {
                business.record = record; business.research = research; business.checkedAt = checked
            }
            businesses[id] = business
        }
        for place in places {
            let id = key(place.placeID, place.domain)
            var business = businesses[id] ?? Business()
            business.website = business.website || place.usableWebsite
            business.closed = business.closed || place.closed
            businesses[id] = business
        }
        for candidate in cache.candidates {
            let domain = websiteDomain(candidate.website)
            let id = key(candidate.sourceID, domain)
            var business = businesses[id] ?? Business()
            business.website = business.website || domain != nil
            businesses[id] = business
        }
        for record in records { add(record) }
        for lead in leads { if let research = lead.quickScanResearch { add(research.record, research: research) } }
        for research in cache.results.values { add(research.record, research: research) }
        var result = Self()
        for business in businesses.values where !business.closed {
            result.funnel.discovered += 1
            if business.website { result.funnel.withUsableWebsite += 1 }
            guard let record = business.record, record.status != .drop,
                  let domain = record.businessDomain, let person = record.contact,
                  let personURL = person.sourceURL, let personHost = URL(string: personURL)?.host,
                  HostMatch.belongs(personHost, to: domain), person.source == .ownSite,
                  person.name.split(separator: " ").count >= 2, person.titleSource == .checkedDirect,
                  ProspectResearcher.isEvidenced(.init(url: personURL, excerpt: person.name), in: record.snapshots),
                  let route = record.route, route.source == .ownSite, !route.value.isEmpty,
                  let routeHost = URL(string: route.sourceURL)?.host, HostMatch.belongs(routeHost, to: domain),
                  routeSupported(route, in: record) else { continue }
            result.funnel.appropriateContact += 1
            if let research = business.research {
                if research.draft(config: config, suppression: suppression, now: now) != nil { result.funnel.evidenceBackedOpportunity += 1 }
            } else if record.status == .ready, LeadFunnel.isEvidenceBacked(record) {
                let draft = OutreachDraftBuilder.build(for: record, config: config, language: "fr", messageID: "overview-" + record.id)
                if MailAddress.domain(draft.to) != nil, OutreachDraftGate.check(draft, prospect: record, config: config, suppression: suppression, now: now) == nil {
                    result.funnel.evidenceBackedOpportunity += 1
                }
            }
        }
        return result
    }

    private static func routeSupported(_ route: ProspectRoute, in record: ProspectRecord) -> Bool {
        record.snapshots.contains { snapshot in
            guard snapshot.url == route.sourceURL else { return false }
            if SiteExtractor.normalizePrintedEmail(snapshot.text).range(of: route.value, options: .caseInsensitive) != nil { return true }
            return (snapshot.links ?? []).contains { link in
                if route.kind == .email, link.lowercased().hasPrefix("mailto:") {
                    return MailAddress.bare(String(link.dropFirst(7)).components(separatedBy: "?")[0]) == MailAddress.bare(route.value)
                }
                return link == "tel:" + route.value || link == route.value
            }
        }
    }

    /// A corrupt source produces an explicit partial-count warning; reading never rewrites it.
    static func load(root: URL, leads: [Lead], config: ICPConfig, now: Date = .now) -> Self {
        var warnings: [String] = []
        func read<T: Decodable>(_ name: String, as: T.Type, fallback: T) -> T {
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 20_000_000 else { throw DiscoverySearchError.responseTooLarge }
                return try JSONDecoder.iso.decode(T.self, from: data)
            } catch { warnings.append("\(name) could not be read. Counts are partial; the file was retained."); return fallback }
        }
        let places = read("discovered.json", as: [DiscoveredPlace].self, fallback: [])
        let records = read("prospects.json", as: [ProspectRecord].self, fallback: [])
        let cache = read("quick-scan-research.json", as: WebsiteResearchCache.self, fallback: WebsiteResearchCache())
        let suppression = SuppressionList(storageURL: root.appendingPathComponent("suppression.json"))
        if let reason = suppression.unavailableReason { warnings.append(reason) }
        var result = make(places: places, records: records, cache: cache, leads: leads, config: config,
                          suppression: suppression, now: now)
        result.warnings = warnings
        return result
    }
}

/// Pure, testable figures for the Overview dashboard. Every number is derived
/// from the workspace records passed in; nothing here invents data.
struct OverviewSnapshot: Equatable, Sendable {
    struct Metric: Equatable, Sendable {
        var value: String
        var detail: String
        /// Weekly counts, oldest first, for the sparkline. Empty when there is no history.
        var trend: [Double]
    }

    struct Action: Equatable, Sendable, Identifiable {
        var id: UUID
        var title: String
        var dueDate: String?
        var overdue: Bool
        var dueToday: Bool
        var context: String
    }

    struct StageColumn: Equatable, Sendable, Identifiable {
        var stage: OpportunityStage
        var items: [Opportunity]
        var id: String { stage.rawValue }
    }

    var openOpportunities: Metric
    var estimatedValue: Metric
    var dueThisWeek: Metric
    var followUps: Metric
    var followUpsOverdue: Int
    var openOpportunitiesAddedThisWeek: Int
    var proposalCount: Int
    var nextActions: [Action]
    var openTaskCount: Int
    var pipeline: [StageColumn]

    /// Next actions takes 45% of the middle row, Pipeline overview 55%, as in the mockup.
    static let middleRowSplit: Double = 0.45
    /// Green up arrow only for a real increase; 0 this week is shown neutral.
    var openOpportunitiesChangeIsPositive: Bool { openOpportunitiesAddedThisWeek > 0 }

    static let pipelineStages: [OpportunityStage] = [.lead, .qualified, .proposal, .negotiation, .won]

    static func make(opportunities: [Opportunity], tasks: [CRMTask], leads: [Lead], companies: [Company],
                     today: String, now: Date = .now, weeks: Int = 8) -> OverviewSnapshot {
        let calendar = Calendar(identifier: .gregorian)
        let open = opportunities.filter { !$0.stage.isClosed }
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let addedThisWeek = open.filter { (parse($0.createdAt) ?? .distantPast) >= weekAgo }.count
        let value = open.compactMap(\.amount).reduce(0, +)
        let proposals = open.filter { $0.stage == .proposal }.count

        let openTasks = tasks.filter { $0.status != .done }
            .sorted { ($0.dueDate ?? "9999") < ($1.dueDate ?? "9999") }
        let weekEnd = CalendarCRM.date(from: today).flatMap { calendar.date(byAdding: .day, value: 6, to: $0) }
            .map { CalendarCRM.dayString($0) } ?? today
        let dueWeek = openTasks.filter { guard let d = $0.dueDate, !d.isEmpty else { return false }; return d >= today && d <= weekEnd }

        let dueLeads = leads.filter { $0.status.isOpen && ($0.nextFollowUp ?? "9999-99-99") <= today }
        let overdueLeads = dueLeads.filter { ($0.nextFollowUp ?? today) < today }.count

        let companyNames = Dictionary(companies.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let oppNames = Dictionary(opportunities.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let actions = openTasks.prefix(3).map { task -> Action in
            let context = task.companyID.flatMap { companyNames[$0] } ?? task.opportunityID.flatMap { oppNames[$0] } ?? ""
            let due = task.dueDate.flatMap { $0.isEmpty ? nil : $0 }
            return Action(id: task.id, title: task.title, dueDate: due,
                          overdue: due.map { $0 < today } ?? false, dueToday: due == today, context: context)
        }

        func trend<T>(_ items: [T], _ date: (T) -> Date?) -> [Double] {
            // Fewer than 2 dated records is not a trend: the view draws a flat line.
            guard items.compactMap(date).count >= 2 else { return [] }
            return weeklyCounts(items.compactMap(date), weeks: weeks, now: now)
        }

        return OverviewSnapshot(
            openOpportunities: Metric(value: "\(open.count)", detail: "\(addedThisWeek) this week",
                                      trend: cumulative(trend(open) { parse($0.createdAt) })),
            estimatedValue: Metric(value: currency(value), detail: proposals == 1 ? "1 proposal" : "\(proposals) proposals",
                                   trend: cumulativeValue(open, weeks: weeks, now: now)),
            dueThisWeek: Metric(value: "\(dueWeek.count)", detail: dueWeek.first?.title ?? "Nothing due",
                                trend: trend(openTasks) { CalendarCRM.date(from: $0.dueDate) }),
            followUps: Metric(value: "\(dueLeads.count)", detail: overdueLeads > 0 ? "Overdue" : (dueLeads.isEmpty ? "All caught up" : "Due today"),
                              trend: trend(dueLeads) { CalendarCRM.date(from: $0.nextFollowUp) }),
            followUpsOverdue: overdueLeads,
            openOpportunitiesAddedThisWeek: addedThisWeek,
            proposalCount: proposals,
            nextActions: Array(actions),
            openTaskCount: openTasks.count,
            pipeline: pipelineStages.map { stage in StageColumn(stage: stage, items: opportunities.filter { $0.stage == stage }) }
        )
    }

    /// Counts per 7-day bucket ending at `now`, oldest first. Dates outside the window are ignored.
    static func weeklyCounts(_ dates: [Date], weeks: Int, now: Date) -> [Double] {
        var buckets = Array(repeating: 0.0, count: weeks)
        for date in dates {
            let age = now.timeIntervalSince(date) / (7 * 86_400)
            guard age >= 0 else { buckets[weeks - 1] += 1; continue }
            let index = weeks - 1 - Int(age)
            if index >= 0 { buckets[index] += 1 }
        }
        return buckets
    }

    static func cumulative(_ values: [Double]) -> [Double] {
        var total = 0.0
        return values.map { total += $0; return total }
    }

    static func cumulativeValue(_ open: [Opportunity], weeks: Int, now: Date) -> [Double] {
        guard open.filter({ $0.amount != nil }).count >= 2 else { return [] }
        var buckets = Array(repeating: 0.0, count: weeks)
        for opp in open {
            guard let amount = opp.amount else { continue }
            let age = now.timeIntervalSince(parse(opp.createdAt) ?? now) / (7 * 86_400)
            let index = max(0, weeks - 1 - max(0, Int(age)))
            buckets[index] += amount
        }
        return cumulative(buckets)
    }

    static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "CAD").precision(.fractionLength(0)).locale(Locale(identifier: "en_CA")))
    }

    static func parse(_ iso: String) -> Date? {
        let full = ISO8601DateFormatter()
        if let date = full.date(from: iso) { return date }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return full.date(from: iso) ?? CalendarCRM.date(from: iso)
    }

    /// "Good morning" / "Good afternoon" / "Good evening" from the local hour.
    static func greeting(hour: Int) -> String {
        switch hour {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    static func initials(_ name: String) -> String {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// The first name to greet with, or nil when the account name is not a person's name
    /// (empty, the same as the short login name, or containing digits, underscores or dots).
    static func greetingName(fullName: String, userName: String) -> String? {
        let first = firstName(fullName)
        guard !first.isEmpty,
              fullName.trimmingCharacters(in: .whitespaces).lowercased() != userName.lowercased(),
              first.lowercased() != userName.lowercased(),
              first.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" }),
              first.first?.isUppercase == true else { return nil }
        return first
    }

    static func firstName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }
}


/// Layout policy for lead rows in the Overview Pipeline card. The name keeps one
/// line with tail truncation and outranks the NEW badge, which never compresses it;
/// the created date moves to the status line so it cannot squeeze the name column.
enum PipelineRowLayout {
    static let nameLineLimit = 1
    static let nameMinWidth: Double = 72
    static let namePriority: Double = 1
    static let accessoryPriority: Double = 0
    static func metaLine(amount: String?, status: String, createdAt: String) -> String {
        let date = String(createdAt.prefix(10))
        return [amount, status, date.isEmpty ? nil : date].compactMap { $0 }.joined(separator: " · ")
    }
}
