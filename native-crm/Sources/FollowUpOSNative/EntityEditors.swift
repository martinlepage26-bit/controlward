import SwiftUI

private struct EditorShell<Content: View>: View {
    let title: String
    let onCancel: () -> Void
    let onSave: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Text(title).font(.headline)
                Spacer()
                Button("Save", action: onSave).buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(CRMTheme.ink)
            .foregroundStyle(.white)
            Form { content() }
                .formStyle(.grouped)
        }
        .frame(width: 560, height: 430)
    }
}

struct ContactEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Contact
    private let existing: Bool

    init(contact: Contact?) { _draft = State(initialValue: contact ?? Contact()); existing = contact != nil }

    var body: some View {
        EditorShell(title: existing ? "Edit contact" : "New contact", onCancel: { dismiss() }, onSave: save) {
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
        existing ? store.update(draft) : store.add(draft)
        dismiss()
    }
}

struct CompanyEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Company
    private let existing: Bool

    init(company: Company?) { _draft = State(initialValue: company ?? Company()); existing = company != nil }

    var body: some View {
        EditorShell(title: existing ? "Edit company" : "New company", onCancel: { dismiss() }, onSave: save) {
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
        existing ? store.update(draft) : store.add(draft)
        dismiss()
    }
}

struct OpportunityEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Opportunity
    private let existing: Bool

    init(opportunity: Opportunity?) { _draft = State(initialValue: opportunity ?? Opportunity()); existing = opportunity != nil }

    var body: some View {
        EditorShell(title: existing ? "Edit opportunity" : "New opportunity", onCancel: { dismiss() }, onSave: save) {
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
    private func save() { guard !draft.name.isEmpty else { return }; existing ? store.update(draft) : store.add(draft); dismiss() }
}

struct TaskEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CRMTask
    private let existing: Bool

    init(task: CRMTask?) { _draft = State(initialValue: task ?? CRMTask()); existing = task != nil }

    var body: some View {
        EditorShell(title: existing ? "Edit task" : "New task", onCancel: { dismiss() }, onSave: save) {
            Section("Task") {
                TextField("Title", text: $draft.title)
                Picker("Status", selection: $draft.status) { ForEach(TaskStatus.allCases) { Text($0.label).tag($0) } }
                DatePicker("Due date", selection: dueDateBinding, displayedComponents: .date)
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
        Binding(get: { CalendarCRM.date(from: draft.dueDate) ?? .now }, set: { draft.dueDate = CalendarCRM.dayString($0) })
    }
    private var contactBinding: Binding<UUID?> { Binding(get: { draft.contactID }, set: { draft.contactID = $0 }) }
    private var companyBinding: Binding<UUID?> { Binding(get: { draft.companyID }, set: { draft.companyID = $0 }) }
    private var opportunityBinding: Binding<UUID?> { Binding(get: { draft.opportunityID }, set: { draft.opportunityID = $0 }) }
    private var leadBinding: Binding<UUID?> { Binding(get: { draft.leadID }, set: { draft.leadID = $0 }) }
    private func save() { guard !draft.title.isEmpty else { return }; existing ? store.update(draft) : store.add(draft); dismiss() }
}

struct NoteEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CRMNote
    private let existing: Bool

    init(note: CRMNote?) { _draft = State(initialValue: note ?? CRMNote()); existing = note != nil }

    var body: some View {
        EditorShell(title: existing ? "Edit note" : "New note", onCancel: { dismiss() }, onSave: save) {
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
            }
        }
        .environmentObject(store)
    }

    private var contactBinding: Binding<UUID?> { Binding(get: { draft.contactID }, set: { draft.contactID = $0 }) }
    private var companyBinding: Binding<UUID?> { Binding(get: { draft.companyID }, set: { draft.companyID = $0 }) }
    private func save() { guard !draft.title.isEmpty else { return }; draft.updatedAt = Date.now.ISO8601Format(); existing ? store.update(draft) : store.add(draft); dismiss() }
}
