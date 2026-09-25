import SwiftUI

struct SavedViewsView: View {
    @EnvironmentObject private var store: AppStore
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
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(CRMTheme.steel)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(view.name).font(.headline)
                            Text("\(view.objectName) · filter: \(view.filter)")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !SavedView.defaults.contains(view) {
                            Button(role: .destructive) { store.delete(view) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 5)
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
                Text("Open").tag("open")
                Text("Completed").tag("completed")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save view") {
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    store.add(SavedView(name: name, objectName: objectName, filter: filter))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 430, height: 280)
    }
}
