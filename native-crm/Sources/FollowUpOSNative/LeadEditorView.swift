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
    private let isNew: Bool

    init(lead: Lead, isNew: Bool) {
        _draft = State(initialValue: lead)
        _message = State(initialValue: lead.lastMessage)
        _showWriter = State(initialValue: !lead.lastMessage.isEmpty)
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
                    if let signal = store.signals.first(where: { $0.leadID == draft.id }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("RESEARCH EVIDENCE").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            Text("Research priority \(signal.priority)/100 · fit \(signal.fitScore) · buyer intent \(signal.intentScore == 0 ? "unknown" : String(signal.intentScore))")
                                .font(.caption.monospacedDigit())
                            Text(signal.evidence).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
                            Button(store.opportunities.contains(where: { $0.leadID == draft.id }) ? "Open opportunity" : "Create opportunity") {
                                let opportunity = store.createOpportunity(from: draft)
                                store.notice = "Opportunity ready in the \(opportunity.stage.label) stage."
                            }
                        }
                        ForEach(store.notes.filter { $0.contactID == draft.contactID || $0.companyID == draft.companyID || $0.opportunityID == store.opportunities.first(where: { $0.leadID == draft.id })?.id }) { note in
                            Label(note.title, systemImage: "note.text").font(.callout)
                        }
                        ForEach(store.audits.filter { $0.leadID == draft.id || $0.contactID == draft.contactID || $0.companyID == draft.companyID }) { audit in
                            Label("Lantern · \(audit.name) · FR/EN gap \(audit.languageGap.formatted(.number.precision(.fractionLength(1))))", systemImage: "checkmark.seal").font(.callout)
                        }
                        ForEach(store.tasks.filter { $0.leadID == draft.id || $0.contactID == draft.contactID || $0.companyID == draft.companyID }) { task in
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
                store.delete(draft)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The lead and follow-up history will be permanently removed.")
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
                    .font(.body)
                    .frame(minHeight: 130)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(CRMTheme.border) }
                HStack {
                    Button("Copy", systemImage: "doc.on.doc") { copyMessage() }
                    Button("Email", systemImage: "envelope") { emailMessage() }
                        .disabled(draft.email.isEmpty || message.isEmpty)
                    Spacer()
                    Button("Mark as sent", systemImage: "paperplane") { markSent() }
                        .buttonStyle(.borderedProminent)
                        .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
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
            Text("Drafts use Apple Intelligence on this Mac when available; customer details stay on the device, and nothing is sent without your review.")
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
        if isNew { store.add(draft) } else { store.update(draft) }
        store.linkLead(draft.id, companyID: draft.companyID, contactID: draft.contactID)
        dismiss()
    }

    private func generate() {
        generating = true
        writerNote = nil
        Task {
            let result = await store.generateMessage(for: draft)
            message = result.text
            draftUsedAI = result.usedIntelligence
            writerNote = result.usedIntelligence
                ? "This lead's name, request, quote, and notes were processed by Apple Intelligence on this Mac only; nothing is sent until you choose Email."
                : "The on-device writer was unavailable, so the standard local template is ready."
            showWriter = true
            generating = false
        }
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
        writerNote = "Copied to the clipboard."
    }

    private func emailMessage() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.email
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Following up\(draft.service.isEmpty ? "" : " - \(draft.service)")"),
            URLQueryItem(name: "body", value: message),
        ]
        if let url = components.url {
#if DEBUG && CONTEXTWARD_ACCEPTANCE
            writerNote = "External apps are disabled in the isolated preview."
#else
            NSWorkspace.shared.open(url)
#endif
        }
    }

    private func markSent() {
        store.markMessageSent(on: &draft, message: message)
        writerNote = draft.nextFollowUp == nil
            ? "Logged. Sequence complete. Decide the next step."
            : "Logged. Next follow-up suggested for \(CalendarCRM.display(draft.nextFollowUp))."
    }
}
