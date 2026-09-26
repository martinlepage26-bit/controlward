import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: AppStore
    @State private var running = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionLabel(text: "Contextward command center")
                        Text("Good morning, \(store.business.name.isEmpty ? "workspace" : store.business.name)").font(.title2.weight(.bold))
                        Text("One view of relationships, signals, evidence, protection, and next actions.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Run automations", systemImage: "bolt.fill") {
                        running = true
                        _ = store.runAutomations()
                        running = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(running)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    OverviewMetric(value: "\(store.leads.count)", label: "CRM records", symbol: "person.2")
                    OverviewMetric(value: "\(store.dueLeads.count)", label: "due follow-ups", symbol: "clock.badge.exclamationmark")
                    OverviewMetric(value: "\(store.qualifiedSignals.count)", label: "qualified signals", symbol: "dot.radiowaves.left.and.right")
                    OverviewMetric(value: store.averageLanguageGap.formatted(.number.precision(.fractionLength(1))), label: "avg Lantern gap", symbol: "arrow.left.and.right")
                    OverviewMetric(value: "\(store.exposureFindings.filter { !$0.resolved }.count)", label: "open findings", symbol: "lock.shield")
                    OverviewMetric(value: "\(store.syncJobs.filter { $0.status == "queued" }.count)", label: "queued syncs", symbol: "arrow.triangle.2.circlepath")
                }

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Next actions")
                        if store.openTasks.isEmpty { Text("No open tasks. Run automations or add a task from Tasks.").foregroundStyle(.secondary) }
                        ForEach(store.openTasks.prefix(6)) { task in
                            Label { Text(task.title) } icon: { Image(systemName: "circle").foregroundStyle(CRMTheme.amberDark) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .crmCard()

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "System pulse")
                        pulse("LeadGen intake", store.activeSignals.isEmpty ? "Waiting for import" : "Receiving signals")
                    pulse("Lantern evidence", store.audits.isEmpty ? "No audit loaded" : "Evidence available")
                        pulse("Pharos hygiene", store.exposureFindings.isEmpty ? "Scan workspace" : "Review findings")
                        pulse("Adapter queue", store.syncJobs.isEmpty ? "No sync intents" : "Review outbox")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .crmCard()
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(28)
        }
        .navigationTitle("Overview")
    }

    private func pulse(_ title: String, _ state: String) -> some View {
        HStack { Circle().fill(CRMTheme.moss).frame(width: 8, height: 8); Text(title); Spacer(); Text(state).font(.caption).foregroundStyle(.secondary) }
    }
}

private struct OverviewMetric: View {
    let value: String; let label: String; let symbol: String
    var body: some View { VStack(alignment: .leading, spacing: 5) { Image(systemName: symbol).foregroundStyle(CRMTheme.steel); Text(value).font(.title2.weight(.bold)); Text(label).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.background, in: RoundedRectangle(cornerRadius: 9)).overlay { RoundedRectangle(cornerRadius: 9).stroke(CRMTheme.border) } }
}
