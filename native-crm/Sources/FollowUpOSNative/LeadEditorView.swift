import AppKit
import SwiftUI

struct LeadEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Lead
    @State private var message = ""
    @State private var showWriter = false
    @State private var generating = false
    @State private var writerNote: String?
    @State private var draftUsedAI = false
    @State private var validationMessage: String?
    @State private var confirmDelete = false
    @State private var pendingConversion: LeadWorkflow.ConversionPlan?
    @State private var groundedDraft: LeadWorkflow.GroundedDraft?
    private let isNew: Bool

    private var emailSubject: String {
        LeadWorkflow.emailSubject(for: draft, body: message, fallback: store.groundedDraft(for: draft).subject)
    }

    private var emailDraftIssue: String? {
        let config = ICPConfig.defaultDirectory(bundle: AppResources.bundle).flatMap { try? ICPConfig.load(directory: $0).interactiveSearch() }
        return LeadWorkflow.emailDraftIssue(for: draft, body: message, subject: emailSubject,
                                           config: config, suppression: store.suppressionList, now: .now)
    }

    init(lead: Lead, isNew: Bool) {
        _draft = State(initialValue: lead)
        _message = State(initialValue: lead.outreachDraft ?? lead.lastMessage)
        _showWriter = State(initialValue: lead.outreachDraft != nil || !lead.lastMessage.isEmpty)
        _writerNote = State(initialValue: lead.outreachDraft == nil ? nil : "Saved unsent draft. Review against the current record before sending.")
        self.isNew = isNew
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                VStack(spacing: 1) {
                    Text(isNew ? "Add lead" : draft.name)
                        .font(.headline)
                    if !isNew { Text("Customer record").font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                if !isNew {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete lead")
                } else {
                    Color.clear.frame(width: 28, height: 1)
                }
            }
            .padding(16)
            .background(CRMTheme.ink)
            .foregroundStyle(.white)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !isNew {
                        Picker("Status", selection: statusBinding) {
                            ForEach(LeadStatus.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(CRMTheme.rust)
                    }

                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                        GridRow {
                            formField("Name *") { TextField("John Smith", text: $draft.name) }
                            formField("Email") { TextField("john@example.com", text: $draft.email) }
                        }
                        GridRow {
                            formField("Phone") { TextField("555-123-4567", text: $draft.phone) }
                            formField("Company") { TextField("Optional", text: $draft.company) }
                        }
                        GridRow {
                            formField("Service / ask") { TextField("Kitchen renovation quote", text: $draft.service) }
                            formField("Quote (CAD)") {
                                TextField("0", value: $draft.quoteAmount, format: .number)
                            }
                        }
                    }

                    SectionLabel(text: "Relationship context")
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                        GridRow {
                            Picker("Company", selection: companyBinding) {
                                Text("Unlinked").tag(UUID?.none)
                                ForEach(store.companies) { Text($0.name).tag(Optional($0.id)) }
                            }
                            Picker("Contact", selection: contactBinding) {
                                Text("Unlinked").tag(UUID?.none)
                                ForEach(store.contacts) { Text($0.displayName).tag(Optional($0.id)) }
                            }
                        }
                    }
                    if !isNew {
                        let completeness = LeadWorkflow.completeness(for: draft, in: store.workspace)
                        let missing = completeness.items.filter { !$0.present }.map(\.label)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SOURCE AND EVIDENCE").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            ForEach(Array(LeadWorkflow.evidenceLines(for: draft, in: store.workspace).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if let research = draft.quickScanResearch {
                                DisclosureGroup("Contact and AI-use research") {
                                    ForEach(Array(research.lines.enumerated()), id: \.offset) { _, line in
                                        Text(line).font(.caption).textSelection(.enabled)
                                    }
                                }
                            }
                            Text("Record completeness \(completeness.score)/100 · missing: \(missing.isEmpty ? "none" : missing.joined(separator: ", "))")
                                .font(.caption.monospacedDigit())
                            Text(LeadWorkflow.Completeness.meaning).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(12).background(CRMTheme.paper, in: RoundedRectangle(cornerRadius: 8))
                    }

                    if isNew {
                        Picker("Initial status", selection: statusBinding) {
                            ForEach(LeadStatus.allCases.filter(\.isOpen)) { Text($0.label).tag($0) }
                        }
                    } else {
                        HStack {
                            SectionLabel(text: "Linked context")
                            Spacer()
                            Button(store.opportunities.contains(where: { $0.leadID == draft.id }) ? "Review links…" : "Review conversion…") { reviewConversion() }
                                .help("Previews the company, contact, opportunity and follow-up task. Nothing changes until you confirm.")
                        }
                        .confirmationDialog("Convert this lead?", isPresented: conversionPresented, titleVisibility: .visible, presenting: pendingConversion) { plan in
                            if plan.blockers.isEmpty {
                                Button("Convert") { convert(plan) }
                            }
                            Button("Cancel", role: .cancel) { pendingConversion = nil }
                        } message: { plan in
                            Text((plan.blockers + plan.lines + plan.warnings).joined(separator: "\n"))
                        }
                        let linked = LeadWorkflow.context(for: draft, in: store.workspace)
                        if let company = linked.company {
                            Label("Company · \(company.name)", systemImage: "building.2").font(.callout)
                        }
                        if let contact = linked.contact {
                            Label("Contact · \(contact.displayName)", systemImage: "person").font(.callout)
                        }
                        if let opportunity = linked.opportunity {
                            Label("Opportunity · \(opportunity.name) · \(opportunity.stage.label) · \(opportunity.amount.map { LeadWorkflow.formatAmount($0) + " CAD" } ?? "no value entered")", systemImage: "chart.line.uptrend.xyaxis").font(.callout)
                        }
                        ForEach(linked.notes) { note in
                            Label(note.title, systemImage: "note.text").font(.callout)
                        }
                        ForEach(linked.audits) { audit in
                            Label("Lantern · \(audit.name) · \(audit.languageGap.map { "FR/EN gap \($0.formatted(.number.precision(.fractionLength(1))))" } ?? "unscored — both assessments need evidence")", systemImage: "checkmark.seal").font(.callout)
                        }
                        ForEach(linked.tasks) { task in
                            Label("\(task.title) · \(task.status.label) · \(CalendarCRM.display(task.dueDate))", systemImage: "checklist").font(.callout)
                        }
                        if draft.status.isOpen {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("NEXT FOLLOW-UP").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                                HStack {
                                    DatePicker(
                                        "",
                                        selection: followUpDateBinding,
                                        displayedComponents: .date
                                    )
                                    .labelsHidden()
                                    Button("Clear") { draft.nextFollowUp = nil }
                                        .disabled(draft.nextFollowUp == nil)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            Text("NOTES").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            TextEditor(text: $draft.notes)
                                .font(.body)
                                .frame(minHeight: 72)
                                .padding(6)
                                .background(CRMTheme.paper, in: RoundedRectangle(cornerRadius: 6))
                                .overlay { RoundedRectangle(cornerRadius: 6).stroke(CRMTheme.border) }
                        }

                        writerSection

                        if !draft.history.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                SectionLabel(text: "History")
                                ForEach(draft.history.reversed()) { event in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "paperplane.fill").foregroundStyle(CRMTheme.steel)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(CalendarCRM.display(event.date)) · follow-up sent")
                                                .font(.callout.weight(.semibold))
                                            Text(event.message)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(22)
            }

            Divider()
            HStack {
                Text("Data saves to this Mac-local workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isNew ? "Add lead" : "Save & close") { saveAndClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 720, height: isNew ? 520 : 720)
        .background(CRMTheme.paper)
        .confirmationDialog(
            "Delete this lead?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(draft.name)", role: .destructive) {
                if store.delete(draft) { dismiss() } else { validationMessage = store.saveFailure }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The saved lead and its history are removed locally after a private recovery backup is saved. Related records stay, their lead links are cleared, and its next-action task is closed. Restore the backup from Settings → Backup and recovery. No upstream record is deleted.")
        }
    }

    @ViewBuilder
    private var writerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Follow-up message")
                Spacer()
                if showWriter {
                    Button("Regenerate", systemImage: "sparkles") { generate() }
                        .disabled(generating)
                }
            }

            if showWriter {
                if draftUsedAI {
                    Label("AI draft · review before sending", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(CRMTheme.amberDark.opacity(0.15), in: Capsule())
                        .foregroundStyle(CRMTheme.amberDark)
                        .accessibilityLabel("AI draft. Review before sending.")
                }
                if let writerNote {
                    Text(writerNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: $message)
                    .onChange(of: message) { _, value in draft.outreachDraft = value }
                    .font(.body)
                    .frame(minHeight: 130)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(CRMTheme.border) }
                if let groundedDraft {
                    Text("Grounded in: \(groundedDraft.groundedIn.joined(separator: " · "))")
                        .font(.caption2).foregroundStyle(.secondary)
                    if !groundedDraft.notMentioned.isEmpty {
                        Text("Unknown, not stated: \(groundedDraft.notMentioned.joined(separator: " "))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Copy", systemImage: "doc.on.doc") { copyMessage() }
                    Menu("Email", systemImage: "envelope") {
                        Button("Default mail app") { emailMessage(.defaultMail) }
                        Button("Gmail in browser…") { emailMessage(.gmail) }
                            .help("Shares this draft's recipient, subject and message with Gmail. Check the sending account there; nothing is sent automatically.")
                    }
                        .disabled(draft.email.isEmpty || message.isEmpty || emailDraftIssue != nil)
                        .help(emailDraftIssue ?? "Choose where to review this unsent draft. Gmail uses the account signed in to your browser.")
                    Spacer()
                    Button("Mark as sent", systemImage: "paperplane") { markSent() }
                        .buttonStyle(.borderedProminent)
                        .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("In Gmail, check the sending account before sending. Gmail may save the unsent draft.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let issue = emailDraftIssue { Text(issue).font(.caption).foregroundStyle(CRMTheme.rust) }
            } else {
                Button {
                    generate()
                } label: {
                    Label(generating ? "Writing…" : "Write follow-up message", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(generating)
            }
            Text("Drafts use only recorded facts. Apple Intelligence may rephrase them on this Mac when available; anything it adds that is not recorded is set aside. Nothing is sent without your review.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(CRMTheme.steel.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private func formField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusBinding: Binding<LeadStatus> {
        Binding(
            get: { draft.status },
            set: { newStatus in
                draft.status = newStatus
                switch newStatus {
                case .won:
                    draft.wonAt = Date.now.ISO8601Format()
                    draft.lostAt = nil
                    draft.nextFollowUp = nil
                case .lost:
                    draft.lostAt = Date.now.ISO8601Format()
                    draft.wonAt = nil
                    draft.nextFollowUp = nil
                default:
                    draft.wonAt = nil
                    draft.lostAt = nil
                    if let delay = newStatus.initialFollowUpDelay {
                        draft.nextFollowUp = CalendarCRM.addDays(delay, to: CalendarCRM.dayString())
                    }
                }
            }
        )
    }

    private var followUpDateBinding: Binding<Date> {
        Binding(
            get: { CalendarCRM.date(from: draft.nextFollowUp) ?? .now },
            set: { draft.nextFollowUp = CalendarCRM.dayString($0) }
        )
    }

    private var companyBinding: Binding<UUID?> { Binding(get: { draft.companyID }, set: { draft.companyID = $0 }) }
    private var contactBinding: Binding<UUID?> { Binding(get: { draft.contactID }, set: { draft.contactID = $0 }) }

    private func saveAndClose() {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationMessage = "Enter the lead's name."
            return
        }
        draft.name = trimmed
        if showWriter && (draft.outreachDraft != nil || message != draft.lastMessage) { draft.outreachDraft = message }
        if isNew ? store.add(draft) : store.update(draft) { dismiss() }
        else { validationMessage = store.saveFailure }
    }

    private var conversionPresented: Binding<Bool> {
        Binding(get: { pendingConversion != nil }, set: { if !$0 { pendingConversion = nil } })
    }

    /// Saves the editor first so the preview describes the record the owner sees, then shows the plan.
    private func reviewConversion() {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationMessage = "Enter the lead's name."
            return
        }
        draft.name = trimmed
        guard store.update(draft) else { validationMessage = store.saveFailure; return }
        pendingConversion = store.conversionPlan(for: draft)
    }

    private func convert(_ plan: LeadWorkflow.ConversionPlan) {
        pendingConversion = nil
        guard store.convertLead(confirmed: plan) != nil else { return }
        // Reload the saved links so Save & close cannot overwrite them with the editor's older copy.
        if let saved = store.leads.first(where: { $0.id == draft.id }) { draft = saved }
    }

    private func generate() {
        generating = true
        writerNote = nil
        Task {
            let result = await store.generateMessage(for: draft)
            message = result.text
            draft.outreachDraft = result.text
            draftUsedAI = result.usedIntelligence
            groundedDraft = result.grounded
            writerNote = result.usedIntelligence
                ? "Apple Intelligence rephrased the grounded draft on this Mac, using only the facts below; internal notes were not given to it. Review it before sending."
                : (result.fallbackReason ?? "Local draft from recorded facts only. \(LeadWorkflow.GroundedDraft.reviewNotice)")
            showWriter = true
            generating = false
        }
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
        writerNote = "Copied to the clipboard."
    }

    private func emailMessage(_ destination: LeadWorkflow.EmailDraftDestination) {
        // Files or evidence may change while the editor is open; the action checks again too.
        let config = ICPConfig.defaultDirectory(bundle: AppResources.bundle).flatMap { try? ICPConfig.load(directory: $0).interactiveSearch() }
        do {
            let url = try LeadWorkflow.emailDraftURL(for: draft, body: message, subject: emailSubject,
                                                    destination: destination, config: config,
                                                    suppression: store.suppressionList, now: .now)
            guard NSWorkspace.shared.open(url) else {
                validationMessage = "No application could open this draft. Use Copy, or choose another Email destination."
                return
            }
            writerNote = "Draft requested in \(destination == .gmail ? "Gmail" : "your default mail app"). Review the sending account, recipient and text there. If no composer appears, use Copy."
        } catch { validationMessage = error.localizedDescription }
    }

    private func markSent() {
        guard store.markMessageSent(on: &draft, message: message) else { validationMessage = store.saveFailure; return }
        writerNote = draft.nextFollowUp == nil
            ? "Logged. Sequence complete. Decide the next step."
            : "Logged. Next follow-up suggested for \(CalendarCRM.display(draft.nextFollowUp))."
    }
}
