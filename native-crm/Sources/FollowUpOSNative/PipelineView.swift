import AppKit
import SwiftUI

struct LeadEditorContext: Identifiable {
    let id = UUID()
    let lead: Lead
    let isNew: Bool
}

struct PipelineView: View {
    @EnvironmentObject private var store: AppStore
    @State private var search = ""
    @State private var filter: PipelineFilter = .open
    @State private var editor: LeadEditorContext?
    @State private var importError: String?
    @State private var showDiscovery = false
    @State private var showLeads = false
    @State private var selectedOpportunity: Opportunity?
    @State private var dueOnly = false
    @State private var projectRecord: WorkspaceRecord?

    private var filtered: [Lead] {
        store.filteredLeads(filter: filter, search: search).filter { lead in
            !dueOnly || (lead.status.isOpen && lead.nextFollowUp.map { $0 <= CalendarCRM.dayString() } == true)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(greeting)
                            .font(.title2.weight(.bold))
                        Text("Here is the current customer pipeline.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        importCSV()
                    } label: {
                        Label("Import CSV", systemImage: "square.and.arrow.down")
                    }
                    Button { showDiscovery = true } label: {
                        Label("Find prospects", systemImage: "globe.americas")
                    }
                    .buttonStyle(.bordered)
                    Button { showLeads = true } label: {
                        Label("Leads", systemImage: "person.crop.rectangle.stack")
                    }
                    .buttonStyle(.bordered)
                    .help("ControlWard's own Leads list: search, own-site evidence, local drafts. Nothing is sent.")
                    Button {
                        editor = LeadEditorContext(lead: .blank(), isNew: true)
                    } label: {
                        Label("Add lead", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: [.command])
                }
                if let result = store.lastCSVImport {
                    CSVImportResultPanel(result: result) { store.dismissCSVImport() }
                }

                HStack(spacing: 12) {
                    MetricCard(value: "\(store.closeRate)%", label: "Close rate", symbol: "percent")
                    MetricCard(value: currency(store.dollarsWon), label: "$ won", symbol: "checkmark.circle")
                    MetricCard(value: currency(store.activePipeline), label: "$ still open", symbol: "chart.line.uptrend.xyaxis")
                }

                VStack(alignment: .leading, spacing: 11) {
                    SectionLabel(text: store.dueLeads.isEmpty ? "Due today" : "\(store.dueLeads.count) follow-up\(store.dueLeads.count == 1 ? "" : "s") due")
                    if store.dueLeads.isEmpty {
                        Label("You're all caught up.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(CRMTheme.moss)
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(15)
                            .crmCard()
                    } else {
                        VStack(spacing: 8) {
                            ForEach(store.dueLeads) { lead in
                                Button { open(lead) } label: { LeadRow(lead: lead, urgent: true) }.buttonStyle(.plain)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Customer pipeline")
                    HStack(spacing: 10) {
                        TextField("Search leads…", text: $search)
                            .textFieldStyle(.roundedBorder)
                        Toggle("Due only", isOn: $dueOnly).toggleStyle(.checkbox)
                        Picker("Filter", selection: $filter) {
                            ForEach(PipelineFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 330)
                    }

                    if filtered.isEmpty {
                        ContentUnavailableView(
                            store.leads.isEmpty ? "No leads yet" : "No matching leads",
                            systemImage: "person.2",
                            description: Text(store.leads.isEmpty ? "Add your first lead to get started." : "Try another search or pipeline filter.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 190)
                        .crmCard()
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(filtered) { lead in
                                Button { open(lead) } label: { LeadRow(lead: lead) }.buttonStyle(.plain)
                                    .contextMenu { Button("Project links and capture") { projectRecord = store.allWorkspaceRecords.first { $0.kind == "leads" && $0.recordID == lead.id } } }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Opportunity stages")
                    Text("Move each opportunity by editing its stage. Closed won/lost records stay visible in their stage.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(OpportunityStage.allCases) { stage in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(stage.label).font(.headline); Spacer(); Text("\(store.opportunities.filter { $0.stage == stage }.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                ForEach(store.opportunities.filter { $0.stage == stage }) { opportunity in
                                    Button { selectedOpportunity = opportunity } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(opportunity.name).font(.callout.weight(.semibold)).lineLimit(2)
                                            Text(opportunity.amount.map { $0.formatted(.currency(code: "CAD").precision(.fractionLength(0))) } ?? "Amount not set")
                                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            if let companyID = opportunity.companyID, let company = store.companies.first(where: { $0.id == companyID }) {
                                                Text(company.name).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8).background(CRMTheme.paper, in: RoundedRectangle(cornerRadius: 7))
                                    }.buttonStyle(.plain)
                                        .contextMenu { Button("Project links and capture") { projectRecord = store.allWorkspaceRecords.first { $0.kind == "opportunities" && $0.recordID == opportunity.id } } }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .frame(width: 190).frame(minHeight: 150, alignment: .topLeading)
                            .background(.background, in: RoundedRectangle(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).stroke(CRMTheme.border) }
                        }
                    }
                    }.scrollIndicators(.visible)
                }
            }
            .frame(maxWidth: 980)
            .padding(28)
        }
        .navigationTitle("Pipeline")
        .sheet(item: $projectRecord) { RecordProjectSheet(record: $0) }
        .sheet(item: $editor) { context in
            LeadEditorView(lead: context.lead, isNew: context.isNew)
                .environmentObject(store)
        }
        .sheet(isPresented: $showDiscovery) { DiscoveryView().environmentObject(store) }
        .sheet(isPresented: $showLeads) { ProspectLeadsView() }
        .sheet(item: $selectedOpportunity) { OpportunityEditor(opportunity: $0).environmentObject(store) }
        .alert("CSV import failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "Unknown error")
        }
    }

    private func open(_ lead: Lead) {
        editor = LeadEditorContext(lead: lead, isNew: false)
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import leads from CSV"
        if panel.runModal() == .OK, let url = panel.url {
            do { _ = try store.importCSV(from: url) }
            catch { importError = error.localizedDescription }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        return hour < 12 ? "Good morning." : hour < 18 ? "Good afternoon." : "Good evening."
    }

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "CAD").precision(.fractionLength(0)))
    }
}

/// CSV-5: what the last import did, row by row. Stays until Martin presses Close.
struct CSVImportResultPanel: View {
    let result: CSVImportResult
    let close: () -> Void

    var body: some View {
        let lines = CSVImportPresentation.lines(result)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("CSV import", systemImage: result.failure == nil ? "tray.and.arrow.down" : "exclamationmark.triangle")
                    .font(.headline)
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(index == 1 ? .body.weight(.semibold) : .callout)
                    .foregroundStyle(index == 0 ? .secondary : .primary)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LeadRow: View {
    let lead: Lead
    var urgent = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(urgent ? CRMTheme.rust : lead.status.color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(lead.name).font(.headline)
                    Text(lead.status.label.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(lead.status.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(lead.status.color.opacity(0.12), in: Capsule())
                }
                Text([lead.company, lead.service].filter { !$0.isEmpty }.joined(separator: " · ").isEmpty ? "No company or service noted" : [lead.company, lead.service].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let amount = lead.quoteAmount {
                    Text(amount.formatted(.currency(code: "CAD").precision(.fractionLength(0))))
                        .font(.system(.callout, design: .monospaced, weight: .semibold))
                }
                if lead.status.isOpen {
                    Text((urgent && CalendarCRM.display(lead.nextFollowUp) != "Today" ? "Overdue · " : "") + CalendarCRM.display(lead.nextFollowUp))
                        .font(.caption)
                        .foregroundStyle(urgent ? CRMTheme.rust : .secondary)
                }
            }
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(CRMTheme.border) }
        .contentShape(Rectangle())
    }
}
