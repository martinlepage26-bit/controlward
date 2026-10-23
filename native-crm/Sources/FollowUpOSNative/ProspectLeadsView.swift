import SwiftUI

/// ControlWard's own Leads list (Slice 3). Leads stay here: they never go to Project Control, and nothing is sent.
/// A search runs only when the button is pressed, through GuardedLeadTransport, and every step is a CW-AUDIT line
/// in the leads folder's cw-audit.log.
struct ProspectLeadsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var environment: LeadPipelineEnvironment?
    @State private var loadError: String?
    @State private var segmentID = "clinic"
    @State private var latitude = "45.5017"
    @State private var longitude = "-73.5673"
    @State private var radius = 3_000
    @State private var limit = 5
    @State private var running = false
    @State private var records: [ProspectRecord] = []
    @State private var drafts: [OutreachDraft] = []
    @State private var summary: String?
    @State private var launchCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Leads").font(.title2.weight(.bold))
                    Text("Own-site evidence only. Drafts stay local; ControlWard sends nothing from here.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(CRMTheme.rust)
            } else if let environment {
                controls(environment)
                if let summary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                if let launchCount { Text("Leads store at launch: \(launchCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                list(environment)
                Text("Audit log: \(environment.auditURL.path)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                ProgressView()
            }
        }
        .padding(22)
        .frame(minWidth: 860, minHeight: 620)
        .task { load() }
    }

    private func controls(_ environment: LeadPipelineEnvironment) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            Picker("Segment", selection: $segmentID) {
                ForEach(environment.config.segments, id: \.id) { Text($0.label).tag($0.id) }
            }.frame(width: 260)
            TextField("Latitude", text: $latitude).frame(width: 90)
            TextField("Longitude", text: $longitude).frame(width: 100)
            Picker("Radius", selection: $radius) {
                Text("1 km").tag(1_000); Text("3 km").tag(3_000); Text("5 km").tag(5_000); Text("10 km").tag(10_000)
            }.frame(width: 110)
            Stepper("Sites \(limit)", value: $limit, in: 1...10).frame(width: 110)
            Button {
                Task { await search(environment) }
            } label: {
                Label(running ? "Searching" : "Search", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(running)
        }
        .pickerStyle(.menu)
    }

    private func list(_ environment: LeadPipelineEnvironment) -> some View {
        let listed = ProspectIngest.listed(records)
        let held = ProspectIngest.heldForMartin(records)
        return List {
            Section("Leads (\(listed.count))") {
                ForEach(listed) { record in row(record, environment: environment) }
            }
            if !held.isEmpty {
                Section("Held for Martin: conflict area (\(held.count))") {
                    ForEach(held) { record in row(record, environment: environment) }
                }
            }
            if !drafts.isEmpty {
                Section("Local drafts (not sent) (\(drafts.count))") {
                    ForEach(drafts) { draft in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(draft.subject).font(.headline)
                            Text(draft.body).font(.caption).textSelection(.enabled)
                            if let unsubscribe = draft.listUnsubscribe { Text("List-Unsubscribe: \(unsubscribe)").font(.caption2).foregroundStyle(.secondary) }
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func row(_ record: ProspectRecord, environment: LeadPipelineEnvironment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(ProspectDisplay.lines(for: record, config: environment.config).enumerated()), id: \.offset) { index, line in
                Text(line).font(index == 0 ? .headline : .caption).textSelection(.enabled)
            }
        }.padding(.vertical, 4)
    }

    private func load() {
        guard environment == nil, loadError == nil else { return }
        guard let directory = ICPConfig.defaultDirectory(bundle: AppResources.bundle) else {
            loadError = "The lead pipeline config (icp.json) is missing from the app bundle."
            return
        }
        do {
            let loaded = try LeadPipelineEnvironment.load(configDirectory: directory)
            launchCount = loaded.recordLaunch(audit: loaded.audit)
            environment = loaded
            reload(loaded)
        } catch {
            loadError = "Lead pipeline refused to start: \(error)"
        }
    }

    private func reload(_ environment: LeadPipelineEnvironment) {
        let inputs = environment.proofInputs()
        records = inputs.prospects
        drafts = inputs.drafts
    }

    private func search(_ environment: LeadPipelineEnvironment) async {
        guard let lat = Double(latitude), let lon = Double(longitude) else { summary = "Enter numeric coordinates."; return }
        running = true
        defer { running = false }
        let request = ProspectSearchRun.Request(segmentID: segmentID, latitude: lat, longitude: lon, radiusMeters: radius, limit: limit)
        let reports = await environment.searchAndIngest([request], audit: environment.audit)
        let found = reports.reduce(0) { $0 + $1.candidates }
        let kept = reports.reduce(0) { $0 + $1.prospects.count }
        let refused = reports.reduce(0) { $0 + $1.refusals.count }
        summary = "Run \(reports.first?.runID ?? "-"): \(found) candidates, \(kept) records, \(refused) refusals. Nothing sent."
        reload(environment)
    }
}
