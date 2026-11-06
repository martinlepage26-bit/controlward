import SwiftUI

struct DiscoveryView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var agentResearch: AgentResearchCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var location: DiscoveryLocation = .montreal
    @State private var category: DiscoveryCategory = .marketing
    @State private var latitude = "45.5017"
    @State private var longitude = "-73.5673"
    @State private var radius = 2_000
    @State private var results: [DiscoveryCandidate] = []
    @State private var searching = false
    @State private var error: String?
    @State private var lastSearchAt: Date?
    @State private var cooldownActive = false
    @State private var addedIDs = Set<String>()
    @State private var researchEnabled = true
    @State private var siteLimit = 3
    @State private var researchResults: [String: QuickScanResearchResult] = [:]
    @State private var researchConfig: ICPConfig?
    @State private var progress: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var deadlineTask: Task<Void, Never>?
    @State private var websiteQueue = ""
    @State private var cached = WebsiteResearchCache()
    @State private var cacheWritable = true
    private var cacheURL: URL { LeadPipelineEnvironment.defaultRoot().appendingPathComponent("quick-scan-research.json") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Find Quick Scan prospects").font(.title2.weight(.bold))
                    Text("ControlWard researches public contact details and AI-use evidence. You review the findings and draft.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            SaveFailureNotice()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent research").font(.headline)
                    Text(agentResearch.summary).font(.caption).foregroundStyle(.secondary)
                    Text("Ask your connected agent for a target market. It finds websites; ControlWard verifies the evidence and puts eligible drafts in Pipeline.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if agentResearch.running { Button("Cancel agent research") { agentResearch.cancel() } }
                Button("Refresh findings") { reloadFindings() }
            }
            HStack(alignment: .bottom, spacing: 12) {
                Picker("Category", selection: $category) {
                    ForEach(DiscoveryCategory.allCases) { Text($0.label).tag($0) }
                }.frame(width: 220)
                Picker("Area", selection: $location) {
                    ForEach(DiscoveryLocation.allCases) { Text($0.label).tag($0) }
                }.frame(width: 180)
                if location == .custom {
                    TextField("Latitude", text: $latitude).frame(width: 100)
                    TextField("Longitude", text: $longitude).frame(width: 110)
                }
                Picker("Radius", selection: $radius) {
                    Text("500 m").tag(500)
                    Text("1 km").tag(1_000)
                    Text("2 km").tag(2_000)
                    Text("5 km").tag(5_000)
                    Text("10 km").tag(10_000)
                }.frame(width: 100)
                Button {
                    startSearch()
                } label: {
                    Label(searching ? "Researching" : "Find and research", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(searching || cooldownActive)
            }
            .pickerStyle(.menu)
            .disabled(searching)

            HStack {
                Toggle("Research contact details and AI use", isOn: $researchEnabled).disabled(searching)
                Stepper("Websites: \(siteLimit)", value: $siteLimit, in: 1...5).frame(width: 150).disabled(searching)
                if searching { Button("Cancel research") { searchTask?.cancel(); deadlineTask?.cancel() } }
            }
            if let progress { Text(progress).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Research websites from a search or agent") {
                Text("One per line, up to 10: Business name | https://business.example. ControlWard checks contacts and AI use; input claims are not treated as verified evidence.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $websiteQueue).font(.body.monospaced()).frame(height: 65).disabled(searching)
                    .accessibilityLabel("Website research queue")
                Button("Research queued websites") { startSearch(queued: true) }
                    .disabled(searching || cooldownActive || websiteQueue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("Priority formula: category and area 50 + website 20 + phone 15 + email 15. This measures public-data completeness; it does not estimate buying intent. Results are capped at 50. Each search is user-started, with a 15-second cooldown.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(CRMTheme.rust) }
            if lastSearchAt != nil && !searching && error == nil && results.isEmpty {
                Text("No named businesses found in this area. Try a wider radius or another category.")
                    .foregroundStyle(.secondary)
            }

            List(results) { candidate in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "building.2.crop.circle").foregroundStyle(CRMTheme.steel).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.name).font(.headline)
                        Text([candidate.category, candidate.address].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Research priority \(candidate.researchPriority)/100 · category/area \(candidate.categoryLocationPoints), website \(candidate.websitePoints), phone \(candidate.phonePoints), email \(candidate.emailPoints) · intent unknown")
                            .font(.caption.monospacedDigit()).foregroundStyle(CRMTheme.steel)
                        if let website = candidate.website { Text(website).font(.caption).lineLimit(1) }
                        Text("\(candidate.sourceID.hasPrefix("website:") ? "Website research input" : "Evidence from OpenStreetMap") · \(candidate.sourceURL)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        if let research = researchResults[candidate.sourceID] {
                            Text(research.hasAIUseEvidence ? "AI-use statement found on the business website" : "AI use not established on checked pages")
                                .font(.caption.weight(.semibold))
                            Text(research.email.map { "Website-published email: \($0)" } ?? "No website-published email found")
                                .font(.caption)
                            DisclosureGroup("Sources, contact checks and qualification") {
                                ForEach(Array(research.lines.enumerated()), id: \.offset) { _, line in
                                    Text(line).font(.caption).textSelection(.enabled)
                                }
                            }
                        } else if researchEnabled {
                            Text(candidate.website == nil ? "No website on this listing to research." : "Website not checked in this batch.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if addedIDs.contains(candidate.sourceID) {
                        Label("In pipeline", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(CRMTheme.moss)
                    } else {
                        Button(store.leads.contains(where: { $0.sourceID == candidate.sourceID }) ? "Save research" : "Add researched lead") {
                            if store.acceptDiscovery(candidate, research: researchResults[candidate.sourceID], researchConfig: researchConfig) != nil { addedIDs.insert(candidate.sourceID) }
                        }
                            .buttonStyle(.bordered)
                            .disabled(searching || (researchEnabled && researchResults[candidate.sourceID] == nil))
                    }
                }.padding(.vertical, 4)
            }
            .listStyle(.inset)
            HStack { Spacer(); Text("© OpenStreetMap contributors · Open database license").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(22)
        .frame(minWidth: 900, minHeight: 620)
        .onDisappear { searchTask?.cancel(); deadlineTask?.cancel() }
        .task {
            do {
                cached = try WebsiteResearchCache.load(cacheURL)
                results = cached.candidates
                researchResults = cached.results
                if let directory = ICPConfig.defaultDirectory(bundle: AppResources.bundle) {
                    researchConfig = try ICPConfig.load(directory: directory).interactiveSearch()
                }
                if !results.isEmpty { progress = "Saved website research. Sources and unknowns are retained; nothing sent." }
            } catch {
                cacheWritable = false
                self.error = "Saved research could not be read. It will not be overwritten. New findings stay in this window until saved as leads."
            }
        }
        .onChange(of: agentResearch.recent) { _, _ in reloadFindings() }
        .onChange(of: location) { _, selected in
            let point = selected.coordinates
            if selected != .custom { latitude = String(point.0); longitude = String(point.1) }
        }
        .task(id: lastSearchAt) {
            guard let lastSearchAt else { return }
            let remaining = max(0, 15 - Date.now.timeIntervalSince(lastSearchAt))
            do { try await Task.sleep(for: .seconds(remaining)) }
            catch { return }
            cooldownActive = false
        }
    }

    @MainActor
    private func reloadFindings() {
        guard !searching else { return }
        do {
            cached = try WebsiteResearchCache.load(cacheURL)
            results = cached.candidates
            researchResults = cached.results
        } catch { self.error = "Saved findings could not be read; existing data was retained." }
    }

    @MainActor
    private func startSearch(queued: Bool = false) {
        guard !searching else { return }
        let task = Task { await search(queued: queued); deadlineTask?.cancel(); searchTask = nil }
        searchTask = task
        deadlineTask = Task {
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            task.cancel()
        }
    }

    @MainActor
    private func search(queued: Bool) async {
        guard !cooldownActive else { error = "Please wait 15 seconds between research runs."; return }
        guard let lat = Double(latitude), let lon = Double(longitude), (-90...90).contains(lat), (-180...180).contains(lon) else {
            error = "Enter latitude from −90 to 90 and longitude from −180 to 180."
            return
        }
        searching = true
        error = nil
        lastSearchAt = .now
        cooldownActive = true
        results = []
        if !queued { researchResults = [:] }
        addedIDs = []
        progress = "Finding businesses. Website research has a three-minute limit; completed results are kept."
        defer { searching = false; if Task.isCancelled { progress = "Research stopped. Completed findings are available below." } }
        do {
            if queued { results = try WebsiteResearchQueue.parse(websiteQueue) }
            else { results = try await DiscoveryClient().search(category: category.selector, latitude: lat, longitude: lon, radiusMeters: radius, limit: 50) }
            guard queued || researchEnabled, !Task.isCancelled else { return }
            guard let directory = ICPConfig.defaultDirectory(bundle: AppResources.bundle) else { error = "Website research configuration is missing."; return }
            let config = try ICPConfig.load(directory: directory).interactiveSearch()
            researchConfig = config
            let audit = FileAuditSink(url: LeadPipelineEnvironment.defaultRoot().appendingPathComponent("cw-audit.log"))
            let guarded = GuardedLeadTransport(config: config, inner: InteractiveLeadTransport(inner: URLSessionLeadTransport()), audit: audit)
            let researcher = QuickScanResearcher(config: config, transport: guarded, clock: SystemLeadClock())
            if queued { researchResults = researchResults.filter { key, _ in results.contains { $0.sourceID == key } } }
            let pending = results.filter { $0.website != nil && (!queued || researchResults[$0.sourceID]?.complete != true) }
            let selected = Array((pending.isEmpty ? results.filter { $0.website != nil } : pending).prefix(siteLimit))
            let trades: Set<DiscoveryCategory> = [.contractor, .plumber, .electrician, .landscaping]
            let matching = config.segments.first { $0.osmSelectors.contains(category.selector) }
                ?? (trades.contains(category) ? config.segments.first { config.rbqLicenceHold?.segments.contains($0.id) == true } : nil)
                ?? config.segments.first { $0.osmSelectors.contains("office=company") }
            guard let matching else { error = "No configured research segment matches this category."; return }
            for (index, candidate) in selected.enumerated() {
                guard !Task.isCancelled else { break }
                progress = "Researching \(index + 1)/\(selected.count): \(candidate.name). Checking the business website for contact and AI-use evidence."
                let source = LeadCandidate(osmID: candidate.sourceID, name: candidate.name, website: candidate.website,
                                           tags: [category.selector], city: candidate.address.isEmpty ? nil : candidate.address,
                                           latitude: candidate.latitude, longitude: candidate.longitude, discoveredVia: candidate.sourceURL)
                let result = await researcher.research(source, segmentID: matching.id)
                researchResults[candidate.sourceID] = result
                if cacheWritable {
                    do {
                        cached = try WebsiteResearchCache.load(cacheURL)
                        cached.merge(candidate, result: result)
                        try cached.save(cacheURL)
                    }
                    catch { self.error = "Research could not be saved. Keep this window open; findings remain available to save as leads." }
                }
            }
            let evidenced = researchResults.values.filter(\.hasAIUseEvidence).count
            progress = "\(results.count) listings; \(researchResults.count) websites checked; \(evidenced) with AI-use evidence. Contact sources and unknowns are shown below. Nothing sent."
        }
        catch { self.error = error.localizedDescription }
    }
}
