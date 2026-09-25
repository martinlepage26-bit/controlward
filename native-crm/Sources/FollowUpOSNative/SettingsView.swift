import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var name = ""
    @State private var industry = Industries.all[0]
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 8) {
                    ContextwardLogo(size: 132)
                    Text("Contextward")
                        .font(.title.weight(.heavy))
                        .foregroundStyle(CRMTheme.ink)
                    Text("PHAROS CRM")
                        .font(.caption.weight(.bold))
                        .tracking(1.8)
                        .foregroundStyle(CRMTheme.amberDark)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace settings").font(.title2.weight(.bold))
                    Text("Manage the business identity used across the CRM and follow-up writer.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 15) {
                    TextField("Business name", text: $name)
                        .textFieldStyle(.roundedBorder)
                    Picker("Industry", selection: $industry) {
                        ForEach(Industries.all, id: \.self) { Text($0) }
                    }
                    HStack {
                        Spacer()
                        Button("Save changes") {
                            store.saveBusiness(BusinessProfile(
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? store.business.name : name,
                                industry: industry
                            ))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .crmCard()

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Native local persistence").font(.headline)
                        Text("Leads, messages, settings, and review state are stored in an owner-only folder on this Mac. Follow-up drafting uses Apple Intelligence on-device when available and a built-in local template otherwise.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(store.storageURL.deletingLastPathComponent().path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Import legacy workspace.json…") { importLegacyWorkspace() }
                            .buttonStyle(.bordered)
                            .help("One-time copy of native-crm/data/workspace.json from an earlier build. The original is kept.")
                    }
                } icon: {
                    Image(systemName: "internaldrive.fill").foregroundStyle(CRMTheme.moss)
                }
                .crmCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Danger zone").font(.headline).foregroundStyle(CRMTheme.rust)
                    Text("Erase every lead, follow-up, business setting, and privacy-review date. A timestamped backup is saved first.")
                        .foregroundStyle(.secondary)
                    Button("Reset all data", role: .destructive) { confirmReset = true }
                }
                .crmCard()
            }
            .frame(maxWidth: 720)
            .padding(28)
        }
        .navigationTitle("Settings")
        .onAppear {
            name = store.business.name
            industry = store.business.industry
        }
        .confirmationDialog("Reset Contextward?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Back up and erase everything", role: .destructive) {
                do { try store.resetAll(confirmed: true) }
                catch { store.notice = "Reset stopped; nothing was erased: \(error.localizedDescription)" }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes the business profile and every lead. A timestamped, owner-only backup is written to the data folder first.")
        }
    }

    private func importLegacyWorkspace() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Select native-crm/data/workspace.json"
        panel.message = "Contextward copies this file once, verifies the copy, and keeps the original as a backup."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.importLegacyWorkspace(from: url) }
        catch { store.notice = "Legacy import failed: \(error.localizedDescription)" }
    }
}
