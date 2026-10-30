import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AccountIntelligenceView: View {
    @EnvironmentObject private var store: AppStore
    @State private var profileID: UUID?
    @State private var companyID: UUID?
    @State private var newProfile = false
    @State private var message: String?
    @State private var search = ""
    @State private var eligibleOnly = false

    private var profile: GTMProfile? { store.gtm.profiles.first { $0.id == profileID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Account intelligence").font(.title2.bold())
            Text("Review account fit, evidence and the next action.").foregroundStyle(.secondary)
            HStack {
                Picker("Offer", selection: $profileID) {
                    Text("Choose an offer").tag(UUID?.none)
                    ForEach(store.gtm.profiles) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 420)
                Button("New offer") { newProfile = true }
                Spacer()
#if !DEBUG || !CONTEXTWARD_ACCEPTANCE
                Button("Import evidence JSON") { importEvidence() }.disabled(profile == nil)
#endif
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            TextField("Find an account by name or domain", text: $search).textFieldStyle(.roundedBorder)
            if let profile {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    TabView {
                        HSplitView {
                            List(store.companies.filter { search.isEmpty || "\($0.name) \($0.domain)".localizedCaseInsensitiveContains(search) }, selection: $companyID) { company in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(company.name).fontWeight(.semibold)
                                    Text(company.domain.isEmpty ? "Identity needs evidence" : company.domain).font(.caption).foregroundStyle(.secondary)
                                }.tag(company.id).padding(.vertical, 4)
                            }.frame(minWidth: 180, idealWidth: 230, maxWidth: 290)
                            if let company = store.companies.first(where: { $0.id == companyID }) {
                                GTMAccountDetail(company: company, profile: profile, now: context.date)
                                    .id("\(company.id)-\(profile.id)")
                            } else {
                                ContentUnavailableView("Choose an account", systemImage: "building.2", description: Text("Import accounts with evidence, or add a company in Companies."))
                            }
                        }.tabItem { Label("Accounts & scores", systemImage: "building.2") }
                        GTMEvidenceInbox(profile: profile).tabItem { Label("Evidence inbox", systemImage: "tray") }
                        segment(profile: profile, now: context.date).tabItem { Label("Segment preview", systemImage: "line.3.horizontal.decrease.circle") }
                    }
                }
            } else {
                ContentUnavailableView("Define one offer first", systemImage: "scope", description: Text("Give each offer its own target criteria. Scores stay separate for different products."))
            }
            Text("Local pilot · Manual runs · Rules-based prioritization · No outreach sent")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .onAppear {
            if profileID == nil { profileID = store.gtm.profiles.first?.id }
            if companyID == nil { companyID = store.companies.first?.id }
        }
        .sheet(isPresented: $newProfile) { GTMProfileEditor { profileID = $0 } }
    }

    private func segment(profile: GTMProfile, now: Date) -> some View {
        let previews = store.gtmPreview(profileID: profile.id, now: now).filter { snapshot in
            let company = store.companies.first { $0.id == snapshot.companyID }
            return (!eligibleOnly || snapshot.queue.eligible) && (search.isEmpty || "\(company?.name ?? "") \(company?.domain ?? "")".localizedCaseInsensitiveContains(search))
        }
        let links = store.gtm.taskLinks.filter { $0.profileID == profile.id }
        let completed = links.filter { link in store.tasks.contains { $0.id == link.taskID && $0.status == .done } }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Eligible accounts only", isOn: $eligibleOnly)
                Spacer()
#if !DEBUG || !CONTEXTWARD_ACCEPTANCE
                Button("Export visible segment") { exportSegment(previews, profile: profile, now: now) }
#endif
            }
            HStack {
                Text("\(previews.filter { $0.queue.eligible }.count) eligible · \(links.count) reviews created · \(completed) completed").font(.headline)
                Spacer()
                Button("Save daily snapshot") { perform { try store.saveGTMSnapshots(profileID: profile.id); return "Snapshot saved. Ordinary activity routing needs two consecutive UTC days." } }
                Button("Create review tasks") { perform { "Created \(try store.createGTMReviewTasks(profileID: profile.id)) new review tasks. Existing account/offer tasks are preserved." } }
                    .buttonStyle(.borderedProminent)
            }
            Text("Recent validated requests enter review immediately. Open opportunities, exclusions and unverified identities block new tasks. Re-running never recreates a completed or deleted review.")
                .font(.callout).foregroundStyle(.secondary)
            List(previews) { snapshot in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(store.companies.first { $0.id == snapshot.companyID }?.name ?? "Removed account").font(.headline)
                        Spacer()
                        Text(snapshot.queue.label).foregroundStyle(snapshot.queue.eligible ? .green : .secondary)
                    }
                    Text("Fit: \(snapshot.fitBand) · Buyer activity: \(snapshot.intent.map(String.init) ?? "Unknown") · Rules-based stage: \(snapshot.stage)")
                    ForEach(snapshot.reasons, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    if let link = links.first(where: { $0.companyID == snapshot.companyID }) {
                        Text("Review task: \(store.tasks.first { $0.id == link.taskID }?.status.label ?? "Deleted; deduplication retained")")
                            .font(.caption.weight(.semibold))
                    }
                }.padding(.vertical, 6)
            }
        }.padding(14)
    }

    private func perform(_ operation: () throws -> String) {
        do { message = try operation() } catch { message = error.localizedDescription }
    }

    private func exportSegment(_ snapshots: [GTMScoreSnapshot], profile: GTMProfile, now: Date) {
#if DEBUG && CONTEXTWARD_ACCEPTANCE
        message = "File export is disabled in the isolated preview."
#else
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "controlward-account-segment.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshots).write(to: url, options: .atomic); try SecureFiles.restrict(url)
            return "Exported \(snapshots.count) visible rules-based assessments for \(profile.name). These scores are not predictive probabilities."
        }
#endif
    }

    private func importEvidence() {
#if DEBUG && CONTEXTWARD_ACCEPTANCE
        message = "File import is disabled in the isolated preview."
#else
        guard let profileID else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        perform {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try GTMEvents.require(size <= 2_000_000, "Import files must be smaller than 2 MB.")
            let count = try store.importGTM(data: Data(contentsOf: url), profileID: profileID)
            if companyID == nil { companyID = store.companies.first?.id }
            return "Imported \(count) new events. Validate their account and buyer action in Evidence inbox before they affect scores."
        }
#endif
    }
}

private struct GTMAccountDetail: View {
    @EnvironmentObject private var store: AppStore
    let company: Company
    let profile: GTMProfile
    let now: Date
    @State private var editor: GTMEditorKind?
    private var snapshot: GTMScoreSnapshot { AccountScoring.evaluate(company: company, profile: profile, workspace: store.workspace, now: now) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(company.name).font(.title.bold())
                Text(company.domain.isEmpty ? "No business domain recorded" : company.domain).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 24) {
                    metric("Product fit", "\(snapshot.fit)/100 · \(snapshot.fitBand)")
                    metric("Evidence coverage", "\(snapshot.coverage)%")
                    metric("Buyer activity", snapshot.intent.map { "\($0)/100" } ?? "Unknown")
                }
                Text("Rules-based stage: \(snapshot.stage) · \(snapshot.queue.label)").font(.headline)
                Text("Purchase is an activity band, not a sale. Scores are not probabilities.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(snapshot.identityVerified ? "Review identity / suppression" : "Verify account identity") { editor = .identity }
                    Button("Assess product fit") { editor = .fit }
                }
                HStack {
                    Button("Record buyer activity") { editor = .activity }
                    Button("Record observation window") { editor = .observation }
                }
                Divider()
                Text("Why this result").font(.headline)
                ForEach(snapshot.reasons, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
                Text("Scored evidence").font(.headline)
                if snapshot.contributions.isEmpty { Text("No eligible buyer activity.").foregroundStyle(.secondary) }
                ForEach(snapshot.contributions, id: \.eventID) { contribution in
                    if let event = store.gtm.events.first(where: { $0.id == contribution.eventID }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(event.kind.label) · \(contribution.points, specifier: "%.1f") points").fontWeight(.medium)
                            Text("\(event.occurredAt.formatted()) · \(event.source)").font(.caption).foregroundStyle(.secondary)
                            Text(event.reference).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                Divider()
                Text("CRM outcomes").font(.headline)
                let opportunities = store.opportunities.filter { $0.companyID == company.id }
                Text("\(opportunities.filter { !$0.stage.isClosed }.count) open opportunities · \(opportunities.filter { $0.stage == .won }.count) won · \(opportunities.filter { $0.stage == .lost }.count) lost")
                Text("Account-associated CRM outcomes; this view does not claim causal lift or product attribution.").font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.sheet(item: $editor) { kind in GTMAccountEditor(kind: kind, company: company, profile: profile) }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline) }
    }
}

private enum GTMEditorKind: String, Identifiable {
    case identity, fit, activity, observation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .identity: "Review account identity"
        case .fit: "Assess product fit"
        case .activity: "Record buyer activity"
        case .observation: "Record observation window"
        }
    }
}

private struct GTMProfileEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var saved: (UUID) -> Void
    @State private var name = ""
    @State private var criteria = Array(repeating: "", count: 4)
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Define an offer").font(.title2.bold())
            Text("Describe the account criteria for this offer. This pilot uses fixed weights of 30 / 20 / 20 / 30. Saved criteria are immutable; create a new offer profile when policy changes.").foregroundStyle(.secondary)
            Form {
                TextField("Offer name", text: $name)
                ForEach(0..<4) { index in TextField(GTMProfile.labels[index], text: $criteria[index]) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save offer") {
                do { saved(try store.createGTMProfile(name: name, criteria: criteria)); dismiss() } catch { self.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 600)
    }
}

private struct GTMAccountEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let kind: GTMEditorKind
    let company: Company
    let profile: GTMProfile
    @State private var proof = ""
    @State private var suppression = ""
    @State private var fit = Array(repeating: GTMFitEvidence(), count: 4)
    @State private var eventKind: GTMEventKind = .handRaise
    @State private var actionKey = ""
    @State private var date = Date()
    @State private var starts = Date().addingTimeInterval(-91 * 86400)
    @State private var source = ""
    @State private var confirmed = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind.title).font(.title2.bold())
            Text("\(company.name) · \(profile.name)").foregroundStyle(.secondary)
            Form {
                switch kind {
                case .identity:
                    Text("Confirm this organization and its exact domain. A shared domain alone does not identify a subsidiary or location.")
                    TextField("Identity evidence / reference", text: $proof)
                    TextField("Suppression reason (blank = none)", text: $suppression)
                case .fit:
                    ForEach(0..<4) { index in
                        VStack(alignment: .leading) {
                            Text("\(GTMProfile.labels[index]) · \(GTMProfile.weights[index]) points").fontWeight(.semibold)
                            Text(profile.criteria[index]).font(.caption).foregroundStyle(.secondary)
                            Picker("Assessment", selection: $fit[index].result) { ForEach(GTMMatch.allCases, id: \.self) { Text($0.label).tag($0) } }
                            TextField("Dated source or reviewed evidence", text: $fit[index].reference)
                        }.padding(.vertical, 4)
                    }
                    TextField("Hard exclusion reason (blank = none)", text: $suppression)
                case .activity:
                    Picker("Buyer action", selection: $eventKind) { ForEach(GTMEventKind.allCases.filter { $0.parameters != nil }, id: \.self) { Text($0.label).tag($0) } }
                    DatePicker("Occurred at", selection: $date)
                    TextField("Stable buyer action key", text: $actionKey)
                    Text("Reuse the same action key if one submission appears in several sources. Do not count a copied request as a separate reply.").font(.caption)
                    TextField("Evidence reference", text: $proof)
                    Toggle("I verified this buyer action and its account attribution", isOn: $confirmed)
                case .observation:
                    Text("Record a source you actually reviewed. A fresh window covering 90 days can support zero observed activity. It does not represent all off-site research.")
                    TextField("Observed source", text: $source)
                    DatePicker("Window starts", selection: $starts)
                    DatePicker("Observed through", selection: $date)
                    TextField("Evidence reference", text: $proof)
                    Toggle("I verified source coverage for this entire window", isOn: $confirmed)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save review") { save() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 650)
        .onAppear {
            if kind == .identity, let review = store.gtm.identities.last(where: { $0.companyID == company.id }) { proof = review.reason; suppression = review.suppressionReason }
            if kind == .fit, let assessment = store.gtm.assessments.last(where: { $0.companyID == company.id && $0.profileID == profile.id }) { fit = assessment.evidence; suppression = assessment.exclusionReason }
        }
    }

    private func save() {
        do {
            switch kind {
            case .identity: try store.reviewGTMIdentity(companyID: company.id, reason: proof, suppression: suppression)
            case .fit: try store.saveGTMFit(GTMFitAssessment(companyID: company.id, profileID: profile.id, evidence: fit, exclusionReason: suppression))
            case .activity:
                try GTMEvents.require(confirmed, "Confirm the buyer action and account attribution.")
                try store.recordGTMEvent(companyID: company.id, profileID: profile.id, kind: eventKind, actionKey: actionKey, occurredAt: date, reference: proof)
            case .observation:
                try GTMEvents.require(confirmed, "Confirm that you reviewed the entire observation window.")
                try store.saveGTMObservation(GTMObservation(companyID: company.id, profileID: profile.id, source: source, startsAt: starts, throughAt: date, reference: proof))
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct GTMEvidenceInbox: View {
    @EnvironmentObject private var store: AppStore
    let profile: GTMProfile
    @State private var selected: GTMEvent?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Imported evidence starts unvalidated. Review the buyer action and select the correct organization; shared domains remain ambiguous.").foregroundStyle(.secondary)
            List(store.gtm.events.filter { $0.profileID == profile.id }.reversed()) { event in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.kind.label).font(.headline)
                        Text("Source account: \(event.accountName) · \(event.domain)").font(.caption)
                        Text("\(event.occurredAt.formatted()) · \(event.source) · \(event.sourceEventID)").font(.caption)
                        Text(event.reference).font(.caption).textSelection(.enabled)
                        Text(status(event)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review evidence") { selected = event }
                }.padding(.vertical, 6)
            }
        }.padding(14).sheet(item: $selected) { GTMEventEditor(event: $0) }
    }
    private func status(_ event: GTMEvent) -> String {
        if store.gtm.retractions.contains(where: { $0.eventID == event.id }) { return "Retracted — excluded from current scores" }
        if event.occurredAt > Date() { return "Quarantined — future event time" }
        if event.kind.parameters == nil || event.isBotOrInternal { return "Research / outbound / internal evidence — never scored as buyer activity" }
        if let review = store.gtm.reviews.last(where: { $0.eventID == event.id }) { return "Validated for \(store.companies.first { $0.id == review.companyID }?.name ?? "removed account")" }
        let candidates = AccountIdentity.candidates(for: event.domain, companies: store.companies)
        return candidates.count > 1 ? "Ambiguous: \(candidates.count) organizations share this domain" : "Needs account and buyer-action validation"
    }
}

private struct GTMEventEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let event: GTMEvent
    @State private var companyID: UUID?
    @State private var reason = ""
    @State private var confirmed = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review evidence").font(.title2.bold())
            Text(event.kind.label).font(.headline)
            Text("Source account: \(event.accountName) · \(event.domain)").foregroundStyle(.secondary)
            Text(event.reference).textSelection(.enabled)
            Text("\(event.occurredAt.formatted()) · Action key: \(event.actionKey)").font(.caption)
            Picker("Correct account", selection: $companyID) {
                Text("Choose an account").tag(UUID?.none)
                ForEach(store.companies) { Text($0.name).tag(Optional($0.id)) }
            }
            TextField("Validation evidence or retraction reason", text: $reason)
            Toggle("I verified this buyer action and its account attribution", isOn: $confirmed)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Button("Retract evidence", role: .destructive) { perform { try store.retractGTMEvent(eventID: event.id, reason: reason) } }
                Spacer()
                Button("Validate evidence") { perform {
                    try GTMEvents.require(confirmed && companyID != nil, "Select an account and confirm validation.")
                    try store.reviewGTMEvent(eventID: event.id, companyID: companyID!, reason: reason)
                } }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 650)
        .onAppear { companyID = store.gtm.reviews.last { $0.eventID == event.id }?.companyID ?? event.candidateCompanyID }
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); dismiss() } catch { self.error = error.localizedDescription }
    }
}
