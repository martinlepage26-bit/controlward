import SwiftUI

struct IntegrationCenterView: View {
    @EnvironmentObject private var store: AppStore
    @State private var twentyEndpoint = ""
    @State private var leadgenEndpoint = ""
    @State private var pharosEndpoint = ""
    @State private var gapsEndpoint = ""
    @State private var kairosEndpoint = ""
    @State private var showExchangeImporter = false
    @State private var confirmPharosPush = false
    @State private var confirmTwentyPush = false
    private var checks: [IntegrationCheck] {
        [
            IntegrationCheck(name: "Native workspace", detail: "SwiftUI app and atomic local JSON persistence", state: .ready, symbol: "checkmark.circle.fill"),
            IntegrationCheck(name: "LeadGen OS", detail: "Qualified leads arrive through the PHAROS lead inbox (Pull leads below), or by JSON event import.", state: store.activeSignals.isEmpty ? .ready : .connected, symbol: "dot.radiowaves.left.and.right"),
            connectorCheck(.kairos, name: "Kairos", purpose: "Reads lead-intent conversations into this local workspace when you choose Import. Nothing is sent back.", symbol: "bubble.left.and.bubble.right"),
            IntegrationCheck(name: "Lantern", detail: "FR/EN score imports, weighted gap and remediation", state: store.audits.isEmpty ? .ready : .connected, symbol: "checkmark.seal"),
            IntegrationCheck(name: "Twenty exchange", detail: "Versioned credential-free JSON snapshot export", state: .ready, symbol: "arrow.triangle.2.circlepath"),
            connectorCheck(.twenty, name: "Live Twenty API", purpose: "Pushes companies, people, opportunities (from leads) and tasks to Twenty on your action, after a preview. Never deletes.", symbol: "network"),
            connectorCheck(.pharos, name: "PHAROS backend", purpose: "Pushes the exchange snapshot to the PHAROS backend on your action.", symbol: "lock.shield"),
            connectorCheck(.gaps, name: "Gap analysis", purpose: "Reads market gaps from the configured Supabase project as signals. Read-only.", symbol: "scope"),
        ]
    }

    private func connectorCheck(_ target: SyncTarget, name: String, purpose: String, symbol: String) -> IntegrationCheck {
        let status = store.connectorStatus(target)
        let state: IntegrationState = switch status {
        case .needsSetup: .needsSetup
        case .notVerified: .ready
        case .active: .connected
        case .error: .error
        }
        return IntegrationCheck(name: name, detail: "\(purpose) \(status.detail)", state: state, symbol: symbol, labelOverride: status.label)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Integration Center").font(.title2.weight(.bold))
                    Text("One operating surface, with explicit boundaries for every connected system.").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)

                UnifiedModuleConnections().padding(.horizontal, 28)

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Adapter endpoints")
                    Text("Endpoints are saved as non-secret configuration. Credentials in a URL (user:pass@ or token parameters) are removed before saving. API keys live in the macOS Keychain and are set in Settings. Every external write is an explicit action.")
                        .font(.caption).foregroundStyle(.secondary)
                    endpointField("Twenty API (e.g. http://localhost:2020)", text: $twentyEndpoint, target: .twenty)
                    endpointField("LeadGen OS", text: $leadgenEndpoint, target: .leadgen)
                    endpointField("PHAROS backend (e.g. https://pharos-contextward-api.ml-c38.workers.dev)", text: $pharosEndpoint, target: .pharos)
                    endpointField("Gap analysis (Supabase project URL, e.g. https://<project>.supabase.co)", text: $gapsEndpoint, target: .gaps)
                    endpointField("Kairos API (https://kairos.govern-ai.ca)", text: $kairosEndpoint, target: .kairos)
                }
                .crmCard()
                .padding(.horizontal, 28)
                .padding(.top, 28)

                VStack(spacing: 0) {
                    ForEach(checks) { check in
                        HStack(spacing: 13) {
                            Image(systemName: check.symbol).foregroundStyle(check.state.color).frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(check.name).font(.headline)
                                Text(check.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(check.labelOverride ?? check.state.label).font(.caption.weight(.semibold)).foregroundStyle(check.state.color)
                        }
                        .padding(.vertical, 13)
                        if check.id != checks.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 16)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(CRMTheme.border) }
                .padding(.horizontal, 28)

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "PHAROS backend")
                    Text("Sends the current exchange snapshot (records, activity, sync history; never API keys) to the PHAROS backend. Unchanged data reuses the same Idempotency-Key, so the backend stores it once.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Verify") { Task { await store.verifyConnector(.pharos) } }
                            .buttonStyle(.bordered)
                        Button("Preview push") { _ = store.previewPharosPush() }
                            .buttonStyle(.bordered)
                            .disabled(isNeedsSetup(.pharos))
                        Button("Confirm and send", systemImage: "arrow.up.circle") { confirmPharosPush = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(isNeedsSetup(.pharos) || store.pharosPreviewFingerprint == nil)
                        if store.busyTargets.contains(.pharos) { ProgressView().controlSize(.small) }
                        Spacer()
                        lastJobText(.pharos)
                    }
                    .disabled(store.busyTargets.contains(.pharos))
                    if store.pharosPreviewFingerprint != nil {
                        Text("Preview ready: current exchange snapshot (\(store.exchange.leads.count) leads, \(store.exchange.contacts.count) contacts, \(store.exchange.companies.count) companies, \(store.exchange.opportunities.count) opportunities, \(store.exchange.tasks.count) tasks). Any change requires a new preview.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .crmCard()
                .padding(.horizontal, 28)
                .confirmationDialog("Send this exchange snapshot to PHAROS?", isPresented: $confirmPharosPush, titleVisibility: .visible) {
                    Button("Send snapshot", role: .destructive) {
                        Task { await store.syncToPharos(confirmedFingerprint: store.pharosPreviewFingerprint) }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This sends the previewed record and activity snapshot to the configured PHAROS backend.")
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Kairos lead inbox")
                    Text("Reads up to 200 recent Kairos conversations and imports only those classified as leads. Handles and the latest inbound message are saved in this Mac’s ControlWard workspace. Ignored conversations are skipped. Import is manual; ControlWard never sends replies or publishes content to Kairos.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Verify") { Task { await store.verifyConnector(.kairos) } }
                            .buttonStyle(.bordered)
                        Button("Import Kairos leads", systemImage: "arrow.down.circle") { Task { await store.importKairosLeads() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(isNeedsSetup(.kairos) || store.busyTargets.contains(.kairos))
                        if store.busyTargets.contains(.kairos) { ProgressView().controlSize(.small) }
                        Spacer()
                        lastJobText(.kairos)
                    }
                    .disabled(store.busyTargets.contains(.kairos))
                }
                .crmCard()
                .padding(.horizontal, 28)

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "LeadGen OS lead inbox")
                    Text("Pulls qualified leads that LeadGen OS sent to the PHAROS backend, using the PHAROS key. Leads are matched by LeadGen id, then email, then phone, so existing leads are updated instead of duplicated. Activity records counts only.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        if store.isPullingLeads {
                            Button("Stop pulling", systemImage: "stop.circle") { store.stopPulling() }
                                .buttonStyle(.bordered)
                        } else {
                            Button("Start pulling", systemImage: "play.circle") { Task { await store.startPulling() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(isNeedsSetup(.pharos) || store.busyTargets.contains(.leadgen))
                        }
                        Button("Pull now", systemImage: "arrow.down.circle") { Task { await store.pullLeads() } }
                            .buttonStyle(.bordered)
                            .disabled(isNeedsSetup(.pharos) || store.busyTargets.contains(.leadgen))
                        if store.busyTargets.contains(.leadgen) { ProgressView().controlSize(.small) }
                        Spacer()
                        lastJobText(.leadgen)
                    }
                    Text(store.isPullingLeads
                         ? "Pulling: checks now and every 5 minutes while ControlWard is open, and resumes when it reopens."
                         : "Stopped: no leads are pulled until you start again or press Pull now.")
                        .font(.caption).foregroundStyle(store.isPullingLeads ? .green : .secondary)
                }
                .crmCard()
                .padding(.horizontal, 28)

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Market gap analysis")
                    Text("Imports the active gap clusters from the gap analysis pipeline as signals titled \"Market gap\", with their score as priority. Importing again updates them by cluster id and keeps your owner, status, and next action. Nothing is written back.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Verify") { Task { await store.verifyConnector(.gaps) } }
                            .buttonStyle(.bordered)
                        Button("Import gaps", systemImage: "arrow.down.circle") { Task { await store.importGaps() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(isNeedsSetup(.gaps))
                        if store.busyTargets.contains(.gaps) { ProgressView().controlSize(.small) }
                        Spacer()
                        lastJobText(.gaps)
                    }
                    .disabled(store.busyTargets.contains(.gaps))
                }
                .crmCard()
                .padding(.horizontal, 28)

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Twenty push")
                    Text("Preview first, then push. Records are matched by a saved local-to-Twenty id map, so pushing again updates instead of duplicating. Nothing is deleted in Twenty. Requests are paced to respect rate limits.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Verify") { Task { await store.verifyConnector(.twenty) } }
                            .buttonStyle(.bordered)
                        Button("Preview push") { store.previewTwentyPush() }
                            .buttonStyle(.bordered)
                        Button("Push to Twenty", systemImage: "arrow.up.circle") { confirmTwentyPush = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.twentyPreview == nil || isNeedsSetup(.twenty))
                        if store.busyTargets.contains(.twenty) { ProgressView().controlSize(.small) }
                        Spacer()
                        lastJobText(.twenty)
                    }
                    .disabled(store.busyTargets.contains(.twenty))
                    if let preview = store.twentyPreview {
                        Text("Preview: \(preview.creates) to create, \(preview.updates) to update, \(preview.unchangedTotal) unchanged")
                            .font(.callout.weight(.semibold))
                        Text(preview.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .crmCard()
                .padding(.horizontal, 28)
                .confirmationDialog("Apply this preview to Twenty?", isPresented: $confirmTwentyPush, titleVisibility: .visible) {
                    Button("Apply to Twenty", role: .destructive) { Task { await store.pushToTwenty() } }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text(store.twentyPreview.map { "Create \($0.creates), update \($0.updates), unchanged \($0.unchangedTotal). No records will be deleted." } ?? "Preview the push first.")
                }

                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel(text: "Sync contract")
                    Text("ControlWard exports a reviewable exchange snapshot before any external adapter is allowed to write. The native app never stores provider secrets in workspace data and does not silently publish or synchronize records.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .crmCard()
                .padding(.horizontal, 28)

                HStack {
                    Text("Portable workspace").font(.headline)
                    Spacer()
                    Button("Merge exchange JSON", systemImage: "square.and.arrow.down") { showExchangeImporter = true }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 28)

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Reviewable sync queue")
                    Text("Queue a snapshot intent now; an authenticated adapter can execute it only after endpoint and credential setup.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        ForEach(SyncTarget.exchangeTargets) { target in
                            Button("Queue \(target.label)") { store.queueSync(to: target) }
                                .buttonStyle(.bordered)
                        }
                        Button("Stage outbox") { _ = store.stageSyncOutbox() }
                            .buttonStyle(.borderedProminent)
                        Button("Discard staged", role: .destructive) { _ = store.discardStagedPackages() }
                            .buttonStyle(.bordered)
                            .disabled(!store.syncJobs.contains { $0.status == "staged" })
                            .help("Deletes staged outbox packages from disk.")
                        Spacer()
                        Text("\(store.syncJobs.filter { $0.status == "queued" }.count) queued · \(store.syncJobs.filter { $0.status == "staged" }.count) staged")
                            .font(.caption.weight(.semibold)).foregroundStyle(CRMTheme.steel)
                    }
                }
                .crmCard()
                .padding(.horizontal, 28)
            }
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle("Integrations")
        .fileImporter(isPresented: $showExchangeImporter, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                do { _ = try store.importExchange(from: url) }
                catch { store.notice = "Could not merge \(url.lastPathComponent): \(error.localizedDescription)" }
            }
        }
        .onAppear {
            twentyEndpoint = store.endpoint(for: .twenty)
            leadgenEndpoint = store.endpoint(for: .leadgen)
            pharosEndpoint = store.endpoint(for: .pharos)
            gapsEndpoint = store.endpoint(for: .gaps)
            kairosEndpoint = store.endpoint(for: .kairos)
        }
    }

    @ViewBuilder private func endpointField(_ label: String, text: Binding<String>, target: SyncTarget) -> some View {
        HStack {
            TextField(label, text: text).textFieldStyle(.roundedBorder)
            Button("Save") {
                store.setEndpoint(text.wrappedValue, for: target)
                text.wrappedValue = store.endpoint(for: target)
            }.buttonStyle(.bordered)
            Button(SyncTarget.keyed.contains(target) ? "Verify" : "Test") { Task { await store.verifyConnector(target) } }.buttonStyle(.bordered)
        }
    }

    private func isNeedsSetup(_ target: SyncTarget) -> Bool {
        if case .needsSetup = store.connectorStatus(target) { return true }
        return false
    }

    @ViewBuilder private func lastJobText(_ target: SyncTarget) -> some View {
        if let job = store.syncJobs.first(where: { $0.target == target && $0.status != "queued" && $0.status != "staged" }) {
            Text(job.status == "failed" ? "Last: failed. \(job.error ?? "")" : "Last: \(job.status). \(job.detail ?? "")")
                .font(.caption).foregroundStyle(job.status == "failed" ? CRMTheme.rust : .secondary)
                .lineLimit(2)
                .frame(maxWidth: 360, alignment: .trailing)
        }
    }
}

private struct IntegrationCheck: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let state: IntegrationState
    let symbol: String
    var labelOverride: String? = nil
}

private enum IntegrationState {
    case ready, connected, needsSetup, notConnected, error
    var label: String {
        switch self { case .ready: "Ready"; case .connected: "Active"; case .needsSetup: "Needs setup"; case .notConnected: "Not connected"; case .error: "Error" }
    }
    var color: Color {
        switch self { case .ready: CRMTheme.steel; case .connected: .green; case .needsSetup: CRMTheme.amberDark; case .notConnected: .secondary; case .error: CRMTheme.rust }
    }
}
