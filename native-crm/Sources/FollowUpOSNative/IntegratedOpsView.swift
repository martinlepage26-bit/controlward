import SwiftUI
import UniformTypeIdentifiers

struct IntegratedOpsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var tab = 0
    @State private var showSignal = false
    @State private var showAudit = false
    @State private var showImporter = false
    @State private var showBAEAImporter = false
    @State private var showBAEAWorkbookImporter = false
    @State private var showExporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Operations").font(.title2.weight(.bold))
                    Text("Signals, routing, follow-up continuity, and bilingual evidence.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Capture signal", systemImage: "dot.radiowaves.left.and.right") { showSignal = true }
                    .buttonStyle(.borderedProminent)
                Button("Import LeadGen", systemImage: "arrow.down.doc") { showImporter = true }
                    .buttonStyle(.bordered)
                Button("New Lantern audit", systemImage: "checkmark.seal") { showAudit = true }
                    .buttonStyle(.bordered)
                Button("Import Lantern CSV", systemImage: "tablecells") { showBAEAImporter = true }
                    .buttonStyle(.bordered)
                Button("Import Lantern workbook", systemImage: "tablecells.fill") { showBAEAWorkbookImporter = true }
                    .buttonStyle(.bordered)
                Button("Export exchange", systemImage: "square.and.arrow.up") { showExporter = true }
                    .buttonStyle(.bordered)
            }
            .padding(28)

            Picker("Operations", selection: $tab) {
                Text("Signal routing").tag(0)
                        Text("Lantern audits").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 28)
            .padding(.bottom, 16)

            if tab == 0 { SignalQueueView() } else { AuditQueueView() }
        }
        .sheet(isPresented: $showSignal) { SignalEditor(signal: nil).environmentObject(store) }
        .sheet(isPresented: $showAudit) { BilingualAuditEditor(audit: nil).environmentObject(store) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                do { _ = try store.importLeadGenJSON(from: url) }
                catch { store.notice = "Could not import \(url.lastPathComponent): \(error.localizedDescription)" }
            }
        }
        .fileImporter(isPresented: $showBAEAImporter, allowedContentTypes: [.commaSeparatedText], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                do { _ = try store.importBAEACSV(from: url) }
                catch { store.notice = "Could not import \(url.lastPathComponent): \(error.localizedDescription)" }
            }
        }
        .fileImporter(isPresented: $showBAEAWorkbookImporter, allowedContentTypes: [.spreadsheet], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                do { _ = try store.importBAEAXLSX(from: url) }
                catch { store.notice = "Could not import \(url.lastPathComponent): \(error.localizedDescription)" }
            }
        }
        .fileExporter(isPresented: $showExporter, document: ExchangeDocument(exchange: store.exchange), contentType: .json, defaultFilename: "contextward-exchange.json") { result in
            guard case .success(let url) = result else { return }
            do { try store.exportExchange(to: url) }
            catch { store.notice = "Could not export exchange: \(error.localizedDescription)" }
        }
        .navigationTitle("Operations")
    }
}

struct ExchangeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var exchange: WorkspaceExchange
    init(exchange: WorkspaceExchange) { self.exchange = exchange }
    init(configuration: ReadConfiguration) throws {
        exchange = try JSONDecoder().decode(WorkspaceExchange.self, from: configuration.file.regularFileContents ?? Data())
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(exchange))
    }
}

private struct SignalQueueView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selected: Signal?

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    OpsMetric(value: "\(store.activeSignals.count)", label: "active", symbol: "dot.radiowaves.left.and.right")
                    OpsMetric(value: "\(store.qualifiedSignals.count)", label: "qualified / routed", symbol: "arrow.triangle.branch")
                    OpsMetric(value: "\(store.openTasks.count)", label: "open actions", symbol: "checklist")
                }
                .listRowBackground(Color.clear)
                HStack {
                    Label("Local automation", systemImage: "bolt.shield")
                        .font(.headline)
                    Spacer()
                    Text("Deterministic and offline").font(.caption).foregroundStyle(.secondary)
                    Button("Run now") { _ = store.runAutomations() }
                        .buttonStyle(.borderedProminent)
                    Button("Schedule reminders") {
                        Task { _ = await store.scheduleDueFollowUpReminders() }
                    }
                    .buttonStyle(.bordered)
                }
                .listRowBackground(Color.clear)
            }
            Section("Priority queue") {
                if store.signals.isEmpty {
                    ContentUnavailableView("No signals yet", systemImage: "dot.radiowaves.left.and.right", description: Text("Capture a lead, referral, event, or audit finding to start the routing loop."))
                }
                ForEach(store.signals) { signal in
                    Button { selected = signal } label: {
                        HStack(spacing: 12) {
                            Image(systemName: signal.status == .routed ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(signal.status == .routed ? .green : CRMTheme.amberDark)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(signal.title.isEmpty ? "Untitled signal" : signal.title).font(.headline)
                                Text("\(signal.source.label) · \(signal.status.label) · priority \(signal.priority)").font(.caption).foregroundStyle(.secondary)
                                if signal.sourceActive == false { Text("Retired upstream · kept for audit").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                                if !signal.nextAction.isEmpty { Text(signal.nextAction).font(.caption).foregroundStyle(CRMTheme.steel) }
                            }
                            Spacer()
                            Text("fit \(signal.fitScore) · intent \(signal.intentScore)").font(.caption.monospacedDigit())
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Recent automation activity") {
                ForEach(store.activity.prefix(5)) { event in
                    Label(event.message, systemImage: "bolt.circle")
                        .font(.callout)
                }
            }
        }
        .listStyle(.inset)
        .sheet(item: $selected) { SignalEditor(signal: $0).environmentObject(store) }
    }
}

private struct AuditQueueView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selected: BilingualAudit?

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    OpsMetric(value: "\(store.audits.count)", label: "audits", symbol: "checkmark.seal")
                    OpsMetric(value: store.averageLanguageGap.formatted(.number.precision(.fractionLength(1))), label: "avg FR/EN gap", symbol: "arrow.left.and.right")
                    OpsMetric(value: "\(store.audits.filter { $0.priority == "Critical" || $0.priority == "High" }.count)", label: "high priority", symbol: "exclamationmark.triangle")
                }
                .listRowBackground(Color.clear)
            }
            Section("Evidence register") {
                if store.audits.isEmpty {
                    ContentUnavailableView("No Lantern audits yet", systemImage: "checkmark.seal", description: Text("Record separate French and English scores to make language gaps visible."))
                }
                ForEach(store.audits) { audit in
                    Button { selected = audit } label: {
                        HStack {
                            Image(systemName: "checkmark.seal").foregroundStyle(CRMTheme.steel)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(audit.name.isEmpty ? "Untitled audit" : audit.name).font(.headline)
                                Text("\(audit.client.isEmpty ? "No client" : audit.client) · \(audit.methodologyVersion) · \(audit.transcripts.count) transcript evidence").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("gap \(audit.languageGap.formatted(.number.precision(.fractionLength(1))))").font(.callout.weight(.semibold))
                                Text(audit.priority).font(.caption).foregroundStyle(audit.priority == "Critical" || audit.priority == "High" ? CRMTheme.rust : .secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.inset)
        .sheet(item: $selected) { BilingualAuditEditor(audit: $0).environmentObject(store) }
    }
}

private struct OpsMetric: View {
    let value: String; let label: String; let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(CRMTheme.steel)
            Text(value).font(.title3.weight(.bold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(CRMTheme.paper, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SignalEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Signal
    private let existing: Bool
    init(signal: Signal?) { _draft = State(initialValue: signal ?? Signal()); existing = signal != nil }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Button("Cancel") { dismiss() }; Spacer(); Text(existing ? "Edit signal" : "Capture signal").font(.headline); Spacer(); Button("Save") { save() }.buttonStyle(.borderedProminent) }.padding(16).background(CRMTheme.ink).foregroundStyle(.white)
            Form {
                Section("Signal") {
                    TextField("Title", text: $draft.title)
                    Picker("Source", selection: $draft.source) { ForEach(SignalSource.allCases) { Text($0.label).tag($0) } }
                    Picker("Status", selection: $draft.status) { ForEach(SignalStatus.allCases) { Text($0.label).tag($0) } }
                    Stepper("Fit score: \(draft.fitScore)", value: $draft.fitScore, in: 0...100)
                    Stepper("Intent score: \(draft.intentScore)", value: $draft.intentScore, in: 0...100)
                    Stepper("Priority: \(draft.priority)", value: $draft.priority, in: 0...100)
                }
                Section("Routing context") { TextField("Owner", text: $draft.owner); TextField("Next action", text: $draft.nextAction); TextEditor(text: $draft.evidence).frame(minHeight: 90) }
            }.formStyle(.grouped)
        }.frame(width: 560, height: 520)
    }
    private func save() { guard !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }; existing ? store.update(draft) : store.add(draft); dismiss() }
}

struct BilingualAuditEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BilingualAudit
    private let existing: Bool
    init(audit: BilingualAudit?) { _draft = State(initialValue: audit ?? BilingualAudit()); existing = audit != nil }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Button("Cancel") { dismiss() }; Spacer(); Text(existing ? "Edit Lantern audit" : "New Lantern audit").font(.headline); Spacer(); Button("Save") { save() }.buttonStyle(.borderedProminent) }.padding(16).background(CRMTheme.ink).foregroundStyle(.white)
            Form {
                Section("Audit identity") {
                    TextField("Audit name", text: $draft.name)
                    TextField("Client", text: $draft.client)
                    TextField("Methodology version", text: $draft.methodologyVersion)
                    Picker("Lead", selection: leadBinding) { Text("Unlinked").tag(UUID?.none); ForEach(store.leads) { Text($0.name).tag(Optional($0.id)) } }
                    Picker("Contact", selection: contactBinding) { Text("Unlinked").tag(UUID?.none); ForEach(store.contacts) { Text($0.displayName).tag(Optional($0.id)) } }
                    Picker("Company", selection: companyBinding) { Text("Unlinked").tag(UUID?.none); ForEach(store.companies) { Text($0.name).tag(Optional($0.id)) } }
                    Stepper("French sample: \(draft.sampleSizeFR)", value: $draft.sampleSizeFR, in: 0...500)
                    Stepper("English sample: \(draft.sampleSizeEN)", value: $draft.sampleSizeEN, in: 0...500)
                }
                ScoreSection(title: "French", score: $draft.french)
                ScoreSection(title: "English", score: $draft.english)
                Section("Findings and remediation") { TextEditor(text: $draft.findings).frame(minHeight: 70).overlay(alignment: .topLeading) { if draft.findings.isEmpty { Text("Findings / quoted evidence").foregroundStyle(.secondary).padding(8) } }; TextEditor(text: $draft.remediation).frame(minHeight: 70).overlay(alignment: .topLeading) { if draft.remediation.isEmpty { Text("Remediation priority").foregroundStyle(.secondary).padding(8) } } }
            }.formStyle(.grouped)
        }.frame(width: 600, height: 680)
    }
    private var leadBinding: Binding<UUID?> { Binding(get: { draft.leadID }, set: { draft.leadID = $0 }) }
    private var contactBinding: Binding<UUID?> { Binding(get: { draft.contactID }, set: { draft.contactID = $0 }) }
    private var companyBinding: Binding<UUID?> { Binding(get: { draft.companyID }, set: { draft.companyID = $0 }) }
    private func save() { guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }; existing ? store.update(draft) : store.add(draft); dismiss() }
}

private struct ScoreSection: View {
    let title: String
    @Binding var score: AuditDimensionScore
    var body: some View {
        Section("\(title) scores (0–100)") {
            Stepper("Disclosure: \(score.disclosure)", value: $score.disclosure, in: 0...100)
            Stepper("Escalation: \(score.escalation)", value: $score.escalation, in: 0...100)
            Stepper("Context transfer: \(score.contextTransfer)", value: $score.contextTransfer, in: 0...100)
            Stepper("Tone / register: \(score.tone)", value: $score.tone, in: 0...100)
            Stepper("Hallucinations: \(score.hallucinations)", value: $score.hallucinations, in: 0...100)
        }
    }
}
