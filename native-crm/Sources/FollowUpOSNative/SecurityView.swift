import SwiftUI

struct SecurityLens: Identifiable {
    let id = UUID()
    let title: String
    let summary: String
    let capability: String
    let symbol: String
}

private let securityLenses = [
    SecurityLens(title: "Financial Exposure", summary: "Identify exposed financial identifiers, breached credentials, targeted assets, and dark-web activity.", capability: "Dark-web intelligence, breach intelligence, financial-identifier monitoring, and remediation workflows.", symbol: "creditcard"),
    SecurityLens(title: "Digital Exposure", summary: "Map publicly exposed information across data brokers, public records, websites, documents, metadata, and abandoned accounts.", capability: "Distributed crawling, OSINT automation, metadata analysis, data-broker discovery, and opt-out workflows.", symbol: "network"),
    SecurityLens(title: "Identity Exposure", summary: "Detect unauthorized profiles, fraudulent domains, impersonation attempts, synthetic identities, and unauthorized use of likeness.", capability: "Language analysis, reverse-image analysis, domain intelligence, identity correlation, and monitoring.", symbol: "person.crop.circle.badge.exclamationmark"),
    SecurityLens(title: "Reputation Exposure", summary: "Monitor narratives, media references, impersonation campaigns, manipulated content, and emerging reputational threats.", capability: "Media intelligence, sentiment analysis, provenance analysis, and C2PA-aware workflows.", symbol: "megaphone"),
    SecurityLens(title: "Family Exposure", summary: "With explicit consent, identify vulnerabilities created through family, staff, social networks, geolocation, and lifestyle exposure.", capability: "Multimodal correlation, social graph analysis, geolocation-risk detection, and family exposure mapping.", symbol: "figure.2.and.child.holdinghands"),
    SecurityLens(title: "AI / Privacy Exposure", summary: "Understand how search engines, AI systems, agents, scrapers, and public models expose or reproduce personal information.", capability: "AI exposure probing, privacy intelligence, deletion workflows, and model-facing privacy controls.", symbol: "sparkles.rectangle.stack"),
]

struct SecurityView: View {
    @EnvironmentObject private var store: AppStore
    @State private var expanded: UUID?

    private var recordsWithContact: Int { store.leads.filter { !$0.email.isEmpty || !$0.phone.isEmpty }.count }
    private var recordsWithNotes: Int { store.leads.filter { !$0.notes.isEmpty || !$0.history.isEmpty }.count }
    private var incompleteRecords: Int { store.leads.filter { $0.email.isEmpty && $0.phone.isEmpty }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(CRMTheme.amberDark)
                    VStack(alignment: .leading, spacing: 5) {
                        SectionLabel(text: "Pharos Privacy Framework")
                        Text("Protect the relationships you are building.")
                            .font(.title2.weight(.bold))
                        Text("A practical data-hygiene workspace for the customer records in this CRM. It does not run external scans or make security claims about your business.")
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            SectionLabel(text: "Workspace review")
                            Text("Understand what is in this CRM.").font(.headline)
                        }
                        Spacer()
                        Button("Run local scan", systemImage: "shield.lefthalf.filled") { _ = store.runLocalExposureScan() }
                            .buttonStyle(.bordered)
                        Button("Mark reviewed", systemImage: "checkmark.shield") { store.markSecurityReviewed() }
                            .buttonStyle(.borderedProminent)
                    }
                    HStack(spacing: 12) {
                        SecurityMetric(value: "\(store.leads.count)", label: "customer records", symbol: "person.2")
                        SecurityMetric(value: "\(recordsWithContact)", label: "with contact details", symbol: "envelope")
                        SecurityMetric(value: reviewDate, label: "last local review", symbol: "checkmark.circle")
                    }
                    Label(
                        recordsWithNotes > 0
                            ? "Keep only what is needed to serve customers. \(recordsWithNotes) record\(recordsWithNotes == 1 ? " has" : "s have") notes or history."
                            : "Keep only the contact and project information needed to serve a customer.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(CRMTheme.steel)
                    if incompleteRecords > 0 {
                        Label("\(incompleteRecords) record\(incompleteRecords == 1 ? " is" : "s are") missing a phone number or email.", systemImage: "exclamationmark.triangle")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(CRMTheme.rust)
                    }
                }
                .crmCard()

                if !store.exposureFindings.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "Local exposure findings")
                        Text("These are workspace hygiene findings only. No external scan or security claim is being made.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(store.exposureFindings.filter { !$0.resolved }) { finding in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: finding.severity == .high ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(finding.severity == .high ? CRMTheme.rust : CRMTheme.amberDark)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(finding.title).font(.headline)
                                    Text("\(finding.lens) · \(finding.detail)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Resolve") { store.resolve(finding) }.buttonStyle(.bordered)
                            }
                            .padding(10)
                            .background(CRMTheme.paper, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .crmCard()
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Pharos protection lenses")
                    Text("Use the right question before collecting more data.").font(.headline)
                    Text("Expand a lens to see the capability it is designed to support.")
                        .foregroundStyle(.secondary)
                    ForEach(securityLenses) { lens in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expanded == lens.id },
                            set: { expanded = $0 ? lens.id : nil }
                        )) {
                            Text(lens.capability)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(lens.title).font(.headline)
                                    Text(lens.summary).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: lens.symbol).foregroundStyle(CRMTheme.steel)
                            }
                        }
                        .padding(14)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).stroke(CRMTheme.border) }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Response path")
                    Text("Turn a concern into a clear next step.").font(.headline)
                    HStack(alignment: .top, spacing: 10) {
                        responseStep("Observe", "Map the relevant information environment.")
                        responseStep("Correlate", "Connect details that may combine into risk.")
                        responseStep("Evaluate", "Assess severity, confidence, and exploitability.")
                        responseStep("Escalate", "Route high-consequence concerns to a qualified human.")
                    }
                }
                .crmCard()
            }
            .frame(maxWidth: 980)
            .padding(28)
        }
        .navigationTitle("Security")
    }

    private var reviewDate: String {
        guard let raw = store.workspace.lastSecurityReview,
              let date = ISO8601DateFormatter().date(from: raw)
        else { return "Not yet" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func responseStep(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.bold)).foregroundStyle(CRMTheme.amberDark)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SecurityMetric: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(CRMTheme.steel)
            Text(value).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(CRMTheme.paper, in: RoundedRectangle(cornerRadius: 7))
    }
}
