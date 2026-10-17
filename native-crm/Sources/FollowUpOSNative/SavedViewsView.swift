import SwiftUI

struct SavedViewsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var navigation: WorkspaceNavigation
    @State private var showingAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Saved views").font(.title2.weight(.bold))
                    Text("Reusable local lenses across your CRM objects.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("New view", systemImage: "plus") { showingAdd = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding(28)
            List {
                ForEach(store.workspace.savedViews) { view in
                    Button {
                        navigation.directory(view.objectName.lowercased(), filter: RecordFilter(rawValue: view.filter) ?? .all, search: view.search ?? "")
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(CRMTheme.steel)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(view.name).font(.headline)
                                Text("\(view.objectName) · \(view.filter.capitalized)").font(.callout).foregroundStyle(CRMTheme.slate)
                            }
                            Spacer()
                            Text("\(store.records(kind: view.objectName.lowercased(), search: view.search ?? "", filter: RecordFilter(rawValue: view.filter) ?? .all).count) matches")
                                .font(.caption).foregroundStyle(CRMTheme.slate)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(CRMTheme.steel)
                        }.padding(.vertical, 9).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Open \(view.name)")
                    .contextMenu {
                        if !SavedView.defaults.contains(view) { Button("Delete view", role: .destructive) { store.delete(view) } }
                    }
                }
            }
            .listStyle(.inset)
        }
        .navigationTitle("Saved views")
        .sheet(isPresented: $showingAdd) { NewSavedView().environmentObject(store) }
    }
}

private struct NewSavedView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var objectName = "Contacts"
    @State private var filter = "all"
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New saved view").font(.title2.weight(.bold))
            TextField("View name", text: $name).textFieldStyle(.roundedBorder)
            Picker("Object", selection: $objectName) {
                Text("Contacts").tag("Contacts")
                Text("Companies").tag("Companies")
                Text("Opportunities").tag("Opportunities")
                Text("Tasks").tag("Tasks")
                Text("Notes").tag("Notes")
            }
            Picker("Filter", selection: $filter) {
                Text("All").tag("all")
                if objectName == "Tasks" || objectName == "Opportunities" {
                    Text("Open").tag("open")
                    Text("Completed").tag("completed")
                    Text("Overdue").tag("overdue")
                }
            }
            TextField("Search terms (optional)", text: $search).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save view") {
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    store.add(SavedView(name: name, objectName: objectName, filter: filter, search: search))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460, height: 340)
        .onChange(of: objectName) { _, _ in filter = "all" }
    }
}
