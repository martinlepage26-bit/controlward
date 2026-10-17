import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var navigation: WorkspaceNavigation
    @State private var search = ""
    @State private var record: WorkspaceRecord?

    private var openTasks: [WorkspaceRecord] { store.records(kind: "tasks", filter: .open, sort: .due) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Today").font(.title2.bold())
                        Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day()).foregroundStyle(CRMTheme.slate)
                    }
                    Spacer()
                    Button("Open projects", systemImage: "rectangle.3.group") { navigation.show(.projects) }
                        .buttonStyle(.borderedProminent)
                }

                VStack(alignment: .leading, spacing: 10) {
                    TextField("Search this workspace", text: $search)
                        .textFieldStyle(.roundedBorder).controlSize(.large)
                        .accessibilityLabel("Search local contacts, companies, tasks, notes, signals and imported mail")
                    if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let matches = store.records(search: search)
                        Text("\(matches.count) matches · select a record to link or capture it in Projects")
                            .font(.caption).foregroundStyle(CRMTheme.slate)
                        if matches.isEmpty { Text("Try a name, subject or company.").foregroundStyle(CRMTheme.slate) }
                        ForEach(matches.prefix(30)) { row in
                            Button { record = row } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.title).fontWeight(.semibold)
                                        Text(row.kind.capitalized).font(.caption).foregroundStyle(CRMTheme.slate)
                                    }
                                    Spacer()
                                    Image(systemName: "link").foregroundStyle(CRMTheme.steel)
                                }.padding(.vertical, 5).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Project links for \(row.title)")
                            Divider()
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 22) {
                        nextActions.frame(minWidth: 350, maxWidth: .infinity)
                        reviewQueue.frame(minWidth: 230, idealWidth: 270, maxWidth: 300)
                    }
                    VStack(alignment: .leading, spacing: 24) { nextActions; reviewQueue }
                }

                Divider()
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "Workspace")
                        summary("CRM records", "\(store.contacts.count + store.companies.count + store.opportunities.count + store.tasks.count + store.notes.count)")
                        summary("Lantern language gap", store.audits.isEmpty ? "No audits" : store.averageLanguageGap.formatted(.number.precision(.fractionLength(1))))
                        summary("Queued syncs", "\(store.syncJobs.filter { $0.status == "queued" }.count)")
                        Button("Manage integrations") { navigation.show(.integrations) }.buttonStyle(.link)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { SectionLabel(text: "Recent activity"); Spacer(); Button("View all") { navigation.show(.activity) }.buttonStyle(.link) }
                        if store.activity.isEmpty { Text("Changes you make here appear in Activity.").font(.callout).foregroundStyle(CRMTheme.slate) }
                        ForEach(store.activity.prefix(3)) { event in
                            Text(event.message).font(.callout).foregroundStyle(CRMTheme.slate).lineLimit(3)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: 980, alignment: .leading).padding(28)
        }
        .navigationTitle("Overview")
        .sheet(item: $record) { RecordProjectSheet(record: $0) }
    }

    private var nextActions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { SectionLabel(text: "Next actions"); Spacer(); Text("\(openTasks.count) open").font(.caption).foregroundStyle(CRMTheme.slate) }
            if openTasks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No open tasks.").font(.headline)
                    Text("Add a task, or turn reviewed email and signals into follow-up work.").foregroundStyle(CRMTheme.slate)
                    Button("Open tasks") { navigation.directory("tasks") }
                }.padding(.vertical, 16)
            }
            ForEach(openTasks.prefix(6)) { task in
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        do { try store.completeTask(task.recordID, completed: true) } catch { store.notice = error.localizedDescription }
                    } label: { Image(systemName: "circle").font(.title3).foregroundStyle(CRMTheme.steel) }
                        .buttonStyle(.plain).accessibilityLabel("Complete \(task.title)").help("Mark complete")
                    Button { navigation.directory("tasks", search: task.title) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(task.title).fontWeight(.medium).foregroundStyle(CRMTheme.ink).multilineTextAlignment(.leading)
                            if !task.date.isEmpty {
                                Text(task.date < CalendarCRM.dayString() ? "Overdue · \(task.date)" : "Due \(task.date)")
                                    .font(.caption).foregroundStyle(task.date < CalendarCRM.dayString() ? CRMTheme.rust : CRMTheme.slate)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Divider()
            }
            HStack {
                Button("All tasks") { navigation.directory("tasks", filter: .open) }.buttonStyle(.link)
                Spacer()
                Button("Run automations", systemImage: "bolt") { _ = store.runAutomations() }.buttonStyle(.bordered)
            }
        }.crmCard()
    }

    private var reviewQueue: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: "Ready to review")
            queueRow("Email", detail: "Imported metadata", count: store.mail.filter { !$0.reviewed }.count, symbol: "envelope") { navigation.show(.email) }
            queueRow("Follow-ups", detail: "Due leads", count: store.dueLeads.count, symbol: "person.crop.circle.badge.clock") { navigation.show(.pipeline) }
            queueRow("Signals", detail: "Qualified and routed", count: store.qualifiedSignals.count, symbol: "scope") { navigation.show(.operations) }
            queueRow("Findings", detail: "Open security reviews", count: store.exposureFindings.filter { !$0.resolved }.count, symbol: "lock.shield") { navigation.show(.security) }
            Button("Browse market gaps") { navigation.show(.operations) }.buttonStyle(.link)
        }.padding(.vertical, 16)
    }

    private func queueRow(_ title: String, detail: String, count: Int, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(CRMTheme.steel)
                VStack(alignment: .leading, spacing: 3) { Text(title).fontWeight(.medium); Text(detail).font(.caption).foregroundStyle(CRMTheme.slate) }
                Spacer()
                Text("\(count)").font(.headline.monospacedDigit()).foregroundStyle(count > 0 ? CRMTheme.ink : CRMTheme.slate)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(CRMTheme.slate)
            }.foregroundStyle(CRMTheme.ink).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(title), \(count) to review. \(detail)")
    }
    private func summary(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(CRMTheme.slate); Spacer(); Text(value).monospacedDigit() }.font(.callout)
    }
}
