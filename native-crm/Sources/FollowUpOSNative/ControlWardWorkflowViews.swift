import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WorkspaceNavigation: ObservableObject {
    @Published var section: WorkspaceSection? = .overview
    @Published var directoryKind = ""
    @Published var directoryFilter: RecordFilter = .all
    @Published var directorySearch = ""
    @Published var requestID = UUID()
    func show(_ section: WorkspaceSection) { self.section = section }
    func directory(_ kind: String, filter: RecordFilter = .all, search: String = "") {
        guard let section = WorkspaceSection.allCases.first(where: { $0.rawValue.lowercased() == kind }) else { return }
        directoryKind = kind; directoryFilter = filter; directorySearch = search; requestID = UUID()
        self.section = section
    }
}

struct RecordProjectSheet: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var modules: WorkspaceModules
    @EnvironmentObject private var navigation: WorkspaceNavigation
    @Environment(\.dismiss) private var dismiss
    let record: WorkspaceRecord
    @State private var snapshot: ProjectModuleSnapshot?
    @State private var selected = ""
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false
    @State private var capture = false

    private var links: [RecordProjectLink] { store.workspace.controlWard.projectLinks.filter { $0.recordKey == record.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(record.title).font(.title2.bold())
            Text("Link this \(record.kind) record to a project, or capture it for review in the project inbox.").foregroundStyle(.secondary)
            ForEach(links) { link in
                HStack {
                    VStack(alignment: .leading) { Text(link.projectTitle).bold(); Text(link.register).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Open") {
                        Task {
                            do {
                                let current = try await modules.controller(for: .projects).projectSnapshot()
                                guard current.register == link.register, current.connected else { throw ControlWardError.invalid("Connect Projects to this link's register first.") }
                                try await modules.controller(for: .projects).openProject(link.projectID)
                                navigation.show(.projects); dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                    Button("Unlink") { perform { try store.unlinkProject(link.id) } }
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Refresh project list") { refresh() }.disabled(loading)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Open Projects") { navigation.show(.projects); dismiss() }
            }
            if let snapshot, snapshot.connected {
                TextField("Find a project", text: $search).textFieldStyle(.roundedBorder)
                Picker("Project", selection: $selected) {
                    Text("Choose a project").tag("")
                    ForEach(snapshot.projects.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) {
                        Text("\($0.title) · \($0.status)").tag($0.id)
                    }
                }
                Button("Save link") {
                    perform {
                        guard let project = snapshot.projects.first(where: { $0.id == selected }) else { return }
                        try store.linkProject(recordKey: record.id, register: snapshot.register, projectID: project.id, title: project.title)
                    }
                }.disabled(selected.isEmpty)
            } else { Text("Connect your register in Projects before choosing a project.").font(.callout).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Divider()
            Text("Capturing creates an inbox item. Assignments, deadlines, status and decisions remain owner actions in Projects.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Preview capture") { capture = true }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620)
        .task {
            do { snapshot = try await modules.controller(for: .projects).projectSnapshot() }
            catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $capture) { CaptureReviewSheet(recordKey: record.id, initial: capturePayload) }
    }
    private var capturePayload: ProjectCapture {
        if record.kind == "mail", let mail = store.mail.first(where: { $0.id == record.recordID }) { return mail.capture }
        if record.kind == "signals", let signal = store.signals.first(where: { $0.id == record.recordID }) {
            return ProjectCapture(source: "controlward-signal", sourceID: signal.sourceID ?? signal.id.uuidString.lowercased(), summary: signal.title,
                                  metadata: ["source": signal.source.label, "priority": String(signal.priority), "evidence": String(signal.evidence.prefix(1000))])
        }
        return ProjectCapture(source: "controlward-record", sourceID: record.id, summary: record.title, metadata: ["record_type": record.kind, "local_id": record.recordID.uuidString.lowercased()])
    }
    private func refresh() {
        loading = true; error = nil
        Task {
            defer { loading = false }
            do { snapshot = try await modules.controller(for: .projects).projectSnapshot(refresh: true); selected = "" }
            catch { self.error = error.localizedDescription }
        }
    }
    private func perform(_ operation: () throws -> Void) { do { try operation(); error = nil } catch { self.error = error.localizedDescription } }
}

struct CaptureReviewSheet: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var modules: WorkspaceModules
    @Environment(\.dismiss) private var dismiss
    let recordKey: String
    @State private var item: ProjectCapture
    @State private var enabled: Set<String>
    @State private var busy = false
    @State private var result: String?
    @State private var sent = false
    @State private var destination: String?
    init(recordKey: String, initial: ProjectCapture) {
        self.recordKey = recordKey; _item = State(initialValue: initial); _enabled = State(initialValue: Set(initial.metadata.keys))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review project intake").font(.title2.bold())
            Text("Review the destination, summary, link and metadata before sending. The source identity is retained to prevent duplicates.").foregroundStyle(.secondary)
            Text(destination.map { "Destination: \($0)" } ?? "Checking project connection…").font(.callout).textSelection(.enabled)
            Text("Source: \(item.source) · \(item.sourceID)").font(.caption).textSelection(.enabled)
            TextField("Summary", text: $item.summary).textFieldStyle(.roundedBorder)
            TextField("Source link (optional)", text: $item.link).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(item.metadata.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .top) {
                            Toggle(key, isOn: Binding(get: { enabled.contains(key) }, set: { if $0 { enabled.insert(key) } else { enabled.remove(key) } })).frame(width: 125, alignment: .leading)
                                .disabled(key == "synthetic")
                            TextField(key, text: Binding(get: { item.metadata[key] ?? "" }, set: { item.metadata[key] = $0 }), axis: .vertical)
                                .textFieldStyle(.roundedBorder).disabled(key == "synthetic")
                        }
                    }
                }
            }.frame(maxHeight: 280)
            if item.source == "email-aggregator-synthetic" { Text("Synthetic mail is restricted to a local test register.").font(.caption).foregroundStyle(.orange) }
            if let result { Text(result).font(.callout).textSelection(.enabled) }
            HStack {
                Button(sent ? "Done" : "Cancel") { dismiss() }.disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Send to project inbox") { send() }.buttonStyle(.borderedProminent)
                    .disabled(busy || sent || destination == nil || item.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 640)
        .task {
            do {
                let snapshot = try await modules.controller(for: .projects).projectSnapshot()
                guard snapshot.connected else { throw ControlWardError.invalid("Connect your register in Projects before capturing.") }
                destination = snapshot.register
            } catch { result = error.localizedDescription }
        }
    }
    private func send() {
        busy = true; result = nil
        Task {
            defer { busy = false }
            do {
                var payload = item; payload.metadata = item.metadata.filter { enabled.contains($0.key) }
                let receipt = try await modules.controller(for: .projects).capture(payload, expectedRegister: destination)
                sent = true
                do {
                    try store.recordCapture(recordKey: recordKey, register: receipt.register, itemID: receipt.id)
                    result = receipt.duplicate ? "Already captured. The existing inbox item was retained." : "Captured. Open Projects to assign and review the item."
                } catch { result = "The register confirmed the capture, but its local receipt could not be saved. The original source identity prevents duplicate delivery." }
            } catch { result = error.localizedDescription }
        }
    }
}

struct MailWorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var modules: WorkspaceModules
    @State private var tab = 0
    @State private var search = ""
    @State private var filter: RecordFilter = .all
    @State private var selected: UUID?
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) { Text("Email").font(.title2.bold()); Text("Review email, link people and create follow-ups.").foregroundStyle(.secondary) }
                Spacer()
                Button("Import metadata") { importMail() }.buttonStyle(.borderedProminent)
            }.padding(.horizontal, 22).padding(.top, 20)
            Picker("Email workspace", selection: $tab) { Text("Local review inbox").tag(0); Text("Email Aggregator").tag(1) }.pickerStyle(.segmented).padding(.horizontal, 22)
            if tab == 0 { MailIntakeStatusBar().padding(.horizontal, 22) }
            if let message { Text(message).font(.caption).padding(.horizontal, 22) }
            if tab == 1 { WorkspaceModuleView(controller: modules.controller(for: .email)) }
            else {
                HStack {
                    TextField("Search subject, sender or recipient", text: $search).textFieldStyle(.roundedBorder)
                    Picker("Status", selection: $filter) { Text("All").tag(RecordFilter.all); Text("Unreviewed").tag(RecordFilter.open); Text("Reviewed").tag(RecordFilter.completed) }
                    Text("\(store.mail.count) imported").font(.caption)
                }.padding(.horizontal, 22)
                HSplitView {
                    List(store.records(kind: "mail", search: search, filter: filter, sort: .newest), selection: $selected) { row in
                        VStack(alignment: .leading, spacing: 4) { Text(row.title).fontWeight(.semibold); Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1); Text(row.status).font(.caption2) }.tag(row.recordID)
                    }.frame(minWidth: 230, idealWidth: 300)
                    if let mail = store.mail.first(where: { $0.id == selected }) { MailReviewDetail(mail: mail).id(mail.id).frame(minWidth: 350) }
                    else { ContentUnavailableView("Choose a message", systemImage: "envelope", description: Text("Import a metadata export, or open the hosted Email Aggregator. Imported messages are not live mailbox synchronization.")) }
                }
            }
        }.navigationTitle("Email")
    }
    private func importMail() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 20_000_000 else { throw ControlWardError.invalid("Mail imports must be under 20 MB.") }
            message = "Imported \(try store.importMailMetadata(Data(contentsOf: url))) new messages. Existing records were refreshed by source identity."
        } catch { message = error.localizedDescription }
    }
}

private struct MailReviewDetail: View {
    @EnvironmentObject private var store: AppStore
    let mail: MailMetadata
    @State private var contactID: UUID?
    @State private var companyID: UUID?
    @State private var reviewed = false
    @State private var message: String?
    @State private var showCapture = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(mail.subject).font(.title2.bold())
                Label(mail.synthetic ? "Synthetic fixture" : "Imported metadata", systemImage: "info.circle").foregroundStyle(.secondary)
                Text("From: \(mail.sender)\nTo: \(mail.recipient)\nReceived: \(mail.receivedAt)").textSelection(.enabled)
                Text("Provider: \(mail.provider)").font(.caption)
                if let url = URL(string: mail.link), !mail.link.isEmpty { Link("Open source", destination: url) }
                Picker("Contact", selection: $contactID) { Text("Unlinked").tag(UUID?.none); ForEach(store.contacts) { Text($0.displayName).tag(Optional($0.id)) } }
                Picker("Company", selection: $companyID) { Text("Unlinked").tag(UUID?.none); ForEach(store.companies) { Text($0.name).tag(Optional($0.id)) } }
                Toggle("Reviewed", isOn: $reviewed)
                Button("Save review") { perform { try store.reviewMail(mail.id, reviewed: reviewed, contactID: contactID, companyID: companyID); return "Review saved." } }
                Divider()
                Button(mail.taskID == nil ? "Create review task" : "Linked task saved") {
                    perform { _ = try store.createMailTask(mail.id); return "Task saved in Tasks. This message keeps the same linked task." }
                }
                Button("Preview project capture") { showCapture = true }.buttonStyle(.borderedProminent)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear { contactID = mail.contactID; companyID = mail.companyID; reviewed = mail.reviewed }
            .sheet(isPresented: $showCapture) { CaptureReviewSheet(recordKey: "mail:\(mail.id.uuidString.lowercased())", initial: mail.capture) }
    }
    private func perform(_ action: () throws -> String) { do { message = try action() } catch { message = error.localizedDescription } }
}

struct WorkspaceRecoveryControls: View {
    @EnvironmentObject private var store: AppStore
    @State private var pending: Data?
    @State private var preview = ""
    @State private var message: String?
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backup and recovery").font(.headline)
            Text("Back up local records, imported mail metadata, project links and evidence. Project Control register exports and hosted email sessions are managed in their own sections.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Save local backup") { backup() }; Button("Review a backup to restore") { inspectBackup() } }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
        }.crmCard()
            .confirmationDialog("Restore this local workspace?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Back up current data and restore", role: .destructive) {
                    guard let pending else { return }
                    do { try store.restoreControlWardBackup(pending, confirmed: true); message = "Restored. Background pulls are stopped; current connector endpoints were retained." }
                    catch { message = error.localizedDescription }
                    self.pending = nil
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { Text(preview + "\nA rollback copy is saved first. Connector endpoints remain current; queued writes and imported sync cursors are cleared.") }
    }
    private func backup() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "controlward-backup-\(CalendarCRM.dayString()).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportControlWardBackup(to: url); message = "Owner-only backup saved." } catch { message = error.localizedDescription }
    }
    private func inspectBackup() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 20_000_000 else { throw ControlWardError.invalid("Backups must be under 20 MB.") }
            let data = try Data(contentsOf: url), backup = try AppStore.readControlWardBackup(data)
            preview = "Backup from \(backup.createdAt): \(backup.workspace.contacts.count) contacts, \(backup.workspace.tasks.count) tasks, \(backup.workspace.controlWard.mail.count) messages."
            pending = data; confirm = true
        } catch { message = error.localizedDescription }
    }
}
