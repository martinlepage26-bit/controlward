import Foundation

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
