import SwiftUI

enum DirectoryKind: String, CaseIterable, Identifiable {
    case contacts, companies, opportunities, tasks, notes
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .contacts: "person.2"
        case .companies: "building.2"
        case .opportunities: "chart.bar.xaxis"
        case .tasks: "checklist"
        case .notes: "note.text"
        }
    }
}

struct DirectoryView: View {
    @EnvironmentObject private var store: AppStore
    let kind: DirectoryKind
    @State private var search = ""
    @State private var showEditor = false
    @State private var selectedContact: Contact?
    @State private var selectedCompany: Company?
    @State private var selectedOpportunity: Opportunity?
    @State private var selectedTask: CRMTask?
    @State private var selectedNote: CRMNote?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title).font(.title2.weight(.bold))
                    Text(subtitle).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add \(kind.title.dropLast(kind == .notes ? 1 : 0))", systemImage: "plus") { showEditor = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 16)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(kind.title.lowercased())…", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(CRMTheme.border) }
            .padding(.horizontal, 28)
            .padding(.bottom, 14)

            List {
                switch kind {
                case .contacts:
                    ForEach(store.contacts.filter { matches($0.displayName, $0.email, $0.title) }) { contact in
                        DirectoryRow(title: contact.displayName.isEmpty ? "Unnamed contact" : contact.displayName, subtitle: [contact.title, contact.email].filter { !$0.isEmpty }.joined(separator: " · "), symbol: "person")
                            .contentShape(Rectangle())
                            .onTapGesture { selectedContact = contact }
                    }
                case .companies:
                    ForEach(store.companies.filter { matches($0.name, $0.domain, $0.industry) }) { company in
                        DirectoryRow(title: company.name, subtitle: [company.industry, company.domain].filter { !$0.isEmpty }.joined(separator: " · "), symbol: "building.2")
                            .contentShape(Rectangle())
                            .onTapGesture { selectedCompany = company }
                    }
                case .opportunities:
                    ForEach(store.opportunities.filter { matches($0.name, $0.stage.label) }) { opportunity in
                        DirectoryRow(title: opportunity.name, subtitle: opportunity.stage.label, trailing: opportunity.amount.map { $0.formatted(.currency(code: "CAD").precision(.fractionLength(0))) } ?? "", symbol: "chart.bar.xaxis")
                            .contentShape(Rectangle())
                            .onTapGesture { selectedOpportunity = opportunity }
                    }
                case .tasks:
                    ForEach(store.tasks.filter { matches($0.title, $0.details, $0.status.label) }) { task in
                        DirectoryRow(title: task.title, subtitle: task.status.label, trailing: CalendarCRM.display(task.dueDate), symbol: task.status == .done ? "checkmark.circle.fill" : "circle")
                            .contentShape(Rectangle())
                            .onTapGesture { selectedTask = task }
                    }
                case .notes:
                    ForEach(store.notes.filter { matches($0.title, $0.body) }) { note in
                        DirectoryRow(title: note.title, subtitle: note.body, symbol: "note.text")
                            .contentShape(Rectangle())
                            .onTapGesture { selectedNote = note }
                    }
                }
            }
            .listStyle(.inset)
        }
        .navigationTitle(kind.title)
        .sheet(isPresented: $showEditor) { editorSheet(existing: nil) }
        .sheet(item: $selectedContact) { ContactEditor(contact: $0).environmentObject(store) }
        .sheet(item: $selectedCompany) { CompanyEditor(company: $0).environmentObject(store) }
        .sheet(item: $selectedOpportunity) { OpportunityEditor(opportunity: $0).environmentObject(store) }
        .sheet(item: $selectedTask) { TaskEditor(task: $0).environmentObject(store) }
        .sheet(item: $selectedNote) { NoteEditor(note: $0).environmentObject(store) }
    }

    @ViewBuilder private func editorSheet(existing: Any?) -> some View {
        switch kind {
        case .contacts: ContactEditor(contact: nil).environmentObject(store)
        case .companies: CompanyEditor(company: nil).environmentObject(store)
        case .opportunities: OpportunityEditor(opportunity: nil).environmentObject(store)
        case .tasks: TaskEditor(task: nil).environmentObject(store)
        case .notes: NoteEditor(note: nil).environmentObject(store)
        }
    }

    private func matches(_ values: String...) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return query.isEmpty || values.contains { $0.lowercased().contains(query) }
    }

    private var subtitle: String {
        switch kind {
        case .contacts: "People connected to your workspace"
        case .companies: "Organizations and accounts"
        case .opportunities: "Revenue records across the pipeline"
        case .tasks: "Work to complete across your records"
        case .notes: "Context attached to customer relationships"
        }
    }
}

struct DirectoryRow: View {
    let title: String
    let subtitle: String
    var trailing = ""
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(CRMTheme.steel).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if !trailing.isEmpty { Text(trailing).font(.system(.callout, design: .monospaced, weight: .semibold)) }
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }
}
