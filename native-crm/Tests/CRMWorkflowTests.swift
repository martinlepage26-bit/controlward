import Foundation

/// Lead-to-follow-up workflow (LeadWorkflow.swift) on synthetic records only. Portable: bin/test-crm-core runs it on
/// Linux and bin/test-native-app runs it on the Mac. The relaunch case writes and re-reads workspace.json with the
/// same encoder options and decoder AppStore uses; the running-app relaunch remains a Mac acceptance step.
enum CRMWorkflowTests {
    static func run() async -> Bool {
        await PortableCheck.suite("CRM workflow", [
            ("Prospect: a Ready record enters the pipeline once, with its source and evidence", promotesReadyProspect),
            ("Prospect: held, dropped and to-fix records are refused with nothing written", refusesUnreadyProspects),
            ("Evidence: source, evidence and 'buyer intent unknown' are shown; completeness is itemised", evidenceAndCompleteness),
            ("Context: an unlinked lead does not collect every unlinked note, task or audit", unlinkedLeadContextIsEmpty),
            ("Convert: preview then confirm creates linked company, contact, opportunity and follow-up task", convertsReviewedLead),
            ("Convert: re-running links the same records and creates nothing", conversionIsIdempotent),
            ("Convert: existing company and contact are reused (name, legal form, email case)", conversionDeduplicates),
            ("Convert: a phone match with a conflicting email is not the same contact", phoneWithConflictingEmailIsNew),
            ("Convert: a company-only listing creates no fake person", companyOnlyLeadHasNoContact),
            ("Convert: a stale preview or a blocker writes nothing", stalePreviewAndBlockerWriteNothing),
            ("Outcomes: converted value is counted once; unvalued records are counted, never valued", outcomesCountOwnerValuesOnce),
            ("Outcomes: legacy lead-only totals are unchanged", legacyOutcomeTotals),
            ("Outcomes: won/lost mirrors between a converted lead and its opportunity", outcomeMirrors),
            ("Draft: states only recorded facts (no invented quote, intent or notes)", draftIsGrounded),
            ("Reminder: 9 AM on the due date, explicit instant first, none when done or past", reminderTiming),
            ("Follow-up: logging a message moves the open follow-up task to the next date", followUpTaskMoves),
            ("Relaunch: records, links, value, stage and next action survive workspace.json", persistsAcrossRelaunch),
            ("Relaunch: a workspace saved before followUpTaskID still loads", legacyWorkspaceLoads),
        ])
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        try PortableCheck.expect(try condition(), message)
    }
    private static let now = ISO8601DateFormatter().date(from: "2026-11-05T15:00:00Z")!

    private static func readyProspect(_ id: String = "fixture-1") -> ProspectRecord {
        var record = ProspectRecord(id: id, organisation: "Atelier Synthétique Inc.")
        record.segment = "renovation"
        record.status = .ready
        record.isTest = true
        record.sourceURL = "https://atelier.example.test/contact"
        record.fetchedAt = now
        record.fit = "renovation firm in the target area"
        record.email = "Info@Atelier.example.test"
        record.phone = "514-555-0100"
        return record
    }

    private static func manualLead(_ name: String = "Camille Tremblay", company: String = "Acme Builders") -> Lead {
        var lead = Lead.blank(today: now)
        lead.name = name
        lead.company = company
        lead.email = "camille@acmebuilders.example.test"
        lead.phone = "(514) 555-0101"
        lead.service = "Kitchen renovation"
        lead.quoteAmount = 5_000
        lead.status = .quoteSent
        lead.nextFollowUp = "2026-11-08"
        return lead
    }

    private static func converted(_ lead: Lead, in workspace: inout PersistentWorkspace) throws -> LeadWorkflow.ConversionResult {
        guard let plan = LeadWorkflow.conversionPlan(for: lead.id, in: workspace) else { throw PortableCheckFailure(description: "no plan") }
        return try LeadWorkflow.applyConversion(plan, to: &workspace, now: now)
    }

    static func promotesReadyProspect() async throws {
        var workspace = PersistentWorkspace()
        let id = try LeadWorkflow.promote(readyProspect(), into: &workspace, now: now)
        try expect(workspace.leads.count == 1 && workspace.leads[0].id == id, "one lead expected")
        let lead = workspace.leads[0]
        try expect(lead.sourceID == "prospect:fixture-1", "source id not kept: \(lead.sourceID ?? "nil")")
        try expect(lead.company == "Atelier Synthétique Inc.", "company not kept")
        try expect(lead.notes.hasPrefix("Synthetic test record."), "synthetic record not marked")
        let signal = try requireValue(workspace.signals.first { $0.leadID == id }, "evidence signal missing")
        try expect(signal.evidence.contains("https://atelier.example.test/contact"), "evidence page missing")
        try expect(signal.intentScore == 0 && signal.priority == 0, "a prospect must not carry an intent or priority score")
        try expect(workspace.activity.first?.kind == "prospect.promoted", "activity not recorded")
        do {
            _ = try LeadWorkflow.promote(readyProspect(), into: &workspace, now: now)
            throw PortableCheckFailure(description: "duplicate source id was accepted")
        } catch LeadWorkflow.PromotionError.alreadyInPipeline(let existing) {
            try expect(existing == id, "duplicate did not point at the existing lead")
        }
        var sameEmail = readyProspect("fixture-2")
        sameEmail.email = "info@atelier.example.test"
        do {
            _ = try LeadWorkflow.promote(sameEmail, into: &workspace, now: now)
            throw PortableCheckFailure(description: "duplicate email was accepted")
        } catch LeadWorkflow.PromotionError.alreadyInPipeline {}
        try expect(workspace.leads.count == 1, "duplicates added leads")
    }

    static func refusesUnreadyProspects() async throws {
        for status in [ProspectStatus.conflictReview, .drop, .fix] {
            var workspace = PersistentWorkspace()
            var record = readyProspect()
            record.status = status
            record.reasons = ["no reachable contact"]
            do {
                _ = try LeadWorkflow.promote(record, into: &workspace, now: now)
                throw PortableCheckFailure(description: "\(status.rawValue) was accepted")
            } catch LeadWorkflow.PromotionError.notReady(let reason) {
                try expect(!reason.isEmpty, "refusal has no reason")
            }
            try expect(workspace.leads.isEmpty && workspace.signals.isEmpty && workspace.activity.isEmpty, "\(status.rawValue) wrote records")
        }
    }

    static func evidenceAndCompleteness() async throws {
        var workspace = PersistentWorkspace()
        let id = try LeadWorkflow.promote(readyProspect(), into: &workspace, now: now)
        let lead = try requireValue(workspace.leads.first { $0.id == id }, "lead missing")
        let lines = LeadWorkflow.evidenceLines(for: lead, in: workspace)
        try expect(lines.first == "Source: ControlWard prospect search (prospect:fixture-1)", "source line: \(lines.first ?? "")")
        try expect(lines.contains { $0.hasPrefix("Evidence page: https://atelier.example.test/contact") }, "evidence page not shown")
        try expect(lines.contains("Buyer intent: unknown. This record was found, not received."), "intent caveat missing")
        let completeness = LeadWorkflow.completeness(for: lead, in: workspace)
        try expect(completeness.items.map(\.points).reduce(0, +) == 100, "completeness points must total 100")
        try expect(completeness.score == completeness.items.filter(\.present).map(\.points).reduce(0, +), "score must equal its items")
        try expect(completeness.items.first { $0.label == "Owner-entered value" }?.present == false, "a prospect has no owner-entered value")
        try expect(completeness.items.first { $0.label == "Named person" }?.present == false, "company name is not a person")
        try expect(LeadWorkflow.Completeness.meaning.contains("not buying intent"), "completeness must disclaim intent")
    }

    static func unlinkedLeadContextIsEmpty() async throws {
        var workspace = PersistentWorkspace()
        let lead = Lead.blank(today: now)
        workspace.leads = [lead]
        workspace.notes = [CRMNote(title: "Unrelated note")]
        workspace.tasks = [CRMTask(title: "Unrelated task")]
        workspace.audits = [BilingualAudit()]
        let context = LeadWorkflow.context(for: lead, in: workspace)
        try expect(context.notes.isEmpty && context.tasks.isEmpty && context.audits.isEmpty, "unlinked records leaked into lead context")
        var linkedTask = CRMTask(title: "Linked")
        linkedTask.leadID = lead.id
        workspace.tasks.append(linkedTask)
        try expect(LeadWorkflow.context(for: lead, in: workspace).tasks.map(\.title) == ["Linked"], "lead-linked task not shown")
    }

    static func convertsReviewedLead() async throws {
        var workspace = PersistentWorkspace()
        let lead = manualLead()
        workspace.leads = [lead]
        let plan = try requireValue(LeadWorkflow.conversionPlan(for: lead.id, in: workspace), "no plan")
        try expect(plan.lines == [
            "Company: create Acme Builders",
            "Contact: create Camille Tremblay",
            "Opportunity: create Camille Tremblay — Kitchen renovation (Proposal, $5,000 CAD owner-entered)",
            "Follow-up task: create Follow up: Camille Tremblay (due 2026-11-08, local reminder at 9 AM)",
        ], "preview lines: \(plan.lines)")
        try expect(plan.blockers.isEmpty && plan.warnings.isEmpty, "unexpected warnings: \(plan.warnings)")
        try expect(workspace.companies.isEmpty && workspace.opportunities.isEmpty, "preview wrote records")

        let result = try LeadWorkflow.applyConversion(plan, to: &workspace, now: now)
        try expect(result.created == ["company", "contact", "opportunity", "follow-up task"], "created: \(result.created)")
        let company = try requireValue(workspace.companies.first, "company missing")
        let contact = try requireValue(workspace.contacts.first, "contact missing")
        let opportunity = try requireValue(workspace.opportunities.first, "opportunity missing")
        let task = try requireValue(workspace.tasks.first, "task missing")
        let saved = workspace.leads[0]
        try expect(company.domain == "acmebuilders.example.test", "company domain from business email: \(company.domain)")
        try expect(saved.companyID == company.id && saved.contactID == contact.id, "lead links")
        try expect(contact.companyID == company.id && contact.leadID == lead.id, "contact links")
        try expect(opportunity.leadID == lead.id && opportunity.companyID == company.id && opportunity.contactID == contact.id, "opportunity links")
        try expect(opportunity.amount == 5_000 && opportunity.stage == .proposal, "opportunity value or stage")
        try expect(task.leadID == lead.id && task.opportunityID == opportunity.id && task.contactID == contact.id && task.companyID == company.id, "task links")
        try expect(task.dueDate == "2026-11-08" && task.status == .todo, "task next action")
        try expect(saved.followUpTaskID == task.id, "lead does not point at its follow-up task")
        try expect(workspace.activity.first?.kind == "lead.converted", "conversion not recorded in activity")
    }

    static func conversionIsIdempotent() async throws {
        var workspace = PersistentWorkspace()
        let lead = manualLead()
        workspace.leads = [lead]
        let first = try converted(lead, in: &workspace)
        let replan = try requireValue(LeadWorkflow.conversionPlan(for: lead.id, in: workspace), "no plan")
        try expect(!replan.creates, "second plan wants to create: \(replan.lines)")
        let second = try LeadWorkflow.applyConversion(replan, to: &workspace, now: now)
        try expect(second.created.isEmpty, "second conversion created \(second.created)")
        try expect(second.opportunityID == first.opportunityID && second.taskID == first.taskID && second.contactID == first.contactID, "different records")
        try expect(workspace.companies.count == 1 && workspace.contacts.count == 1 && workspace.opportunities.count == 1 && workspace.tasks.count == 1, "duplicates created")
    }

    static func conversionDeduplicates() async throws {
        var workspace = PersistentWorkspace()
        var company = Company()
        company.name = "ACME Builders Inc."
        var contact = Contact()
        contact.firstName = "Camille"
        contact.email = "CAMILLE@acmebuilders.example.test"
        workspace.companies = [company]
        workspace.contacts = [contact]
        let lead = manualLead()
        workspace.leads = [lead]
        let plan = try requireValue(LeadWorkflow.conversionPlan(for: lead.id, in: workspace), "no plan")
        try expect(plan.company == .linkExisting(company.id, "ACME Builders Inc."), "company: \(plan.company)")
        try expect(plan.contact == .linkExisting(contact.id, "Camille"), "contact: \(plan.contact)")
        let result = try LeadWorkflow.applyConversion(plan, to: &workspace, now: now)
        try expect(workspace.companies.count == 1 && workspace.contacts.count == 1, "duplicates created")
        try expect(workspace.contacts[0].companyID == company.id && workspace.contacts[0].leadID == lead.id, "existing contact links not filled")
        try expect(result.companyID == company.id, "wrong company")
    }

    static func phoneWithConflictingEmailIsNew() async throws {
        var workspace = PersistentWorkspace()
        var contact = Contact()
        contact.firstName = "Switchboard"
        contact.phone = "514 555 0101"
        contact.email = "reception@other.example.test"
        workspace.contacts = [contact]
        let lead = manualLead()
        workspace.leads = [lead]
        let plan = try requireValue(LeadWorkflow.conversionPlan(for: lead.id, in: workspace), "no plan")
        try expect(plan.contact == .create("Camille Tremblay"), "conflicting email merged: \(plan.contact)")
    }

    static func companyOnlyLeadHasNoContact() async throws {
        var workspace = PersistentWorkspace()
        var lead = Lead.blank(today: now)
        lead.name = "Plomberie Exemple"
        lead.company = "Plomberie Exemple"
        lead.phone = "418-555-0199"
        lead.sourceID = "osm:node:1"
        workspace.leads = [lead]
        let plan = try requireValue(LeadWorkflow.conversionPlan(for: lead.id, in: workspace), "no plan")
        try expect(plan.contact == .skip("no named person recorded"), "contact: \(plan.contact)")
        try expect(plan.warnings.contains { $0.contains("No owner-entered value") }, "missing value not flagged")
        _ = try LeadWorkflow.applyConversion(plan, to: &workspace, now: now)
        try expect(workspace.contacts.isEmpty, "a person was invented from a company name")
        try expect(workspace.companies.first?.phone == "418-555-0199", "listing phone not kept on the company")
        try expect(workspace.opportunities.first?.amount == nil, "a value was invented")
    }

    static func stalePreviewAndBlockerWriteNothing() async throws {
        var workspace = PersistentWorkspace()
        let lead = manualLead()
        workspace.leads = [lead]
        let plan = try requireValue(LeadWorkflow.conversionPlan(for: lead.id, in: workspace), "no plan")
        var company = Company()
        company.name = "Acme Builders"
        workspace.companies.append(company)
        let before = workspace
        do {
            _ = try LeadWorkflow.applyConversion(plan, to: &workspace, now: now)
            throw PortableCheckFailure(description: "stale preview applied")
        } catch LeadWorkflow.ConversionError.planChanged {}
        try expect(workspace == before, "stale preview changed the workspace")

        var unnamed = Lead.blank(today: now)
        unnamed.company = "Nameless Co"
        workspace.leads.append(unnamed)
        let blocked = try requireValue(LeadWorkflow.conversionPlan(for: unnamed.id, in: workspace), "no plan")
        let beforeBlocked = workspace
        do {
            _ = try LeadWorkflow.applyConversion(blocked, to: &workspace, now: now)
            throw PortableCheckFailure(description: "blocked conversion applied")
        } catch LeadWorkflow.ConversionError.blocked {}
        try expect(workspace == beforeBlocked, "blocked conversion changed the workspace")
    }

    static func outcomesCountOwnerValuesOnce() async throws {
        var workspace = PersistentWorkspace()
        let lead = manualLead()
        workspace.leads = [lead]
        _ = try converted(lead, in: &workspace)
        var outcomes = LeadWorkflow.outcomes(leads: workspace.leads, opportunities: workspace.opportunities)
        try expect(outcomes.openValue == 5_000, "converted value double-counted: \(outcomes.openValue)")
        var unvalued = Lead.blank(today: now)
        unvalued.name = "No value yet"
        workspace.leads.append(unvalued)
        workspace.opportunities[0].stage = .won
        outcomes = LeadWorkflow.outcomes(leads: workspace.leads, opportunities: workspace.opportunities)
        try expect(outcomes.wonValue == 5_000 && outcomes.wonCount == 1 && outcomes.closeRate == 100, "won: \(outcomes)")
        try expect(outcomes.openValue == 0 && outcomes.openWithoutValue == 1, "unvalued: \(outcomes)")
    }

    static func legacyOutcomeTotals() async throws {
        var won = Lead.blank(today: now)
        won.status = .won
        won.quoteAmount = 1_200
        var open = Lead.blank(today: now)
        open.status = .quoteSent
        open.quoteAmount = 800
        var lost = Lead.blank(today: now)
        lost.status = .lost
        lost.quoteAmount = 9_000
        let outcomes = LeadWorkflow.outcomes(leads: [won, open, lost], opportunities: [])
        try expect(outcomes.wonValue == 1_200 && outcomes.openValue == 800 && outcomes.closeRate == 50, "legacy totals: \(outcomes)")
    }

    static func outcomeMirrors() async throws {
        var workspace = PersistentWorkspace()
        let lead = manualLead()
        workspace.leads = [lead]
        _ = try converted(lead, in: &workspace)
        var opportunity = workspace.opportunities[0]
        opportunity.stage = .won
        workspace.opportunities[0] = opportunity
        try expect(LeadWorkflow.mirrorOutcome(ofOpportunity: opportunity, in: &workspace, now: now), "won opportunity not mirrored")
        try expect(workspace.leads[0].status == .won && workspace.leads[0].wonAt != nil && workspace.leads[0].nextFollowUp == nil, "lead not won")
        var reopened = workspace.leads[0]
        reopened.status = .lost
        workspace.leads[0] = reopened
        try expect(LeadWorkflow.mirrorOutcome(ofLead: reopened, in: &workspace), "lost lead not mirrored")
        try expect(workspace.opportunities[0].stage == .lost, "opportunity not lost")
    }

    static func draftIsGrounded() async throws {
        var business = BusinessProfile()
        business.name = "Studio Fixture"
        var workspace = PersistentWorkspace()
        var fresh = Lead.blank(today: now)
        fresh.name = "Jordan Lee"
        fresh.notes = "PRIVATE-NOTE-MARKER budget is tight"
        workspace.leads = [fresh]
        let plain = LeadWorkflow.draft(for: fresh, in: workspace, business: business)
        try expect(!plain.text.lowercased().contains("quote"), "a quote was invented: \(plain.text)")
        try expect(!plain.text.contains("PRIVATE-NOTE-MARKER"), "private notes were quoted")
        try expect(plain.text.hasPrefix("Hi Jordan,") && plain.text.hasSuffix("Studio Fixture"), "greeting/signature: \(plain.text)")
        try expect(plain.notMentioned.contains("Internal notes are not quoted."), "notes omission not disclosed")

        let quoted = manualLead()
        let quote = LeadWorkflow.draft(for: quoted, in: workspace, business: business)
        try expect(quote.text.contains("$5,000 CAD") && quote.groundedIn.contains { $0.contains("owner-entered quote") }, "recorded quote missing: \(quote.text)")

        var prospect = PersistentWorkspace()
        let id = try LeadWorkflow.promote(readyProspect(), into: &prospect, now: now)
        let found = try requireValue(prospect.leads.first { $0.id == id }, "lead missing")
        let intro = LeadWorkflow.draft(for: found, in: prospect, business: business)
        try expect(intro.text.contains("I came across Atelier Synthétique Inc.") && !intro.text.contains("following up"), "prospect draft: \(intro.text)")
        try expect(intro.subject.hasPrefix("Introduction") && intro.text.hasPrefix("Hello,"), "prospect subject/greeting: \(intro.subject)")
        try expect(intro.notMentioned.contains { $0.contains("Buyer intent is unknown") }, "intent caveat missing")

        var followed = fresh
        followed.history = [FollowUpEvent(date: "2026-11-01", message: "First")]
        let again = LeadWorkflow.draft(for: followed, in: workspace, business: business)
        try expect(again.text.contains("my message of 2026-11-01"), "recorded history not used: \(again.text)")
    }

    static func reminderTiming() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        var task = CRMTask(title: "Call")
        task.dueDate = "2026-11-08"
        let fire = try requireValue(LeadWorkflow.reminderFireDate(for: task, now: now, calendar: calendar), "no reminder")
        let parts = calendar.dateComponents([.hour, .minute], from: fire)
        try expect(parts.hour == 9 && parts.minute == 0, "not 9 AM local: \(parts)")
        task.reminderAt = "2026-11-06T14:30:00Z"
        try expect(LeadWorkflow.reminderFireDate(for: task, now: now, calendar: calendar) == ISO8601DateFormatter().date(from: "2026-11-06T14:30:00Z"), "explicit instant ignored")
        task.reminderAt = "2026-11-01T14:30:00Z"
        try expect(LeadWorkflow.reminderFireDate(for: task, now: now, calendar: calendar) == nil, "past reminder scheduled")
        task.reminderAt = nil
        task.status = .done
        try expect(LeadWorkflow.reminderFireDate(for: task, now: now, calendar: calendar) == nil, "done task scheduled")
    }

    static func followUpTaskMoves() async throws {
        var workspace = PersistentWorkspace()
        let lead = manualLead()
        workspace.leads = [lead]
        let result = try converted(lead, in: &workspace)
        var sent = workspace.leads[0]
        sent.nextFollowUp = "2026-11-12"
        workspace.leads[0] = sent
        let moved = try requireValue(LeadWorkflow.syncFollowUpTask(for: sent, in: &workspace), "task not moved")
        try expect(moved.id == result.taskID && moved.dueDate == "2026-11-12", "moved task: \(moved)")
        try expect(LeadWorkflow.syncFollowUpTask(for: sent, in: &workspace) == nil, "unchanged date reported a move")
    }

    static func persistsAcrossRelaunch() async throws {
        var workspace = PersistentWorkspace()
        let prospectLeadID = try LeadWorkflow.promote(readyProspect(), into: &workspace, now: now)
        let lead = manualLead()
        workspace.leads.append(lead)
        let result = try converted(lead, in: &workspace)
        var note = CRMNote(title: "Discovery call", body: "Synthetic note")
        note.opportunityID = result.opportunityID
        workspace.notes.append(note)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crm-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workspace.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(workspace).write(to: file, options: .atomic)
        let reloaded = try JSONDecoder().decode(PersistentWorkspace.self, from: Data(contentsOf: file))

        try expect(reloaded == workspace, "workspace changed across save and load")
        let saved = try requireValue(reloaded.leads.first { $0.id == lead.id }, "lead missing")
        let context = LeadWorkflow.context(for: saved, in: reloaded)
        try expect(context.company?.id == result.companyID && context.contact?.id == result.contactID, "links lost")
        try expect(context.opportunity?.stage == .proposal && context.opportunity?.amount == 5_000, "stage or value lost")
        try expect(context.tasks.first { $0.id == saved.followUpTaskID }?.dueDate == "2026-11-08", "next action lost")
        try expect(context.notes.map(\.title) == ["Discovery call"], "note link lost")
        let found = try requireValue(reloaded.leads.first { $0.id == prospectLeadID }, "prospect lead missing")
        try expect(LeadWorkflow.evidenceLines(for: found, in: reloaded).contains { $0.contains("atelier.example.test") }, "evidence lost")
    }

    static func legacyWorkspaceLoads() async throws {
        let id = UUID()
        let json = """
        {"leads":[{"id":"\(id.uuidString)","name":"Legacy","email":"","phone":"","company":"","service":"","status":"new",
        "sequenceStage":0,"notes":"","lastMessage":"","history":[],"createdAt":"2026-09-01T00:00:00Z"}]}
        """
        let workspace = try JSONDecoder().decode(PersistentWorkspace.self, from: Data(json.utf8))
        try expect(workspace.leads.first?.id == id && workspace.leads.first?.followUpTaskID == nil, "legacy lead did not load")
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw PortableCheckFailure(description: message) }
        return value
    }
}
