import SwiftUI

private struct EditorShell<Content: View>: View {
    @EnvironmentObject private var store: AppStore
    let title: String
    let onCancel: () -> Void
    let onSave: () -> Void
    let saveIssue: String?
    let deleteTitle: String?
    let deleteMessage: String
    let onDelete: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @State private var confirmDelete = false
    @State private var validationError: String?

    init(title: String, onCancel: @escaping () -> Void, onSave: @escaping () -> Void,
         saveIssue: String? = nil, deleteTitle: String? = nil, deleteMessage: String = "",
         onDelete: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.onCancel = onCancel; self.onSave = onSave
        self.saveIssue = saveIssue; self.deleteTitle = deleteTitle; self.deleteMessage = deleteMessage
        self.onDelete = onDelete; self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Text(title).font(.headline)
                Spacer()
                if let deleteTitle, onDelete != nil {
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                        .help(deleteTitle).accessibilityLabel(deleteTitle)
                }
                Button("Save") {
                    validationError = saveIssue
                    if saveIssue == nil { onSave() }
                }.buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(CRMTheme.ink)
            .foregroundStyle(.white)
            SaveFailureNotice()
            if let validationError {
                Text(validationError).foregroundStyle(CRMTheme.rust).padding(.horizontal, 16).padding(.top, 8)
            }
            Form { content() }
                .formStyle(.grouped)
        }
        .frame(width: 560, height: 430)
        .onAppear { store.clearSaveFailure() }
        .onChange(of: saveIssue) { _, issue in if issue == nil { validationError = nil } }
        .confirmationDialog(deleteTitle ?? "Delete record?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete local record", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(deleteMessage + " A private recovery backup is saved first. Restore it from Settings → Backup and recovery. Unsaved edits are discarded. No upstream record is deleted.")
        }
    }
}

struct ContactEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Contact
    private let existing: Bool

    init(contact: Contact?) { _draft = State(initialValue: contact ?? Contact()); existing = contact != nil }

    var body: some View {
        EditorShell(title: existing ? "Edit contact" : "New contact", onCancel: { dismiss() }, onSave: save,
                    saveIssue: draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a first or last name." : nil,
                    deleteTitle: existing ? "Delete contact \"\(draft.displayName)\"?" : nil,
                    deleteMessage: "Related records and their text stay; their contact link is cleared.",
                    onDelete: { if store.delete(draft) { dismiss() } }) {
            Section("Identity") {
                TextField("First name", text: $draft.firstName)
                TextField("Last name", text: $draft.lastName)
                TextField("Job title", text: $draft.title)
            }
            Section("Contact details") {
                TextField("Email", text: $draft.email)
                TextField("Phone", text: $draft.phone)
            }
            Section("Relationships") {
                Picker("Company", selection: companyBinding) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(store.companies) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Lead", selection: leadBinding) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(store.leads) { Text($0.name).tag(Optional($0.id)) }
                }
            }
        }
        .environmentObject(store)
    }

    private var companyBinding: Binding<UUID?> { Binding(get: { draft.companyID }, set: { draft.companyID = $0 }) }
    private var leadBinding: Binding<UUID?> { Binding(get: { draft.leadID }, set: { draft.leadID = $0 }) }
    private func save() {
        guard !draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if existing ? store.update(draft) : store.add(draft) { dismiss() }
    }
}

struct CompanyEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Company
    private let existing: Bool

    init(company: Company?) { _draft = State(initialValue: company ?? Company()); existing = company != nil }

    var body: some View {
        EditorShell(title: existing ? "Edit company" : "New company", onCancel: { dismiss() }, onSave: save,
                    saveIssue: draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a company name." : nil,
                    deleteTitle: existing ? "Delete company \"\(draft.name)\"?" : nil,
                    deleteMessage: "Related records and their text stay; their company link is cleared. Account evidence history is retained.",
                    onDelete: { if store.delete(draft) { dismiss() } }) {
            Section("Company") {
                TextField("Name", text: $draft.name)
                TextField("Domain", text: $draft.domain)
                TextField("Industry", text: $draft.industry)
                TextField("Phone", text: $draft.phone)
            }
            Section("Notes") { TextEditor(text: $draft.notes).frame(minHeight: 90) }
        }
        .environmentObject(store)
    }

    private func save() {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if existing ? store.update(draft) : store.add(draft) { dismiss() }
    }
}

struct OpportunityEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Opportunity
    private let existing: Bool

    init(opportunity: Opportunity?) { _draft = State(initialValue: opportunity ?? Opportunity()); existing = opportunity != nil }

    var body: some View {
        EditorShell(title: existing ? "Edit opportunity" : "New opportunity", onCancel: { dismiss() }, onSave: save,
                    saveIssue: draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter an opportunity name." : nil,
                    deleteTitle: existing ? "Delete opportunity \"\(draft.name)\"?" : nil,
                    deleteMessage: "Related tasks and notes stay; their opportunity link is cleared. Leads keep their own recorded values and status.",
                    onDelete: { if store.delete(draft) { dismiss() } }) {
            Section("Opportunity") {
                TextField("Name", text: $draft.name)
                TextField("Amount (CAD)", value: $draft.amount, format: .number)
                Picker("Stage", selection: $draft.stage) { ForEach(OpportunityStage.allCases) { Text($0.label).tag($0) } }
                DatePicker("Close date", selection: closeDateBinding, displayedComponents: .date)
            }
            Section("Context") {
                Picker("Contact", selection: contactBinding) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(store.contacts) { Text($0.displayName).tag(Optional($0.id)) }
                }
                Picker("Company", selection: companyBinding) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(store.companies) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Lead", selection: leadBinding) {
                    Text("Unlinked").tag(UUID?.none)
                    ForEach(store.leads) { Text($0.name).tag(Optional($0.id)) }
                }
                TextEditor(text: $draft.notes).frame(minHeight: 70)
            }
        }
        .environmentObject(store)
    }

    private var closeDateBinding: Binding<Date> {
        Binding(get: { CalendarCRM.date(from: draft.closeDate) ?? .now }, set: { draft.closeDate = CalendarCRM.dayString($0) })
    }
    private var contactBinding: Binding<UUID?> { Binding(get: { draft.contactID }, set: { draft.contactID = $0 }) }
    private var companyBinding: Binding<UUID?> { Binding(get: { draft.companyID }, set: { draft.companyID = $0 }) }
    private var leadBinding: Binding<UUID?> { Binding(get: { draft.leadID }, set: { draft.leadID = $0 }) }
    private func save() { guard !draft.name.isEmpty else { return }; if existing ? store.update(draft) : store.add(draft) { dismiss() } }
}

struct TaskEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CRMTask
    private let existing: Bool

    init(task: CRMTask?) { _draft = State(initialValue: task ?? CRMTask()); existing = task != nil }

    var body: some View {
        EditorShell(title: existing ? "Edit task" : "New task", onCancel: { dismiss() }, onSave: save,
                    saveIssue: draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a task title." : nil,
                    deleteTitle: existing ? "Delete task \"\(draft.title)\"?" : nil,
                    deleteMessage: "If this is a lead’s next-action task, its follow-up date is cleared and its reminder is cancelled. Historical task receipts are retained.",
                    onDelete: { if store.delete(draft) { dismiss() } }) {
            Section("Task") {
                TextField("Title", text: $draft.title)
                Picker("Status", selection: $draft.status) { ForEach(TaskStatus.allCases) { Text($0.label).tag($0) } }
                DatePicker("Reminder date and time", selection: dueDateBinding, displayedComponents: [.date, .hourAndMinute])
                Text("Sends a local macOS notification at this time. It does not email or message anyone.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.details).frame(minHeight: 90)
            }
            Section("Relationships") {
                Picker("Contact", selection: contactBinding) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(store.contacts) { Text($0.displayName).tag(Optional($0.id)) }
                }
                Picker("Company", selection: companyBinding) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(store.companies) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Opportunity", selection: opportunityBinding) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(store.opportunities) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Lead", selection: leadBinding) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(store.leads) { Text($0.name).tag(Optional($0.id)) }
                }
            }
        }
        .environmentObject(store)
    }

    private var dueDateBinding: Binding<Date> {
        Binding(
            get: {
                if let value = draft.reminderAt, let date = ISO8601DateFormatter().date(from: value) { return date }
                if let due = CalendarCRM.date(from: draft.dueDate) { return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: due) ?? due }
                return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
            },
            set: { draft.dueDate = CalendarCRM.dayString($0); draft.reminderAt = $0.ISO8601Format() }
        )
    }
    private var contactBinding: Binding<UUID?> { Binding(get: { draft.contactID }, set: { draft.contactID = $0 }) }
    private var companyBinding: Binding<UUID?> { Binding(get: { draft.companyID }, set: { draft.companyID = $0 }) }
    private var opportunityBinding: Binding<UUID?> { Binding(get: { draft.opportunityID }, set: { draft.opportunityID = $0 }) }
    private var leadBinding: Binding<UUID?> { Binding(get: { draft.leadID }, set: { draft.leadID = $0 }) }
    private func save() {
        guard !draft.title.isEmpty else { return }
        // Persist the displayed default too; otherwise a new task can appear dated
        // in the editor while still having no reminder instant in storage.
        if draft.reminderAt == nil { dueDateBinding.wrappedValue = dueDateBinding.wrappedValue }
        if existing ? store.update(draft) : store.add(draft) { dismiss() }
    }
}

struct NoteEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CRMNote
    private let existing: Bool

    init(note: CRMNote?) { _draft = State(initialValue: note ?? CRMNote()); existing = note != nil }

    var body: some View {
        EditorShell(title: existing ? "Edit note" : "New note", onCancel: { dismiss() }, onSave: save,
                    saveIssue: draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a note title." : nil,
                    deleteTitle: existing ? "Delete note \"\(draft.title)\"?" : nil,
                    deleteMessage: "The saved note is removed. Related contacts, companies and opportunities stay.",
                    onDelete: { if store.delete(draft) { dismiss() } }) {
            Section("Note") {
                TextField("Title", text: $draft.title)
                TextEditor(text: $draft.body).frame(minHeight: 170)
            }
            Section("Relationships") {
                Picker("Contact", selection: contactBinding) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(store.contacts) { Text($0.displayName).tag(Optional($0.id)) }
                }
                Picker("Company", selection: companyBinding) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(store.companies) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Opportunity", selection: opportunityBinding) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(store.opportunities) { Text($0.name).tag(Optional($0.id)) }
                }
            }
        }
        .environmentObject(store)
    }

    private var contactBinding: Binding<UUID?> { Binding(get: { draft.contactID }, set: { draft.contactID = $0 }) }
    private var companyBinding: Binding<UUID?> { Binding(get: { draft.companyID }, set: { draft.companyID = $0 }) }
    private var opportunityBinding: Binding<UUID?> { Binding(get: { draft.opportunityID }, set: { draft.opportunityID = $0 }) }
    private func save() { guard !draft.title.isEmpty else { return }; draft.updatedAt = Date.now.ISO8601Format(); if existing ? store.update(draft) : store.add(draft) { dismiss() } }
}

/// A save error remains visible while the editor retains the owner's draft.
struct SaveFailureNotice: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        if let error = store.saveFailure {
            Label(error + " Check storage and try saving again.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(CRMTheme.rust)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
}
