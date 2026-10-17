import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var name = ""
    @State private var industry = Industries.all[0]
    @State private var confirmReset = false
    @State private var keyDrafts: [SyncTarget: String] = [:]
    @State private var autoPilotEnabled = false

    private func keyBinding(_ target: SyncTarget) -> Binding<String> {
        Binding(get: { keyDrafts[target] ?? "" }, set: { keyDrafts[target] = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 8) {
                    ControlWardLogo(size: 132)
                    Text("ControlWard")
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

                VStack(alignment: .leading, spacing: 12) {
                    Text("Automation").font(.headline)
                    Text("When enabled, ControlWard checks the configured PHAROS lead inbox at startup and every five minutes while open, then runs local rules on imported leads. It never sends outreach or pushes records. Turn it off to stop background pulls.")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("Auto-Pilot", isOn: $autoPilotEnabled)
                        .onChange(of: autoPilotEnabled) { _, enabled in
                            if enabled {
                                Task {
                                    await store.startPulling()
                                    autoPilotEnabled = store.workspace.autoPilotEnabled
                                }
                            } else {
                                store.stopPulling()
                            }
                        }
                }
                .crmCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("API keys").font(.headline)
                    Text("Keys are stored in the macOS login Keychain, never in workspace data or exports. They are write-only here: paste to save or replace.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(SyncTarget.keyed) { target in
                        HStack {
                            Text(target.label).frame(width: 130, alignment: .leading)
                            SecureField(store.hasKey(target) ? "Paste a new key to replace" : "Paste API key", text: keyBinding(target))
                                .textFieldStyle(.roundedBorder)
                            Button(store.hasKey(target) ? "Replace" : "Save") {
                                store.setAPIKey(keyDrafts[target] ?? "", for: target)
                                keyDrafts[target] = ""
                            }
                            .buttonStyle(.bordered)
                            .disabled((keyDrafts[target] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Text(store.hasKey(target) ? "Saved" : "Not set")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(store.hasKey(target) ? .green : .secondary)
                                .frame(width: 52)
                            Button("Remove", role: .destructive) { store.removeAPIKey(for: target) }
                                .buttonStyle(.borderless)
                                .disabled(!store.hasKey(target))
                        }
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

                WorkspaceRecoveryControls()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Danger zone").font(.headline).foregroundStyle(CRMTheme.rust)
                    Text("Erase the local CRM workspace after saving a timestamped backup. Project Control and Email Aggregator keep their separate data and sign-in sessions.")
                        .foregroundStyle(.secondary)
                    Button("Reset CRM data", role: .destructive) { confirmReset = true }
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
            autoPilotEnabled = store.workspace.autoPilotEnabled
        }
        .confirmationDialog("Reset the local CRM workspace?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Back up and erase CRM data", role: .destructive) {
                do { try store.resetAll(confirmed: true) }
                catch { store.notice = "Reset stopped; nothing was erased: \(error.localizedDescription)" }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes local CRM records and settings after writing an owner-only backup. Manage project data and email sessions in their own sections.")
        }
    }

    private func importLegacyWorkspace() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Select native-crm/data/workspace.json"
        panel.message = "ControlWard copies this file once, verifies the copy, and keeps the original as a backup."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.importLegacyWorkspace(from: url) }
        catch { store.notice = "Legacy import failed: \(error.localizedDescription)" }
    }
}
