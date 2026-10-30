import AppKit
import SwiftUI

struct WorkspaceActivityView: View {
    @EnvironmentObject private var store: AppStore
    @State private var search = ""
    @State private var kind = "all"
    @State private var message: String?
    @State private var tab = 0
    private var events: [ActivityEvent] {
        store.activity.filter { (kind == "all" || $0.kind == kind) && (search.isEmpty || "\($0.kind) \($0.message)".localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) { Text("Activity").font(.title2.bold()); Text("Local actions and confirmed project capture receipts.").foregroundStyle(.secondary) }
                Spacer()
#if !DEBUG || !CONTEXTWARD_ACCEPTANCE
                Button("Export visible activity") { export() }
#endif
            }
            HStack {
                TextField("Search activity", text: $search).textFieldStyle(.roundedBorder)
                Picker("Kind", selection: $kind) { Text("All kinds").tag("all"); ForEach(Set(store.activity.map(\.kind)).sorted(), id: \.self) { Text($0).tag($0) } }.frame(width: 230)
            }
            if let message { Text(message).font(.caption) }
            // A segmented picker, not TabView: on macOS 26 TabView puts its tabs in the window
            // toolbar, which shifts the custom sidebar and top bar down.
            Picker("", selection: $tab) {
                Text("Activity · \(events.count)").tag(0)
                Text("Project receipts · \(store.workspace.controlWard.captures.count)").tag(1)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            if tab == 0 {
                List(events) { event in
                    VStack(alignment: .leading, spacing: 5) { Text(event.message); Text("\(event.createdAt) · \(event.kind)").font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 4)
                }
            } else {
                List(store.workspace.controlWard.captures.reversed()) { receipt in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.allWorkspaceRecords.first { $0.id == receipt.recordKey }?.title ?? "Source record removed").fontWeight(.semibold)
                        Text("Confirmed item \(receipt.itemID)").font(.callout.monospaced())
                        Text("\(receipt.register) · \(receipt.capturedAt)").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
            Text("Project decisions and the shared register's event history remain in Projects → Activity. A local receipt confirms capture, not project assignment or completion.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).navigationTitle("Activity")
    }
    private func export() {
#if DEBUG && CONTEXTWARD_ACCEPTANCE
        message = "File export is disabled in the isolated preview."
#else
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "controlward-activity.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(events).write(to: url, options: .atomic); try SecureFiles.restrict(url)
            message = "Exported \(events.count) visible events."
        } catch { message = error.localizedDescription }
#endif
    }
}

struct UnifiedModuleConnections: View {
    @EnvironmentObject private var modules: WorkspaceModules
    @EnvironmentObject private var navigation: WorkspaceNavigation
    @State private var status = "Project connection has not been checked."
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ControlWard modules").font(.headline)
            Text(status).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Check Projects") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            let snapshot = try await modules.controller(for: .projects).projectSnapshot(refresh: true)
                            status = "Connected register: \(snapshot.projects.count) projects. Last confirmed pull: \(snapshot.pulledAt ?? "unavailable")."
                        } catch { status = error.localizedDescription }
                    }
                }.disabled(busy)
                Button("Open Projects") { navigation.show(.projects) }
                Button("Open Email") { navigation.show(.email) }
                Button("Capture receipts") { navigation.show(.activity) }
            }
            Text("Email Aggregator is a hosted synthetic-mail prototype. Its sign-in is separate. GAP remains a read-only source; set its Supabase endpoint and publishable key below.").font(.caption).foregroundStyle(.secondary)
        }.crmCard()
    }
}
