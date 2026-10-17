import SwiftUI

enum DirectoryKind: String, CaseIterable, Identifiable {
    case contacts, companies, opportunities, tasks, notes
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var singular: String {
        switch self { case .contacts: "contact"; case .companies: "company"; case .opportunities: "opportunity"; case .tasks: "task"; case .notes: "note" }
    }
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
    @State private var filter: RecordFilter = .all
    @State private var sort: RecordSort = .name
    @State private var projectRecord: WorkspaceRecord?
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
                Button("Add \(kind.singular)", systemImage: "plus") { showEditor = true }
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

            HStack {
                Text("\(rows.count) record\(rows.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if kind == .tasks || kind == .opportunities {
                    Picker("Status", selection: $filter) { ForEach(RecordFilter.allCases) { Text($0.label).tag($0) } }.frame(width: 180)
                }
                Picker("Sort", selection: $sort) { ForEach(RecordSort.allCases) { Text($0.label).tag($0) } }.frame(width: 180)
            }.padding(.horizontal, 28).padding(.bottom, 10)
            List(rows) { row in
                HStack {
                    Button { open(row) } label: {
                        DirectoryRow(title: row.title.isEmpty ? "Untitled" : row.title, subtitle: row.detail,
                                     trailing: row.date, symbol: kind.symbol)
                    }.buttonStyle(.plain)
                    if kind == .tasks {
                        Button(row.completed ? "Reopen" : "Complete") {
                            do { try store.completeTask(row.recordID, completed: !row.completed) }
                            catch { store.notice = error.localizedDescription }
                        }.buttonStyle(.borderless)
                    }
                    Button { projectRecord = row } label: { Image(systemName: "link") }
                        .help("Project links and capture").accessibilityLabel("Project links for \(row.title)")
                        .buttonStyle(.borderless)
                }
            }
            .listStyle(.inset)
        }
        .navigationTitle(kind.title)
        .sheet(item: $projectRecord) { RecordProjectSheet(record: $0) }
        .sheet(isPresented: $showEditor) { editorSheet(existing: nil) }
        .sheet(item: $selectedContact) { ContactEditor(contact: $0).environmentObject(store) }
        .sheet(item: $selectedCompany) { CompanyEditor(company: $0).environmentObject(store) }
        .sheet(item: $selectedOpportunity) { OpportunityEditor(opportunity: $0).environmentObject(store) }
        .sheet(item: $selectedTask) { TaskEditor(task: $0).environmentObject(store) }
        .sheet(item: $selectedNote) { NoteEditor(note: $0).environmentObject(store) }
    }

    init(kind: DirectoryKind, initialFilter: RecordFilter = .all, initialSearch: String = "") {
        self.kind = kind
        _filter = State(initialValue: initialFilter)
        _search = State(initialValue: initialSearch)
    }

    private var rows: [WorkspaceRecord] { store.records(kind: kind.rawValue, search: search, filter: filter, sort: sort) }
    private func open(_ row: WorkspaceRecord) {
        switch kind {
        case .contacts: selectedContact = store.contacts.first { $0.id == row.recordID }
        case .companies: selectedCompany = store.companies.first { $0.id == row.recordID }
        case .opportunities: selectedOpportunity = store.opportunities.first { $0.id == row.recordID }
        case .tasks: selectedTask = store.tasks.first { $0.id == row.recordID }
        case .notes: selectedNote = store.notes.first { $0.id == row.recordID }
        }
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
