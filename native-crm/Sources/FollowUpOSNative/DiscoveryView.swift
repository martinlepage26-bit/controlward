import SwiftUI

struct DiscoveryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var location: DiscoveryLocation = .montreal
    @State private var category: DiscoveryCategory = .contractor
    @State private var latitude = "45.5017"
    @State private var longitude = "-73.5673"
    @State private var radius = 2_000
    @State private var results: [DiscoveryCandidate] = []
    @State private var searching = false
    @State private var error: String?
    @State private var lastSearchAt: Date?
    @State private var addedIDs = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Find public prospects").font(.title2.weight(.bold))
                    Text("Search named businesses in OpenStreetMap. Buyer intent is unknown.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
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
                    Task { await search() }
                } label: {
                    Label(searching ? "Searching" : "Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(searching || cooldownActive)
            }
            .pickerStyle(.menu)

            Text("Priority formula: category and area 50 + website 20 + phone 15 + email 15. This measures public-data completeness; it does not estimate buying intent. Results are capped at 50. Each search is user-started, with a 15-second cooldown.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(CRMTheme.rust) }

            List(results) { candidate in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "building.2.crop.circle").foregroundStyle(CRMTheme.steel).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.name).font(.headline)
                        Text([candidate.category, candidate.address].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Research priority \(candidate.researchPriority)/100 · category/area 50, website \(candidate.websitePoints), phone \(candidate.phonePoints), email \(candidate.emailPoints) · intent unknown")
                            .font(.caption.monospacedDigit()).foregroundStyle(CRMTheme.steel)
                        if let website = candidate.website { Text(website).font(.caption).lineLimit(1) }
                        Text("Evidence from OpenStreetMap · \(candidate.sourceURL)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if addedIDs.contains(candidate.sourceID) || store.leads.contains(where: { $0.sourceID == candidate.sourceID }) {
                        Label("In pipeline", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(CRMTheme.moss)
                    } else {
                        Button("Add for review") { _ = store.acceptDiscovery(candidate); addedIDs.insert(candidate.sourceID) }
                            .buttonStyle(.bordered)
                    }
                }.padding(.vertical, 4)
            }
            .listStyle(.inset)
            HStack { Spacer(); Text("© OpenStreetMap contributors · Open database license").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(22)
        .frame(minWidth: 900, minHeight: 620)
        .onChange(of: location) { _, selected in
            let point = selected.coordinates
            if selected != .custom { latitude = String(point.0); longitude = String(point.1) }
        }
    }

    private var cooldownActive: Bool { lastSearchAt.map { Date.now.timeIntervalSince($0) < 15 } ?? false }

    @MainActor
    private func search() async {
        guard !cooldownActive else { error = "Please wait 15 seconds between public map searches."; return }
        guard let lat = Double(latitude), let lon = Double(longitude), (-90...90).contains(lat), (-180...180).contains(lon) else {
            error = "Enter latitude from −90 to 90 and longitude from −180 to 180."
            return
        }
        searching = true
        error = nil
        lastSearchAt = .now
        defer { searching = false }
        do { results = try await DiscoveryClient().search(category: category.selector, latitude: lat, longitude: lon, radiusMeters: radius, limit: 50) }
        catch { results = []; self.error = error.localizedDescription }
    }
}
