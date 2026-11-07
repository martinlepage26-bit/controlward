import AppKit
import CryptoKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import OSLog
@preconcurrency import UserNotifications
import SwiftUI

enum WorkspaceRecoveryState: Equatable {
    case ready
    case blocked(String)
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var workspace: PersistentWorkspace
    @Published var notice: String?
    @Published private(set) var saveFailure: String?
    /// The last CSV import's result; stays until Martin closes it (CSV-5).
    @Published var lastCSVImport: CSVImportResult?
    @Published private(set) var recoveryState: WorkspaceRecoveryState
    @Published private(set) var researchFailure: String?
    @Published private(set) var activeResearch: Set<UUID> = []
    @Published private(set) var lastDeletionBackup: URL?

    /// Connectors whose API key is in the secret store. The key itself is never held here.
    @Published private(set) var savedKeys: Set<SyncTarget> = []
    @Published private(set) var keyAccessNeeded: Set<SyncTarget> = []
    @Published private(set) var keyAccessChecking: Set<SyncTarget> = []
    private var credentialConfigurationRevisions = Dictionary(uniqueKeysWithValues: SyncTarget.keyed.map { ($0, UUID()) })
    private var credentialReadRevisions: [SyncTarget: UUID] = [:]
    private var credentialProbeIDs: [SyncTarget: UUID] = [:]
    private var credentialProbeTasks: [SyncTarget: Task<Void, Never>] = [:]
    @Published private(set) var busyTargets: Set<SyncTarget> = []
    /// Latest read-only import attempt, including a failure that storage could not retain.
    /// Kept outside the workspace so reporting a failed save cannot publish partial records.
    @Published private var readImportJobs: [SyncTarget: SyncJob] = [:]
    /// Dry-run result that must exist before a Twenty push is allowed.
    @Published private(set) var twentyPreview: TwentyPlan?
    @Published private(set) var pharosPreviewFingerprint: String?
    private var kairosDiscoveryGeneration = UUID()

    let storageURL: URL
    let researchRoot: URL
    let isReviewMode: Bool
    let secrets: SecretStore
    let transport: HTTPTransport
    var twentyPacing: Duration = .milliseconds(700)
    var twentyMaxBackoffSeconds: Double = 30
    /// Receives every sync log line (tests assert these carry no keys or PII).
    var syncLogSink: ((String) -> Void)?
    private var noticeTask: Task<Void, Never>?
    @Published private(set) var reminderStatus = "Choose Schedule reminders to check notification access."
    private let reminderCoordinator: ReminderCoordinator?
    private var lastQueuedReminders: [LeadWorkflow.Reminder]?
    /// CSV-8: the bytes (SHA-256) of each file imported this session and when, so the same file is never imported twice.
    private var importedCSVFiles: [String: Date] = [:]

    init(storageURL: URL = StorageLocation.workspaceFile, secrets: SecretStore? = nil, transport: HTTPTransport = URLSessionTransport(), reminderCenter: (any ReminderSchedulingCenter)? = nil, reviewMode: Bool = StorageLocation.isReview, researchRoot: URL? = nil) {
        self.storageURL = storageURL
        self.researchRoot = researchRoot ?? (storageURL.standardizedFileURL == StorageLocation.workspaceFile.standardizedFileURL
            ? LeadPipelineEnvironment.defaultRoot() : storageURL.deletingLastPathComponent().appendingPathComponent("leads", isDirectory: true))
        self.isReviewMode = reviewMode
#if CONTEXTWARD_ACCEPTANCE
        let center: (any ReminderSchedulingCenter)? = reviewMode ? nil : (reminderCenter ?? (Bundle.main.bundleURL.pathExtension == "app" ? SystemReminderCenter() : nil))
#else
        let center: (any ReminderSchedulingCenter)? = reviewMode ? nil : (reminderCenter ?? SystemReminderCenter())
#endif
        self.reminderCoordinator = center.map { ReminderCoordinator(center: $0) }
        let selectedSecrets: SecretStore
        if reviewMode {
            selectedSecrets = InMemorySecretStore()
        } else {
#if CONTEXTWARD_ACCEPTANCE
        selectedSecrets = secrets ?? InMemorySecretStore()
#else
        selectedSecrets = secrets ?? KeychainSecretStore()
#endif
        }
        self.secrets = selectedSecrets
        self.transport = reviewMode ? IsolatedMailTransport() : transport
        if reviewMode { self.reminderStatus = "Review workspace: macOS notifications are not scheduled." }
        let loaded = Self.load(from: storageURL)
        self.workspace = loaded.workspace
        self.recoveryState = loaded.recovery
        for target in SyncTarget.keyed {
            applyCredentialAvailability(selectedSecrets.cachedAvailability(target) ?? .checking, for: target)
        }
        if FileManager.default.fileExists(atPath: storageURL.path) {
            try? SecureFiles.ensurePrivateDirectory(storageURL.deletingLastPathComponent())
            try? SecureFiles.restrict(storageURL)
        }
        if case .ready = recoveryState { scrubStoredEndpointSecrets(); recoverResearchStorage() }
        Self.log.notice("Loaded workspace (sandboxed: \(StorageLocation.isSandboxed, privacy: .public)): leads=\(self.workspace.leads.count, privacy: .public) contacts=\(self.workspace.contacts.count, privacy: .public) companies=\(self.workspace.companies.count, privacy: .public) tasks=\(self.workspace.tasks.count, privacy: .public)")
        for target in SyncTarget.keyed where keyAccessChecking.contains(target) { startCredentialProbe(target) }
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
    var websiteResearch: WebsiteResearchCache { workspace.websiteResearch }
    var suppressionList: SuppressionList {
        SuppressionList(storageURL: researchRoot.appendingPathComponent("suppression.json"), additionalEntries: workspace.restoredSuppressionEntries)
    }

    /// A restore cannot race a network result into a different workspace generation.
    func beginResearch() -> UUID { let id = UUID(); activeResearch.insert(id); return id }
    func endResearch(_ id: UUID) { activeResearch.remove(id) }

    private var researchRecoveryURL: URL { researchRoot.appendingPathComponent("research-recovery.json") }

    /// A read-only complete snapshot, including any completed work retained after a failed save.
    func researchSnapshot() throws -> (cache: WebsiteResearchCache, recoveryDigest: String?) {
        var cache = workspace.websiteResearch
        if !workspace.researchMigrationComplete {
            cache.mergePreservingNewest(try WebsiteResearchCache.load(researchRoot.appendingPathComponent("quick-scan-research.json")))
        }
        var digest = workspace.consumedResearchRecovery
        if FileManager.default.fileExists(atPath: researchRecoveryURL.path) {
            let data = try Data(contentsOf: researchRecoveryURL)
            guard data.count <= 20_000_000 else { throw ResearchStorageError.responseTooLarge }
            let current = SecureFiles.sha256(data)
            if current != workspace.consumedResearchRecovery {
                cache.mergePreservingNewest(try WebsiteResearchCache.load(researchRecoveryURL))
                digest = current
            }
        }
        try cache.validate()
        return (cache, digest)
    }

    /// Legacy files remain byte-preserved; the canonical cache participates in native transactions.
    func recoverResearchStorage() {
        guard case .ready = recoveryState else { return }
        do {
            let snapshot = try researchSnapshot()
            guard !workspace.researchMigrationComplete || snapshot.recoveryDigest != workspace.consumedResearchRecovery else { researchFailure = nil; return }
            if !workspace.researchMigrationComplete, FileManager.default.fileExists(atPath: storageURL.path) {
                let original = try Data(contentsOf: storageURL)
                let backup = storageURL.deletingLastPathComponent().appendingPathComponent("before-research-migration-\(UUID()).json")
                try SecureFiles.writePrivate(original, to: backup)
            }
            try commitWorkspace { next in
                next.websiteResearch = snapshot.cache
                next.researchMigrationComplete = true
                next.consumedResearchRecovery = snapshot.recoveryDigest
            }
            researchFailure = nil
        } catch { researchFailure = "Saved research could not be imported. Original files were retained; restore storage access or repair the research file before retrying." }
    }

    func recordDiscoveryCandidates(_ candidates: [DiscoveryCandidate]) throws {
        try saveResearch(candidates: candidates, result: nil)
    }

    func recordWebsiteResearch(_ candidate: DiscoveryCandidate, result: QuickScanResearchResult) throws {
        try saveResearch(candidates: [candidate], result: result)
    }

    private func saveResearch(candidates: [DiscoveryCandidate], result: QuickScanResearchResult?) throws {
        do {
            var snapshot = try researchSnapshot()
            snapshot.cache.discover(candidates)
            if let candidate = candidates.first, let result { snapshot.cache.mergePreservingNewest({ var delta = WebsiteResearchCache(); delta.merge(candidate, result: result); return delta }()) }
            try snapshot.cache.validate()
            try commitWorkspace { next in
                next.websiteResearch = snapshot.cache
                next.researchMigrationComplete = true
                next.consumedResearchRecovery = snapshot.recoveryDigest
            }
            researchFailure = nil
        } catch {
            // A private delta is recovery evidence, not another authoritative workspace. Do not
            // overwrite unreadable legacy data or publish a failed native save as successful.
            var retained = false
            do {
                var delta = WebsiteResearchCache()
                if FileManager.default.fileExists(atPath: researchRecoveryURL.path) {
                    let data = try Data(contentsOf: researchRecoveryURL)
                    if SecureFiles.sha256(data) != workspace.consumedResearchRecovery { delta = try WebsiteResearchCache.load(researchRecoveryURL) }
                }
                delta.discover(candidates)
                if let candidate = candidates.first, let result { var incoming = WebsiteResearchCache(); incoming.merge(candidate, result: result); delta.mergePreservingNewest(incoming) }
                try delta.save(researchRecoveryURL)
                retained = true
            } catch { }
            let message = retained
                ? "Research could not be committed. Findings were retained in a private recovery file; restore storage access and retry recovery."
                : "Research could not be saved. Original files were retained; keep the findings open and restore storage access before retrying."
            researchFailure = message
            throw ControlWardError.invalid(message)
        }
    }
    var leads: [Lead] { workspace.leads }
    var contacts: [Contact] { workspace.contacts }
    var companies: [Company] { workspace.companies }
    var opportunities: [Opportunity] { workspace.opportunities }
    var tasks: [CRMTask] { workspace.tasks }
    var notes: [CRMNote] { workspace.notes }
    var signals: [Signal] { workspace.signals }
    /// Operational surfaces exclude records retired by an upstream source. The full
    /// `signals` collection remains available for audit/history and reactivation.
    var activeSignals: [Signal] { workspace.signals.filter { $0.sourceActive != false } }
    var audits: [BilingualAudit] { workspace.audits }
    var automationRules: [AutomationRule] { workspace.automationRules }
    var activity: [ActivityEvent] { workspace.activity }
    var syncJobs: [SyncJob] { workspace.syncJobs }
    var exposureFindings: [ExposureFinding] { workspace.exposureFindings }
    func endpoint(for target: SyncTarget) -> String {
        workspace.connectorEndpoints[target.rawValue] ?? (target == .kairos ? KairosClient.defaultEndpoint : "")
    }

    /// Saves an endpoint without its secret parts. `user:pass@` and token-like
    /// query items are removed before anything is persisted.
    func setEndpoint(_ endpoint: String, for target: SyncTarget) {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            workspace.connectorEndpoints.removeValue(forKey: target.rawValue)
            invalidateConnector(target)
            persist(message: target == .kairos
                ? "Kairos endpoint reset to its default URL."
                : "\(target.label) endpoint cleared.")
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
        } catch { showNotice("\(target.label) preflight failed: \(message(for: error))") }
    }

    // MARK: - Connectors (API keys, status, PHAROS push, Twenty push)

    private static let syncLog = Logger(subsystem: "com.pharos.contextward", category: "sync")

    func hasKey(_ target: SyncTarget) -> Bool { savedKeys.contains(target) }

    private func applyCredentialAvailability(_ value: CredentialAvailability, for target: SyncTarget) {
        savedKeys.remove(target); keyAccessNeeded.remove(target); keyAccessChecking.remove(target)
        switch value {
        case .available: savedKeys.insert(target)
        case .accessRequired: keyAccessNeeded.insert(target)
        case .checking: keyAccessChecking.insert(target)
        case .missing: break
        }
    }

    private func cancelCredentialProbe(_ target: SyncTarget) {
        credentialProbeIDs[target] = UUID()
        credentialProbeTasks.removeValue(forKey: target)?.cancel()
    }

    private func startCredentialProbe(_ target: SyncTarget) {
        cancelCredentialProbe(target)
        let reader = secrets, revision = credentialConfigurationRevisions[target], id = UUID()
        credentialProbeIDs[target] = id
        applyCredentialAvailability(.checking, for: target)
        credentialProbeTasks[target] = Task { [weak self] in
            let value = await CredentialIO.perform { reader.availability(target) }
            guard let self, !Task.isCancelled, self.credentialProbeIDs[target] == id,
                  self.credentialConfigurationRevisions[target] == revision else { return }
            self.applyCredentialAvailability(value, for: target)
            self.credentialProbeTasks.removeValue(forKey: target)
        }
    }

    func waitForCredentialChecks() async {
        let pending = Array(credentialProbeTasks.values)
        for task in pending { await task.value }
    }

    func connectorStatus(_ target: SyncTarget) -> ConnectorStatus {
        if keyAccessChecking.contains(target), !endpoint(for: target).isEmpty { return .checkingAccess }
        if keyAccessNeeded.contains(target), !endpoint(for: target).isEmpty {
            return .accessRequired("Credential access could not be checked. Choose Verify to retry. Automatic checks are paused.")
        }
        return ConnectorStatus.resolve(endpoint: endpoint(for: target), hasKey: hasKey(target), health: workspace.connectorHealth[target.rawValue])
    }

    /// Saves or replaces a key in the Keychain. The key never enters workspace data, activity, or logs.
    func setAPIKey(_ key: String, for target: SyncTarget) {
        guard !isReviewMode else { showNotice("Account connections are off in review mode."); return }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { showNotice("\(target.label) key is empty. Nothing was saved."); return }
        do {
            try secrets.write(value, for: target)
            applyCredentialAvailability(.available, for: target)
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
            applyCredentialAvailability(.missing, for: target)
            invalidateConnector(target)
            workspace.activity.insert(ActivityEvent(kind: "credential", message: "Removed the \(target.label) API key from the Keychain."), at: 0)
            persist(message: "\(target.label) key removed from the Keychain.")
        } catch {
            showNotice("Could not remove the \(target.label) key: \(error.localizedDescription)")
        }
    }

    private func invalidateConnector(_ target: SyncTarget) {
        let wasChecking = keyAccessChecking.contains(target)
        credentialConfigurationRevisions[target] = UUID()
        cancelCredentialProbe(target)
        if wasChecking { startCredentialProbe(target) }
        workspace.connectorHealth.removeValue(forKey: target.rawValue)
        if target == .twenty { twentyPreview = nil }
        if target == .kairos {
            kairosDiscoveryGeneration = UUID()
            workspace.websiteResearch.kairosContext = nil
        }
    }

    private func recordHealth(_ target: SyncTarget, ok: Bool, detail: String) {
        workspace.connectorHealth[target.rawValue] = ConnectorHealth(ok: ok, detail: detail)
    }

    private func apiKey(for target: SyncTarget, userInitiated: Bool = true) async throws -> String {
        cancelCredentialProbe(target)
        let reader = secrets, configuration = credentialConfigurationRevisions[target], readID = UUID()
        credentialReadRevisions[target] = readID
        do {
            let value = try await CredentialIO.read {
                try userInitiated ? reader.read(target) : reader.readWithoutInteraction(target)
            }
            guard !Task.isCancelled, credentialConfigurationRevisions[target] == configuration,
                  credentialReadRevisions[target] == readID else { throw CredentialLookupError.superseded }
            guard let key = value, !key.isEmpty else {
                applyCredentialAvailability(.missing, for: target)
                throw IntegrationError.missingKey
            }
            applyCredentialAvailability(.available, for: target)
            return key
        } catch let error as SecretStoreError {
            guard credentialConfigurationRevisions[target] == configuration,
                  credentialReadRevisions[target] == readID else { throw CredentialLookupError.superseded }
            if case .keychain = error { applyCredentialAvailability(.accessRequired, for: target) }
            throw error
        }
    }

    private func pharosClient(userInitiated: Bool = true) async throws -> PharosClient {
        let url = endpoint(for: .pharos), revision = credentialConfigurationRevisions[.pharos]
        let key = try await apiKey(for: .pharos, userInitiated: userInitiated)
        guard credentialConfigurationRevisions[.pharos] == revision else { throw CredentialLookupError.superseded }
        return try PharosClient(endpoint: url, apiKey: key, transport: transport)
    }

    private func gapClient() async throws -> GapClient {
        let url = endpoint(for: .gaps), revision = credentialConfigurationRevisions[.gaps]
        let key = try await apiKey(for: .gaps)
        guard credentialConfigurationRevisions[.gaps] == revision else { throw CredentialLookupError.superseded }
        return try GapClient(endpoint: url, apiKey: key, transport: transport)
    }

    private func twentyClient() async throws -> TwentyClient {
        let url = endpoint(for: .twenty), revision = credentialConfigurationRevisions[.twenty]
        let key = try await apiKey(for: .twenty)
        guard credentialConfigurationRevisions[.twenty] == revision else { throw CredentialLookupError.superseded }
        return try TwentyClient(endpoint: url, apiKey: key, transport: transport,
                         interval: twentyPacing, maxBackoffSeconds: twentyMaxBackoffSeconds)
    }

    private func kairosClient() async throws -> KairosClient {
        let url = endpoint(for: .kairos), revision = credentialConfigurationRevisions[.kairos]
        let key = try await apiKey(for: .kairos)
        guard credentialConfigurationRevisions[.kairos] == revision else { throw CredentialLookupError.superseded }
        return try KairosClient(endpoint: url, apiKey: key, transport: transport)
    }

    private func message(for error: Error) -> String {
        if let integration = error as? IntegrationError { return integration.errorDescription ?? "The integration request failed." }
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return String(description.prefix(180)) }
        return "The integration request failed. Check the endpoint and try again."
    }

    /// Authenticated check. PHAROS: health plus key check. Twenty: authenticated GET.
    /// Status becomes Active only when this (or a real push) succeeds.
    @discardableResult
    func verifyConnector(_ target: SyncTarget) async -> Bool {
        guard SyncTarget.keyed.contains(target) else { await probeEndpoint(target); return false }
        guard !busyTargets.contains(target) else { return false }
        let configuration = credentialConfigurationRevisions[target]
        busyTargets.insert(target); defer { busyTargets.remove(target) }
        do {
            switch target {
            case .pharos: try await pharosClient().verify()
            case .twenty: try await twentyClient().verify()
            case .leadgen: break
            case .gaps: try await gapClient().verify()
            case .kairos: try await kairosClient().verify()
            }
            guard credentialConfigurationRevisions[target] == configuration else { return false }
            recordHealth(target, ok: true, detail: "Verified \(Date.now.formatted(date: .abbreviated, time: .shortened)): endpoint reachable and key accepted.")
            Self.syncLog.notice("verify target=\(target.rawValue, privacy: .public) ok")
            persist(message: "\(target.label) verified. The key is accepted.")
            return true
        } catch {
            guard credentialConfigurationRevisions[target] == configuration, !(error is CredentialLookupError) else { return false }
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
    func previewPharosPush() -> String {
        let fingerprint = ExchangeFingerprint.idempotencyKey(for: exchange)
        pharosPreviewFingerprint = fingerprint
        showNotice("PHAROS preview ready. Review the snapshot summary, then confirm the push.")
        return fingerprint
    }

    @discardableResult
    func syncToPharos(confirmedFingerprint: String? = nil) async -> SyncJob {
        let snapshot = exchange
        let key = ExchangeFingerprint.idempotencyKey(for: snapshot)
        var job = SyncJob(target: .pharos, status: "sending", idempotencyKey: key)
        guard let preview = pharosPreviewFingerprint, preview == key, confirmedFingerprint == preview else {
            job.status = "failed"
            job.error = "Preview the current snapshot and confirm before pushing."
            showNotice(job.error ?? "Preview and confirm before pushing.")
            if pharosPreviewFingerprint != key { pharosPreviewFingerprint = nil }
            return job
        }
        pharosPreviewFingerprint = nil
        workspace.syncJobs.insert(job, at: 0)
        busyTargets.insert(.pharos); defer { busyTargets.remove(.pharos) }
        do {
            let client = try await pharosClient()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let receipt = try await client.push(try encoder.encode(snapshot), idempotencyKey: key)
            job.status = "synced"
            job.detail = receipt.duplicate == true
                ? "Already stored (same Idempotency-Key)."
                : "Stored successfully."
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
        showNotice(plan.blockers.isEmpty
            ? "Twenty preview: \(plan.creates) to create or resume, \(plan.updates) to update, \(plan.unchangedTotal) unchanged."
            : plan.summary)
        return plan
    }

    /// Pushes companies, people, opportunities, then tasks. Requires a preview first.
    /// Create identities are saved before HTTP, so a lost response or failed receipt
    /// save can resume the same remote record after reload.
    /// Never deletes anything in Twenty.
    @discardableResult
    func pushToTwenty() async -> SyncJob {
        var job = SyncJob(target: .twenty, status: "sending")
        guard !busyTargets.contains(.twenty) else {
            job.status = "failed"; job.error = "A Twenty push is already running."
            return job
        }
        guard let preview = twentyPreview else {
            job.status = "failed"; job.error = "Run the preview before pushing."
            showNotice("Preview the Twenty push first.")
            return job
        }
        guard preview.blockers.isEmpty else {
            job.status = "failed"; job.error = preview.summary
            showNotice(preview.summary)
            return job
        }
        let current = TwentyMapper.plan(workspace, links: workspace.twentyLinks)
        guard current.fingerprint == preview.fingerprint else {
            twentyPreview = nil
            job.status = "failed"; job.error = "The workspace changed after preview. Preview again before pushing."
            showNotice(job.error ?? "Preview again before pushing.")
            return job
        }
        let approvedWorkspace = workspace, approvedLinks = workspace.twentyLinks
        let configuration = credentialConfigurationRevisions[.twenty]
        func requireCurrentApproval() throws {
            guard !Task.isCancelled, credentialConfigurationRevisions[.twenty] == configuration,
                  TwentyMapper.plan(workspace, links: approvedLinks).fingerprint == preview.fingerprint else {
                throw IntegrationError.unexpected("CRM data or the connection changed during the push. Preview again before continuing.")
            }
        }
        workspace.syncJobs.insert(job, at: 0)
        busyTargets.insert(.twenty); defer { busyTargets.remove(.twenty) }
        var created = 0, updated = 0
        do {
            // Refuse remote writes when the workspace cannot retain their identities.
            try persistOrThrow()
            let client = try await twentyClient()
            try requireCurrentApproval()
            for object in TwentyObject.allCases {
                // Resolve new remote identities against durable progress, while all
                // business content remains bound to the approved value snapshot.
                for operation in TwentyMapper.plan(approvedWorkspace, links: workspace.twentyLinks, only: object).operations {
                    try requireCurrentApproval()
                    var durableLink = workspace.twentyLinks[operation.localKey]
                    var id = operation.twentyID
                    if let existing = id, try await client.update(object, id: existing, operation.payload) {
                        updated += 1
                    } else {
                        try requireCurrentApproval()
                        // A completed link returning404 gets a fresh identity. Pending
                        // creates reuse their durable UUID, including after a lost response.
                        let resumingCreate = durableLink?.pendingCreate == true || (operation.kind == .create && id != nil)
                        let reservedID = resumingCreate ? (id ?? UUID().uuidString.lowercased()) : UUID().uuidString.lowercased()
                        let pending = TwentyLink(twentyID: reservedID, object: object, payloadHash: "pending:\(operation.payloadHash)", pendingCreate: true)
                        workspace.twentyLinks[operation.localKey] = pending
                        do { try persistOrThrow() }
                        catch { workspace.twentyLinks[operation.localKey] = durableLink; throw error }
                        durableLink = pending
                        id = try await client.create(object, operation.payload, id: reservedID)
                        created += 1
                    }
                    workspace.twentyLinks[operation.localKey] = TwentyLink(twentyID: id ?? "", object: object, payloadHash: operation.payloadHash)
                    do { try persistOrThrow() }
                    catch { workspace.twentyLinks[operation.localKey] = durableLink; throw error }
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

    // MARK: - Kairos inbox

    /// Imports only lead-intent conversations on explicit user action. This is read-only
    /// against Kairos; message bodies remain in the local ControlWard workspace.
    @discardableResult
    func importKairosLeads() async -> SyncJob {
        var job = SyncJob(target: .kairos, status: "sending", snapshotSchema: "kairos.inbox.v1")
        guard case .ready = recoveryState else {
            job.status = "failed"; job.error = "Workspace recovery is blocked; no Kairos data was imported."
            readImportJobs[.kairos] = job
            return job
        }
        guard !busyTargets.contains(.kairos) else {
            job.status = "failed"; job.error = "A Kairos import is already running."
            return job
        }
        busyTargets.insert(.kairos); defer { busyTargets.remove(.kairos) }
        readImportJobs[.kairos] = job
        var created = 0, updated = 0, unchanged = 0, skipped = 0
        do {
            let inbox = try await kairosClient().pullInbox()
            try commitWorkspace { next in
                for conversation in inbox.conversations {
                    guard conversation.intent.lowercased() == "lead",
                          conversation.status.lowercased() != "ignored" else { skipped += 1; continue }
                    switch Self.applyKairosLead(conversation, to: &next) {
                    case .created: created += 1
                    case .updated: updated += 1
                    case .unchanged: unchanged += 1
                    case .skipped: skipped += 1
                    }
                }
                if var context = next.websiteResearch.kairosContext {
                    context.enquiryStates = inbox.discoveryStates
                    context.inboxFetchedAt = Date.now.ISO8601Format()
                    context.disabledPlatforms = inbox.disabledPlatforms
                    try context.validate()
                    next.websiteResearch.kairosContext = context
                }
                job.status = "synced"
                job.detail = "\(created) new, \(updated) updated, \(unchanged) unchanged, \(skipped) skipped."
                job.completedAt = Date.now.ISO8601Format()
                next.syncJobs.insert(job, at: 0)
                next.connectorHealth[SyncTarget.kairos.rawValue] = ConnectorHealth(ok: true, detail: "Last import \(Date.now.formatted(date: .abbreviated, time: .shortened)): \(job.detail ?? "")")
                next.activity.insert(ActivityEvent(kind: "kairos_import", message: "Imported Kairos leads: \(job.detail ?? "")", sourceID: job.id), at: 0)
            }
            saveFailure = nil
            readImportJobs[.kairos] = job
            showNotice("Kairos import complete: \(job.detail ?? "")")
            Self.syncLog.notice("kairos import ok created=\(created) updated=\(updated) unchanged=\(unchanged) skipped=\(skipped)")
        } catch {
            Self.syncLog.error("kairos import failed")
            return failedReadOnlyImport(job, error: error)
        }
        return job
    }

    /// Strategy, aggregate performance and inbound enquiries form one durable snapshot.
    /// A failed route/save or changed connection publishes none of the new snapshot.
    @discardableResult
    func refreshKairosDiscovery() async -> Bool {
        guard !isReviewMode else { showNotice("Account refresh is off in review mode."); return false }
        guard case .ready = recoveryState else { showNotice("Recover the workspace before refreshing KAIROS context."); return false }
        guard !busyTargets.contains(.kairos) else { showNotice("Wait for the current KAIROS request."); return false }
        busyTargets.insert(.kairos); defer { busyTargets.remove(.kairos) }
        let generation = kairosDiscoveryGeneration
        let researchGeneration = workspace.researchGeneration
        var job = SyncJob(target: .kairos, status: "sending", snapshotSchema: "kairos.discovery.v1")
        do {
            let client = try await kairosClient()
            let strategy = try await client.strategy()
            let inbox = try await client.pullInbox()
            let insights = try await client.insights()
            guard generation == kairosDiscoveryGeneration, researchGeneration == workspace.researchGeneration else {
                throw ControlWardError.invalid("The connection or workspace changed during refresh. Refresh the current connection again.")
            }
            let old = workspace.websiteResearch.kairosContext
            let base = client.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let context = KairosDiscoveryContext(endpoint: base, fetchedAt: Date.now.ISO8601Format(),
                strategyRevision: old?.endpoint == base && old?.strategy?.audience == strategy?.audience && old?.strategy?.positioning == strategy?.positioning ? old!.strategyRevision : UUID(),
                strategy: strategy, insights: insights, disabledPlatforms: inbox.disabledPlatforms,
                inboxFetchedAt: Date.now.ISO8601Format(), enquiryStates: inbox.discoveryStates)
            try context.validate()
            var created = 0, updated = 0, unchanged = 0, skipped = 0
            try commitWorkspace { next in
                for conversation in inbox.conversations {
                    guard conversation.intent.lowercased() == "lead", conversation.status.lowercased() != "ignored" else { skipped += 1; continue }
                    switch Self.applyKairosLead(conversation, to: &next) {
                    case .created: created += 1
                    case .updated: updated += 1
                    case .unchanged: unchanged += 1
                    case .skipped: skipped += 1
                    }
                }
                next.websiteResearch.kairosContext = context
                try next.websiteResearch.validate()
                job.status = "synced"; job.completedAt = Date.now.ISO8601Format()
                job.detail = "Discovery context: \(created) new, \(updated) updated, \(unchanged) unchanged, \(skipped) skipped."
                next.syncJobs.insert(job, at: 0)
                next.connectorHealth[SyncTarget.kairos.rawValue] = ConnectorHealth(ok: true, detail: "Discovery context refreshed; collection availability is shown in Discovery.")
                next.activity.insert(ActivityEvent(kind: "discovery_context", message: job.detail ?? "KAIROS context refreshed.", sourceID: job.id), at: 0)
            }
            readImportJobs[.kairos] = job
            saveFailure = nil
            showNotice(job.detail ?? "KAIROS context saved.")
            return true
        } catch {
            _ = failedReadOnlyImport(job, error: error)
            return false
        }
    }

    @discardableResult
    func linkDiscoveryEnquiry(sourceID: String, businessKey: String?, reason: String = "") -> Bool {
        guard let enquiry = workspace.leads.first(where: { $0.sourceID == sourceID }), sourceID.hasPrefix("kairos:") else {
            showNotice("This KAIROS enquiry is no longer available."); return false
        }
        let explanation = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let business = DiscoveryIntelligence.businesses(workspace.websiteResearch).first { $0.id == businessKey && $0.verifiedWebsite }
        if businessKey != nil {
            guard business != nil else {
                showNotice("Research this business website before linking an enquiry."); return false
            }
        }
        let old = workspace.websiteResearch.enquiryBusinessLinks?[sourceID]
        if old?.businessKey == businessKey && (explanation.isEmpty || old?.reason == explanation) { return true }
        let supportedReason = business.flatMap { DiscoveryIntelligence.suggestion(enquiry, for: $0) }
        guard explanation.count <= 2_000, businessKey == nil || !explanation.isEmpty || supportedReason != nil else {
            showNotice("Give a reason for linking this enquiry to this business."); return false
        }
        return saveChange { next in
            if next.websiteResearch.enquiryBusinessLinks == nil { next.websiteResearch.enquiryBusinessLinks = [:] }
            next.websiteResearch.enquiryBusinessLinks?[sourceID] = DiscoveryEnquiryLink(businessKey: businessKey, confirmedAt: Date.now.ISO8601Format(),
                reason: businessKey == nil ? "Owner removed the association." : (explanation.isEmpty ? supportedReason : explanation),
                incomingExcerpt: enquiry.sourceMessage.map { String($0.prefix(4_000)) }, incomingAt: enquiry.sourceUpdatedAt,
                businessSourceURL: business?.candidate.sourceURL)
            try next.websiteResearch.validate()
            next.activity.insert(ActivityEvent(kind: "discovery_link", message: businessKey == nil ? "Removed one enquiry-to-business association." : "Confirmed one enquiry-to-researched-business association.", sourceID: enquiry.id), at: 0)
            return businessKey == nil ? "Enquiry unlinked. Its CRM history was retained." : "Enquiry linked. CRM identities and outreach were retained."
        }
    }

    @discardableResult
    func reviewDiscoveryFit(businessKey: String, decision: DiscoveryFit, reason: String, strategyRevision: UUID?) -> Bool {
        let explanation = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard strategyRevision == workspace.websiteResearch.kairosContext?.strategyRevision else {
            showNotice("Targeting changed while this review was open. Close it and review the current audience and offer."); return false
        }
        guard DiscoveryIntelligence.businesses(workspace.websiteResearch).contains(where: { $0.id == businessKey }),
              explanation.count <= 2_000, decision == .unassessed || !explanation.isEmpty else {
            showNotice("Use the current targeting context and give a reason for a fit decision."); return false
        }
        let old = workspace.websiteResearch.fitReviews?[businessKey]
        if old?.decision == decision && old?.reason == explanation && old?.strategyRevision == strategyRevision { return true }
        return saveChange { next in
            if next.websiteResearch.fitReviews == nil { next.websiteResearch.fitReviews = [:] }
            next.websiteResearch.fitReviews?[businessKey] = DiscoveryFitReview(decision: decision, reason: explanation, reviewedAt: Date.now.ISO8601Format(), strategyRevision: strategyRevision)
            try next.websiteResearch.validate()
            next.activity.insert(ActivityEvent(kind: "discovery_fit", message: "Saved one explained offer-fit review."), at: 0)
            return "Fit review saved. Interest and contact evidence are unchanged."
        }
    }

    private enum KairosLeadOutcome { case created, updated, unchanged, skipped }

    private static func applyKairosLead(_ conversation: KairosConversation, to workspace: inout PersistentWorkspace) -> KairosLeadOutcome {
        let handle = conversation.authorHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !conversation.id.isEmpty, !handle.isEmpty else { return .skipped }
        let sourceID = "kairos:\(conversation.id)"
        guard !workspace.dismissedLeadSources.contains(sourceID) else { return .skipped }
        if let index = workspace.leads.firstIndex(where: { $0.sourceID == sourceID }) {
            let original = workspace.leads[index]
            if let appliedAt = original.sourceUpdatedAt, conversation.lastMessageAt < appliedAt { return .unchanged }
            var lead = LeadWorkflow.normalizeKairosLead(original)
            if lead.sourceUpdatedAt != conversation.lastMessageAt || original.sourceMessage == nil {
                if let latestMessage = conversation.latestMessage, !latestMessage.isEmpty {
                    lead.sourceMessage = String(latestMessage.prefix(4_000))
                }
                lead.sourceUpdatedAt = conversation.lastMessageAt
            }
            lead.sourcePlatform = String(conversation.platform.prefix(80))
            // Sending a reply changes Kairos status without advancing its inbound
            // message timestamp. Reconcile that status even when the message is unchanged.
            if lead.status == .new && conversation.status.lowercased() == "answered" { lead.status = .contacted }
            guard lead != workspace.leads[index] else { return .unchanged }
            workspace.leads[index] = lead
            return .updated
        }

        var lead = Lead.blank()
        lead.name = handle
        lead.sourcePlatform = String(conversation.platform.prefix(80))
        lead.sourceMessage = conversation.latestMessage.map { String($0.prefix(4_000)) }
        lead.notes = "Imported from a Kairos conversation classified as a lead."
        lead.status = conversation.status.lowercased() == "answered" ? .contacted : .new
        lead.sourceID = sourceID
        lead.sourceUpdatedAt = conversation.lastMessageAt
        workspace.leads.insert(lead, at: 0)
        return .created
    }

    // MARK: - PHAROS lead inbox

    static let maxInboxPages = 20

    /// Writes a sync log line. Callers pass counts, statuses, and target names only.
    private func logSync(_ line: String, error: Bool = false) {
        if error { Self.syncLog.error("\(line, privacy: .public)") } else { Self.syncLog.notice("\(line, privacy: .public)") }
        syncLogSink?(line)
    }

    /// Pulls qualified leads that LeadGen OS pushed to the PHAROS Worker, dedupes them
    /// into the workspace, then acks each page. The cursor is saved only after its page
    /// is acked, so a failed ack re-delivers the page and dedupe makes that harmless.
    /// Activity, the job, and logs record counts only.
    @discardableResult
    func pullLeads(userInitiated: Bool = true, requiresAutoPilot: Bool = false) async -> SyncJob {
        var job = SyncJob(target: .leadgen, status: "sending", snapshotSchema: LeadInboxPage.schema)
        guard case .ready = recoveryState else {
            job.status = "failed"; job.error = "Workspace recovery is blocked; no inbox leads were imported."
            readImportJobs[.leadgen] = job
            return job
        }
        guard !busyTargets.contains(.leadgen) else {
            job.status = "failed"; job.error = "A lead pull is already running."
            return job
        }
        readImportJobs[.leadgen] = job
        busyTargets.insert(.leadgen); defer { busyTargets.remove(.leadgen) }
        var counts = LeadPullCounts()
        do {
            let client = try await pharosClient(userInitiated: userInitiated)
            // The owner can stop Auto-Pilot while credential I/O is pending.
            guard !Task.isCancelled, !((!userInitiated || requiresAutoPilot) && !workspace.autoPilotEnabled) else {
                job.status = "cancelled"
                readImportJobs[.leadgen] = job
                return job
            }
            var cursor = workspace.leadInboxCursor ?? 0
            for _ in 0..<Self.maxInboxPages {
                var page = try await client.pullLeads(since: cursor)
                var resetCursor = false
                // A recreated inbox restarts its sequence; a cursor from the old one would skip every new lead.
                if let epoch = page.epoch, let known = workspace.leadInboxEpoch, epoch != known, cursor != 0 {
                    cursor = 0
                    resetCursor = true
                    page = try await client.pullLeads(since: 0)
                }
                var committedCounts = counts
                // Publish the page and epoch only after the complete candidate is durable.
                // A failed write cannot expose phantom leads, retractions, cursor resets or jobs.
                try commitWorkspace { next in
                    if resetCursor { next.leadInboxCursor = nil }
                    if let epoch = page.epoch { next.leadInboxEpoch = epoch }
                    for item in page.leads { committedCounts.add(Self.applyInboxItem(item, to: &next)) }
                }
                counts = committedCounts
                if page.leads.isEmpty { break }
                counts.acked += try await client.ackLeads(page.leads).acked
                cursor = page.cursor
                try commitWorkspace { $0.leadInboxCursor = cursor }
                if !page.hasMore { break }
            }
            job.status = "synced"
            job.detail = counts.summary
            job.completedAt = Date.now.ISO8601Format()
            try commitWorkspace { next in
                next.syncJobs.insert(job, at: 0)
                if counts.total > 0 {
                    next.activity.insert(ActivityEvent(kind: "lead_pull", message: "Pulled leads from the PHAROS inbox: \(counts.summary)", sourceID: job.id), at: 0)
                }
            }
            saveFailure = nil
            showNotice(counts.total == 0 ? "No new leads in the PHAROS inbox." : "Pulled leads: \(counts.summary)")
            logSync("lead pull ok created=\(counts.created) updated=\(counts.updated) unchanged=\(counts.unchanged) skipped=\(counts.skipped) acked=\(counts.acked)")
        } catch {
            job.status = "failed"
            job.detail = nil
            job.error = "\(message(for: error)) Progress kept: \(counts.summary)"
            job.completedAt = Date.now.ISO8601Format()
            do {
                try commitWorkspace { next in
                    next.syncJobs.insert(job, at: 0)
                    next.activity.insert(ActivityEvent(kind: "lead_pull", message: "Lead pull failed: \(job.error ?? "unknown error")", sourceID: job.id), at: 0)
                }
                showNotice("Lead pull failed: \(job.error ?? "")")
            } catch {
                saveFailure = "Changes were not saved. \(error.localizedDescription)"
                showNotice(saveFailure ?? "Lead pull failed.")
            }
            logSync("lead pull failed created=\(counts.created) updated=\(counts.updated) acked=\(counts.acked)", error: true)
        }
        readImportJobs[.leadgen] = job
        return job
    }

    /// How often leads are pulled while pulling is on and the app is open.
    var leadPullInterval: Duration = .seconds(300)
    private var pullLoop: Task<Void, Never>?
    /// True while the periodic pull is running.
    @Published private(set) var isPullingLeads = false

    private var pharosConfigured: Bool { !endpoint(for: .pharos).isEmpty && hasKey(.pharos) }

    /// Runs when the app opens: if Auto-Pilot is on and PHAROS is set up, pull now and keep pulling.
    func pullLeadsOnLaunch() async {
        if let pending = credentialProbeTasks[.pharos] { await pending.value }
        guard workspace.autoPilotEnabled, pharosConfigured else { return }
        await pullLeads(userInitiated: false)
        if workspace.autoPilotEnabled && pharosConfigured { startPullLoop() }
    }

    /// "Start Auto-Pilot": saves the choice, pulls now, then every `leadPullInterval` while the app is open.
    func startPulling() async {
        guard pharosConfigured else {
            showNotice(keyAccessNeeded.contains(.pharos) ? "Choose Verify for PHAROS to check saved credential access. Your Auto-Pilot preference is retained." : "Save the PHAROS endpoint and key before enabling Auto-Pilot.")
            return
        }
        workspace.autoPilotEnabled = true
        persist()
        await pullLeads(requiresAutoPilot: true)
        if workspace.autoPilotEnabled && pharosConfigured { startPullLoop() }
    }

    /// "Stop Auto-Pilot": saves the choice and stops the periodic pull. Leads already pulled stay.
    func stopPulling() {
        pullLoop?.cancel()
        pullLoop = nil
        isPullingLeads = false
        workspace.autoPilotEnabled = false
        persist(message: "Auto-Pilot disabled.")
    }

    private func startPullLoop() {
        pullLoop?.cancel()
        isPullingLeads = true
        pullLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.leadPullInterval else { break }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.workspace.autoPilotEnabled, self.pharosConfigured else { break }
                await self.pullLeads(userInitiated: false)
            }
            if !Task.isCancelled { self?.isPullingLeads = false }
        }
    }

    private static func applyInboxItem(_ item: LeadInboxItem, to workspace: inout PersistentWorkspace) -> LeadPullCounts.Outcome {
        let sourceID = "leadgen:\(item.sourceID)"
        if item.retracted { return removeRetractedLead(sourceID, from: &workspace) }
        guard let event = item.event, !workspace.dismissedLeadSources.contains(sourceID) else { return .skipped }
        return applyInboxLead(sourceID: sourceID, event: event, to: &workspace)
    }

    /// LeadGen withdrew the lead (deletion request, consent withdrawn, or no longer qualified):
    /// remove it and the signals that point at it.
    private static func removeRetractedLead(_ sourceID: String, from workspace: inout PersistentWorkspace) -> LeadPullCounts.Outcome {
        let ids = Set(workspace.leads.filter { $0.sourceID == sourceID }.map(\.id))
        guard !ids.isEmpty else { return .unchanged }
        workspace.leads.removeAll { ids.contains($0.id) }
        workspace.signals.removeAll { $0.leadID.map(ids.contains) ?? false }
        return .removed
    }

    /// Matches by source id, then by email (relinking a lead whose LeadGen identity was merged),
    /// then by phone only when the emails cannot conflict. Existing leads keep local edits:
    /// only empty fields are filled. Scores refresh on the lead's LeadGen signal.
    private static func applyInboxLead(sourceID: String, event: LeadGenEvent, to workspace: inout PersistentWorkspace) -> LeadPullCounts.Outcome {
        let identity = event.identity
        func clean(_ value: String?) -> String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = [clean(identity.firstName), clean(identity.lastName)].filter { !$0.isEmpty }.joined(separator: " ")
        let email = clean(identity.email ?? event.email)
        let phone = clean(identity.phoneRaw)
        let company = clean(identity.companyNameRaw)
        guard !name.isEmpty || !email.isEmpty else { return .skipped }
        let phoneKey = LeadMatching.phoneKey(phone)
        let fromLeadGen = { (lead: Lead) in lead.sourceID == nil || lead.sourceID?.hasPrefix("leadgen:") == true }

        let index = workspace.leads.firstIndex { $0.sourceID == sourceID }
            ?? (email.isEmpty ? nil : workspace.leads.firstIndex { fromLeadGen($0) && $0.email.caseInsensitiveCompare(email) == .orderedSame })
            // A shared switchboard number is not identity: never match two people with different emails.
            ?? (phoneKey == nil ? nil : workspace.leads.firstIndex {
                $0.sourceID == nil && LeadMatching.phoneKey($0.phone) == phoneKey && ($0.email.isEmpty || email.isEmpty)
            })

        var lead: Lead
        let created = index == nil
        if let index {
            lead = workspace.leads[index]
        } else {
            lead = Lead.blank()
            lead.createdAt = event.capturedAt ?? lead.createdAt
        }
        let before = lead
        lead.sourceID = sourceID
        if lead.name.isEmpty { lead.name = name.isEmpty ? email : name }
        if lead.email.isEmpty { lead.email = email }
        if lead.phone.isEmpty { lead.phone = phone }
        if lead.company.isEmpty { lead.company = company }
        if let index { workspace.leads[index] = lead } else { workspace.leads.insert(lead, at: 0) }

        let fit = min(max(event.fitScore ?? 0, 0), 100)
        let intent = min(max(event.intentScore ?? 0, 0), 100)
        let priority = min(max(event.compositeScore ?? ((fit + intent) / 2), 0), 100)
        let signalIndex = workspace.signals.firstIndex { $0.leadID == lead.id && $0.source == .imported }
        var signal = signalIndex.map { workspace.signals[$0] } ?? Signal()
        let signalBefore = signal
        if signalIndex == nil {
            signal.title = "LeadGen: \(lead.name)"
            signal.source = .imported
            signal.status = .qualified
            signal.leadID = lead.id
            signal.nextAction = "Review the qualified lead and make first contact."
            signal.capturedAt = event.capturedAt ?? signal.capturedAt
        }
        signal.evidence = "Pulled from the PHAROS lead inbox. LeadGen id: \(sourceID.dropFirst("leadgen:".count))."
        signal.fitScore = fit
        signal.intentScore = intent
        signal.priority = priority
        if let signalIndex { workspace.signals[signalIndex] = signal } else { workspace.signals.insert(signal, at: 0) }

        if created { return .created }
        return lead == before && signal == signalBefore ? .unchanged : .updated
    }

    // MARK: - Gap analysis

    /// Reads active gap clusters and turns each into a signal ("Market gap: ..."), matched by
    /// cluster id so a re-import updates instead of duplicating. Local owner, status, and next
    /// action are kept. Read-only: nothing is written to the gap analysis project.
    @discardableResult
    func importGaps() async -> SyncJob {
        var job = SyncJob(target: .gaps, status: "sending", snapshotSchema: "gap_clusters")
        guard case .ready = recoveryState else {
            job.status = "failed"; job.error = "Workspace recovery is blocked; no market gaps were imported."
            readImportJobs[.gaps] = job
            return job
        }
        guard !busyTargets.contains(.gaps) else {
            job.status = "failed"; job.error = "A gap import is already running."
            return job
        }
        busyTargets.insert(.gaps); defer { busyTargets.remove(.gaps) }
        readImportJobs[.gaps] = job
        var created = 0, updated = 0, unchanged = 0, retired = 0
        do {
            let clusters = try await gapClient().activeClusters()
            try commitWorkspace { next in
                for cluster in clusters {
                    switch Self.applyGap(cluster, to: &next) {
                    case .created: created += 1
                    case .updated: updated += 1
                    default: unchanged += 1
                    }
                }
                retired = Self.retireMissingGaps(activeSourceIDs: Set(clusters.map { "gap:\($0.id)" }), in: &next)
                job.status = "synced"
                job.detail = "\(created) new, \(updated) updated, \(unchanged) unchanged\(retired > 0 ? ", \(retired) retired" : "")."
                job.completedAt = Date.now.ISO8601Format()
                next.syncJobs.insert(job, at: 0)
                next.connectorHealth[SyncTarget.gaps.rawValue] = ConnectorHealth(ok: true, detail: "Last import \(Date.now.formatted(date: .abbreviated, time: .shortened)): \(job.detail ?? "")")
                next.activity.insert(ActivityEvent(kind: "gap_import", message: "Imported market gaps: \(job.detail ?? "")", sourceID: job.id), at: 0)
            }
            saveFailure = nil
            readImportJobs[.gaps] = job
            showNotice("Market gaps: \(job.detail ?? "")")
            logSync("gap import ok created=\(created) updated=\(updated) unchanged=\(unchanged) retired=\(retired)")
        } catch {
            logSync("gap import failed", error: true)
            return failedReadOnlyImport(job, error: error)
        }
        return job
    }

    /// Failed reads can retain a diagnostic when storage works. A failed save publishes no records,
    /// retirement, success job or health result; the visible error stays outside the saved workspace.
    private func failedReadOnlyImport(_ original: SyncJob, error: Error) -> SyncJob {
        var job = original
        job.status = "failed"; job.detail = nil; job.error = message(for: error)
        job.completedAt = Date.now.ISO8601Format()
        let summary = "\(job.target.label) import failed: \(job.error ?? "unknown error")"
        do {
            try commitWorkspace { next in
                next.syncJobs.insert(job, at: 0)
                next.connectorHealth[job.target.rawValue] = ConnectorHealth(ok: false, detail: job.error ?? "Import failed.")
                next.activity.insert(ActivityEvent(kind: job.target == .gaps ? "gap_import" : "kairos_import", message: summary, sourceID: job.id), at: 0)
            }
            showNotice(summary)
        } catch {
            saveFailure = "Changes were not saved. \(error.localizedDescription)"
            showNotice(saveFailure ?? summary)
        }
        readImportJobs[job.target] = job
        return job
    }

    func latestSyncJob(for target: SyncTarget) -> SyncJob? {
        readImportJobs[target] ?? syncJobs.first { $0.target == target && $0.status != "queued" && $0.status != "staged" }
    }

    private static func applyGap(_ cluster: GapCluster, to workspace: inout PersistentWorkspace) -> LeadPullCounts.Outcome {
        func percent(_ value: Double?) -> Int { min(max(Int(((value ?? 0) * 100).rounded()), 0), 100) }
        let sourceID = "gap:\(cluster.id)"
        let label = [cluster.label, cluster.summary].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Unlabelled gap"
        let scores = cluster.scores
        let category = (cluster.category ?? "other").replacingOccurrences(of: "_", with: " ")
        var evidence = "Gap analysis cluster \(cluster.id): market \(cluster.marketKey ?? "unknown"), category \(category)."
        if let scores {
            evidence += " Scores (0-100): frequency \(percent(scores.frequency)), intensity \(percent(scores.intensity)), breadth \(percent(scores.breadth)), willingness to pay \(percent(scores.willingnessToPay)), workaround \(percent(scores.workaround)), segment \(percent(scores.segment))."
        }
        if let summary = cluster.summary, !summary.isEmpty, summary != label { evidence += " Summary: \(summary)" }

        let index = workspace.signals.firstIndex { $0.sourceID == sourceID }
        var signal = index.map { workspace.signals[$0] } ?? Signal()
        let before = signal
        if index == nil {
            signal.source = .imported
            signal.status = .captured
            signal.sourceID = sourceID
            signal.nextAction = "Decide whether this gap deserves an offer, content, or a product change."
        }
        signal.sourceActive = true
        signal.title = "Market gap: \(label)"
        signal.evidence = evidence
        signal.priority = percent(scores?.total)
        signal.intentScore = percent(scores?.intensity)
        signal.fitScore = percent(scores?.segment)
        if let index { workspace.signals[index] = signal } else { workspace.signals.insert(signal, at: 0) }
        if index == nil { return .created }
        return signal == before ? .unchanged : .updated
    }

    /// Marks imported gap signals absent from a complete active-cluster read as retired.
    /// The signal and all user-owned workflow fields remain intact.
    private static func retireMissingGaps(activeSourceIDs: Set<String>, in workspace: inout PersistentWorkspace) -> Int {
        var retired = 0
        for index in workspace.signals.indices {
            guard let sourceID = workspace.signals[index].sourceID,
                  sourceID.hasPrefix("gap:"), !activeSourceIDs.contains(sourceID),
                  workspace.signals[index].sourceActive != false else { continue }
            workspace.signals[index].sourceActive = false
            retired += 1
        }
        return retired
    }

    var qualifiedSignals: [Signal] { activeSignals.filter { $0.status == .qualified || $0.status == .routed }.sorted { $0.priority > $1.priority } }
    var averageLanguageGap: Double? {
        let gaps = audits.compactMap(\.languageGap)
        guard !gaps.isEmpty else { return nil }
        return gaps.reduce(0, +) / Double(gaps.count)
    }

    /// Totals from owner-entered values only. A converted lead's value and outcome come from its opportunity,
    /// so nothing is counted twice; records without a value are counted, never estimated (LeadWorkflow.outcomes).
    var outcomes: LeadWorkflow.Outcomes { LeadWorkflow.outcomes(leads: leads, opportunities: opportunities) }
    var closeRate: Int { outcomes.closeRate }
    var dollarsWon: Double { outcomes.wonValue }
    var activePipeline: Double { outcomes.openValue }

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

    @discardableResult
    func createWorkspace(name: String, industry: String) -> Bool {
        return saveChange { next in
            next.business = BusinessProfile(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                industry: industry
            )
            return "Workspace created."
        }
    }

    @discardableResult
    func saveBusiness(_ business: BusinessProfile) -> Bool {
        return saveChange { next in
            next.business = business
            return "Settings saved."
        }
    }

    @discardableResult
    func add(_ lead: Lead) -> Bool {
        let saved = saveChange { next in
            if let sourceID = lead.sourceID, !sourceID.isEmpty,
               next.leads.contains(where: { $0.sourceID == sourceID }) {
                throw GTMError.invalid("This source record is already in the pipeline.")
            }
            var linked = lead
            if let companyID = lead.companyID, let company = next.companies.first(where: { $0.id == companyID }) { linked.company = company.name }
            next.leads.insert(linked, at: 0)
            return "\(lead.name) added."
        }
        if saved && workspace.autoPilotEnabled { _ = runAutomations() }
        return saved
    }

    @discardableResult
    func linkLead(_ id: UUID, companyID: UUID?, contactID: UUID?) -> Bool {
        return saveChange { next in
            guard var lead = next.leads.first(where: { $0.id == id }) else { throw GTMError.invalid("This lead no longer exists.") }
            lead.companyID = companyID
            lead.contactID = contactID
            if let companyID, let company = next.companies.first(where: { $0.id == companyID }) { lead.company = company.name }
            replace(&next.leads, with: lead)
            for index in next.signals.indices where next.signals[index].leadID == id {
                next.signals[index].companyID = companyID
                next.signals[index].contactID = contactID
            }
            return "Lead relationships saved."
        }
    }

    @discardableResult
    func createOpportunity(from lead: Lead) -> Opportunity? {
        if let existing = workspace.opportunities.first(where: { $0.leadID == lead.id }) { return existing }
        let opportunity = Opportunity(name: lead.service.isEmpty ? lead.name : "\(lead.name) — \(lead.service)", amount: lead.quoteAmount, stage: .lead, contactID: lead.contactID, companyID: lead.companyID, leadID: lead.id, notes: "Created from the lead pipeline.")
        return add(opportunity) ? opportunity : nil
    }

    /// Preview of converting a reviewed lead into linked company, contact, opportunity and follow-up task records.
    func conversionPlan(for lead: Lead) -> LeadWorkflow.ConversionPlan? {
        LeadWorkflow.conversionPlan(for: lead.id, in: workspace)
    }

    /// Applies exactly the preview the owner confirmed. A changed preview, a blocker or a failed save writes nothing.
    @discardableResult
    func convertLead(confirmed plan: LeadWorkflow.ConversionPlan) -> LeadWorkflow.ConversionResult? {
        var result: LeadWorkflow.ConversionResult?
        do {
            try commitWorkspace { next in result = try LeadWorkflow.applyConversion(plan, to: &next) }
        } catch let error as LeadWorkflow.ConversionError {
            showNotice(error.description)
            return nil
        } catch {
            showNotice("The conversion was not saved. Nothing changed.")
            return nil
        }
        guard let result else { return nil }
        showNotice(result.created.isEmpty ? "Lead already linked; nothing new was created." : "Converted after review: \(result.created.joined(separator: ", ")).")
        return result
    }

    /// Adds one Ready prospect from the Leads list to the CRM pipeline for review. Nothing is sent.
    @discardableResult
    func addProspectToPipeline(_ record: ProspectRecord) -> UUID? {
        var leadID: UUID?
        do {
            try commitWorkspace { next in leadID = try LeadWorkflow.promote(record, into: &next) }
        } catch let error as LeadWorkflow.PromotionError {
            showNotice(error.description)
            if case .alreadyInPipeline(let existing) = error { return existing }
            return nil
        } catch {
            showNotice("The prospect was not added. Nothing changed.")
            return nil
        }
        showNotice("\(record.organisation) added to the pipeline for review.")
        return leadID
    }

    @discardableResult
    func acceptDiscovery(_ candidate: DiscoveryCandidate, research: QuickScanResearchResult? = nil, researchConfig: ICPConfig? = nil) -> UUID? {
        if research == nil, let existing = workspace.leads.first(where: { $0.sourceID == candidate.sourceID }) {
            showNotice("Already in pipeline: \(existing.name).")
            return existing.id
        }
        let researchedDomain = research?.record.businessDomain
        var lead = workspace.leads.first(where: {
            $0.sourceID == candidate.sourceID || (researchedDomain != nil && $0.quickScanResearch?.record.businessDomain == researchedDomain)
        }) ?? Lead.blank()
        let existing = workspace.leads.contains { $0.id == lead.id }
        if !existing {
            lead.name = candidate.name
            lead.company = candidate.name
            lead.phone = candidate.phone ?? ""
            lead.email = candidate.email ?? ""
        }
        // A public business category is evidence about the business, not a service requested by a buyer.
        if !existing { lead.service = "" }
        if !existing { lead.sourceID = candidate.sourceID }
        if !existing { lead.notes = candidate.evidence; lead.createdAt = candidate.capturedAt }
        if let research {
            guard research.record.id == "cw:\(candidate.sourceID)" else { showNotice("The research belongs to a different business."); return nil }
            lead.quickScanResearch = research
            if !existing || lead.email == (candidate.email ?? "") || lead.email.isEmpty { lead.email = research.email ?? "" }
            if !existing || lead.phone == (candidate.phone ?? "") || lead.phone.isEmpty {
                lead.phone = research.contacts.first(where: { $0.kind == .phone })?.value ?? ""
            }
            if lead.name == candidate.name, let person = research.record.contact { lead.name = person.name }
            if lead.outreachDraft == nil, lead.lastMessage.isEmpty, lead.email == research.email,
               let config = researchConfig,
               let draft = research.draft(config: config, suppression: suppressionList, now: .now) {
                lead.outreachDraft = draft.body
            }
        }
        guard saveChange({ next in
            next.websiteResearch.discover([candidate])
            if let research {
                var delta = WebsiteResearchCache(); delta.merge(candidate, result: research)
                next.websiteResearch.mergePreservingNewest(delta)
            }
            if let index = next.leads.firstIndex(where: { $0.id == lead.id }) { next.leads[index] = lead }
            else { next.leads.insert(lead, at: 0) }

            var signal = Signal()
            signal.title = "Public prospect: \(candidate.name)"
            signal.source = .imported
            signal.status = .captured
            signal.fitScore = candidate.researchPriority
            signal.intentScore = 0
            signal.priority = candidate.researchPriority
            signal.leadID = lead.id
            signal.companyID = lead.companyID
            signal.contactID = lead.contactID
            signal.sourceID = candidate.sourceID
            signal.evidence = ([candidate.evidence] + (research?.lines ?? [])).joined(separator: "\n")
            signal.nextAction = lead.outreachDraft != nil ? "Review the source-backed Quick Scan draft. Nothing has been sent." : "Review the automated research findings and recorded unknowns."
            if let index = next.signals.firstIndex(where: { $0.leadID == lead.id && ($0.sourceID == candidate.sourceID || $0.sourceID == lead.sourceID) }) {
                next.signals[index].evidence = signal.evidence
                next.signals[index].nextAction = signal.nextAction
            } else { next.signals.insert(signal, at: 0) }
            next.activity.insert(ActivityEvent(kind: "discovery", message: "Added one public business record to the review pipeline.", sourceID: lead.id), at: 0)
            return "\(candidate.name) added for human review."
        }) else { return nil }
        return lead.id
    }

    @discardableResult
    func add(_ contact: Contact) -> Bool {
        saveChange { next in next.contacts.insert(contact, at: 0); return "Contact added." }
    }
    @discardableResult
    func update(_ contact: Contact) -> Bool {
        saveChange { next in replace(&next.contacts, with: contact); return "Contact saved." }
    }
    @discardableResult
    func delete(_ contact: Contact) -> Bool {
        deleteRecord(contact.id, kind: .contacts)
    }

    @discardableResult
    func add(_ company: Company) -> Bool {
        saveChange { next in next.companies.insert(company, at: 0); return "Company added." }
    }
    @discardableResult
    func update(_ company: Company) -> Bool {
        saveChange { next in replace(&next.companies, with: company); return "Company saved." }
    }
    @discardableResult
    func delete(_ company: Company) -> Bool {
        deleteRecord(company.id, kind: .companies)
    }

    @discardableResult
    func add(_ opportunity: Opportunity) -> Bool {
        saveChange { next in next.opportunities.insert(opportunity, at: 0); return "Opportunity added." }
    }
    @discardableResult
    func update(_ opportunity: Opportunity) -> Bool {
        return saveChange { next in
            replace(&next.opportunities, with: opportunity)
            LeadWorkflow.mirrorOutcome(ofOpportunity: opportunity, in: &next)
            var closedTask: CRMTask?
            if opportunity.stage.isClosed, let leadID = opportunity.leadID, let lead = next.leads.first(where: { $0.id == leadID }) {
                closedTask = LeadWorkflow.syncFollowUpTask(for: lead, in: &next)
            }
            return closedTask == nil ? "Opportunity saved." : "Opportunity saved; the lead's follow-up task is closed and its reminder cancelled."
        }
    }

    @discardableResult
    func delete(_ opportunity: Opportunity) -> Bool {
        deleteRecord(opportunity.id, kind: .opportunities)
    }

    @discardableResult
    func add(_ task: CRMTask) -> Bool {
        saveChange { next in next.tasks.insert(task, at: 0); return "Task added." }
    }
    @discardableResult
    func update(_ task: CRMTask) -> Bool {
        return saveChange { next in
            replace(&next.tasks, with: task)
            // A lead's follow-up task and the lead's next follow-up date stay the same date.
            let leadMoved = LeadWorkflow.syncLead(afterSaving: task, in: &next)
            return leadMoved ? "Task saved; the lead's next follow-up moved to \(task.dueDate ?? "-")." : "Task saved."
        }
    }

    @discardableResult
    func delete(_ task: CRMTask) -> Bool {
        deleteRecord(task.id, kind: .tasks)
    }

    @discardableResult
    func add(_ note: CRMNote) -> Bool {
        saveChange { next in next.notes.insert(note, at: 0); return "Note added." }
    }
    @discardableResult
    func update(_ note: CRMNote) -> Bool {
        saveChange { next in replace(&next.notes, with: note); return "Note saved." }
    }
    @discardableResult
    func delete(_ note: CRMNote) -> Bool {
        deleteRecord(note.id, kind: .notes)
    }

    @discardableResult
    func add(_ signal: Signal) -> Bool {
        saveChange { next in next.signals.insert(signal, at: 0); return "Signal captured." }
    }
    @discardableResult
    func update(_ signal: Signal) -> Bool {
        saveChange { next in replace(&next.signals, with: signal); return "Signal saved." }
    }
    @discardableResult
    func delete(_ signal: Signal) -> Bool {
        saveChange { next in next.signals.removeAll { $0.id == signal.id }; return "Signal deleted." }
    }

    @discardableResult
    func add(_ audit: BilingualAudit) -> Bool {
        saveChange { next in next.audits.insert(audit, at: 0); return "Lantern audit saved." }
    }
    @discardableResult
    func update(_ audit: BilingualAudit) -> Bool {
        saveChange { next in replace(&next.audits, with: audit); return "Lantern audit updated." }
    }
    @discardableResult
    func delete(_ audit: BilingualAudit) -> Bool {
        saveChange { next in next.audits.removeAll { $0.id == audit.id }; return "Lantern audit deleted." }
    }

    @discardableResult
    func setAutomation(_ rule: AutomationRule, enabled: Bool) -> Bool {
        return saveChange { next in
            var updated = rule
            updated.enabled = enabled
            replace(&next.automationRules, with: updated)
            return enabled ? "Automation enabled." : "Automation paused."
        }
    }

    /// Runs only deterministic, local actions. No network calls, message sends, or external mutations occur here.
    @discardableResult
    func runAutomations() -> Int {
        var created = 0
        guard saveChange({ next in
            let today = CalendarCRM.dayString()
            if automationRules.contains(where: { $0.enabled && $0.trigger == .dueFollowUp }) {
                for lead in dueLeads {
                    // A linked next action is retained even when completed or deliberately deleted.
                    // Recording a new date reopens that task through syncFollowUpTask.
                    guard lead.followUpTaskID == nil else { continue }
                    let existing = tasks.first { task in
                        task.leadID == lead.id && task.title == "Follow up with \(lead.name)" && task.dueDate == today
                    }
                    if let existing {
                        if lead.followUpTaskID == nil, existing.leadID == lead.id,
                           let index = next.leads.firstIndex(where: { $0.id == lead.id }) {
                            next.leads[index].followUpTaskID = existing.id
                        }
                        continue
                    }
                    let task = CRMTask(title: "Follow up with \(lead.name)", details: lead.lastMessage.isEmpty ? "Review the relationship record and send the next appropriate follow-up." : lead.lastMessage, dueDate: today, leadID: lead.id)
                    next.tasks.insert(task, at: 0)
                    if let index = next.leads.firstIndex(where: { $0.id == lead.id }) {
                        next.leads[index].followUpTaskID = task.id
                    }
                    next.activity.insert(ActivityEvent(kind: "automation", message: "Created a follow-up task for \(lead.name).", sourceID: lead.id), at: 0)
                    created += 1
                }
            }
            if automationRules.contains(where: { $0.enabled && $0.trigger == .highIntentSignal }) {
                for signal in activeSignals where signal.status == .captured && signal.intentScore >= 70 && signal.fitScore >= 70 {
                    var routed = signal
                    routed.status = .qualified
                    routed.owner = routed.owner.isEmpty ? business.name : routed.owner
                    next.signals[next.signals.firstIndex(where: { $0.id == signal.id })!] = routed
                    next.activity.insert(ActivityEvent(kind: "automation", message: "Qualified high-intent signal: \(signal.title).", sourceID: signal.id), at: 0)
                    created += 1
                }
            }
            if automationRules.contains(where: { $0.enabled && $0.trigger == .auditGap }) {
                for audit in audits {
                    guard let gap = audit.languageGap, gap >= 8 else { continue }
                    let title = "Remediate Lantern gap: \(audit.name)"
                    let alreadyExists = tasks.contains { $0.title == title && $0.status != .done }
                    guard !alreadyExists else { continue }
                    next.tasks.insert(CRMTask(title: title, details: audit.remediation.isEmpty ? "Review evidence and define a human-approved remediation plan." : audit.remediation, dueDate: today), at: 0)
                    next.activity.insert(ActivityEvent(kind: "automation", message: "Flagged \(audit.priority.lowercased()) bilingual gap for remediation.", sourceID: audit.id), at: 0)
                    created += 1
                }
            }
            return created == 0 ? "No new automation actions." : "Ran automations: \(created) action\(created == 1 ? "" : "s")."
        }) else { return 0 }
        return created
    }

    func route(_ signal: Signal, owner: String) {
        var routed = signal
        routed.status = .routed
        routed.owner = owner
        routed.routedAt = Date.now.ISO8601Format()
        update(routed)
    }

    @discardableResult
    func add(_ view: SavedView) -> Bool {
        saveChange { next in next.savedViews.append(view); return "View saved." }
    }
    @discardableResult
    func delete(_ view: SavedView) -> Bool {
        return saveChange { next in
            next.savedViews.removeAll { $0.id == view.id }
            return "View deleted."
        }
    }

    private func replace<T: Identifiable>(_ collection: inout [T], with value: T) where T.ID: Equatable {
        guard let index = collection.firstIndex(where: { $0.id == value.id }) else { return }
        collection[index] = value
    }

    @discardableResult
    func update(_ lead: Lead) -> Bool {
        return saveChange { next in
            guard let index = next.leads.firstIndex(where: { $0.id == lead.id }) else { throw GTMError.invalid("This lead no longer exists.") }
            var linked = lead
            if let companyID = lead.companyID, let company = next.companies.first(where: { $0.id == companyID }) { linked.company = company.name }
            next.leads[index] = linked
            for signalIndex in next.signals.indices where next.signals[signalIndex].leadID == lead.id {
                next.signals[signalIndex].companyID = lead.companyID
                next.signals[signalIndex].contactID = lead.contactID
            }
            LeadWorkflow.mirrorOutcome(ofLead: lead, in: &next)
            // The follow-up task follows the lead's next follow-up; a won or lost lead closes it and cancels its reminder.
            let changedTask = LeadWorkflow.syncFollowUpTask(for: lead, in: &next)
            let message = changedTask.map {
                $0.status == .done ? "Lead saved; its follow-up task is closed and its reminder cancelled." : "Lead saved; the follow-up task moved to \($0.dueDate ?? "-")."
            } ?? "Lead saved."
            return message
        }
    }

    @discardableResult
    func delete(_ lead: Lead) -> Bool {
        deleteRecord(lead.id, kind: .leads)
    }

    var deletionRecoveryDirectory: URL { storageURL.deletingLastPathComponent().appendingPathComponent("record-recovery", isDirectory: true) }

    /// Recovery is part of deletion: if either the private backup or commit fails, the record stays.
    private func deleteRecord(_ id: UUID, kind: RecordDeletion.Kind) -> Bool {
        var backup: URL?
        let saved = saveChange { next in
            guard RecordDeletion.contains(id, kind: kind, in: next) else { throw ControlWardError.invalid("This record no longer exists. Refresh the directory.") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(ControlWardBackup(workspace: completeBackupWorkspace()))
            guard data.count <= 20_000_000 else { throw ControlWardError.invalid("The recovery backup exceeds 20 MB. Nothing was deleted.") }
            let file = deletionRecoveryDirectory.appendingPathComponent("before-delete-\(kind.rawValue)-\(UUID()).json")
            try SecureFiles.writePrivate(data, to: file)
            backup = file
            RecordDeletion.apply(id, kind: kind, to: &next)
            next.activity.insert(ActivityEvent(kind: "record_delete", message: "Deleted one local \(kind.label.lowercased()). Linked records were retained; recovery backup: \(file.lastPathComponent).", sourceID: id), at: 0)
            return "\(kind.label) deleted. Recovery backup saved; restore it from Settings → Backup and recovery."
        }
        if saved { lastDeletionBackup = backup }
        return saved
    }

    @discardableResult
    func markSecurityReviewed() -> Bool {
        return saveChange { next in
            next.lastSecurityReview = Date.now.ISO8601Format()
            return "Local record review saved."
        }
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
        guard activeResearch.isEmpty, busyTargets.isEmpty else { throw ControlWardError.invalid("Wait for running research and integrations before resetting.") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backup = storageURL.deletingLastPathComponent()
            .appendingPathComponent("workspace-backup-\(formatter.string(from: .now)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let retained = try completeBackupWorkspace()
        try SecureFiles.writePrivate(try encoder.encode(retained), to: backup)
        let consumed = try currentResearchRecoveryDigest()
        try commitWorkspace {
            $0 = PersistentWorkspace()
            $0.restoredSuppressionEntries = retained.restoredSuppressionEntries
            $0.consumedResearchRecovery = consumed
        }
        showNotice("Workspace reset. Backup saved as \(backup.lastPathComponent).")
        return backup
    }

    /// One-time, user-selected import of the pre-sandbox `native-crm/data/workspace.json`.
    func importLegacyWorkspace(from legacy: URL) throws {
        let outcome = try WorkspaceMigration.migrateLegacy(from: legacy, to: storageURL)
        let loaded = Self.load(from: storageURL)
        workspace = loaded.workspace
        recoveryState = loaded.recovery
        scrubStoredEndpointSecrets()
        if case .ready = recoveryState { queueReminderReconciliation() }
        showNotice(outcome.legacyRestricted
            ? "Imported and hash-verified the legacy workspace. The original was kept and set to owner-only access."
            : "Imported and hash-verified the legacy workspace. The original was kept; run chmod 600 on it manually.")
    }

    var exchange: WorkspaceExchange {
        WorkspaceExchange(
            business: business, leads: leads, contacts: contacts, companies: companies,
            opportunities: opportunities, tasks: tasks, notes: notes, signals: activeSignals,
            audits: audits, activity: activity, syncJobs: syncJobs, exposureFindings: exposureFindings, connectorEndpoints: workspace.connectorEndpoints
        )
    }

    func exportExchange(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(exchange).write(to: url, options: .atomic)
        try? SecureFiles.restrict(url)
        workspace.activity.insert(ActivityEvent(kind: "export", message: "Exported ControlWard exchange snapshot."), at: 0)
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
            "signals": activeSignals.count, "audits": audits.count, "findings": exposureFindings.count,
        ])
    }

    /// Local-only Pharos hygiene scan. This is a data-quality and exposure review,
    /// not a penetration test or external intelligence scan.
    @discardableResult
    func runLocalExposureScan() -> Int {
        var count = 0
        let saved = saveChange { next in
            let previous = next.exposureFindings
            var findings = previous.filter(\.resolved)
            func record(_ candidate: ExposureFinding) {
                let retained = previous.first { $0.recordID == candidate.recordID && $0.lens == candidate.lens && $0.title == candidate.title } ?? candidate
                if !findings.contains(where: { $0.id == retained.id }) { findings.append(retained) }
            }
            let sensitiveTerms = ["password", "secret", "token", "ssn", "sin", "credit card", "api key"]
            for lead in next.leads {
                let text = "\(lead.notes) \(lead.lastMessage)".lowercased()
                if sensitiveTerms.contains(where: { text.contains($0) }) {
                    record(ExposureFinding(lens: "AI / Privacy Exposure", severity: .high, title: "Sensitive-looking text in lead record", detail: "Review and remove credentials or identity numbers from notes and messages.", recordID: lead.id))
                }
                if lead.email.isEmpty && lead.phone.isEmpty {
                    record(ExposureFinding(lens: "Identity Exposure", severity: .warning, title: "Lead lacks a contact channel", detail: "Confirm the source and retention need before keeping this record.", recordID: lead.id))
                }
            }
            for signal in next.signals where signal.sourceActive != false && signal.evidence.isEmpty {
                record(ExposureFinding(lens: "Digital Exposure", severity: .warning, title: "Signal has no evidence trail", detail: "Add the source event, file, or operator note before routing.", recordID: signal.id))
            }
            next.exposureFindings = findings
            count = findings.count
            next.activity.insert(ActivityEvent(kind: "security_scan", message: "Ran local workspace exposure scan: \(count) finding\(count == 1 ? "" : "s")."), at: 0)
            return "Local exposure scan complete."
        }
        return saved ? count : 0
    }

    func resolve(_ finding: ExposureFinding) {
        _ = saveChange { next in
            guard let index = next.exposureFindings.firstIndex(where: { $0.id == finding.id }) else { throw ControlWardError.invalid("This finding is no longer available.") }
            next.exposureFindings[index].resolved = true
            return "Finding marked resolved."
        }
    }

    /// Permission requests happen only after the owner selects Schedule reminders.
    func scheduleDueFollowUpReminders() async -> Int {
        await reconcileReminders(requestPermission: true)
    }

    func scheduleTaskReminders() async { _ = await reconcileReminders(requestPermission: false) }

    private func queueReminderReconciliation() {
        guard reminderCoordinator != nil else { return }
        let desired = LeadWorkflow.reminders(in: workspace)
        guard lastQueuedReminders != desired else { return }
        lastQueuedReminders = desired
        Task { _ = await reconcileReminders(requestPermission: false) }
    }

    private func reconcileReminders(requestPermission: Bool) async -> Int {
        guard let reminderCoordinator else { return 0 }
        let result = await reminderCoordinator.reconcile(LeadWorkflow.reminders(in: workspace), requestPermission: requestPermission)
        reminderStatus = result.message
        if requestPermission { showNotice(result.message) }
        return result.scheduled
    }

    /// CSV-1..CSV-8 (Water 9:42 AM ET): every row is accounted for. Imported, skipped (no name) or flagged for review
    /// (placeholder or role names, duplicate leads), with warnings for values left empty and the columns it ignored.
    /// The result stays on `lastCSVImport` until Martin closes it. A failed save keeps nothing from the file.
    func importCSV(from url: URL) throws -> Int {
        let data = try ImportLimits.readCapped(url)
        let fileName = url.lastPathComponent
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let earlier = importedCSVFiles[digest] {
            var result = CSVImportResult(fileName: fileName, finishedAt: Date())
            result.alreadyImportedAt = earlier
            result.summary = "This file was already imported at \(earlier.formatted(date: .omitted, time: .shortened)). Nothing was imported and nothing was merged."
            lastCSVImport = result
            return 0
        }
        guard let text = ImportLimits.decodeText(data) else {
            throw ImportLimits.error(415, "\(fileName) is not UTF-8, UTF-16, or Windows-1252 text. Save it as CSV UTF-8 and import again.")
        }
        let rows = CSVParser.parse(text)
        try ImportLimits.checkRows(max(rows.count - 1, 0), fileName)
        let headers = rows.first ?? []
        // Exact header names or known alternatives only; unknown columns are ignored and named.
        let fields = CSVHeaderMap.fields(for: headers)
        var result = CSVImportResult(fileName: fileName, finishedAt: Date())
        result.ignoredColumns = zip(headers, fields).compactMap { header, field in
            let name = header.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return field == nil && !name.isEmpty ? name : nil
        }
        guard fields.contains(where: { $0 != nil }) else {
            result.summary = rows.isEmpty ? "No valid leads found in CSV." : "No recognized columns in CSV. Use headers such as name, email, phone, company, service, quote."
            lastCSVImport = result
            return 0
        }
        func key(_ name: String, _ company: String) -> String {
            func clean(_ text: String) -> String {
                text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            return clean(name) + "|" + clean(company)
        }
        var known = Set(workspace.leads.map { key($0.name, $0.company) })
        var imported: [Lead] = []
        var companyColumnsUsed = Set<Int>()
        for (offset, row) in rows.enumerated().dropFirst() where !row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let rowNumber = offset + 1
            var lead = Lead.blank()
            lead.name = ""
            var firstName = "", lastName = ""
            var rowWarnings: [String] = []
            for (index, field) in fields.enumerated() {
                guard let field else { continue }
                let value = index < row.count ? row[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let header = headers[index].replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                switch field {
                case .name: lead.name = value
                case .firstName: firstName = value
                case .lastName: lastName = value
                case .email: lead.email = value
                case .phone: lead.phone = value
                case .company:
                    if lead.company.isEmpty, !value.isEmpty { lead.company = value; companyColumnsUsed.insert(index) }
                case .service: lead.service = value
                case .amount:
                    switch CSVValue.amount(value) {
                    case .value(let amount): lead.quoteAmount = amount
                    case .unreadable: rowWarnings.append("row \(rowNumber), \(header): \"\(value)\"")
                    case .empty: break
                    }
                case .date:
                    switch CSVValue.date(value) {
                    case .day(let day): if let date = CalendarCRM.date(from: day) { lead.createdAt = date.ISO8601Format() }
                    case .ambiguous: rowWarnings.append("row \(rowNumber), \(header): \"\(value)\" (ambiguous day/month, not guessed)")
                    case .unreadable: rowWarnings.append("row \(rowNumber), \(header): \"\(value)\"")
                    case .empty: break
                    }
                }
            }
            if lead.name.isEmpty {
                lead.name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
            }
            guard !lead.name.isEmpty else {
                result.skipped.append(CSVRowNote(row: rowNumber, reason: "no-name"))
                continue
            }
            if let reason = CSVNameCheck.flag(lead.name) {
                result.flagged.append(CSVRowNote(row: rowNumber, reason: reason))
                result.rowNames[rowNumber] = lead.name
                continue
            }
            guard known.insert(key(lead.name, lead.company)).inserted else {
                result.flagged.append(CSVRowNote(row: rowNumber, reason: "duplicate-lead"))
                result.rowNames[rowNumber] = lead.name
                continue
            }
            result.warnings += rowWarnings
            imported.append(lead)
        }
        result.companyColumns = companyColumnsUsed.sorted().map {
            headers[$0].replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let previous = workspace
        workspace.leads.insert(contentsOf: imported, at: 0)
        do {
            try persistOrThrow()
        } catch {
            workspace = previous
            var failed = CSVImportResult(fileName: fileName, finishedAt: Date())
            failed.failure = error.localizedDescription
            failed.summary = "Import failed: the leads could not be saved (\(error.localizedDescription)). Nothing from this file was kept."
            lastCSVImport = failed
            return 0
        }
        importedCSVFiles[digest] = result.finishedAt
        result.imported = imported.count
        result.summary = imported.isEmpty ? "No valid leads found in CSV." : "Imported \(imported.count) lead\(imported.count == 1 ? "" : "s") from CSV."
        lastCSVImport = result
        return imported.count
    }

    /// Imports exported LeadGen stage payloads without making a network request.
    /// Accepts one object or an array, and preserves the source filename in evidence.
    func importLeadGenJSON(from url: URL) throws -> Int {
        let events = try LeadGenEvent.decodeBatch(try ImportLimits.readCapped(url), source: url.lastPathComponent)
        var imported = 0
        var skipped = 0
        var existing = 0
        try commitWorkspace { next in
          for event in events {
            let identity = event.identity
            func clean(_ value: String?) -> String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let name = [clean(identity.firstName), clean(identity.lastName)].filter { !$0.isEmpty }.joined(separator: " ")
            let email = clean(identity.email ?? event.email)
            let phone = clean(identity.phoneRaw)
            let company = clean(identity.companyNameRaw)
            guard !name.isEmpty || !email.isEmpty else { skipped += 1; continue }

            // File exports do not prove an inbound conversation. Keep their IDs separate from the live inbox.
            let eventID = clean(event.eventID)
            let identityData = try JSONEncoder().encode([name.lowercased(), email.lowercased(), LeadMatching.phoneKey(phone) ?? phone, company.lowercased()])
            let identityHash = SHA256.hash(data: identityData).map { String(format: "%02x", $0) }.joined()
            let sourceID = "leadgen-file:" + (eventID.isEmpty ? "identity-" + identityHash : "event-" + eventID)
            let legacyEvidence = "Event ID: \(eventID)."
            guard !next.signals.contains(where: {
                $0.sourceID == sourceID || (!eventID.isEmpty && $0.sourceID == nil && $0.title.hasPrefix("LeadGen: ") && $0.evidence.hasSuffix(legacyEvidence))
            }) else { existing += 1; continue }

            let exact = next.leads.filter { $0.sourceID == sourceID }
            let emailMatches = email.isEmpty ? [] : next.leads.filter { clean($0.email).caseInsensitiveCompare(email) == .orderedSame }
            let matches = exact.isEmpty ? emailMatches : exact
            guard matches.count <= 1 else {
                throw ImportLimits.error(409, "LeadGen import matches multiple existing leads. Resolve the duplicate identity first; nothing from this file was imported.")
            }
            let lead: Lead
            if let known = matches.first {
                // Preserve owner edits, existing source identity, values, status and relationship links.
                lead = known
            } else {
                var created = Lead.blank()
                created.name = name.isEmpty ? email : name
                created.email = email
                created.phone = phone
                created.company = company
                created.sourceID = sourceID
                if let captured = event.capturedAt, ISO8601DateFormatter().date(from: captured) != nil { created.createdAt = captured }
                next.leads.insert(created, at: 0)
                lead = created
            }

            var signal = Signal()
            signal.title = "LeadGen: \(lead.name)"
            signal.source = .imported
            signal.sourceID = sourceID
            signal.status = .captured
            signal.leadID = lead.id
            signal.evidence = "Imported from \(url.lastPathComponent). Event ID: \(eventID.isEmpty ? "not supplied" : eventID). Scores were supplied in this file; they are not verified buying intent."
            signal.nextAction = "Resolve identity, qualify fit, and route."
            signal.fitScore = min(max(event.fitScore ?? 0, 0), 100)
            signal.intentScore = min(max(event.intentScore ?? 0, 0), 100)
            signal.priority = min(max(event.compositeScore ?? ((signal.fitScore + signal.intentScore) / 2), 0), 100)
            next.signals.insert(signal, at: 0)
            next.activity.insert(ActivityEvent(kind: "import", message: "Imported one LeadGen file event for review.", sourceID: lead.id), at: 0)
            imported += 1
          }
        }
        showNotice("LeadGen: \(imported) imported, \(existing) already recorded, \(skipped) missing an identity.")
        return imported
    }

    /// Imports a flat BAEA export. Expected columns include audit, client, language,
    /// disclosure, escalation, context_transfer, tone, hallucinations, sample_size.
    func importBAEACSV(from url: URL) throws -> Int {
        let rows = CSVParser.parse(try ImportLimits.readCappedText(url))
        try ImportLimits.checkRows(rows.count - 1, url.lastPathComponent)
        return try importBAEARows(rows, source: url.lastPathComponent)
    }

    /// Reads the first worksheet of a BAEA .xlsx export with an in-process ZIP reader and XMLParser.
    /// This intentionally supports the workbook's flat score-table shape without adding a third-party runtime.
    func importBAEAXLSX(from url: URL) throws -> Int {
        let archive = try ImportLimits.readCapped(url)
        // Excel writes shared strings; openpyxl and others may use inline strings instead.
        let strings = try zipText(archive, entry: "xl/sharedStrings.xml", required: false).map(XLSXXMLParser.sharedStrings) ?? []
        let overview = XLSXXMLParser.rows(try zipText(archive, entry: "xl/worksheets/sheet1.xml") ?? "", sharedStrings: strings)
        try ImportLimits.checkRows(overview.count - 1, url.lastPathComponent)
        let directCount = try importBAEARows(overview, source: url.lastPathComponent)
        if directCount > 0 { return directCount }

        // Canonical BAEA workbooks store one scored transcript per row on EN_Transcripts and FR_Transcripts.
        var normalized = [["audit", "client", "language", "disclosure", "escalation", "context_transfer", "tone", "hallucinations", "sample_size", "transcript_id", "workflow", "date", "taxonomy_codes", "quoted_excerpt"]]
        for (sheetNumber, language) in [(2, "EN"), (3, "FR")] {
            let rows = XLSXXMLParser.rows(try zipText(archive, entry: "xl/worksheets/sheet\(sheetNumber).xml") ?? "", sharedStrings: strings)
            try ImportLimits.checkRows(normalized.count + rows.count - 1, url.lastPathComponent)
            let headers = (rows.first ?? []).map { $0.lowercased().replacingOccurrences(of: " ", with: "_") }
            for (offset, row) in rows.dropFirst().enumerated() where !row.isEmpty && !row[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The canonical template prefills transcript IDs. An ID alone is
                // not a scored transcript and must not create zero-score evidence.
                if row.dropFirst().allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }
                func invalid(_ column: String) -> NSError {
                    ImportLimits.error(422, "\(url.lastPathComponent), \(language) worksheet row \(offset + 2), \(column): use a numeric score from 0 to 5. Nothing from this file was imported.")
                }
                guard row.count >= 8 else { throw invalid("score columns") }
                func scaled(_ index: Int) throws -> String {
                    guard let value = Double(row[index]), value.isFinite, (0...5).contains(value) else {
                        throw invalid(index < headers.count ? headers[index] : "score")
                    }
                    return String(value * 20)
                }
                func text(_ names: String...) -> String {
                    for name in names { if let index = headers.firstIndex(of: name), index < row.count { return row[index] } }
                    return ""
                }
                normalized.append(try [url.deletingPathExtension().lastPathComponent, url.deletingPathExtension().lastPathComponent, language, scaled(3), scaled(4), scaled(5), scaled(6), scaled(7), "1", row[0], row[1], row[2], text("taxonomy_code(s)", "taxonomy_codes"), text("notes_/_quoted_excerpt", "notes", "quoted_excerpt")])
            }
        }
        return try importBAEARows(normalized, source: url.lastPathComponent)
    }

    private func importBAEARows(_ rows: [[String]], source: String) throws -> Int {
        guard rows.count > 1 else {
            showNotice("No Lantern scores found.")
            return 0
        }
        let headers = rows[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "_") }
        struct ScoreSum {
            var total = AuditDimensionScore()
            var samples = 0
            mutating func add(_ score: AuditDimensionScore, weight: Int, checkedTotal: Int) {
                guard weight > 0 else { return }
                let count = Double(weight)
                total.disclosure += score.disclosure * count
                total.escalation += score.escalation * count
                total.contextTransfer += score.contextTransfer * count
                total.tone += score.tone * count
                total.hallucinations += score.hallucinations * count
                samples = checkedTotal
            }
            var mean: AuditDimensionScore {
                guard samples > 0 else { return AuditDimensionScore() }
                let count = Double(samples)
                // All input scores are in 0...100; keep floating-point boundary
                // noise from making a mathematically valid mean look unscored.
                func bounded(_ sum: Double) -> Double { min(100, max(0, sum / count)) }
                return AuditDimensionScore(disclosure: bounded(total.disclosure), escalation: bounded(total.escalation),
                    contextTransfer: bounded(total.contextTransfer), tone: bounded(total.tone), hallucinations: bounded(total.hallucinations))
            }
        }
        var grouped: [String: BilingualAudit] = [:]
        var sums: [String: (french: ScoreSum, english: ScoreSum)] = [:]
        for (offset, row) in rows.dropFirst().enumerated() {
            func value(_ names: String...) -> String {
                for name in names { if let i = headers.firstIndex(of: name), i < row.count { return row[i].trimmingCharacters(in: .whitespacesAndNewlines) } }
                return ""
            }
            let auditName = value("audit", "audit_name")
            guard !auditName.isEmpty else { continue }
            var audit = grouped[auditName] ?? BilingualAudit(name: auditName, client: value("client"))
            let language = value("language").uppercased()
            func invalid(_ column: String, _ requirement: String) -> NSError {
                ImportLimits.error(422, "\(source), row \(offset + 2), \(column): \(requirement). Nothing from this file was imported.")
            }
            guard language == "FR" || language == "EN" else { throw invalid("language", "use FR or EN") }
            func scoreValue(_ raw: String, column: String) throws -> Double {
                guard !raw.isEmpty else { return 0 }
                guard let number = Double(raw), number.isFinite, (0...100).contains(number) else { throw invalid(column, "use a number from 0 to 100") }
                return number
            }
            let rawScores = [value("disclosure"), value("escalation"), value("context_transfer", "context"), value("tone", "tone_register"), value("hallucinations", "hallucination")]
            let complete = rawScores.allSatisfy { !$0.isEmpty }
            let score = try AuditDimensionScore(disclosure: scoreValue(rawScores[0], column: "disclosure"),
                escalation: scoreValue(rawScores[1], column: "escalation"), contextTransfer: scoreValue(rawScores[2], column: "context_transfer"),
                tone: scoreValue(rawScores[3], column: "tone"), hallucinations: scoreValue(rawScores[4], column: "hallucinations"))
            let rawSamples = value("sample_size", "samples")
            let parsedSamples = Double(rawSamples).flatMap { $0.isFinite ? Int(exactly: $0) : nil }
            guard let samples = rawSamples.isEmpty ? 1 : (Int(rawSamples) ?? parsedSamples), samples >= 0 else {
                throw invalid("sample_size", "use a non-negative whole number")
            }
            let previousSamples = language == "FR" ? audit.sampleSizeFR : audit.sampleSizeEN
            let (totalSamples, overflow) = previousSamples.addingReportingOverflow(samples)
            guard !overflow else { throw invalid("sample_size", "the total sample count is too large") }
            if language == "FR" { audit.french = score; audit.sampleSizeFR = totalSamples }
            else { audit.english = score; audit.sampleSizeEN = totalSamples }
            var weighted = sums[auditName] ?? (french: ScoreSum(), english: ScoreSum())
            if language == "FR" { weighted.french.add(score, weight: samples, checkedTotal: totalSamples) }
            else { weighted.english.add(score, weight: samples, checkedTotal: totalSamples) }
            sums[auditName] = weighted
            audit.transcripts.append(BAEATranscript(
                transcriptID: value("transcript_id", "id"),
                language: language == "FR" ? .french : .english,
                workflow: value("workflow"),
                date: value("date"),
                scores: score,
                taxonomyCodes: value("taxonomy_code(s)", "taxonomy_codes", "taxonomy"),
                notes: value("notes_/_quoted_excerpt", "notes", "quoted_excerpt"),
                source: source,
                sampleCount: samples,
                scoreFieldsComplete: complete
            ))
            grouped[auditName] = audit
        }
        for name in Array(grouped.keys) {
            guard var audit = grouped[name], let weighted = sums[name] else { continue }
            audit.french = weighted.french.mean; audit.english = weighted.english.mean
            grouped[name] = audit
        }
        guard !grouped.isEmpty else { showNotice("No Lantern scores found."); return 0 }
        try commitWorkspace { next in
          for var audit in grouped.values.sorted(by: { $0.name < $1.name }) {
            let existing = next.audits.indices.filter { next.audits[$0].name == audit.name }
            guard existing.count <= 1 else {
                throw ImportLimits.error(409, "\(source) matches multiple audits named \(audit.name). Resolve the duplicate names first. Nothing from this file was imported.")
            }
            if let index = existing.first {
                let reviewed = next.audits[index]
                audit.id = reviewed.id; audit.createdAt = reviewed.createdAt
                audit.leadID = reviewed.leadID; audit.contactID = reviewed.contactID; audit.companyID = reviewed.companyID
                audit.findings = reviewed.findings; audit.remediation = reviewed.remediation
                audit.methodologyVersion = reviewed.methodologyVersion
                // An explicit owner withholding decision survives a source refresh.
                // Positive approval is rebound to the newly imported source evidence.
                audit.frenchScoresComplete = reviewed.frenchScoresComplete == false ? false : nil
                audit.englishScoresComplete = reviewed.englishScoresComplete == false ? false : nil
                if audit.client.isEmpty { audit.client = reviewed.client }
                // Keep identical transcript identities stable on replay, consuming each
                // old identity once so repeated identical rows still remain distinct.
                var previous = reviewed.transcripts
                for i in audit.transcripts.indices {
                    if let match = previous.firstIndex(where: { old in
                        var incoming = audit.transcripts[i]; incoming.id = old.id
                        if old.sampleCount == nil { incoming.sampleCount = nil }
                        if old.scoreFieldsComplete == nil { incoming.scoreFieldsComplete = nil }
                        return incoming == old
                    }) {
                        audit.transcripts[i].id = previous.remove(at: match).id
                    }
                }
                next.audits[index] = audit
            } else { next.audits.insert(audit, at: 0) }
            next.activity.insert(ActivityEvent(kind: "import", message: "Imported Lantern score export for \(audit.name) from \(source).", sourceID: audit.id), at: 0)
          }
        }
        showNotice("Imported \(grouped.count) Lantern audit\(grouped.count == 1 ? "" : "s").")
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

    func generateMessage(for originalLead: Lead) async -> GeneratedMessage {
        let lead = LeadWorkflow.normalizeKairosLead(originalLead)
        let grounded = groundedDraft(for: lead)
#if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return LeadWorkflow.AIDraft.accept(nil, draft: grounded, lead: lead) }
        return await generateOnDevice(for: lead, grounded: grounded)
#else
        return LeadWorkflow.AIDraft.accept(nil, draft: grounded, lead: lead)
#endif
    }

#if canImport(FoundationModels)
    /// The model only rephrases the grounded draft; LeadWorkflow.AIDraft checks its text before it is shown.
    @available(macOS 26.0, *)
    private func generateOnDevice(for lead: Lead, grounded: LeadWorkflow.GroundedDraft) async -> GeneratedMessage {
        guard SystemLanguageModel.default.availability == .available else {
            return LeadWorkflow.AIDraft.accept(nil, draft: grounded, lead: lead)
        }
        do {
            let session = LanguageModelSession(instructions: LeadWorkflow.AIDraft.instructions)
            let response = try await session.respond(to: LeadWorkflow.AIDraft.prompt(for: grounded))
            return LeadWorkflow.AIDraft.accept(response.content, draft: grounded, lead: lead)
        } catch {
            return LeadWorkflow.AIDraft.accept(nil, draft: grounded, lead: lead)
        }
    }
#endif

    /// Local draft that states only recorded facts (no invented quote, intent or private notes).
    func groundedDraft(for lead: Lead) -> LeadWorkflow.GroundedDraft {
        LeadWorkflow.draft(for: lead, in: workspace, business: business)
    }

    func standardMessage(for lead: Lead) -> String { groundedDraft(for: lead).text }

    @discardableResult
    func markMessageSent(on lead: inout Lead, message: String) -> Bool {
        var next = lead
        let today = CalendarCRM.dayString()
        let stage = next.sequenceStage
        let delay = stage < FollowUpCadence.days.count ? FollowUpCadence.days[stage] : nil
        next.lastMessage = message
        next.outreachDraft = nil
        next.sequenceStage = min(stage + 1, FollowUpCadence.days.count)
        next.nextFollowUp = delay.flatMap { CalendarCRM.addDays($0, to: today) }
        next.history.append(FollowUpEvent(date: today, message: message))
        guard update(next) else { return false }
        lead = next
        return true
    }

    private static func load(from url: URL) -> (workspace: PersistentWorkspace, recovery: WorkspaceRecoveryState) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (PersistentWorkspace(), .ready) }
        do {
            let data = try Data(contentsOf: url)
            return (try JSONDecoder().decode(PersistentWorkspace.self, from: data), .ready)
        } catch {
            return (PersistentWorkspace(), .blocked("The existing workspace could not be read. Its original bytes were preserved and all workspace writes are blocked."))
        }
    }

    /// Commit a complete GTM transaction to disk before publishing it to the UI.
    /// A failed import/task write cannot leave a partial in-memory success.
    func commitGTM(_ mutation: (inout PersistentWorkspace) throws -> Void) throws {
        try commitWorkspace(mutation)
    }

    func clearSaveFailure() { saveFailure = nil }

    @discardableResult
    private func saveChange(_ mutation: (inout PersistentWorkspace) throws -> String) -> Bool {
        do {
            var message = "Saved."
            try commitWorkspace { next in message = try mutation(&next) }
            saveFailure = nil
            showNotice(message)
            return true
        } catch {
            let message = "Changes were not saved. \(error.localizedDescription)"
            saveFailure = message
            showNotice(message)
            return false
        }
    }

    /// Publish local workflow changes only after the complete transaction is durable.
    func commitWorkspace(_ mutation: (inout PersistentWorkspace) throws -> Void) throws {
        guard case .ready = recoveryState else { throw GTMError.invalid("Workspace recovery is required before saving.") }
        var next = workspace
        try mutation(&next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= 20_000_000 else { throw ControlWardError.invalid("The native workspace exceeds 20 MB. No changes were saved; export or archive records before adding more research.") }
        try SecureFiles.writePrivate(data, to: storageURL)
        workspace = next
        queueReminderReconciliation()
        twentyPreview = nil
        pharosPreviewFingerprint = nil
    }

    /// Writes or throws; the file importer restores its previous workspace on failure.
    private func persistOrThrow() throws {
        guard case .ready = recoveryState else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "Workspace recovery is required before saving."])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFiles.writePrivate(try encoder.encode(workspace), to: storageURL)
        queueReminderReconciliation()
    }

    private func persist(message: String? = nil) {
        guard case .ready = recoveryState else {
            showNotice("Workspace recovery required. The existing file was not changed.")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try SecureFiles.writePrivate(try encoder.encode(workspace), to: storageURL)
            queueReminderReconciliation()
            if let message { showNotice(message) }
        } catch {
            showNotice("Could not save CRM data: \(error.localizedDescription)")
        }
    }

    /// Martin closes the import result panel.
    func dismissCSVImport() { lastCSVImport = nil }

#if CONTEXTWARD_ACCEPTANCE
    func showNoticeForTesting(_ message: String) { showNotice(message) }
#endif

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

enum CSVParser {
    /// Parses RFC 4180-style CSV. Works on Unicode scalars so CRLF ("\r\n", a single
    /// Swift Character) still ends a row. The delimiter is detected from the first rows
    /// (comma, semicolon as in French-locale Excel, or tab) unless an Excel `sep=` line
    /// names it. A leading byte-order mark and leading blank lines are dropped.
    static func parse(_ text: String) -> [[String]] {
        var scalars = Substring(text).unicodeScalars[...]
        if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }
        scalars = scalars.drop { $0 == "\n" || $0 == "\r" }
        let delimiter: Unicode.Scalar
        if let hinted = separatorHint(scalars) {
            delimiter = hinted.delimiter
            scalars = scalars[hinted.rest...]
        } else {
            delimiter = detectDelimiter(scalars)
        }

        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false
        var index = scalars.startIndex

        func endRow() {
            row.append(String(field))
            if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
            row = []
            field = String.UnicodeScalarView()
        }

        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\"" {
                let next = scalars.index(after: index)
                if quoted, next < scalars.endIndex, scalars[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    quoted.toggle()
                }
            } else if scalar == delimiter, !quoted {
                row.append(String(field))
                field = String.UnicodeScalarView()
            } else if scalar == "\n" || scalar == "\r", !quoted {
                if scalar == "\r" {
                    let next = scalars.index(after: index)
                    if next < scalars.endIndex, scalars[next] == "\n" { index = next }
                }
                endRow()
            } else {
                field.append(scalar)
            }
            index = scalars.index(after: index)
        }

        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Excel writes `sep=;` as the first line when the delimiter differs from the locale default.
    private static func separatorHint(_ scalars: Substring.UnicodeScalarView) -> (delimiter: Unicode.Scalar, rest: Substring.UnicodeScalarView.Index)? {
        let line = Array(scalars.prefix { $0 != "\n" && $0 != "\r" })
        guard line.count == 5, String(String.UnicodeScalarView(line[..<4])).lowercased() == "sep=" else { return nil }
        var rest = scalars.index(scalars.startIndex, offsetBy: line.count)
        while rest < scalars.endIndex, scalars[rest] == "\r" || scalars[rest] == "\n" { rest = scalars.index(after: rest) }
        return (line[4], rest)
    }

    /// Counts unquoted candidates per record over the first rows. A delimiter that appears
    /// the same number of times in every sampled record wins, so a stray comma in a tab or
    /// semicolon file (a "Last, First" header, French decimals) does not outvote it.
    /// Otherwise the most frequent candidate wins; ties keep comma, then semicolon.
    private static func detectDelimiter(_ scalars: Substring.UnicodeScalarView) -> Unicode.Scalar {
        let candidates: [Unicode.Scalar] = [",", ";", "\t"]
        let sampleLimit = 10
        var samples: [[Int]] = []
        var counts = [0, 0, 0]
        var quoted = false, hasContent = false

        for scalar in scalars {
            if scalar == "\"" { quoted.toggle(); hasContent = true; continue }
            if !quoted, scalar == "\n" || scalar == "\r" {
                if hasContent { samples.append(counts) }
                counts = [0, 0, 0]
                hasContent = false
                if samples.count == sampleLimit { break }
                continue
            }
            hasContent = true
            if !quoted, let candidate = candidates.firstIndex(of: scalar) { counts[candidate] += 1 }
        }
        if hasContent, samples.count < sampleLimit { samples.append(counts) }

        var best: (index: Int, score: Int)?
        for index in candidates.indices {
            let perRecord = samples.map { $0[index] }
            guard let first = perRecord.first, first > 0, perRecord.allSatisfy({ $0 == first }) else { continue }
            if best == nil || first > best!.score { best = (index, first) }
        }
        if let best { return candidates[best.index] }

        let totals = candidates.indices.map { index in samples.reduce(0) { $0 + $1[index] } }
        let top = totals.max() ?? 0
        return top > 0 ? candidates[totals.firstIndex(of: top)!] : ","
    }
}

enum CSVAmount {
    /// Parses quote amounts written in English or French conventions: "$2,500.00",
    /// "2 500,00 $", "2.500,00", "1,200". When both "." and "," appear, the last one is
    /// the decimal mark, and a repeated mark groups thousands. A lone "." is always a
    /// decimal point ("99.950" is 99.95). A lone "," groups thousands only in the
    /// "2,500" shape: one to three leading digits, not zero, then exactly three digits.
    static func parse(_ raw: String) -> Double? {
        var text = String(raw.unicodeScalars.filter { ("0"..."9").contains($0) || $0 == "." || $0 == "," }.map(Character.init))
        guard text.contains(where: \.isNumber) else { return nil }
        let lastDot = text.lastIndex(of: "."), lastComma = text.lastIndex(of: ",")
        if let lastDot, let lastComma {
            let decimal: Character = lastDot > lastComma ? "." : ","
            text = text.filter { $0 != (decimal == "." ? "," : ".") }
            text = text.replacingOccurrences(of: String(decimal), with: ".")
        } else if let mark = lastDot ?? lastComma {
            let separator = text[mark]
            let leading = text[..<mark], trailing = text[text.index(after: mark)...]
            let groupsThousands = separator == "," && trailing.count == 3 && (1...3).contains(leading.count) && leading.first != "0"
            if text.filter({ $0 == separator }).count > 1 || groupsThousands {
                text = text.filter { $0 != separator }
            } else {
                text = text.replacingOccurrences(of: String(separator), with: ".")
            }
        }
        return Double(text)
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
