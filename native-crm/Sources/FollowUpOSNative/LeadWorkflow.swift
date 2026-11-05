import Foundation

/// Lead-to-follow-up workflow: source and evidence, record completeness, reviewed conversion into linked
/// contact/company/opportunity/task records, outcome totals from owner-entered values, evidence-grounded
/// drafts and reminder timing. Foundation only, so `bin/test-crm-core` runs it on Linux; AppStore and the
/// SwiftUI views call it on the Mac. Nothing here sends a message or touches the network.
enum LeadWorkflow {
    // MARK: - Source and origin

    enum Origin: String, Equatable, Sendable {
        case manualOrFile, pharosInbox, pharosIntake, kairos, publicListing, prospectSearch, other

        var label: String {
            switch self {
            case .manualOrFile: "Entered by hand or imported from a file"
            case .pharosInbox: "PHAROS lead inbox"
            case .pharosIntake: "PHAROS intake form"
            case .kairos: "KAIROS inbox (read-only)"
            case .publicListing: "Public OpenStreetMap business listing"
            case .prospectSearch: "ControlWard prospect search"
            case .other: "Other recorded source"
            }
        }

        /// Found by ControlWard rather than reaching out. Buyer intent is unknown for these.
        var isOutboundProspect: Bool { self == .publicListing || self == .prospectSearch }
    }

    static func origin(of lead: Lead) -> Origin {
        guard let source = lead.sourceID, !source.isEmpty else { return .manualOrFile }
        if source.hasPrefix("leadgen:") { return .pharosInbox }
        if source.hasPrefix("intake:") { return .pharosIntake }
        if source.hasPrefix("kairos:") { return .kairos }
        if source.hasPrefix("osm:") { return .publicListing }
        if source.hasPrefix("prospect:") { return .prospectSearch }
        return .other
    }

    /// Source and evidence lines shown with the lead. Only recorded text; nothing is inferred.
    static func evidenceLines(for lead: Lead, in workspace: PersistentWorkspace) -> [String] {
        let origin = origin(of: lead)
        var lines = ["Source: \(origin.label)\(lead.sourceID.map { " (\($0))" } ?? "")"]
        for signal in workspace.signals where signal.leadID == lead.id {
            let evidence = signal.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
            if !evidence.isEmpty { lines.append(contentsOf: evidence.split(separator: "\n").map(String.init)) }
            if signal.priority > 0 {
                lines.append("Research priority \(signal.priority)/100 (public-record completeness, not buyer intent).")
            }
        }
        if origin.isOutboundProspect { lines.append("Buyer intent: unknown. This record was found, not received.") }
        return lines
    }

    // MARK: - Linked context

    struct LinkedContext: Equatable, Sendable {
        var company: Company?
        var contact: Contact?
        var opportunity: Opportunity?
        var notes: [CRMNote] = []
        var tasks: [CRMTask] = []
        var audits: [BilingualAudit] = []
    }

    /// Records linked to the lead. Only a set ID matches: an unlinked lead never collects every unlinked record.
    static func context(for lead: Lead, in workspace: PersistentWorkspace) -> LinkedContext {
        func same(_ left: UUID?, _ right: UUID?) -> Bool {
            guard let left else { return false }
            return left == right
        }
        let opportunity = workspace.opportunities.first { $0.leadID == lead.id }
        return LinkedContext(
            company: workspace.companies.first { same(lead.companyID, $0.id) },
            contact: workspace.contacts.first { same(lead.contactID, $0.id) },
            opportunity: opportunity,
            notes: workspace.notes.filter {
                same(lead.contactID, $0.contactID) || same(lead.companyID, $0.companyID) || same(opportunity?.id, $0.opportunityID)
            },
            tasks: workspace.tasks.filter {
                $0.leadID == lead.id || same(lead.contactID, $0.contactID) || same(lead.companyID, $0.companyID)
                    || same(opportunity?.id, $0.opportunityID)
            },
            audits: workspace.audits.filter {
                $0.leadID == lead.id || same(lead.contactID, $0.contactID) || same(lead.companyID, $0.companyID)
            }
        )
    }

    // MARK: - Record completeness (explainable, not intent)

    struct CompletenessItem: Equatable, Sendable {
        var label: String
        var points: Int
        var present: Bool
    }

    struct Completeness: Equatable, Sendable {
        var score: Int
        var items: [CompletenessItem]
        static let meaning = "Record completeness: how much of this lead is recorded. It is not buying intent or a likelihood to close."
    }

    static func completeness(for lead: Lead, in workspace: PersistentWorkspace) -> Completeness {
        let hasSignalEvidence = workspace.signals.contains { $0.leadID == lead.id && !$0.evidence.isEmpty }
        let items = [
            CompletenessItem(label: "Named person", points: 15, present: personName(for: lead) != nil || lead.contactID != nil),
            CompletenessItem(label: "Email or phone", points: 20, present: !trim(lead.email).isEmpty || !trim(lead.phone).isEmpty),
            CompletenessItem(label: "Company", points: 15, present: !trim(lead.company).isEmpty || lead.companyID != nil),
            CompletenessItem(label: "Service or ask", points: 10, present: !trim(lead.service).isEmpty),
            CompletenessItem(label: "Owner-entered value", points: 15, present: lead.quoteAmount != nil),
            CompletenessItem(label: "Next follow-up date", points: 15, present: !lead.status.isOpen || lead.nextFollowUp != nil),
            CompletenessItem(label: "Source evidence", points: 10, present: lead.sourceID != nil || hasSignalEvidence),
        ]
        return Completeness(score: items.filter(\.present).map(\.points).reduce(0, +), items: items)
    }

    // MARK: - Reviewed conversion

    enum Step: Equatable, Sendable {
        case linkExisting(UUID, String)
        case create(String)
        case skip(String)

        var line: String {
            switch self {
            case .linkExisting(_, let name): "link existing \(name)"
            case .create(let name): "create \(name)"
            case .skip(let reason): "none: \(reason)"
            }
        }
    }

    struct ConversionPlan: Equatable, Sendable {
        var leadID: UUID
        var leadName: String
        var company: Step
        var contact: Step
        var opportunity: Step
        var followUpTask: Step
        var blockers: [String]
        var warnings: [String]

        var lines: [String] {
            ["Company: \(company.line)", "Contact: \(contact.line)", "Opportunity: \(opportunity.line)", "Follow-up task: \(followUpTask.line)"]
        }

        /// The owner confirms this exact preview. Any change to the records it names produces a new fingerprint.
        var fingerprint: String { ([leadID.uuidString, leadName] + lines + blockers + warnings).joined(separator: "\n") }
        var creates: Bool { [company, contact, opportunity, followUpTask].contains { if case .create = $0 { true } else { false } } }
    }

    struct ConversionResult: Equatable, Sendable {
        var companyID: UUID?
        var contactID: UUID?
        var opportunityID: UUID
        var taskID: UUID?
        var created: [String]
    }

    enum ConversionError: Error, Equatable, CustomStringConvertible {
        case missingLead
        case blocked(String)
        case planChanged

        var description: String {
            switch self {
            case .missingLead: "The lead no longer exists."
            case .blocked(let reason): reason
            case .planChanged: "The records changed after the preview. Review the conversion again."
            }
        }
    }

    private struct Resolution {
        var plan: ConversionPlan
        var companyID: UUID?
        var newCompany: Company?
        var contactID: UUID?
        var newContact: Contact?
        var opportunityID: UUID?
        var newOpportunity: Opportunity?
        var taskID: UUID?
        var newTask: CRMTask?
    }

    static func conversionPlan(for leadID: UUID, in workspace: PersistentWorkspace) -> ConversionPlan? {
        resolve(leadID, in: workspace)?.plan
    }

    /// Applies a confirmed preview. Fill-only: existing links and values are never overwritten. Re-running it
    /// links the same records instead of creating duplicates.
    @discardableResult
    static func applyConversion(_ confirmed: ConversionPlan, to workspace: inout PersistentWorkspace, now: Date = .now) throws -> ConversionResult {
        guard let resolution = resolve(confirmed.leadID, in: workspace),
              let leadIndex = workspace.leads.firstIndex(where: { $0.id == confirmed.leadID }) else { throw ConversionError.missingLead }
        guard resolution.plan.fingerprint == confirmed.fingerprint else { throw ConversionError.planChanged }
        if let blocker = resolution.plan.blockers.first { throw ConversionError.blocked(blocker) }

        var created: [String] = []
        if let company = resolution.newCompany { workspace.companies.insert(company, at: 0); created.append("company") }
        let companyID = resolution.companyID ?? resolution.newCompany?.id
        if var contact = resolution.newContact {
            contact.companyID = companyID
            workspace.contacts.insert(contact, at: 0)
            created.append("contact")
        } else if let id = resolution.contactID, let index = workspace.contacts.firstIndex(where: { $0.id == id }) {
            if workspace.contacts[index].companyID == nil { workspace.contacts[index].companyID = companyID }
            if workspace.contacts[index].leadID == nil { workspace.contacts[index].leadID = confirmed.leadID }
        }
        let contactID = resolution.contactID ?? resolution.newContact?.id

        var lead = workspace.leads[leadIndex]
        if lead.companyID == nil { lead.companyID = companyID }
        if lead.contactID == nil { lead.contactID = contactID }
        if trim(lead.company).isEmpty, let companyID, let company = workspace.companies.first(where: { $0.id == companyID }) {
            lead.company = company.name
        }

        let opportunityID: UUID
        if var opportunity = resolution.newOpportunity {
            opportunity.companyID = companyID
            opportunity.contactID = contactID
            workspace.opportunities.insert(opportunity, at: 0)
            opportunityID = opportunity.id
            created.append("opportunity")
        } else if let id = resolution.opportunityID, let index = workspace.opportunities.firstIndex(where: { $0.id == id }) {
            if workspace.opportunities[index].companyID == nil { workspace.opportunities[index].companyID = companyID }
            if workspace.opportunities[index].contactID == nil { workspace.opportunities[index].contactID = contactID }
            opportunityID = id
        } else {
            throw ConversionError.missingLead
        }

        var taskID = resolution.taskID
        if var task = resolution.newTask {
            task.contactID = contactID
            task.companyID = companyID
            task.opportunityID = opportunityID
            workspace.tasks.insert(task, at: 0)
            taskID = task.id
            created.append("follow-up task")
        } else if let id = taskID, let index = workspace.tasks.firstIndex(where: { $0.id == id }) {
            if workspace.tasks[index].opportunityID == nil { workspace.tasks[index].opportunityID = opportunityID }
            if workspace.tasks[index].contactID == nil { workspace.tasks[index].contactID = contactID }
            if workspace.tasks[index].companyID == nil { workspace.tasks[index].companyID = companyID }
        }
        if lead.followUpTaskID == nil { lead.followUpTaskID = taskID }
        workspace.leads[leadIndex] = lead

        for index in workspace.signals.indices where workspace.signals[index].leadID == lead.id {
            if workspace.signals[index].companyID == nil { workspace.signals[index].companyID = companyID }
            if workspace.signals[index].contactID == nil { workspace.signals[index].contactID = contactID }
        }
        let summary = created.isEmpty ? "linked existing records only" : "created \(created.joined(separator: ", "))"
        workspace.activity.insert(ActivityEvent(kind: "lead.converted", message: "Converted \(lead.name) after review: \(summary).", sourceID: lead.id, createdAt: now.ISO8601Format()), at: 0)
        return ConversionResult(companyID: companyID, contactID: contactID, opportunityID: opportunityID, taskID: taskID, created: created)
    }

    private static func resolve(_ leadID: UUID, in workspace: PersistentWorkspace) -> Resolution? {
        guard let lead = workspace.leads.first(where: { $0.id == leadID }) else { return nil }
        var blockers: [String] = []
        var warnings: [String] = []
        if trim(lead.name).isEmpty { blockers.append("Enter the lead's name before converting it.") }

        // Company: linked → same normalized name → same non-webmail email domain → create from the lead → none.
        let emailDomain = businessEmailDomain(lead.email)
        let companyName = trim(lead.company)
        var resolution = Resolution(plan: ConversionPlan(leadID: lead.id, leadName: lead.name, company: .skip(""), contact: .skip(""), opportunity: .skip(""), followUpTask: .skip(""), blockers: [], warnings: []))
        if let id = lead.companyID, let company = workspace.companies.first(where: { $0.id == id }) {
            resolution.companyID = id
            resolution.plan.company = .linkExisting(id, company.name)
        } else if !companyName.isEmpty, let company = workspace.companies.first(where: { normalizedName($0.name) == normalizedName(companyName) }) {
            resolution.companyID = company.id
            resolution.plan.company = .linkExisting(company.id, company.name)
        } else if let emailDomain, let company = workspace.companies.first(where: { normalizedDomain($0.domain) == emailDomain }) {
            resolution.companyID = company.id
            resolution.plan.company = .linkExisting(company.id, company.name)
        } else if !companyName.isEmpty {
            var company = Company()
            company.name = companyName
            company.domain = emailDomain ?? ""
            if personName(for: lead) == nil { company.phone = trim(lead.phone) }
            company.notes = "Created from lead \(lead.name) on owner review."
            resolution.newCompany = company
            resolution.plan.company = .create(companyName)
        } else {
            resolution.plan.company = .skip("no company name recorded")
            warnings.append("No company name is recorded, so no company is created.")
        }

        // Contact: linked → same email → same phone without a conflicting email → create from a named person → none.
        let email = MailAddress.bare(lead.email)
        let phone = digits(lead.phone)
        if let id = lead.contactID, let contact = workspace.contacts.first(where: { $0.id == id }) {
            resolution.contactID = id
            resolution.plan.contact = .linkExisting(id, contact.displayName)
        } else if !email.isEmpty, let contact = workspace.contacts.first(where: { MailAddress.bare($0.email) == email }) {
            resolution.contactID = contact.id
            resolution.plan.contact = .linkExisting(contact.id, contact.displayName)
        } else if phone.count >= 10, let contact = workspace.contacts.first(where: {
            digits($0.phone) == phone && (trim($0.email).isEmpty || email.isEmpty || MailAddress.bare($0.email) == email)
        }) {
            resolution.contactID = contact.id
            resolution.plan.contact = .linkExisting(contact.id, contact.displayName)
        } else if let person = personName(for: lead) {
            let parts = person.split(separator: " ", maxSplits: 1).map(String.init)
            var contact = Contact()
            contact.firstName = parts.first ?? person
            contact.lastName = parts.count > 1 ? parts[1] : ""
            contact.email = trim(lead.email)
            contact.phone = trim(lead.phone)
            contact.leadID = lead.id
            resolution.newContact = contact
            resolution.plan.contact = .create(person)
        } else {
            resolution.plan.contact = .skip("no named person recorded")
            warnings.append("No named person is recorded. Add a contact when one is known.")
        }

        // Opportunity: one per lead; value only from the owner-entered quote.
        if let existing = workspace.opportunities.first(where: { $0.leadID == lead.id }) {
            resolution.opportunityID = existing.id
            resolution.plan.opportunity = .linkExisting(existing.id, "\(existing.name) (\(existing.stage.label))")
        } else {
            var opportunity = Opportunity()
            opportunity.name = trim(lead.service).isEmpty ? trim(lead.name) : "\(trim(lead.name)) — \(trim(lead.service))"
            opportunity.amount = lead.quoteAmount
            opportunity.stage = stage(for: lead.status)
            opportunity.leadID = lead.id
            opportunity.notes = "Converted from the lead pipeline after owner review."
            resolution.newOpportunity = opportunity
            let value = lead.quoteAmount.map { "\(formatAmount($0)) CAD owner-entered" } ?? "no value"
            resolution.plan.opportunity = .create("\(opportunity.name) (\(opportunity.stage.label), \(value))")
            if lead.quoteAmount == nil {
                warnings.append("No owner-entered value. The opportunity is left out of value totals until you enter one.")
            }
        }

        // Follow-up task: the lead's next action, dated from its recorded next follow-up.
        if let id = lead.followUpTaskID, let task = workspace.tasks.first(where: { $0.id == id && $0.status != .done }) {
            resolution.taskID = id
            resolution.plan.followUpTask = .linkExisting(id, "\(task.title) (due \(task.dueDate ?? "no date"))")
        } else if !lead.status.isOpen {
            resolution.plan.followUpTask = .skip("lead is \(lead.status.label.lowercased())")
        } else if let due = lead.nextFollowUp {
            var task = CRMTask()
            task.title = "Follow up: \(trim(lead.name))"
            task.details = "Next action for this lead. Review the recorded evidence and the draft before contacting anyone."
            task.dueDate = due
            task.leadID = lead.id
            resolution.newTask = task
            resolution.plan.followUpTask = .create("\(task.title) (due \(due), local reminder at 9 AM)")
        } else {
            resolution.plan.followUpTask = .skip("no next follow-up date recorded")
            warnings.append("No next follow-up date. Set one to create the follow-up task and reminder.")
        }
        resolution.plan.blockers = blockers
        resolution.plan.warnings = warnings
        return resolution
    }

    static func stage(for status: LeadStatus) -> OpportunityStage {
        switch status {
        case .new, .contacted: .qualified
        case .quoteSent: .proposal
        case .won: .won
        case .lost: .lost
        }
    }

    // MARK: - Outcomes (owner-entered values only)

    struct Outcomes: Equatable, Sendable {
        var wonValue: Double
        var openValue: Double
        var closeRate: Int
        var wonCount: Int
        var lostCount: Int
        /// Open records with no owner-entered value. They are counted, never valued.
        var openWithoutValue: Int
    }

    /// A converted lead's outcome and value come from its opportunity, so nothing is counted twice.
    static func outcomes(leads: [Lead], opportunities: [Opportunity]) -> Outcomes {
        let leadIDs = Set(leads.map(\.id))
        let converted = Set(opportunities.compactMap(\.leadID)).intersection(leadIDs)
        let standalone = leads.filter { !converted.contains($0.id) }
        let won = opportunities.filter { $0.stage == .won }.count + standalone.filter { $0.status == .won }.count
        let lost = opportunities.filter { $0.stage == .lost }.count + standalone.filter { $0.status == .lost }.count
        let wonValue = opportunities.filter { $0.stage == .won }.compactMap(\.amount).reduce(0, +)
            + standalone.filter { $0.status == .won }.compactMap(\.quoteAmount).reduce(0, +)
        let openOpportunities = opportunities.filter { !$0.stage.isClosed }
        let openLeads = standalone.filter { $0.status.isOpen }
        let openValue = openOpportunities.compactMap(\.amount).reduce(0, +) + openLeads.compactMap(\.quoteAmount).reduce(0, +)
        let closed = won + lost
        return Outcomes(
            wonValue: wonValue,
            openValue: openValue,
            closeRate: closed == 0 ? 0 : Int((Double(won) / Double(closed) * 100).rounded()),
            wonCount: won,
            lostCount: lost,
            openWithoutValue: openOpportunities.filter { $0.amount == nil }.count + openLeads.filter { $0.quoteAmount == nil }.count
        )
    }

    /// Keeps a converted lead and its opportunity on the same recorded outcome. Returns true when anything changed.
    @discardableResult
    static func mirrorOutcome(ofOpportunity opportunity: Opportunity, in workspace: inout PersistentWorkspace, now: Date = .now) -> Bool {
        guard opportunity.stage.isClosed, let leadID = opportunity.leadID,
              let index = workspace.leads.firstIndex(where: { $0.id == leadID }) else { return false }
        let status: LeadStatus = opportunity.stage == .won ? .won : .lost
        guard workspace.leads[index].status != status else { return false }
        setOutcome(status, on: &workspace.leads[index], now: now)
        return true
    }

    @discardableResult
    static func mirrorOutcome(ofLead lead: Lead, in workspace: inout PersistentWorkspace) -> Bool {
        guard lead.status == .won || lead.status == .lost,
              let index = workspace.opportunities.firstIndex(where: { $0.leadID == lead.id }) else { return false }
        let stage: OpportunityStage = lead.status == .won ? .won : .lost
        guard workspace.opportunities[index].stage != stage else { return false }
        workspace.opportunities[index].stage = stage
        return true
    }

    static func setOutcome(_ status: LeadStatus, on lead: inout Lead, now: Date = .now) {
        lead.status = status
        lead.nextFollowUp = nil
        if status == .won { lead.wonAt = now.ISO8601Format(); lead.lostAt = nil }
        if status == .lost { lead.lostAt = now.ISO8601Format(); lead.wonAt = nil }
    }

    // MARK: - Follow-up task and reminder

    /// After a follow-up is logged, the lead's open follow-up task moves to the next suggested date.
    /// Returns the updated task so the caller can reschedule its local reminder.
    static func syncFollowUpTask(for lead: Lead, in workspace: inout PersistentWorkspace) -> CRMTask? {
        guard let id = lead.followUpTaskID, let next = lead.nextFollowUp,
              let index = workspace.tasks.firstIndex(where: { $0.id == id && $0.status != .done }),
              workspace.tasks[index].dueDate != next else { return nil }
        workspace.tasks[index].dueDate = next
        workspace.tasks[index].reminderAt = nil
        return workspace.tasks[index]
    }

    /// When the local reminder for a task fires: its explicit reminder instant, else 9 AM local on its due date.
    /// Done tasks and past instants have no reminder.
    static func reminderFireDate(for task: CRMTask, now: Date = .now, calendar: Calendar = .current) -> Date? {
        guard task.status != .done else { return nil }
        let fireAt: Date?
        if let reminderAt = task.reminderAt, let instant = ISO8601DateFormatter().date(from: reminderAt) {
            fireAt = instant
        } else if let day = task.dueDate, let due = CalendarCRM.date(from: day) {
            var components = calendar.dateComponents([.year, .month, .day], from: due)
            components.hour = 9
            components.minute = 0
            fireAt = calendar.date(from: components)
        } else {
            fireAt = nil
        }
        guard let fireAt, fireAt > now else { return nil }
        return fireAt
    }

    // MARK: - Evidence-grounded draft

    struct GroundedDraft: Equatable, Sendable {
        var subject: String
        var text: String
        /// The recorded facts the draft uses, shown to the owner next to it.
        var groundedIn: [String]
        /// Facts the draft deliberately does not state because they are not recorded.
        var notMentioned: [String]
        static let reviewNotice = "Draft only. Review and edit it; nothing is sent from ControlWard."
    }

    /// A local draft that states only what the workspace records. It never claims a quote, a meeting or
    /// interest that is not recorded, and never quotes private notes.
    static func draft(for lead: Lead, in workspace: PersistentWorkspace, business: BusinessProfile) -> GroundedDraft {
        let origin = origin(of: lead)
        let context = context(for: lead, in: workspace)
        var grounded: [String] = []
        var notMentioned: [String] = []
        let service = trim(lead.service)

        let greetingName: String?
        if let contact = context.contact, !trim(contact.firstName).isEmpty {
            greetingName = trim(contact.firstName)
            grounded.append("Contact: \(contact.displayName)")
        } else if let person = personName(for: lead) {
            greetingName = person.split(separator: " ").first.map(String.init)
            grounded.append("Lead name: \(person)")
        } else {
            greetingName = nil
            notMentioned.append("No named person is recorded, so the greeting is general.")
        }

        var body: [String] = []
        if let last = lead.history.last {
            body.append("I'm following up on my message of \(last.date)\(service.isEmpty ? "" : " about \(service)").")
            grounded.append("Logged follow-up on \(last.date)")
        } else if lead.status == .quoteSent {
            if let amount = lead.quoteAmount {
                body.append("I'm following up on the quote\(service.isEmpty ? "" : " for \(service)") (\(formatAmount(amount)) CAD).")
                grounded.append("Status Quote Sent; owner-entered quote \(formatAmount(amount)) CAD")
            } else {
                body.append("I'm following up on the quote I sent\(service.isEmpty ? "" : " for \(service)").")
                grounded.append("Status Quote Sent")
                notMentioned.append("No quote amount is recorded, so none is stated.")
            }
        } else if origin.isOutboundProspect {
            let company = trim(lead.company).isEmpty ? "your business" : trim(lead.company)
            body.append("I came across \(company) through \(origin == .publicListing ? "its public business listing" : "your public website").")
            body.append("Would a short conversation be useful to see whether there is a fit?")
            grounded.append("Source: \(origin.label)")
            notMentioned.append("Buyer intent is unknown; the draft does not assume interest or a prior conversation.")
        } else if lead.status == .contacted {
            body.append("Thank you for speaking with me\(service.isEmpty ? "" : " about \(service)").")
            grounded.append("Status Contacted")
        } else {
            body.append(service.isEmpty ? "Thank you for getting in touch." : "Thank you for your interest in \(service).")
            grounded.append(service.isEmpty ? "Status New" : "Service or ask: \(service)")
        }
        if !service.isEmpty, !grounded.contains(where: { $0.contains(service) }) { grounded.append("Service or ask: \(service)") }
        if lead.status != .quoteSent, lead.quoteAmount != nil {
            notMentioned.append("The owner-entered value is internal and is not stated.")
        }
        body.append("Let me know if you have any questions or would like to discuss next steps.")
        if !context.notes.isEmpty || !trim(lead.notes).isEmpty {
            notMentioned.append("Internal notes are not quoted.")
        }

        let signature = trim(business.name).isEmpty ? "the team" : trim(business.name)
        let text = ([greetingName.map { "Hi \($0)," } ?? "Hello,", ""] + body + ["", "Best,", signature]).joined(separator: "\n")
        let subject = lead.history.isEmpty && origin.isOutboundProspect
            ? "Introduction\(service.isEmpty ? "" : " - \(service)")"
            : "Following up\(service.isEmpty ? "" : " - \(service)")"
        return GroundedDraft(subject: subject, text: text, groundedIn: grounded, notMentioned: notMentioned)
    }

    // MARK: - Prospect search → pipeline

    enum PromotionError: Error, Equatable, CustomStringConvertible {
        case notReady(String)
        case alreadyInPipeline(UUID)

        var description: String {
            switch self {
            case .notReady(let reason): reason
            case .alreadyInPipeline: "This prospect is already in the pipeline."
            }
        }
    }

    static func sourceID(for record: ProspectRecord) -> String { "prospect:\(record.id)" }

    /// Adds one Ready prospect to the CRM pipeline for owner review, with its evidence. Held, dropped and
    /// to-fix records are refused. Nothing is sent and no score is treated as intent.
    @discardableResult
    static func promote(_ record: ProspectRecord, into workspace: inout PersistentWorkspace, now: Date = .now) throws -> UUID {
        switch record.status {
        case .ready: break
        case .conflictReview: throw PromotionError.notReady("Held for owner review (conflict area). It is not added to the pipeline.")
        case .drop: throw PromotionError.notReady("Dropped by the lead pipeline\(record.reasons.isEmpty ? "" : ": \(record.reasons.joined(separator: "; "))").")
        case .fix: throw PromotionError.notReady("Fix the listed issues first\(record.reasons.isEmpty ? "" : ": \(record.reasons.joined(separator: "; "))").")
        }
        let source = sourceID(for: record)
        if let existing = workspace.leads.first(where: { $0.sourceID == source }) { throw PromotionError.alreadyInPipeline(existing.id) }
        let email = record.email.map(MailAddress.bare) ?? ""
        if !email.isEmpty, let existing = workspace.leads.first(where: { MailAddress.bare($0.email) == email }) {
            throw PromotionError.alreadyInPipeline(existing.id)
        }

        var lead = Lead.blank(today: now)
        lead.name = record.contact?.name ?? record.organisation
        lead.company = record.organisation
        lead.email = record.email ?? ""
        lead.phone = record.phone ?? ""
        lead.service = record.segment ?? ""
        lead.sourceID = source
        lead.createdAt = now.ISO8601Format()
        let evidence = prospectEvidence(record)
        lead.notes = (record.isTest ? "Synthetic test record.\n" : "") + "Added from prospect search for owner review."

        var signal = Signal()
        signal.title = "Prospect search: \(record.organisation)"
        signal.source = .imported
        signal.status = .captured
        signal.leadID = lead.id
        signal.sourceID = source
        signal.evidence = evidence.joined(separator: "\n")
        signal.nextAction = "Review the recorded evidence and decide whether to pursue this prospect."
        signal.capturedAt = now.ISO8601Format()

        workspace.leads.insert(lead, at: 0)
        workspace.signals.insert(signal, at: 0)
        workspace.activity.insert(ActivityEvent(kind: "prospect.promoted", message: "Added \(record.organisation) from prospect search for review.", sourceID: lead.id, createdAt: now.ISO8601Format()), at: 0)
        return lead.id
    }

    static func prospectEvidence(_ record: ProspectRecord) -> [String] {
        var lines: [String] = []
        if let url = record.sourceURL {
            lines.append("Evidence page: \(url)\(record.fetchedAt.map { " · fetched \($0.ISO8601Format())" } ?? "")")
        }
        if let fit = record.fit { lines.append("Segment fit: \(fit)") }
        if let trigger = record.trigger { lines.append("Trigger (\(trigger.state.rawValue)): \(trigger.summary)") }
        if let contact = record.contact {
            lines.append("Contact: \(contact.name)\(contact.title.map { ", \($0)" } ?? "") (source: \(contact.source.rawValue))")
        }
        if let risk = record.risk { lines.append("Risk: \(risk)") }
        if let attribution = record.dataAttribution { lines.append(attribution) }
        lines.append("Fit describes the target segment, not interest in buying.")
        return lines
    }

    // MARK: - Helpers

    private static let webmailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com", "yahoo.ca",
        "icloud.com", "me.com", "mac.com", "aol.com", "proton.me", "protonmail.com", "videotron.ca", "sympatico.ca", "bell.net",
    ]

    static func businessEmailDomain(_ email: String) -> String? {
        guard let domain = normalizedDomain(MailAddress.domain(email) ?? ""), !webmailDomains.contains(domain) else { return nil }
        return domain
    }

    static func normalizedDomain(_ domain: String) -> String? {
        var host = trim(domain).lowercased()
        if let parsed = URL(string: host.contains("://") ? host : "https://\(host)")?.host?.lowercased() { host = parsed }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// Case-, accent- and punctuation-insensitive name with a trailing legal form removed ("Acme Inc." = "acme").
    static func normalizedName(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_CA_POSIX"))
        var words = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if let last = words.last, ["inc", "ltd", "ltee", "llc", "corp", "enr", "senc"].contains(last), words.count > 1 { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// The lead's name when it names a person rather than repeating the company.
    static func personName(for lead: Lead) -> String? {
        let name = trim(lead.name)
        guard !name.isEmpty, normalizedName(name) != normalizedName(lead.company) else { return nil }
        return name
    }

    static func digits(_ text: String) -> String { text.filter(\.isNumber) }
    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func formatAmount(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_CA_POSIX")
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = amount.rounded() == amount ? 0 : 2
        formatter.maximumFractionDigits = 2
        return "$" + (formatter.string(from: NSNumber(value: amount)) ?? String(amount))
    }
}
