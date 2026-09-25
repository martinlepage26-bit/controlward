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

    private var filtered: [Lead] {
        store.filteredLeads(filter: filter, search: search)
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
                    Button {
                        editor = LeadEditorContext(lead: .blank(), isNew: true)
                    } label: {
                        Label("Add lead", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: [.command])
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
                                LeadRow(lead: lead, urgent: true)
                                    .onTapGesture { open(lead) }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Customer pipeline")
                    HStack(spacing: 10) {
                        TextField("Search leads…", text: $search)
                            .textFieldStyle(.roundedBorder)
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
                                LeadRow(lead: lead)
                                    .onTapGesture { open(lead) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 980)
            .padding(28)
        }
        .navigationTitle("Pipeline")
        .sheet(item: $editor) { context in
            LeadEditorView(lead: context.lead, isNew: context.isNew)
                .environmentObject(store)
        }
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
