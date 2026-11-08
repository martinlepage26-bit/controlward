import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var name = ""
    @State private var industry = Industries.all[0]
    @State private var confirmReset = false
    @State private var keyDrafts: [SyncTarget: String] = [:]
    @State private var autoPilotEnabled = false
    @State private var recipientReview: ResendRecipientReview?
    @State private var confirmOwnerOnly = false

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
                    SaveFailureNotice()
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
                    Text("Outreach through Resend").font(.headline)
                    Text("Sender: ml@pharos-ai.ca · Resend account: martinlepage26@me.com, team martinlepage26. Use a sending-only API key restricted to the existing pharos-ai.ca domain. Each message requires its own review and confirmation.")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("Open existing Resend account", destination: URL(string: "https://resend.com/api-keys")!)
                    Text("A saved key is configuration only. A successful send records the Resend receipt; delivery and replies remain separate outcomes.").font(.caption)
                    Text(store.resendRecipientDecisionSummary)
                        .font(.callout).foregroundStyle(store.resendExternalRecipientsAllowed ? CRMTheme.moss : CRMTheme.rust)
                    if case .recorded(let decision, _) = store.resendRecipientDecision {
                        Text("Last saved decision: \(decision.recordedAt) · \(decision.assessmentReference)")
                            .font(.caption).textSelection(.enabled)
                    }
                    Button("Review recipient policy…") { recipientReview = store.prepareResendRecipientReview() }
                    if store.resendExternalRecipientsAllowed {
                        Button("Restrict to owner addresses…") { confirmOwnerOnly = true }
                    }
                    if let failure = store.resendRecipientDecisionFailure {
                        Text(failure).font(.caption).foregroundStyle(CRMTheme.rust)
                    }
                    Text("This Mac's decision stays outside CRM backups. A restored workspace or changed outreach policy needs a fresh review. Changing recipient policy cancels existing message previews.")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.pendingResendReceipt != nil {
                        Text(store.resendFailure ?? "An accepted Resend message needs its local receipt saved.").font(.caption).foregroundStyle(CRMTheme.rust)
                        Button("Save pending Resend receipt") { _ = store.retrySavingResendReceipt() }
                    }
                }.crmCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("API keys").font(.headline)
                    Text(store.isReviewMode ? "Account connections are off in this review workspace. Keys cannot be saved here." : "Keys are stored in the macOS login Keychain, never in workspace data or exports. They are write-only here: paste to save or replace.")
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
                            Text(store.keyAccessChecking.contains(target) ? "Checking access…" : (store.keyAccessNeeded.contains(target) ? (target == .resend ? "Access needed: confirm a send" : "Access needed: use Integrations → Verify") : (store.hasKey(target) ? "Saved" : "Not set")))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(store.hasKey(target) ? .green : .secondary)
                                .frame(width: 130)
                            Button("Remove", role: .destructive) { store.removeAPIKey(for: target) }
                                .buttonStyle(.borderless)
                                .disabled(!store.hasKey(target) && !store.keyAccessNeeded.contains(target))
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
            store.refreshResendRecipientDecision()
            name = store.business.name
            industry = store.business.industry
            autoPilotEnabled = store.workspace.autoPilotEnabled
        }
        .onChange(of: store.business.name) { _, value in name = value }
        .onChange(of: store.business.industry) { _, value in industry = value }
        .onChange(of: store.workspace.autoPilotEnabled) { _, value in autoPilotEnabled = value }
        .sheet(item: $recipientReview) { review in
            RecipientPolicyReviewSheet(review: review).environmentObject(store)
        }
        .confirmationDialog("Restrict future sends to owner addresses?", isPresented: $confirmOwnerOnly, titleVisibility: .visible) {
            Button("Save owner-only decision") {
                if let review = store.prepareResendRecipientReview() {
                    _ = store.recordResendRecipientDecision(allowExternal: false, assessmentReference: "",
                                                           review: review, confirmed: true)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Existing message previews are cancelled. Requests already sent to Resend retain their observed outcome.")
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

private struct IncludedOutreachPrivacyDraft: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ResendRecipientDecision.assessmentDraftReference).font(.headline)
            Text("Draft for the owner's decision. No ruling, signature or legal-compliance certificate is supplied by the app. Reference an existing assessment instead if it better covers your operating scope.")
            Text("Scope and purpose").font(.headline)
            Text("One manually reviewed business prospect at a time for the existing 99 CAD Quick Scan. This recipient ruling permits all otherwise eligible external addresses in this native workspace; it is not a one-address limit. Every actual message still needs separate confirmation. KAIROS collection and other connectors are separate decisions.")
            Text("Data and destinations").font(.headline)
            Text("Website research sends public URLs and normal request metadata to business sites, then retains professional contact routes, AI-use claims, sources and timestamps locally. CRM records include drafts, relationships, activity and receipts. A confirmed Resend request contains the sender ml@pharos-ai.ca, one recipient, subject, body, unsubscribe information and request identifiers. Private notes, mailbox bodies and the complete CRM are not automatically attached. User-entered outgoing text needs review.")
            Text("Existing controls and limits").font(.headline)
            Text("Exact-message approval, suppression, duplicate prevention and a durable provider receipt remain required. Researched cold outreach also checks current contact and AI-use evidence and the approved offer. Publication alone does not establish personal-inbox ownership, deliverability, consent, buyer need or actual internal AI use. Mail and KAIROS can contain non-public context; including that context in outgoing text needs a separate review.")
            Text("Provider processing").font(.headline)
            Text("Resend describes US-based storage; selecting another sending region does not relocate retained content. Published email/log retention is 30 days for Free, Pro and Scale, with remaining customer data removed within 90 days after account closure. These provider statements were checked on 8 November 2026. This review did not inspect the account's actual plan, terms or settings. Review the applicable DPA and subprocessors.")
            Link("Resend security and retention", destination: URL(string: "https://resend.com/security")!)
            Link("Resend data processing agreement", destination: URL(string: "https://resend.com/legal/dpa")!)
            Text("Owner determinations still needed").font(.headline)
            Text("For each recipient, retain where and when the route was published, any solicitation restriction, relevance to the business role and the relied-on contact basis. CRTC guidance describes conditions beyond simple public availability, alongside consent, identification and unsubscribe requirements. Assess the necessary payload, outside-Québec processing, safeguards and accepted residual risk. The CAI guide supports the assessment process; this draft does not resolve legal applicability or certify a completed EFVP.")
            Link("CRTC commercial-message guidance", destination: URL(string: "https://crtc.gc.ca/fra/com500/faq500.htm")!)
            Link("CAI privacy-assessment guide", destination: URL(string: "https://www.cai.gouv.qc.ca/uploads/pdfs/CAI_GU_EFVP.pdf")!)
            Text("Retention, rights and opt-outs").font(.headline)
            Text("Choose who handles access, correction, deletion and complaints, and set a local prospect-data review schedule. Preserve the minimum suppression and dispatch evidence needed for opt-outs and safe retries. Assign responsibility for monitoring the published reply address and recording exclusions before more outreach. Automatic local 30-day deletion and automatic processing of every incoming opt-out are not implemented. Disk/backup encryption, formal privacy-officer designation and account terms have not been inspected by this review.")
            Text("Recording and restricting a ruling").font(.headline)
            Text("The private local decision stays outside CRM backups and is bound to the workspace and policy. Restore/reset, copying it elsewhere or a policy change requires a new review. Restricting recipients cancels pending previews, including a credential wait. A request already issued retains its real outcome. If saving fails, external sends pause for the current session; an earlier saved ruling may still apply after restart until a successful retry. Recording eligibility sends no message and creates no buying intent or revenue.")
        }.font(.callout).textSelection(.enabled)
    }
}

private struct RecipientPolicyReviewSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let review: ResendRecipientReview
    @State private var assessmentReference = ""
    @State private var confirmedScope = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review external recipients").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if store.isReviewMode {
                        Text("Isolated review: this decision affects only the review workspace. Account access and sending remain disabled.")
                            .font(.callout).foregroundStyle(CRMTheme.rust)
                    }
                    Text("This owner decision permits all otherwise eligible external recipients in this Mac's native Resend workflow. It applies beyond a single prospect or message.")
                    Text("Each send still requires the exact recipient, subject and body to be reviewed and confirmed, with suppression, duplicate prevention and a provider receipt. Researched cold outreach also requires current contact and AI-use evidence. Auto-Pilot and reminders do not send outreach.")
                    Text("When you confirm a message, Resend receives the recipient, subject, body, sender and unsubscribe information. Public business details alone do not establish consent, personal-inbox ownership or delivery. Review the applicable contact basis, provider processing, retention and opt-out handling in your assessment.")
                    DisclosureGroup("Read the included assessment draft") {
                        IncludedOutreachPrivacyDraft().padding(.top, 8)
                    }
                    Button("Use the included draft's reference") {
                        assessmentReference = ResendRecipientDecision.assessmentDraftReference
                    }
                    Link("Latest web review (reader access required)", destination: ResendRecipientDecision.reviewURL)
                    Text("Record the title or reference of the assessment you reviewed. This records your ruling; it does not certify legal compliance. Enter a reference only, without passwords or API keys.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextField("Assessment title or reference", text: $assessmentReference).textFieldStyle(.roundedBorder)
                    Toggle("I reviewed the referenced assessment and approve this scope for external recipients", isOn: $confirmedScope)
                    Text("You can restrict recipients again in Settings. A successful change cancels message previews, including a confirmation waiting for credential access. A request already issued to Resend cannot be undone here.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let failure = store.resendRecipientDecisionFailure {
                        Text(failure).foregroundStyle(CRMTheme.rust)
                    }
                }.padding(.trailing, 4)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Allow reviewed external recipients") {
                    if store.recordResendRecipientDecision(allowExternal: true, assessmentReference: assessmentReference,
                                                           review: review, confirmed: confirmedScope) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!confirmedScope || !ResendRecipientDecision.validReference(assessmentReference))
            }
        }.padding(24).frame(width: 620, height: 620)
    }
}
