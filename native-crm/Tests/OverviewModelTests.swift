import Foundation

@MainActor
enum OverviewModelTests {
    static var count = 0
    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw SmokeTestFailure.failed(message) }
        count += 1
        print("PASS  Overview: \(message)")
    }

    static func run() -> Bool {
        do {
            let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
            let today = "2026-10-17"
            let empty = OverviewSnapshot.make(opportunities: [], tasks: [], leads: [], companies: [], today: today, now: now)
            try expect(empty.openOpportunities.value == "0", "empty workspace must show zero open opportunities")
            try expect(empty.openOpportunities.trend.isEmpty, "empty workspace must not draw an invented trend")
            try expect(empty.nextActions.isEmpty && empty.openTaskCount == 0, "empty workspace has no actions")
            try expect(empty.dueThisWeek.detail == "Nothing due", "empty due-this-week detail")
            try expect(empty.pipeline.map(\.stage) == [.lead, .qualified, .proposal, .negotiation, .won], "pipeline columns order")

            let longName = "Mustafa Abdul Ghafour"
            try expect(PipelineRowLayout.nameLineLimit == 1, "pipeline lead name renders on a single line (\(longName))")
            try expect(PipelineRowLayout.namePriority > PipelineRowLayout.accessoryPriority, "lead name outranks the NEW badge so it is not squeezed")
            try expect(PipelineRowLayout.nameMinWidth >= 72, "lead name keeps a minimum width before truncating")
            let meta = PipelineRowLayout.metaLine(amount: nil, status: "New", createdAt: "2026-10-09T14:00:00Z")
            try expect(meta == "New · 2026-10-09", "created date moves to the status line, out of the name row")
            try expect(PipelineRowLayout.metaLine(amount: "$1,200", status: "Won", createdAt: "") == "$1,200 · Won", "empty date is omitted from the status line")

            let company = Company(name: "Érable Studio")
            let opps = [
                Opportunity(name: "Synthetic onboarding review", amount: 2400, stage: .proposal, companyID: company.id, createdAt: "2026-10-15T10:00:00Z"),
                Opportunity(name: "Old lead", amount: nil, stage: .lead, createdAt: "2026-08-01T10:00:00Z"),
                Opportunity(name: "Closed", amount: 9000, stage: .won, createdAt: "2026-10-16T10:00:00Z"),
            ]
            let tasks = [
                CRMTask(title: "Review project brief", status: .todo, dueDate: "2026-10-15"),
                CRMTask(title: "Follow up", status: .todo, dueDate: "2026-10-17", companyID: company.id),
                CRMTask(title: "Later", status: .todo, dueDate: "2026-10-30"),
                CRMTask(title: "Done", status: .done, dueDate: "2026-10-18"),
            ]
            var overdueLead = Lead(); overdueLead.name = "A"; overdueLead.nextFollowUp = "2026-10-10"
            var futureLead = Lead(); futureLead.name = "B"; futureLead.nextFollowUp = "2026-11-10"
            let s = OverviewSnapshot.make(opportunities: opps, tasks: tasks, leads: [overdueLead, futureLead], companies: [company], today: today, now: now)
            try expect(s.openOpportunities.value == "2", "won opportunities are not open")
            try expect(s.openOpportunitiesAddedThisWeek == 1, "one open opportunity was created this week")
            try expect(s.estimatedValue.value.contains("2,400") && !s.estimatedValue.value.contains("9"), "est. value sums open amounts only: \(s.estimatedValue.value)")
            try expect(s.proposalCount == 1 && s.estimatedValue.detail == "1 proposal", "proposal count")
            try expect(s.dueThisWeek.value == "1" && s.dueThisWeek.detail == "Follow up", "due this week excludes overdue, later and done tasks")
            try expect(s.followUps.value == "1" && s.followUpsOverdue == 1 && s.followUps.detail == "Overdue", "follow-ups count due leads")
            try expect(s.nextActions.count == 3 && s.nextActions[0].overdue && s.nextActions[1].dueToday, "next actions sorted by due date")
            try expect(s.nextActions[1].context == "Érable Studio", "action context uses the linked company")
            try expect(s.pipeline.first { $0.stage == .proposal }?.items.count == 1, "proposal column holds the proposal")
            try expect(OverviewSnapshot.weeklyCounts([now, now.addingTimeInterval(-8 * 86_400)], weeks: 4, now: now) == [0, 0, 1, 1], "weekly buckets")
            try expect(OverviewSnapshot.cumulative([1, 0, 2]) == [1, 1, 3], "cumulative")
            try expect(OverviewSnapshot.greeting(hour: 8) == "Good morning" && OverviewSnapshot.greeting(hour: 14) == "Good afternoon" && OverviewSnapshot.greeting(hour: 21) == "Good evening", "greeting")
            try expect(OverviewSnapshot.initials("Martin Lepage") == "ML" && OverviewSnapshot.initials("") == "?", "initials")
            try expect(OverviewSnapshot.firstName("Martin Lepage") == "Martin", "first name")
            try expect(OverviewSnapshot.greetingName(fullName: "Martin Lepage", userName: "pharos_ai") == "Martin", "real name greets by first name")
            try expect(OverviewSnapshot.greetingName(fullName: "pharos_ai", userName: "pharos_ai") == nil, "login name is not a first name")
            try expect(OverviewSnapshot.greetingName(fullName: "pharos ai", userName: "pharos_ai") == nil, "lowercase account name is not a first name")
            try expect(OverviewSnapshot.greetingName(fullName: "", userName: "x") == nil, "empty name has no greeting name")
            try expect(OverviewSnapshot.greetingName(fullName: "admin2", userName: "x") == nil, "digits are not a first name")
            try expect(!empty.openOpportunitiesChangeIsPositive && empty.openOpportunities.detail == "0 this week", "0 this week is neutral (no green up arrow)")
            try expect(s.openOpportunitiesChangeIsPositive, "a new open opportunity this week shows the green up arrow")
            try expect(OverviewSnapshot.middleRowSplit == 0.45, "middle row split is 45/55")
            let single = OverviewSnapshot.make(opportunities: [Opportunity(name: "One", amount: 10, stage: .lead)], tasks: [], leads: [], companies: [], today: today, now: now)
            try expect(single.openOpportunities.trend.isEmpty && single.estimatedValue.trend.isEmpty, "fewer than 2 records draws a flat sparkline, not a trend")

            // Preview badge outside acceptance builds; the environment is passed in, the process environment is untouched.
            let realMail = MailMetadata(sourceID: "m1", subject: "Real", sender: "a@example.test", recipient: "b@example.test",
                                        receivedAt: "2026-10-17T10:00:00Z", provider: "gmail", accountID: "b@example.test", synthetic: false)
            var syntheticMail = realMail; syntheticMail.synthetic = true
            try expect(PreviewBadge.isShowing(environment: ["CONTROLWARD_PREVIEW": "synthetic"], mail: [realMail]), "CONTROLWARD_PREVIEW=synthetic alone shows the preview badge")
            try expect(PreviewBadge.isShowing(environment: [:], mail: [realMail, syntheticMail]), "synthetic mail alone shows the preview badge")
            try expect(!PreviewBadge.isShowing(environment: [:], mail: [realMail]) && !PreviewBadge.isShowing(environment: ["CONTROLWARD_PREVIEW": "empty"], mail: [realMail]),
                       "real mail without the synthetic preview hides the badge")
            print("Overview model tests: \(count)/\(count) passed")
            return true
        } catch {
            print("Overview model tests failed: \(error)")
            return false
        }
    }
}
