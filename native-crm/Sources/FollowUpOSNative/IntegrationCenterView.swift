import SwiftUI

struct IntegrationCenterView: View {
    @EnvironmentObject private var store: AppStore
    @State private var twentyEndpoint = ""
    @State private var leadgenEndpoint = ""
    @State private var pharosEndpoint = ""
    @State private var showExchangeImporter = false
    private var checks: [IntegrationCheck] {
        [
            IntegrationCheck(name: "Native workspace", detail: "SwiftUI app and atomic local JSON persistence", state: .ready, symbol: "checkmark.circle.fill"),
            IntegrationCheck(name: "LeadGen OS", detail: "JSON event import, scoring fields, routing and automation", state: store.signals.isEmpty ? .ready : .connected, symbol: "dot.radiowaves.left.and.right"),
            IntegrationCheck(name: "Lantern", detail: "FR/EN score imports, weighted gap and remediation", state: store.audits.isEmpty ? .ready : .connected, symbol: "checkmark.seal"),
            IntegrationCheck(name: "Twenty exchange", detail: "Versioned credential-free JSON snapshot export", state: .ready, symbol: "arrow.triangle.2.circlepath"),
            IntegrationCheck(name: "Live Twenty API", detail: "Endpoint profile saved; credentials still required for writes", state: store.endpoint(for: .twenty).isEmpty ? .needsSetup : .connected, symbol: "network"),
            IntegrationCheck(name: "External Pharos scans", detail: "Endpoint profile saved; no scan is invoked automatically", state: store.endpoint(for: .pharos).isEmpty ? .notConnected : .connected, symbol: "lock.shield"),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Integration Center").font(.title2.weight(.bold))
                    Text("One operating surface, with explicit boundaries for every connected system.").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Adapter endpoints")
                    Text("Endpoints are saved as non-secret configuration. Credentials in a URL (user:pass@ or token parameters) are removed before saving. Authentication and external writes remain explicit adapter operations.")
                        .font(.caption).foregroundStyle(.secondary)
                    endpointField("Twenty API", text: $twentyEndpoint, target: .twenty)
                    endpointField("LeadGen OS", text: $leadgenEndpoint, target: .leadgen)
                    endpointField("Pharos scans", text: $pharosEndpoint, target: .pharos)
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
                            Text(check.state.label).font(.caption.weight(.semibold)).foregroundStyle(check.state.color)
                        }
                        .padding(.vertical, 13)
                        if check.id != checks.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 16)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(CRMTheme.border) }
                .padding(.horizontal, 28)

                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel(text: "Sync contract")
                    Text("Contextward exports a reviewable exchange snapshot before any external adapter is allowed to write. The native app never stores provider secrets in workspace data and does not silently publish or synchronize records.")
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
                        ForEach(SyncTarget.allCases) { target in
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
        }
    }

    @ViewBuilder private func endpointField(_ label: String, text: Binding<String>, target: SyncTarget) -> some View {
        HStack {
            TextField(label, text: text).textFieldStyle(.roundedBorder)
            Button("Save") {
                store.setEndpoint(text.wrappedValue, for: target)
                text.wrappedValue = store.endpoint(for: target)
            }.buttonStyle(.bordered)
            Button("Test") { Task { await store.probeEndpoint(target) } }.buttonStyle(.bordered)
        }
    }
}

private struct IntegrationCheck: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let state: IntegrationState
    let symbol: String
}

private enum IntegrationState {
    case ready, connected, needsSetup, notConnected
    var label: String {
        switch self { case .ready: "Ready"; case .connected: "Active"; case .needsSetup: "Needs setup"; case .notConnected: "Not connected" }
    }
    var color: Color {
        switch self { case .ready: CRMTheme.steel; case .connected: .green; case .needsSetup: CRMTheme.amberDark; case .notConnected: .secondary }
    }
}
