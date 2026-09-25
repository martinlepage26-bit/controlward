import AppKit
import CryptoKit
import Foundation
import FoundationModels
import OSLog
import UserNotifications
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var workspace: PersistentWorkspace
    @Published var notice: String?

    /// Connectors whose API key is in the secret store. The key itself is never held here.
    @Published private(set) var savedKeys: Set<SyncTarget> = []
    @Published private(set) var busyTargets: Set<SyncTarget> = []
    /// Dry-run result that must exist before a Twenty push is allowed.
    @Published private(set) var twentyPreview: TwentyPlan?

    let storageURL: URL
    let secrets: SecretStore
    let transport: HTTPTransport
    var twentyPacing: Duration = .milliseconds(700)
    var twentyMaxBackoffSeconds: Double = 30
    private var noticeTask: Task<Void, Never>?

    init(storageURL: URL = StorageLocation.workspaceFile, secrets: SecretStore = KeychainSecretStore(), transport: HTTPTransport = URLSessionTransport()) {
        self.storageURL = storageURL
        self.secrets = secrets
        self.transport = transport
        self.workspace = Self.load(from: storageURL)
        self.savedKeys = Set(SyncTarget.keyed.filter { secrets.exists($0) })
        if FileManager.default.fileExists(atPath: storageURL.path) {
            try? SecureFiles.ensurePrivateDirectory(storageURL.deletingLastPathComponent())
            try? SecureFiles.restrict(storageURL)
        }
        scrubStoredEndpointSecrets()
        Self.log.notice("Loaded workspace (sandboxed: \(StorageLocation.isSandboxed, privacy: .public)): leads=\(self.workspace.leads.count, privacy: .public) contacts=\(self.workspace.contacts.count, privacy: .public) companies=\(self.workspace.companies.count, privacy: .public) tasks=\(self.workspace.tasks.count, privacy: .public)")
    }

    private static let log = Logger(subsystem: "com.pharos.contextward", category: "storage")

    /// Endpoints saved before the secret filter existed may contain credentials. Remove them once.
    private func scrubStoredEndpointSecrets() {
        var changed = false
        for (key, value) in workspace.connectorEndpoints {
            guard let result = EndpointPolicy.sanitize(value) else { continue }
            if result.removedSecrets { workspace.connectorEndpoints[key] = result.url; changed = true }
        }
        if changed { persist(message: "Removed credentials from saved endpoint URLs.") }
    }

    var business: BusinessProfile { workspace.business }
    var leads: [Lead] { workspace.leads }
    var contacts: [Contact] { workspace.contacts }
    var companies: [Company] { workspace.companies }
    var opportunities: [Opportunity] { workspace.opportunities }
    var tasks: [CRMTask] { workspace.tasks }
    var notes: [CRMNote] { workspace.notes }
    var signals: [Signal] { workspace.signals }
    var audits: [BilingualAudit] { workspace.audits }
    var automationRules: [AutomationRule] { workspace.automationRules }
    var activity: [ActivityEvent] { workspace.activity }
    var syncJobs: [SyncJob] { workspace.syncJobs }
    var exposureFindings: [ExposureFinding] { workspace.exposureFindings }
    func endpoint(for target: SyncTarget) -> String { workspace.connectorEndpoints[target.rawValue] ?? "" }

    /// Saves an endpoint without its secret parts. `user:pass@` and token-like
    /// query items are removed before anything is persisted.
    func setEndpoint(_ endpoint: String, for target: SyncTarget) {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            workspace.connectorEndpoints.removeValue(forKey: target.rawValue)
            invalidateConnector(target)
            persist(message: "\(target.label) endpoint cleared.")
            return
        }
        guard let result = EndpointPolicy.sanitize(value) else {
            showNotice("\(target.label) endpoint must be an http or https URL. Nothing was saved.")
            return
        }
        if workspace.connectorEndpoints[target.rawValue] != result.url { invalidateConnector(target) }
        workspace.connectorEndpoints[target.rawValue] = result.url
        persist(message: result.removedSecrets
            ? "\(target.label) endpoint saved without its credentials. Keep secrets in the adapter, not in the URL."
            : "\(target.label) endpoint saved.")
    }

    func probeEndpoint(_ target: SyncTarget) async {
        let raw = endpoint(for: target)
        guard let result = EndpointPolicy.sanitize(raw), let url = URL(string: result.url) else {
            showNotice("\(target.label) endpoint is not a valid HTTP URL.")
            return
        }
        guard !result.removedSecrets else {
            showNotice("\(target.label) endpoint contains credentials. Save it again without them before testing.")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                showNotice("\(target.label) preflight returned HTTP \(http.statusCode). No data was sent.")
            } else { showNotice("\(target.label) responded without an HTTP status.") }
        } catch { showNotice("\(target.label) preflight failed: \(error.localizedDescription)") }
    }

    // MARK: - Connectors (API keys, status, PHAROS push, Twenty push)

    private static let syncLog = Logger(subsystem: "com.pharos.contextward", category: "sync")

    func hasKey(_ target: SyncTarget) -> Bool { savedKeys.contains(target) }

    func connectorStatus(_ target: SyncTarget) -> ConnectorStatus {
        ConnectorStatus.resolve(endpoint: endpoint(for: target), hasKey: hasKey(target), health: workspace.connectorHealth[target.rawValue])
    }

    /// Saves or replaces a key in the Keychain. The key never enters workspace data, activity, or logs.
    func setAPIKey(_ key: String, for target: SyncTarget) {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { showNotice("\(target.label) key is empty. Nothing was saved."); return }
        do {
            try secrets.write(value, for: target)
            savedKeys.insert(target)
            invalidateConnector(target)
            workspace.activity.insert(ActivityEvent(kind: "credential", message: "Saved the \(target.label) API key to the Keychain."), at: 0)
            persist(message: "\(target.label) key saved to the Keychain. Run Verify to activate it.")
        } catch {
            showNotice("Could not save the \(target.label) key: \(error.localizedDescription)")
        }
    }

    func removeAPIKey(for target: SyncTarget) {
        do {
            try secrets.delete(target)
            savedKeys.remove(target)
            invalidateConnector(target)
            workspace.activity.insert(ActivityEvent(kind: "credential", message: "Removed the \(target.label) API key from the Keychain."), at: 0)
            persist(message: "\(target.label) key removed from the Keychain.")
        } catch {
            showNotice("Could not remove the \(target.label) key: \(error.localizedDescription)")
        }
    }

    private func invalidateConnector(_ target: SyncTarget) {
        workspace.connectorHealth.removeValue(forKey: target.rawValue)
        if target == .twenty { twentyPreview = nil }
    }

    private func recordHealth(_ target: SyncTarget, ok: Bool, detail: String) {
        workspace.connectorHealth[target.rawValue] = ConnectorHealth(ok: ok, detail: detail)
    }

    private func apiKey(for target: SyncTarget) throws -> String {
        guard let key = try secrets.read(target), !key.isEmpty else { throw IntegrationError.missingKey }
        return key
    }

    private func pharosClient() throws -> PharosClient {
        try PharosClient(endpoint: endpoint(for: .pharos), apiKey: try apiKey(for: .pharos), transport: transport)
    }

    private func twentyClient() throws -> TwentyClient {
        try TwentyClient(endpoint: endpoint(for: .twenty), apiKey: try apiKey(for: .twenty), transport: transport,
                         interval: twentyPacing, maxBackoffSeconds: twentyMaxBackoffSeconds)
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Authenticated check. PHAROS: health plus key check. Twenty: authenticated GET.
    /// Status becomes Active only when this (or a real push) succeeds.
    @discardableResult
    func verifyConnector(_ target: SyncTarget) async -> Bool {
        guard SyncTarget.keyed.contains(target) else { await probeEndpoint(target); return false }
        busyTargets.insert(target); defer { busyTargets.remove(target) }
        do {
            switch target {
            case .pharos: try await pharosClient().verify()
            case .twenty: try await twentyClient().verify()
            case .leadgen: break
            }
            recordHealth(target, ok: true, detail: "Verified \(Date.now.formatted(date: .abbreviated, time: .shortened)): endpoint reachable and key accepted.")
            Self.syncLog.notice("verify target=\(target.rawValue, privacy: .public) ok")
            persist(message: "\(target.label) verified. The key is accepted.")
            return true
        } catch {
            let reason = message(for: error)
            recordHealth(target, ok: false, detail: reason)
            Self.syncLog.error("verify target=\(target.rawValue, privacy: .public) failed")
            persist(message: "\(target.label) check failed: \(reason)")
            return false
        }
    }

    /// Pushes the current exchange snapshot to the PHAROS backend. The Idempotency-Key
    /// is derived from record content, so re-sending unchanged data is deduplicated server-side.
    @discardableResult
    func syncToPharos() async -> SyncJob {
        let snapshot = exchange
        let key = ExchangeFingerprint.idempotencyKey(for: snapshot)
        var job = SyncJob(target: .pharos, status: "sending", idempotencyKey: key)
        workspace.syncJobs.insert(job, at: 0)
        busyTargets.insert(.pharos); defer { busyTargets.remove(.pharos) }
        do {
            let client = try pharosClient()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let receipt = try await client.push(try encoder.encode(snapshot), idempotencyKey: key)
            job.status = "synced"
            job.detail = receipt.duplicate == true
                ? "Already stored (same Idempotency-Key); receipt \(receipt.receipt ?? "n/a")."
                : "Stored; receipt \(receipt.receipt ?? "n/a")."
            recordHealth(.pharos, ok: true, detail: "Last push \(Date.now.formatted(date: .abbreviated, time: .shortened)) stored by the backend.")
            Self.syncLog.notice("pharos push ok duplicate=\(receipt.duplicate == true, privacy: .public)")
        } catch {
            job.status = "failed"
            job.error = message(for: error)
            recordHealth(.pharos, ok: false, detail: job.error ?? "Push failed.")
            Self.syncLog.error("pharos push failed")
        }
        job.completedAt = Date.now.ISO8601Format()
        replace(&workspace.syncJobs, with: job)
        workspace.activity.insert(ActivityEvent(kind: "sync", message: job.status == "synced"
            ? "Pushed the exchange snapshot to the PHAROS backend. \(job.detail ?? "")"
            : "PHAROS push failed: \(job.error ?? "unknown error")", sourceID: job.id), at: 0)
        persist(message: job.status == "synced" ? "Synced to PHAROS. \(job.detail ?? "")" : "PHAROS sync failed: \(job.error ?? "")")
        return job
    }

    /// Dry run: counts what a Twenty push would create, update, or skip. No network call.
    @discardableResult
    func previewTwentyPush() -> TwentyPlan {
        let plan = TwentyMapper.plan(workspace, links: workspace.twentyLinks)
        twentyPreview = plan
        showNotice("Twenty preview: \(plan.creates) to create, \(plan.updates) to update, \(plan.unchangedTotal) unchanged.")
        return plan
    }

    /// Pushes companies, people, opportunities, then tasks. Requires a preview first.
    /// Creates store the returned Twenty id immediately so a retry never duplicates.
    /// Never deletes anything in Twenty.
    @discardableResult
    func pushToTwenty() async -> SyncJob {
        var job = SyncJob(target: .twenty, status: "sending")
        guard twentyPreview != nil else {
            job.status = "failed"; job.error = "Run the preview before pushing."
            showNotice("Preview the Twenty push first.")
            return job
        }
        workspace.syncJobs.insert(job, at: 0)
        busyTargets.insert(.twenty); defer { busyTargets.remove(.twenty) }
        var created = 0, updated = 0
        do {
            let client = try twentyClient()
            for object in TwentyObject.allCases {
                for operation in TwentyMapper.plan(workspace, links: workspace.twentyLinks, only: object).operations {
                    var id = operation.twentyID
                    if let existing = id, try await client.update(object, id: existing, operation.payload) {
                        updated += 1
                    } else {
                        // New record, or the linked record no longer exists in Twenty.
                        id = try await client.create(object, operation.payload)
                        created += 1
                    }
                    workspace.twentyLinks[operation.localKey] = TwentyLink(twentyID: id ?? "", object: object, payloadHash: operation.payloadHash)
                    persist()
                }
            }
            job.status = "synced"
            job.detail = "\(created) created, \(updated) updated."
            recordHealth(.twenty, ok: true, detail: "Last push \(Date.now.formatted(date: .abbreviated, time: .shortened)): \(job.detail ?? "")")
            Self.syncLog.notice("twenty push ok created=\(created, privacy: .public) updated=\(updated, privacy: .public)")
        } catch {
            job.status = "failed"
            job.error = "\(message(for: error)) Progress kept: \(created) created, \(updated) updated."
            recordHealth(.twenty, ok: false, detail: message(for: error))
            Self.syncLog.error("twenty push failed created=\(created, privacy: .public) updated=\(updated, privacy: .public)")
        }
        twentyPreview = nil
        job.completedAt = Date.now.ISO8601Format()
        replace(&workspace.syncJobs, with: job)
        workspace.activity.insert(ActivityEvent(kind: "sync", message: job.status == "synced"
            ? "Pushed to Twenty: \(job.detail ?? "")" : "Twenty push failed: \(job.error ?? "")", sourceID: job.id), at: 0)
        persist(message: job.status == "synced" ? "Twenty push complete: \(job.detail ?? "")" : "Twenty push failed: \(job.error ?? "")")
        return job
    }

    var qualifiedSignals: [Signal] { signals.filter { $0.status == .qualified || $0.status == .routed }.sorted { $0.priority > $1.priority } }
    var averageLanguageGap: Double {
        guard !audits.isEmpty else { return 0 }
        return audits.map(\.languageGap).reduce(0, +) / Double(audits.count)
    }

    var closeRate: Int {
        let closed = leads.filter { $0.status == .won || $0.status == .lost }
        guard !closed.isEmpty else { return 0 }
        return Int((Double(closed.filter { $0.status == .won }.count) / Double(closed.count) * 100).rounded())
    }

    var dollarsWon: Double {
        leads.filter { $0.status == .won }.compactMap(\.quoteAmount).reduce(0, +)
    }

    var activePipeline: Double {
        let native = opportunities.filter { !$0.stage.isClosed }.compactMap(\.amount).reduce(0, +)
        return native + leads.filter { $0.status.isOpen }.compactMap(\.quoteAmount).reduce(0, +)
    }

    var openTasks: [CRMTask] {
        tasks.filter { $0.status != .done }.sorted { ($0.dueDate ?? "9999") < ($1.dueDate ?? "9999") }
    }

    var dueLeads: [Lead] {
        let today = CalendarCRM.dayString()
        return leads
            .filter { $0.status.isOpen && ($0.nextFollowUp ?? "9999-99-99") <= today }
            .sorted { ($0.quoteAmount ?? 0) > ($1.quoteAmount ?? 0) }
    }

    func filteredLeads(filter: PipelineFilter, search: String) -> [Lead] {
        leads.filter { lead in
            let statusMatch: Bool = switch filter {
            case .open: lead.status.isOpen
            case .all: true
            case .won: lead.status == .won
            case .lost: lead.status == .lost
            }
            guard statusMatch else { return false }
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !query.isEmpty else { return true }
            return [lead.name, lead.company, lead.service, lead.email]
                .contains { $0.lowercased().contains(query) }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func createWorkspace(name: String, industry: String) {
        workspace.business = BusinessProfile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            industry: industry
        )
        persist(message: "Workspace created.")
    }

    func saveBusiness(_ business: BusinessProfile) {
        workspace.business = business
        persist(message: "Settings saved.")
    }

    func add(_ lead: Lead) {
        workspace.leads.insert(lead, at: 0)
        persist(message: "\(lead.name) added.")
    }

    func add(_ contact: Contact) { workspace.contacts.insert(contact, at: 0); persist(message: "Contact added.") }
    func update(_ contact: Contact) { replace(&workspace.contacts, with: contact); persist(message: "Contact saved.") }
    func delete(_ contact: Contact) { workspace.contacts.removeAll { $0.id == contact.id }; persist(message: "Contact deleted.") }

    func add(_ company: Company) { workspace.companies.insert(company, at: 0); persist(message: "Company added.") }
    func update(_ company: Company) { replace(&workspace.companies, with: company); persist(message: "Company saved.") }
    func delete(_ company: Company) { workspace.companies.removeAll { $0.id == company.id }; persist(message: "Company deleted.") }

    func add(_ opportunity: Opportunity) { workspace.opportunities.insert(opportunity, at: 0); persist(message: "Opportunity added.") }
    func update(_ opportunity: Opportunity) { replace(&workspace.opportunities, with: opportunity); persist(message: "Opportunity saved.") }
    func delete(_ opportunity: Opportunity) { workspace.opportunities.removeAll { $0.id == opportunity.id }; persist(message: "Opportunity deleted.") }

    func add(_ task: CRMTask) { workspace.tasks.insert(task, at: 0); persist(message: "Task added.") }
    func update(_ task: CRMTask) { replace(&workspace.tasks, with: task); persist(message: "Task saved.") }
    func delete(_ task: CRMTask) { workspace.tasks.removeAll { $0.id == task.id }; persist(message: "Task deleted.") }

    func add(_ note: CRMNote) { workspace.notes.insert(note, at: 0); persist(message: "Note added.") }
    func update(_ note: CRMNote) { replace(&workspace.notes, with: note); persist(message: "Note saved.") }
    func delete(_ note: CRMNote) { workspace.notes.removeAll { $0.id == note.id }; persist(message: "Note deleted.") }

    func add(_ signal: Signal) { workspace.signals.insert(signal, at: 0); persist(message: "Signal captured.") }
    func update(_ signal: Signal) { replace(&workspace.signals, with: signal); persist(message: "Signal saved.") }
    func delete(_ signal: Signal) { workspace.signals.removeAll { $0.id == signal.id }; persist(message: "Signal deleted.") }

    func add(_ audit: BilingualAudit) { workspace.audits.insert(audit, at: 0); persist(message: "Lantern audit saved.") }
    func update(_ audit: BilingualAudit) { replace(&workspace.audits, with: audit); persist(message: "Lantern audit updated.") }
    func delete(_ audit: BilingualAudit) { workspace.audits.removeAll { $0.id == audit.id }; persist(message: "Lantern audit deleted.") }

    func setAutomation(_ rule: AutomationRule, enabled: Bool) {
        var updated = rule
        updated.enabled = enabled
        replace(&workspace.automationRules, with: updated)
        persist(message: enabled ? "Automation enabled." : "Automation paused.")
    }

    /// Runs only deterministic, local actions. No network calls, message sends, or external mutations occur here.
    @discardableResult
    func runAutomations() -> Int {
        var created = 0
        let today = CalendarCRM.dayString()
        if automationRules.contains(where: { $0.enabled && $0.trigger == .dueFollowUp }) {
            for lead in dueLeads {
                let alreadyExists = tasks.contains { task in
                    task.title == "Follow up with \(lead.name)" && task.dueDate == today && task.status != .done
                }
                guard !alreadyExists else { continue }
                workspace.tasks.insert(CRMTask(title: "Follow up with \(lead.name)", details: lead.lastMessage.isEmpty ? "Review the relationship record and send the next appropriate follow-up." : lead.lastMessage, dueDate: today, leadID: lead.id), at: 0)
                workspace.activity.insert(ActivityEvent(kind: "automation", message: "Created a follow-up task for \(lead.name).", sourceID: lead.id), at: 0)
                created += 1
            }
        }
        if automationRules.contains(where: { $0.enabled && $0.trigger == .highIntentSignal }) {
            for signal in signals where signal.status == .captured && signal.intentScore >= 70 && signal.fitScore >= 70 {
                var routed = signal
                routed.status = .qualified
                routed.owner = routed.owner.isEmpty ? business.name : routed.owner
                workspace.signals[workspace.signals.firstIndex(where: { $0.id == signal.id })!] = routed
                workspace.activity.insert(ActivityEvent(kind: "automation", message: "Qualified high-intent signal: \(signal.title).", sourceID: signal.id), at: 0)
                created += 1
            }
        }
        if automationRules.contains(where: { $0.enabled && $0.trigger == .auditGap }) {
            for audit in audits where audit.languageGap >= 8 {
                let title = "Remediate Lantern gap: \(audit.name)"
                let alreadyExists = tasks.contains { $0.title == title && $0.status != .done }
                guard !alreadyExists else { continue }
                workspace.tasks.insert(CRMTask(title: title, details: audit.remediation.isEmpty ? "Review evidence and define a human-approved remediation plan." : audit.remediation, dueDate: today), at: 0)
                workspace.activity.insert(ActivityEvent(kind: "automation", message: "Flagged \(audit.priority.lowercased()) bilingual gap for remediation.", sourceID: audit.id), at: 0)
                created += 1
            }
        }
        persist(message: created == 0 ? "No new automation actions." : "Ran automations: \(created) action\(created == 1 ? "" : "s").")
        return created
    }

    func route(_ signal: Signal, owner: String) {
        var routed = signal
        routed.status = .routed
        routed.owner = owner
        routed.routedAt = Date.now.ISO8601Format()
        update(routed)
    }

    func add(_ view: SavedView) { workspace.savedViews.append(view); persist(message: "View saved.") }
    func delete(_ view: SavedView) {
        workspace.savedViews.removeAll { $0.id == view.id }
        persist(message: "View deleted.")
    }

    private func replace<T: Identifiable>(_ collection: inout [T], with value: T) where T.ID: Equatable {
        guard let index = collection.firstIndex(where: { $0.id == value.id }) else { return }
        collection[index] = value
    }

    func update(_ lead: Lead) {
        guard let index = workspace.leads.firstIndex(where: { $0.id == lead.id }) else { return }
        workspace.leads[index] = lead
        persist(message: "Lead saved.")
    }

    func delete(_ lead: Lead) {
        workspace.leads.removeAll { $0.id == lead.id }
        persist(message: "Lead deleted.")
    }

    func markSecurityReviewed() {
        workspace.lastSecurityReview = Date.now.ISO8601Format()
        persist(message: "Local record review saved.")
    }

    enum ResetError: LocalizedError {
        case notConfirmed
        var errorDescription: String? { "Reset needs explicit confirmation." }
    }

    /// Erases the workspace only when confirmed, after writing a timestamped
    /// mode-600 backup next to workspace.json. If the backup fails, nothing is erased.
    @discardableResult
    func resetAll(confirmed: Bool) throws -> URL {
        guard confirmed else { throw ResetError.notConfirmed }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backup = storageURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-backup-\(formatter.string(from: .now)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFiles.writePrivate(try encoder.encode(workspace), to: backup)
        workspace = PersistentWorkspace()
        persist(message: "Workspace reset. Backup saved as \(backup.lastPathComponent).")
        return backup
    }

    /// One-time, user-selected import of the pre-sandbox `native-crm/data/workspace.json`.
    func importLegacyWorkspace(from legacy: URL) throws {
        let outcome = try WorkspaceMigration.migrateLegacy(from: legacy, to: storageURL)
        workspace = Self.load(from: storageURL)
        scrubStoredEndpointSecrets()
        showNotice(outcome.legacyRestricted
            ? "Imported and hash-verified the legacy workspace. The original was kept and set to owner-only access."
            : "Imported and hash-verified the legacy workspace. The original was kept; run chmod 600 on it manually.")
    }

    var exchange: WorkspaceExchange {
        WorkspaceExchange(
            business: business, leads: leads, contacts: contacts, companies: companies,
            opportunities: opportunities, tasks: tasks, notes: notes, signals: signals,
            audits: audits, activity: activity, syncJobs: syncJobs, exposureFindings: exposureFindings, connectorEndpoints: workspace.connectorEndpoints
        )
    }

    func exportExchange(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(exchange).write(to: url, options: .atomic)
        try? SecureFiles.restrict(url)
        workspace.activity.insert(ActivityEvent(kind: "export", message: "Exported Contextward exchange snapshot."), at: 0)
        persist(message: "Exchange snapshot exported.")
    }

    /// Merges a versioned exchange snapshot by UUID. Existing local records win;
    /// new records are appended. No deletions or external writes occur.
    @discardableResult
    func importExchange(from url: URL) throws -> Int {
        let data = try ImportLimits.readCapped(url)
        let incoming = try JSONDecoder().decode(WorkspaceExchange.self, from: data)
        guard incoming.schemaVersion == "contextward.exchange.v1" else {
            throw NSError(domain: "ContextwardImport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported exchange schema: \(incoming.schemaVersion)"])
        }
        for count in [incoming.leads.count, incoming.contacts.count, incoming.companies.count, incoming.opportunities.count,
                      incoming.tasks.count, incoming.notes.count, incoming.signals.count, incoming.audits.count, incoming.exposureFindings.count] {
            try ImportLimits.checkRows(count, url.lastPathComponent)
        }
        var added = 0
        func merge<T: Identifiable>(_ source: [T], into destination: inout [T]) where T.ID: Equatable {
            for record in source where !destination.contains(where: { $0.id == record.id }) { destination.append(record); added += 1 }
        }
        if business.name.isEmpty { workspace.business = incoming.business }
        merge(incoming.leads, into: &workspace.leads)
        merge(incoming.contacts, into: &workspace.contacts)
        merge(incoming.companies, into: &workspace.companies)
        merge(incoming.opportunities, into: &workspace.opportunities)
        merge(incoming.tasks, into: &workspace.tasks)
        merge(incoming.notes, into: &workspace.notes)
        merge(incoming.signals, into: &workspace.signals)
        merge(incoming.audits, into: &workspace.audits)
        merge(incoming.exposureFindings, into: &workspace.exposureFindings)
        workspace.activity.insert(ActivityEvent(kind: "import", message: "Merged \(added) records from exchange snapshot."), at: 0)
        persist(message: "Merged \(added) exchange record\(added == 1 ? "" : "s").")
        return added
    }

    /// Queues an explicit, credential-free sync intent for a future adapter. It never performs a network write.
    func queueSync(to target: SyncTarget) {
        workspace.syncJobs.insert(SyncJob(target: target), at: 0)
        workspace.activity.insert(ActivityEvent(kind: "sync", message: "Queued a reviewable snapshot for \(target.label)."), at: 0)
        persist(message: "\(target.label) sync queued for review.")
    }

    /// Materializes queued sync intents as reviewable JSON outbox packages.
    /// This is the adapter handoff boundary; it performs no network operation.
    private var outboxDirectory: URL { storageURL.deletingLastPathComponent().appendingPathComponent("outbox", isDirectory: true) }

    private func outboxFiles(for job: SyncJob) -> [URL] {
        let stem = "\(job.target.rawValue)-\(job.id.uuidString)"
        return [outboxDirectory.appendingPathComponent("\(stem).json"), outboxDirectory.appendingPathComponent("\(stem).manifest.json")]
    }

    /// Outbox packages hold a full PII snapshot, so they live in a mode-700
    /// directory as mode-600 files and are deleted once synced or discarded.
    @discardableResult
    func stageSyncOutbox() -> Int {
        let outbox = outboxDirectory
        do { try SecureFiles.ensurePrivateDirectory(outbox) }
        catch { showNotice("Could not create sync outbox: \(error.localizedDescription)"); return 0 }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var staged = 0
        for job in syncJobs where job.status == "queued" {
            let files = outboxFiles(for: job)
            do {
                try SecureFiles.writePrivate(try encoder.encode(exchange), to: files[0])
                let manifest = syncManifest(for: job)
                try SecureFiles.writePrivate(try encoder.encode(manifest), to: files[1])
                var updated = job; updated.status = "staged"; updated.completedAt = Date.now.ISO8601Format()
                replace(&workspace.syncJobs, with: updated)
                workspace.activity.insert(ActivityEvent(kind: "sync", message: "Staged \(job.target.label) outbox package for adapter review.", sourceID: job.id), at: 0)
                staged += 1
            } catch {
                var failed = job; failed.status = "failed"; failed.error = error.localizedDescription
                replace(&workspace.syncJobs, with: failed)
            }
        }
        persist(message: staged == 0 ? "No queued sync packages." : "Staged \(staged) sync outbox package\(staged == 1 ? "" : "s").")
        return staged
    }

    private func deletePackage(for job: SyncJob, status: String) {
        for file in outboxFiles(for: job) where FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.removeItem(at: file)
        }
        var updated = job; updated.status = status; updated.completedAt = Date.now.ISO8601Format()
        replace(&workspace.syncJobs, with: updated)
    }

    /// Adapter hook: call after a staged package was delivered. Deletes the package.
    func markSynced(_ job: SyncJob) {
        deletePackage(for: job, status: "synced")
        workspace.activity.insert(ActivityEvent(kind: "sync", message: "Delivered \(job.target.label) package; local copy deleted.", sourceID: job.id), at: 0)
        persist(message: "\(job.target.label) package synced and deleted from the outbox.")
    }

    /// Deletes every staged package that was not delivered.
    @discardableResult
    func discardStagedPackages() -> Int {
        let staged = syncJobs.filter { $0.status == "staged" }
        for job in staged { deletePackage(for: job, status: "discarded") }
        if !staged.isEmpty {
            workspace.activity.insert(ActivityEvent(kind: "sync", message: "Discarded \(staged.count) staged outbox package\(staged.count == 1 ? "" : "s")."), at: 0)
        }
        persist(message: staged.isEmpty ? "No staged packages to discard." : "Discarded and deleted \(staged.count) outbox package\(staged.count == 1 ? "" : "s").")
        return staged.count
    }

    func syncManifest(for job: SyncJob) -> SyncManifest {
        let material = "\(job.target.rawValue):\(job.id.uuidString):\(exchange.schemaVersion)"
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return SyncManifest(target: job.target, jobID: job.id, idempotencyKey: "ctx_\(digest.prefix(32))", entityCounts: [
            "leads": leads.count, "contacts": contacts.count, "companies": companies.count,
            "opportunities": opportunities.count, "tasks": tasks.count, "notes": notes.count,
            "signals": signals.count, "audits": audits.count, "findings": exposureFindings.count,
        ])
    }

    /// Local-only Pharos hygiene scan. This is a data-quality and exposure review,
    /// not a penetration test or external intelligence scan.
    @discardableResult
    func runLocalExposureScan() -> Int {
        workspace.exposureFindings.removeAll { !$0.resolved }
        let sensitiveTerms = ["password", "secret", "token", "ssn", "sin", "credit card", "api key"]
        for lead in leads {
            let text = "\(lead.notes) \(lead.lastMessage)".lowercased()
            if sensitiveTerms.contains(where: { text.contains($0) }) {
                workspace.exposureFindings.append(ExposureFinding(lens: "AI / Privacy Exposure", severity: .high, title: "Sensitive-looking text in lead record", detail: "Review and remove credentials or identity numbers from notes and messages.", recordID: lead.id))
            }
            if lead.email.isEmpty && lead.phone.isEmpty {
                workspace.exposureFindings.append(ExposureFinding(lens: "Identity Exposure", severity: .warning, title: "Lead lacks a contact channel", detail: "Confirm the source and retention need before keeping this record.", recordID: lead.id))
            }
        }
        for signal in signals where signal.evidence.isEmpty {
            workspace.exposureFindings.append(ExposureFinding(lens: "Digital Exposure", severity: .warning, title: "Signal has no evidence trail", detail: "Add the source event, file, or operator note before routing.", recordID: signal.id))
        }
        workspace.activity.insert(ActivityEvent(kind: "security_scan", message: "Ran local workspace exposure scan: \(workspace.exposureFindings.count) finding\(workspace.exposureFindings.count == 1 ? "" : "s")."), at: 0)
        persist(message: "Local exposure scan complete.")
        return workspace.exposureFindings.count
    }

    func resolve(_ finding: ExposureFinding) {
        guard let index = workspace.exposureFindings.firstIndex(where: { $0.id == finding.id }) else { return }
        workspace.exposureFindings[index].resolved = true
        persist(message: "Finding marked resolved.")
    }

    /// Schedules local macOS notifications for currently due follow-ups.
    /// It never sends email, SMS, or CRM messages.
    func scheduleDueFollowUpReminders() async -> Int {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else {
            showNotice("Notifications were not authorized.")
            return 0
        }
        var scheduled = 0
        for lead in dueLeads {
            let content = UNMutableNotificationContent()
            content.title = "Follow up with \(lead.name)"
            content.body = lead.lastMessage.isEmpty ? "Review the record and choose the next appropriate action." : "Review the last follow-up and decide the next action."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "contextward-followup-\(lead.id.uuidString)", content: content, trigger: nil)
            try? await center.add(request)
            scheduled += 1
        }
        showNotice(scheduled == 0 ? "No due follow-ups to remind you about." : "Scheduled \(scheduled) local reminder\(scheduled == 1 ? "" : "s").")
        return scheduled
    }

    func importCSV(from url: URL) throws -> Int {
        let rows = CSVParser.parse(try ImportLimits.readCappedText(url))
        guard rows.count >= 2 else { return 0 }
        try ImportLimits.checkRows(rows.count - 1, url.lastPathComponent)
        // Exact header names or known alternatives only; unknown columns are ignored.
        let fields = rows[0].map(CSVHeaderMap.field(for:))
        var imported: [Lead] = []

        for row in rows.dropFirst() where !row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            var lead = Lead.blank()
            lead.name = "Unknown"
            var firstName = "", lastName = ""
            for (index, field) in fields.enumerated() {
                guard let field else { continue }
                let value = index < row.count ? row[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                switch field {
                case .name: lead.name = value
                case .firstName: firstName = value
                case .lastName: lastName = value
                case .email: lead.email = value
                case .phone: lead.phone = value
                case .company: lead.company = value
                case .service: lead.service = value
                case .amount:
                    let numeric = value.filter { $0.isNumber || $0 == "." }
                    lead.quoteAmount = Double(numeric)
                case .date:
                    if let date = CalendarCRM.date(from: value) { lead.createdAt = date.ISO8601Format() }
                }
            }
            if lead.name == "Unknown" || lead.name.isEmpty {
                let combined = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
                if !combined.isEmpty { lead.name = combined }
            }
            if lead.name != "Unknown", !lead.name.isEmpty { imported.append(lead) }
        }

        workspace.leads.insert(contentsOf: imported, at: 0)
        persist(message: imported.isEmpty ? "No valid leads found in CSV." : "Imported \(imported.count) leads from CSV.")
        return imported.count
    }

    /// Imports exported LeadGen stage payloads without making a network request.
    /// Accepts one object or an array, and preserves the source filename in evidence.
    func importLeadGenJSON(from url: URL) throws -> Int {
        let events = try LeadGenEvent.decodeBatch(try ImportLimits.readCapped(url), source: url.lastPathComponent)

        var imported = 0
        for event in events {
            let identity = event.identity
            let name = [identity.firstName, identity.lastName].compactMap { $0 }.joined(separator: " ")
            let email = identity.email ?? event.email ?? ""
            guard !name.isEmpty || !email.isEmpty else { continue }

            var lead = Lead.blank()
            lead.name = name.isEmpty ? email : name
            lead.email = email
            lead.phone = identity.phoneRaw ?? ""
            lead.company = identity.companyNameRaw ?? ""
            lead.createdAt = event.capturedAt ?? lead.createdAt
            workspace.leads.insert(lead, at: 0)

            var signal = Signal()
            signal.title = "LeadGen: \(lead.name)"
            signal.source = .manual
            signal.status = .captured
            signal.leadID = lead.id
            signal.evidence = "Imported from \(url.lastPathComponent). Event ID: \(event.eventID ?? "not supplied")."
            signal.nextAction = "Resolve identity, qualify fit, and route."
            signal.fitScore = min(max(event.fitScore ?? 0, 0), 100)
            signal.intentScore = min(max(event.intentScore ?? 0, 0), 100)
            signal.priority = min(max(event.compositeScore ?? ((signal.fitScore + signal.intentScore) / 2), 0), 100)
            workspace.signals.insert(signal, at: 0)
            workspace.activity.insert(ActivityEvent(kind: "import", message: "Imported LeadGen event for \(lead.name).", sourceID: signal.id), at: 0)
            imported += 1
        }
        persist(message: imported == 0 ? "No LeadGen events found." : "Imported \(imported) LeadGen event\(imported == 1 ? "" : "s").")
        return imported
    }

    /// Imports a flat BAEA export. Expected columns include audit, client, language,
    /// disclosure, escalation, context_transfer, tone, hallucinations, sample_size.
    func importBAEACSV(from url: URL) throws -> Int {
        let rows = CSVParser.parse(try ImportLimits.readCappedText(url))
        try ImportLimits.checkRows(rows.count - 1, url.lastPathComponent)
        return importBAEARows(rows, source: url.lastPathComponent)
    }

    /// Reads the first worksheet of a BAEA .xlsx export with an in-process ZIP reader and XMLParser.
    /// This intentionally supports the workbook's flat score-table shape without adding a third-party runtime.
    func importBAEAXLSX(from url: URL) throws -> Int {
        let archive = try ImportLimits.readCapped(url)
        // Excel writes shared strings; openpyxl and others may use inline strings instead.
        let strings = try zipText(archive, entry: "xl/sharedStrings.xml", required: false).map(XLSXXMLParser.sharedStrings) ?? []
        let overview = XLSXXMLParser.rows(try zipText(archive, entry: "xl/worksheets/sheet1.xml") ?? "", sharedStrings: strings)
        try ImportLimits.checkRows(overview.count - 1, url.lastPathComponent)
        let directCount = importBAEARows(overview, source: url.lastPathComponent)
        if directCount > 0 { return directCount }

        // Canonical BAEA workbooks store one scored transcript per row on EN_Transcripts and FR_Transcripts.
        var normalized = [["audit", "client", "language", "disclosure", "escalation", "context_transfer", "tone", "hallucinations", "sample_size"]]
        for (sheetNumber, language) in [(2, "EN"), (3, "FR")] {
            let rows = XLSXXMLParser.rows(try zipText(archive, entry: "xl/worksheets/sheet\(sheetNumber).xml") ?? "", sharedStrings: strings)
            try ImportLimits.checkRows(normalized.count + rows.count - 1, url.lastPathComponent)
            for row in rows.dropFirst() where row.count >= 8 && !row[0].isEmpty {
                func scaled(_ index: Int) -> String { String((Double(row[index]) ?? 0) * 20) }
                normalized.append([url.deletingPathExtension().lastPathComponent, url.deletingPathExtension().lastPathComponent, language, scaled(3), scaled(4), scaled(5), scaled(6), scaled(7), "1"])
            }
        }
        return importBAEARows(normalized, source: url.lastPathComponent)
    }

    private func importBAEARows(_ rows: [[String]], source: String) -> Int {
        guard rows.count > 1 else { return 0 }
        let headers = rows[0].map { $0.lowercased().replacingOccurrences(of: " ", with: "_") }
        var grouped: [String: BilingualAudit] = [:]
        for row in rows.dropFirst() {
            func value(_ names: String...) -> String {
                for name in names { if let i = headers.firstIndex(of: name), i < row.count { return row[i].trimmingCharacters(in: .whitespacesAndNewlines) } }
                return ""
            }
            let auditName = value("audit", "audit_name")
            guard !auditName.isEmpty else { continue }
            var audit = grouped[auditName] ?? BilingualAudit(name: auditName, client: value("client"))
            let language = value("language").uppercased()
            var score = language == "FR" ? audit.french : audit.english
            score.disclosure = Int(value("disclosure")) ?? score.disclosure
            score.escalation = Int(value("escalation")) ?? score.escalation
            score.contextTransfer = Int(value("context_transfer", "context")) ?? score.contextTransfer
            score.tone = Int(value("tone", "tone_register")) ?? score.tone
            score.hallucinations = Int(value("hallucinations", "hallucination")) ?? score.hallucinations
            if language == "FR" { audit.french = score; audit.sampleSizeFR += Int(value("sample_size", "samples")) ?? 1 }
            else { audit.english = score; audit.sampleSizeEN += Int(value("sample_size", "samples")) ?? 1 }
            audit.transcripts.append(BAEATranscript(
                transcriptID: value("transcript_id", "id"),
                language: language == "FR" ? .french : .english,
                workflow: value("workflow"),
                date: value("date"),
                scores: score,
                taxonomyCodes: value("taxonomy_code(s)", "taxonomy_codes", "taxonomy"),
                notes: value("notes_/_quoted_excerpt", "notes", "quoted_excerpt"),
                source: source
            ))
            grouped[auditName] = audit
        }
        for audit in grouped.values {
            workspace.audits.removeAll { $0.name == audit.name }
            workspace.audits.insert(audit, at: 0)
            workspace.activity.insert(ActivityEvent(kind: "import", message: "Imported Lantern score export for \(audit.name) from \(source).", sourceID: audit.id), at: 0)
        }
        persist(message: grouped.isEmpty ? "No Lantern scores found." : "Imported \(grouped.count) Lantern audit\(grouped.count == 1 ? "" : "s").")
        return grouped.count
    }

    /// Reads one workbook entry in-process. Missing required entries keep the historical error.
    private func zipText(_ archive: Data, entry: String, required: Bool = true) throws -> String? {
        guard let data = try ZipReader.entry(entry, in: archive, maxBytes: ImportLimits.maxInflatedEntryBytes) else {
            if !required { return nil }
            throw NSError(domain: "ContextwardImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Workbook entry \(entry) could not be read."])
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ContextwardImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Workbook entry \(entry) is not UTF-8."])
        }
        return text
    }

    func generateMessage(for lead: Lead) async -> GeneratedMessage {
        let fallback = standardMessage(for: lead)
        guard #available(macOS 26.0, *) else {
            return GeneratedMessage(text: fallback, usedIntelligence: false)
        }
        return await generateOnDevice(for: lead, fallback: fallback)
    }

    @available(macOS 26.0, *)
    private func generateOnDevice(for lead: Lead, fallback: String) async -> GeneratedMessage {
        guard SystemLanguageModel.default.availability == .available else {
            return GeneratedMessage(text: fallback, usedIntelligence: false)
        }

        // Customer-controlled fields are delimited and declared as data (F14).
        let instructions = FollowUpPrompt.instructions
        let prompt = FollowUpPrompt.build(businessName: business.name, industry: business.industry, lead: lead)

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return GeneratedMessage(text: text.isEmpty ? fallback : text, usedIntelligence: !text.isEmpty)
        } catch {
            return GeneratedMessage(text: fallback, usedIntelligence: false)
        }
    }

    func standardMessage(for lead: Lead) -> String {
        let firstName = lead.name.split(separator: " ").first.map(String.init) ?? lead.name
        let subject = lead.service.isEmpty ? "quote" : lead.service
        let signature = business.name.isEmpty ? "the team" : business.name
        return """
        Hi \(firstName),

        Just checking in regarding the \(subject) I sent over. Let me know if you have any questions or if you'd like to discuss next steps.

        Best,
        \(signature)
        """
    }

    func markMessageSent(on lead: inout Lead, message: String) {
        let today = CalendarCRM.dayString()
        let stage = lead.sequenceStage
        let delay = stage < FollowUpCadence.days.count ? FollowUpCadence.days[stage] : nil
        lead.lastMessage = message
        lead.sequenceStage = min(stage + 1, FollowUpCadence.days.count)
        lead.nextFollowUp = delay.flatMap { CalendarCRM.addDays($0, to: today) }
        lead.history.append(FollowUpEvent(date: today, message: message))
        update(lead)
    }

    private static func load(from url: URL) -> PersistentWorkspace {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PersistentWorkspace.self, from: data)
        else { return PersistentWorkspace() }
        return decoded
    }

    private func persist(message: String? = nil) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try SecureFiles.writePrivate(try encoder.encode(workspace), to: storageURL)
            if let message { showNotice(message) }
        } catch {
            showNotice("Could not save CRM data: \(error.localizedDescription)")
        }
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

struct GeneratedMessage: Equatable {
    var text: String
    var usedIntelligence: Bool
}

enum CSVParser {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if quoted, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    quoted.toggle()
                }
            } else if character == ",", !quoted {
                row.append(field)
                field = ""
            } else if (character == "\n" || character == "\r"), !quoted {
                if character == "\r" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\n" { index = next }
                }
                row.append(field)
                if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

private enum XLSXXMLParser {
    static func sharedStrings(_ xml: String) -> [String] {
        let texts = XMLTextCollector(xml: xml, target: "t").values
        return texts
    }

    static func rows(_ xml: String, sharedStrings: [String]) -> [[String]] {
        let collector = XLSXRowCollector(xml: xml, sharedStrings: sharedStrings)
        return collector.rows
    }
}

private final class XMLTextCollector: NSObject, XMLParserDelegate {
    private let target: String
    private var current = ""
    var values: [String] = []
    init(xml: String, target: String) {
        self.target = target
        super.init()
        let parser = XMLParser(data: Data(xml.utf8)); parser.delegate = self; parser.parse()
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) { if elementName == target { current = "" } }
    func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if elementName == target { values.append(current) } }
}

private final class XLSXRowCollector: NSObject, XMLParserDelegate {
    let sharedStrings: [String]
    var rows: [[String]] = []
    private var row: [String] = []
    private var cellType = ""
    private var cellRef = ""
    private var value = ""
    init(xml: String, sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
        super.init()
        let parser = XMLParser(data: Data(xml.utf8)); parser.delegate = self; parser.parse()
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributesDict: [String : String] = [:]) {
        if elementName == "row" { row = [] }
        if elementName == "c" { cellType = attributesDict["t"] ?? ""; cellRef = attributesDict["r"] ?? ""; value = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { value += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "c" {
            let index = columnIndex(cellRef)
            while row.count <= index { row.append("") }
            let text: String
            if cellType == "s", let i = Int(value), i < sharedStrings.count { text = sharedStrings[i] } else { text = value }
            row[index] = text
        } else if elementName == "row" { rows.append(row) }
    }
    private func columnIndex(_ ref: String) -> Int {
        let letters = ref.prefix { $0.isLetter }
        return letters.reduce(0) { $0 * 26 + Int($1.asciiValue! - 64) } - 1
    }
}
