import Foundation
import LocalAuthentication
import Security

@MainActor enum CredentialAccessTests {
    static func run() async -> Bool {
        let cases: [(String, () async throws -> Void)] = [
            ("cancelling a credential wait settles before the blocked worker returns", cancelledWait),
            ("already-cancelled waits start no credential operation", alreadyCancelledWait),
            ("deadlines discard late credential success and error independently of the worker", deadlineWait),
            ("startup probe deadlines retain connections and ignore late availability", probeDeadlines),
            ("API and mail deadlines release busy states without HTTP or delayed effects", readDeadlines),
            ("a held native lookup is not duplicated by retries after the waiter times out", duplicateNativeLookup),
            ("a Resend credential deadline queues and sends nothing; a new review can retry", resendDeadline),
            ("PHAROS rechecks the approved CRM snapshot after credential access", pharosDelayedSnapshot),
            ("late KAIROS success and failure cannot publish into a changed connection", kairosChangedConnection),
            ("a changed GAP connection stops paging without imports or retirements", gapsChangedConnection),
            ("a changed PHAROS connection discards a pending page without acknowledgement", leadPageChangedConnection),
            ("stopping automatic intake during a page read prevents commit and acknowledgement", leadStopDuringPage),
            ("a confirmed ack keeps its saved page but cannot advance a replacement connection", leadAckChangedConnection),
            ("already-issued writes retain their real outcome without verifying a new connection", issuedWriteResults),
            ("noninteractive query policy distinguishes unavailable access from missing items", lookupPolicy),
            ("startup probes retain credentials and Auto-Pilot without network or interactive reads", startup),
            ("automatic PHAROS data denial pauses; explicit Verify can request authentication", pharosBackground),
            ("automatic mail data denial pauses; explicit Refresh retries only the chosen account", mailBackground),
            ("delayed startup lookups allow main-actor progress and discard stale probes after changes", delayedStartup),
            ("delayed manual key reads keep the main actor responsive and never use a superseded connection", delayedRead),
            ("stopping Auto-Pilot or disconnecting mail during a pending read prevents a later request", stoppedRead),
            ("Twenty refuses CRM edits made during pending credential access with zero HTTP", twentyDelayedApproval),
            ("Twenty stops after a mid-push CRM edit and resumes only after a new preview", twentyMidPushApproval),
        ]
        var failures = 0
        for (name, test) in cases {
            do { try await test(); print("PASS Credential access: \(name)") }
            catch { failures += 1; print("FAIL Credential access: \(name): \(error)") }
        }
        print("Credential access tests: \(cases.count - failures)/\(cases.count) passed")
        return failures == 0
    }
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw SmokeTestFailure.failed(message) }
    }
    @MainActor final class Progress { var value = false }
    final class SecurityFake: @unchecked Sendable {
        struct Call: Sendable { var service: String; var account: String; var data: Bool; var interactive: Bool; var mainThread: Bool }
        private let lock = NSLock()
        private var calls: [Call] = []
        let attributesStatus: OSStatus
        init(attributesStatus: OSStatus = errSecSuccess) { self.attributesStatus = attributesStatus }
        var history: [Call] { lock.withLock { calls } }
        var lookup: KeychainLookup {
            KeychainLookup { [self] query in
                let context = query[kSecUseAuthenticationContext as String] as? LAContext
                let interactive = context?.interactionNotAllowed != true
                let data = query[kSecReturnData as String] as? Bool == true
                lock.withLock { calls.append(Call(service: query[kSecAttrService as String] as? String ?? "", account: query[kSecAttrAccount as String] as? String ?? "", data: data, interactive: interactive, mainThread: Thread.isMainThread)) }
                if !data { return .init(status: attributesStatus, data: nil) }
                if attributesStatus == errSecItemNotFound { return .init(status: errSecItemNotFound, data: nil) }
                return interactive ? .init(status: errSecSuccess, data: Data("synthetic-credential".utf8)) : .init(status: errSecInteractionNotAllowed, data: nil)
            }
        }
    }
    /// Entirely in memory, including writes/deletes. Never use the production stores for mutation races.
    final class DelayedStore: SecretStore, MailTokenStore, @unchecked Sendable {
        private let lock = NSLock(), gate = NSCondition()
        private var released = false
        private var values: [String: String] = [:]
        private var probes = 0, reads = 0, mainCalls = 0, completedReads = 0
        private var expired = false
        let delayProbes: Bool, delayReads: Bool
        let probeResult: CredentialAvailability?
        init(delayProbes: Bool, delayReads: Bool = false, probeResult: CredentialAvailability? = nil) {
            self.delayProbes = delayProbes; self.delayReads = delayReads; self.probeResult = probeResult
            for target in SyncTarget.keyed { values["api:" + target.rawValue] = "synthetic-old" }
            for account in MailAccount.signIns { values[account.email] = "synthetic-old" }
        }
        var waitingProbes: Int { lock.withLock { probes } }
        var waitingReads: Int { lock.withLock { reads } }
        var finishedReads: Int { lock.withLock { completedReads } }
        var mainThreadCalls: Int { lock.withLock { mainCalls } }
        var timedOut: Bool { lock.withLock { expired } }
        func release() { gate.lock(); released = true; gate.broadcast(); gate.unlock() }
        private func wait(probe: Bool) {
            if Thread.isMainThread { lock.withLock { mainCalls += 1 }; return }
            guard probe ? delayProbes : delayReads else { return }
            lock.withLock { if probe { probes += 1 } else { reads += 1 } }
            let deadline = Date.now.addingTimeInterval(5)
            gate.lock()
            while !released {
                if !gate.wait(until: deadline) { lock.withLock { expired = true }; break }
            }
            gate.unlock()
        }
        private func probe(_ key: String) -> CredentialAvailability {
            let before = lock.withLock { probeResult ?? (values[key] == nil ? .missing : .available) }
            wait(probe: true)
            return before
        }
        private func value(_ key: String) -> String? {
            let before = lock.withLock { values[key] }; wait(probe: false)
            lock.withLock { completedReads += 1 }
            return before
        }
        func cachedAvailability(_ target: SyncTarget) -> CredentialAvailability? { nil }
        func cachedAvailability(_ email: String) -> CredentialAvailability? { nil }
        func availability(_ target: SyncTarget) -> CredentialAvailability { probe("api:" + target.rawValue) }
        func availability(_ email: String) -> CredentialAvailability { probe(email) }
        func exists(_ target: SyncTarget) -> Bool { availability(target) == .available }
        func exists(_ email: String) -> Bool { availability(email) == .available }
        func read(_ target: SyncTarget) throws -> String? { value("api:" + target.rawValue) }
        func read(_ email: String) throws -> String? { value(email) }
        func readWithoutInteraction(_ target: SyncTarget) throws -> String? { try read(target) }
        func readWithoutInteraction(_ email: String) throws -> String? { try read(email) }
        func write(_ value: String, for target: SyncTarget) throws { lock.withLock { values["api:" + target.rawValue] = value } }
        func write(_ value: String, for email: String) throws { lock.withLock { values[email] = value } }
        func delete(_ target: SyncTarget) throws { _ = lock.withLock { values.removeValue(forKey: "api:" + target.rawValue) } }
        func delete(_ email: String) throws { _ = lock.withLock { values.removeValue(forKey: email) } }
    }
    private static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw SmokeTestFailure.failed("controlled background lookup did not reach the expected state")
    }
    static func cancelledWait() async throws {
        let fake = DelayedStore(delayProbes: false, delayReads: true)
        defer { fake.release() }
        let pending = Task { try await CredentialIO.read { try fake.read(.pharos) } }
        try await eventually { fake.waitingReads == 1 }
        pending.cancel()
        do {
            _ = try await pending.value
            throw SmokeTestFailure.failed("cancelled waiter accepted the later credential result")
        } catch is CancellationError {}
        try check(!fake.timedOut, "cancellation waited for the fake worker's five-second safety release")
    }
    static func alreadyCancelledWait() async throws {
        let fake = DelayedStore(delayProbes: false, delayReads: true)
        defer { fake.release() }
        let pending = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CredentialIO.read { try fake.read(.pharos) }
        }
        do { _ = try await pending.value; throw SmokeTestFailure.failed("already-cancelled wait succeeded") }
        catch is CancellationError {}
        try check(fake.waitingReads == 0, "already-cancelled waiter started a native lookup")
    }
    static func deadlineWait() async throws {
        for failsLate in [false, true] {
            let fake = DelayedStore(delayProbes: false, delayReads: true)
            defer { fake.release() }
            let pending = Task {
                try await CredentialIO.read(timeout: .milliseconds(100)) {
                    let value = try fake.read(.pharos)
                    if failsLate { throw SecretStoreError.empty }
                    return value
                }
            }
            try await eventually { fake.waitingReads == 1 }
            do { _ = try await pending.value; throw SmokeTestFailure.failed("deadline accepted a held worker result") }
            catch CredentialLookupError.timedOut {}
            try check(!fake.timedOut && fake.finishedReads == 0, "deadline waited for the worker's safety release")
            fake.release()
            try await eventually { fake.finishedReads == 1 }
            let fresh = try await CredentialIO.read { "fresh result" }
            try check(fresh == "fresh result", "late success/error interfered with another wait")
        }
    }
    static func probeDeadlines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-probe-deadline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let api = DelayedStore(delayProbes: true), tokens = DelayedStore(delayProbes: true)
        defer { api.release(); tokens.release() }
        let file = try fixture(root), before = try Data(contentsOf: file)
        let network = NetworkFake()
        let store = AppStore(storageURL: file, secrets: api, transport: network, credentialWaitLimit: .milliseconds(100))
        let mail = MailIntakeController(tokens: tokens, transport: network, defaults: UserDefaults(suiteName: "probe-deadline-\(UUID())")!,
                                        accessMode: .live, credentialWaitLimit: .milliseconds(100))
        try await eventually { api.waitingProbes > 0 && tokens.waitingProbes > 0 }
        await store.waitForCredentialChecks(); await mail.waitForCredentialChecks()
        try check(!api.timedOut && !tokens.timedOut && store.keyAccessChecking.isEmpty, "probe wait did not finish independently")
        try check(store.keyAccessNeeded.contains(.pharos) && mail.state(.personalGmail) == .accessRequired && mail.anyConnected, "timeout erased saved connections or stayed Checking")
        try check(try Data(contentsOf: file) == before && store.workspace.autoPilotEnabled && network.requests == 0, "probe deadline changed owner preference/data or reached a provider")
        store.setAPIKey("synthetic-new", for: .pharos); mail.disconnect(.personalGmail)
        api.release(); tokens.release()
        for _ in 0..<10 { await Task.yield() }
        try check(store.hasKey(.pharos) && mail.state(.personalGmail) == .notConnected, "late probe replaced a newer decision")
    }
    static func readDeadlines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-read-deadline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let api = DelayedStore(delayProbes: false, delayReads: true), tokens = DelayedStore(delayProbes: false, delayReads: true)
        defer { api.release(); tokens.release() }
        let network = NetworkFake()
        let store = AppStore(storageURL: try fixture(root), secrets: api, transport: network, credentialWaitLimit: .milliseconds(100))
        let mail = MailIntakeController(tokens: tokens, transport: network, defaults: UserDefaults(suiteName: "read-deadline-\(UUID())")!,
                                        accessMode: .live, credentialWaitLimit: .milliseconds(100))
        await store.waitForCredentialChecks(); await mail.waitForCredentialChecks()
        let checking = Task { await store.verifyConnector(.pharos) }
        let refreshing = Task { await mail.refresh(.personalGmail, store: store) }
        try await eventually { api.waitingReads == 1 && tokens.waitingReads == 1 }
        var note = CRMNote(); note.title = "Local work during credential wait"
        try check(store.add(note), "local CRM did not remain usable")
        let verified = await checking.value; await refreshing.value
        try check(!verified && !store.busyTargets.contains(.pharos) && store.keyAccessNeeded.contains(.pharos), "API wait stayed busy or falsely succeeded")
        try check(mail.state(.personalGmail) == .accessRequired && mail.isConfigured(MailAccount.personalGmail.email), "mail wait stayed Refreshing or lost its sign-in")
        try check(!api.timedOut && !tokens.timedOut && api.finishedReads == 0 && tokens.finishedReads == 0 && network.requests == 0, "deadline was not independent or reached HTTP")
        api.release(); tokens.release()
        try await eventually { api.finishedReads == 1 && tokens.finishedReads == 1 }
        try check(network.requests == 0 && store.notes == [note] && store.keyAccessNeeded.contains(.pharos) && mail.state(.personalGmail) == .accessRequired, "late credentials changed local work/access state or started HTTP")
        try check(await store.verifyConnector(.pharos), "explicit current retry failed")
        await mail.refresh(.personalGmail, store: store)
        try check(network.requests == 4 && store.hasKey(.pharos), "current retries did not issue only their expected GETs")
    }
    final class HeldLookup: @unchecked Sendable {
        private let lock = NSLock(), gate = NSCondition()
        private var released = false, reads = 0
        var calls: Int { lock.withLock { reads } }
        func release() { gate.lock(); released = true; gate.broadcast(); gate.unlock() }
        func result(_ query: [String: Any]) -> KeychainLookup.Result {
            guard query[kSecReturnData as String] as? Bool == true else { return .init(status: errSecSuccess, data: nil) }
            lock.withLock { reads += 1 }
            let deadline = Date.now.addingTimeInterval(5)
            gate.lock()
            while !released { if !gate.wait(until: deadline) { break } }
            gate.unlock()
            return .init(status: errSecSuccess, data: Data("synthetic-test-only".utf8))
        }
    }
    static func duplicateNativeLookup() async throws {
        let held = HeldLookup(); defer { held.release() }
        let lookup = KeychainLookup { held.result($0) }
        let store = KeychainSecretStore(servicePrefix: "test.no-system-lookup.\(UUID())", lookup: lookup)
        let pending = Task { try await CredentialIO.read(timeout: .milliseconds(100)) { try store.read(.pharos) } }
        try await eventually { held.calls == 1 }
        do { _ = try await pending.value; throw SmokeTestFailure.failed("held lookup ignored its deadline") }
        catch CredentialLookupError.timedOut {}
        for _ in 0..<5 {
            do { _ = try await CredentialIO.read { try store.read(.pharos) }; throw SmokeTestFailure.failed("retry duplicated a held lookup") }
            catch CredentialLookupError.pending {}
        }
        try check(held.calls == 1 && store.availability(.pharos) == .accessRequired, "retry/probe multiplied native reads or labelled a saved item missing")
        held.release()
        try await eventually { store.availability(.pharos) == .available }
        let current = try await CredentialIO.read { try store.read(.pharos) }
        try check(current == "synthetic-test-only" && held.calls == 2, "a fresh explicit read could not run after the original native call finished")
    }
    static func resendDeadline() async throws {
        let secret = DelayedStore(delayProbes: false, delayReads: true); defer { secret.release() }
        try secret.write("re_synthetic_test_only", for: .resend)
        let http = ResendTests.FakeHTTP()
        let (store, lead, root) = try ResendTests.fixture(http, secrets: secret)
        defer { try? FileManager.default.removeItem(at: root) }
        store.credentialWaitLimit = .milliseconds(100)
        await store.waitForCredentialChecks()
        let preview = try ResendTests.preview(store, lead)
        let pending = Task { await store.sendResend(preview) }
        try await eventually { secret.waitingReads == 1 }
        try check(await pending.value == false && !secret.timedOut, "send waited for the held credential worker or reported acceptance")
        try check(store.workspace.resendDispatches.isEmpty && store.leads == [lead] && store.keyAccessNeeded.contains(.resend) && !store.busyTargets.contains(.resend), "credential timeout staged a send, changed the lead, or stayed busy")
        secret.release()
        try await eventually { secret.finishedReads == 1 }
        try check(await http.captured().isEmpty, "late credential started an unapproved send")
        let retry = try ResendTests.preview(store, lead)
        try check(await store.sendResend(retry), "new exact-message review could not retry")
        try check(await http.captured().count == 1 && store.leads[0].history.count == 1, "retry duplicated or lost the single provider acceptance")
    }
    /// Holds a response after the backend handled it. No real URLSession/credential is used.
    final class PausedResponse: HTTPTransport, @unchecked Sendable {
        let backend: any HTTPTransport
        let path: String
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        init(_ backend: any HTTPTransport, path: String) { self.backend = backend; self.path = path }
        var waiting: Bool { lock.withLock { continuation != nil } }
        func release() {
            let pending = lock.withLock { released = true; let value = continuation; continuation = nil; return value }
            pending?.resume()
        }
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            let result: Result<HTTPResponse, any Error>
            do { result = .success(try await backend.send(request)) } catch { result = .failure(error) }
            if request.url?.path == path {
                await withCheckedContinuation { value in
                    let ready = lock.withLock {
                        if released { return true }
                        continuation = value; return false
                    }
                    if ready { value.resume() }
                }
            }
            return try result.get()
        }
    }
    struct FixedInbox: HTTPTransport {
        let status: Int
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            HTTPResponse(status: status, headers: [:], body: Data(#"{"conversations":[{"id":"stale-synthetic-conversation","author_handle":"Synthetic","intent":"lead","priority":1,"status":"open","last_message_at":"2026-11-08T00:00:00Z","platform":"instagram","latest_message":"Synthetic old-account inbound message"}]}"#.utf8))
        }
    }
    static func pharosDelayedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pharos-delayed-snapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = DelayedStore(delayProbes: false, delayReads: true); defer { credentials.release() }
        let backend = IntegrationTests.FakePharos(key: "synthetic-old")
        let store = AppStore(storageURL: try fixture(root), secrets: credentials, transport: backend)
        await store.waitForCredentialChecks()
        let fingerprint = store.previewPharosPush()
        let pending = Task { await store.syncToPharos(confirmedFingerprint: fingerprint) }
        try await eventually { credentials.waitingReads == 1 }
        var company = Company(); company.name = "Unapproved change during credential access"
        try check(store.add(company), "local edit failed")
        credentials.release()
        let job = await pending.value
        try check(job.status == "failed" && job.error?.lowercased().contains("preview") == true && backend.pushes.isEmpty && backend.storedCount == 0, "a stale approved snapshot reached PHAROS")
        let current = store.previewPharosPush()
        let retried = await store.syncToPharos(confirmedFingerprint: current)
        try check(retried.status == "synced" && backend.pushes.count == 1, "fresh confirmation did not permit one current push")
    }
    static func kairosChangedConnection() async throws {
        for status in [200, 500] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("kairos-changed-context-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let transport = PausedResponse(FixedInbox(status: status), path: "/v1/inbox"); defer { transport.release() }
            let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore([.kairos: "synthetic-old"]), transport: transport)
            store.setEndpoint("https://old-kairos.example.test", for: .kairos)
            let pending = Task { await store.importKairosLeads() }
            try await eventually { transport.waiting }
            if status == 200 { store.setEndpoint("https://new-kairos.example.test", for: .kairos) }
            else { store.setAPIKey("synthetic-replacement", for: .kairos) }
            let before = try Data(contentsOf: store.storageURL)
            transport.release()
            let job = await pending.value
            try check(job.status == "cancelled" && store.leads.isEmpty && store.workspace.connectorHealth[SyncTarget.kairos.rawValue] == nil, "old-account result or error became current data/health")
            try check(try Data(contentsOf: store.storageURL) == before && !store.busyTargets.contains(.kairos), "stale result wrote diagnostics or stayed busy")
        }
    }
    static func gapsChangedConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gap-changed-context-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = GapAnalysisTests.FakeSupabase(key: "synthetic-old")
        backend.clusters = (1...501).map { GapAnalysisTests.cluster(String(format: "%04d", $0), label: "Old source \($0)", total: 0.5) }
        let transport = PausedResponse(backend, path: "/rest/v1/gap_clusters"); defer { transport.release() }
        let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore([.gaps: "synthetic-old"]), transport: transport)
        store.setEndpoint("https://old-gap.example.test", for: .gaps)
        var retained = Signal(); retained.title = "Owner-reviewed earlier signal"; retained.sourceID = "gap:retained"; retained.sourceActive = true
        try store.commitWorkspace { $0.signals = [retained] }
        let pending = Task { await store.importGaps() }
        try await eventually { transport.waiting }
        store.setEndpoint("https://new-gap.example.test", for: .gaps)
        let before = try Data(contentsOf: store.storageURL)
        transport.release()
        let job = await pending.value
        try check(job.status == "cancelled" && backend.readCount == 1 && store.signals == [retained], "stale gap response paged, imported or retired current signals")
        try check(try Data(contentsOf: store.storageURL) == before && store.workspace.connectorHealth[SyncTarget.gaps.rawValue] == nil, "stale GAP response published health/diagnostics")
    }
    static func pendingLeadPage(changeConnection: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lead-page-context-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = LeadInboxTests.FakeInbox(key: "synthetic-old")
        backend.add("held-source", email: "synthetic@example.test", first: "Synthetic")
        let transport = PausedResponse(backend, path: "/v1/leads"); defer { transport.release() }
        let store = AppStore(storageURL: try fixture(root), secrets: InMemorySecretStore([.pharos: "synthetic-old"]), transport: transport)
        let pending = Task { await store.pullLeads(userInitiated: changeConnection, requiresAutoPilot: !changeConnection) }
        try await eventually { transport.waiting }
        if changeConnection { store.setEndpoint("https://replacement-pharos.example.test", for: .pharos) }
        else { store.stopPulling() }
        let before = try Data(contentsOf: store.storageURL)
        transport.release()
        let job = await pending.value
        try check(job.status == "cancelled" && store.leads.isEmpty && store.signals.isEmpty && backend.pending == 1, "stale/stopped page was committed or acknowledged")
        try check(!backend.requests.contains { $0.url?.path == "/v1/leads/ack" } && Data(contentsOf: store.storageURL) == before, "stale/stopped read wrote state or sent an ack")
    }
    static func leadPageChangedConnection() async throws { try await pendingLeadPage(changeConnection: true) }
    static func leadStopDuringPage() async throws { try await pendingLeadPage(changeConnection: false) }
    static func leadAckChangedConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lead-ack-context-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = LeadInboxTests.FakeInbox(key: "synthetic-old")
        backend.add("saved-before-ack", email: "synthetic@example.test", first: "Synthetic")
        let transport = PausedResponse(backend, path: "/v1/leads/ack"); defer { transport.release() }
        let store = AppStore(storageURL: try fixture(root), secrets: InMemorySecretStore([.pharos: "synthetic-old"]), transport: transport)
        let pending = Task { await store.pullLeads() }
        try await eventually { transport.waiting }
        try check(store.leads.count == 1 && backend.pending == 0, "ack was not preceded by a durable page")
        store.setEndpoint("https://replacement-pharos.example.test", for: .pharos)
        let before = try Data(contentsOf: store.storageURL)
        transport.release()
        let job = await pending.value
        try check(job.status == "cancelled" && store.leads.count == 1 && store.workspace.leadInboxCursor == nil, "confirmed ack lost saved work or advanced a replacement connection")
        try check(try Data(contentsOf: store.storageURL) == before, "late ack published a job/cursor to the replacement connection")
    }
    static func issuedWriteResults() async throws {
        for changeConnection in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("issued-pharos-context-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let backend = IntegrationTests.FakePharos(key: "synthetic-old")
            let transport = PausedResponse(backend, path: "/v1/exchange/push"); defer { transport.release() }
            let store = AppStore(storageURL: try fixture(root), secrets: InMemorySecretStore([.pharos: "synthetic-old"]), transport: transport)
            let preview = store.previewPharosPush()
            let pending = Task { await store.syncToPharos(confirmedFingerprint: preview) }
            try await eventually { transport.waiting }
            if changeConnection { store.setEndpoint("https://replacement-pharos.example.test", for: .pharos) }
            else { pending.cancel() }
            transport.release()
            let job = await pending.value
            try check(job.status == "synced" && backend.storedCount == 1 && store.syncJobs.contains { $0.id == job.id && $0.status == "synced" }, "an issued accepted write was falsely called safely cancelled")
            if changeConnection { try check(store.workspace.connectorHealth[SyncTarget.pharos.rawValue] == nil && job.detail?.contains("previous connection") == true, "old acceptance verified the replacement PHAROS connection") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("issued-twenty-context-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PausedTwenty(); defer { transport.release() }
        let store = AppStore(storageURL: try fixture(root), secrets: InMemorySecretStore([.twenty: "synthetic-old"]), transport: transport)
        store.twentyPacing = .zero
        store.setEndpoint("https://old-twenty.example.test", for: .twenty)
        var company = Company(); company.name = "Approved synthetic company"; try check(store.add(company), "fixture failed")
        _ = store.previewTwentyPush()
        let pending = Task { await store.pushToTwenty() }
        try await eventually { transport.waiting }
        store.setEndpoint("https://replacement-twenty.example.test", for: .twenty)
        transport.release()
        let job = await pending.value
        try check(job.status == "synced" && store.workspace.connectorHealth[SyncTarget.twenty.rawValue] == nil && job.detail?.contains("previous connection") == true, "old Twenty acceptance verified the replacement connection or lost its actual outcome")
    }
    final class NetworkFake: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var requests: Int { lock.withLock { count } }
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            lock.withLock { count += 1 }
            let body: String
            switch request.url?.path {
            case "/token": body = "{\"access_token\":\"synthetic-access\"}"
            case "/gmail/v1/users/me/messages": body = "{\"messages\":[]}"
            default: body = "{\"ok\":true,\"service\":\"pharos-contextward-api\"}"
            }
            return HTTPResponse(status: 200, headers: [:], body: Data(body.utf8))
        }
    }
    private static func fixture(_ root: URL) throws -> URL {
        var workspace = PersistentWorkspace()
        workspace.business.name = "Synthetic credential startup"
        workspace.autoPilotEnabled = true
        workspace.connectorEndpoints[SyncTarget.pharos.rawValue] = "https://pharos.example.test"
        workspace.connectorHealth[SyncTarget.pharos.rawValue] = ConnectorHealth(ok: true, detail: "Historical synthetic check")
        let file = root.appendingPathComponent("workspace.json")
        try SecureFiles.writePrivate(JSONEncoder().encode(workspace), to: file)
        return file
    }
    static func lookupPolicy() throws {
        for (status, expected) in [(errSecSuccess, CredentialAvailability.available), (errSecItemNotFound, .missing), (errSecInteractionNotAllowed, .accessRequired), (errSecAuthFailed, .accessRequired), (errSecNotAvailable, .accessRequired)] {
            let fake = SecurityFake(attributesStatus: status)
            let key = KeychainSecretStore(lookup: fake.lookup)
            let mail = KeychainMailTokenStore(lookup: fake.lookup)
            try check(key.availability(.pharos) == expected && mail.availability("fixture@example.test") == expected, "status became false missing/available")
            try check(fake.history.allSatisfy { !$0.interactive && !$0.data }, "presence query allows interaction or requests secret data")
            try check(fake.history[0].service == "com.pharos.contextward.pharos" && fake.history[0].account == "api", "API key identity changed")
            try check(fake.history[1].service == "com.pharos.contextward.mail.fixture@example.test" && fake.history[1].account == "oauth", "mail identity changed")
            if status == errSecItemNotFound { try check(try key.read(.pharos) == nil, "missing item did not remain missing") }
        }
    }
    static func startup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-startup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root); let before = try Data(contentsOf: file)
        let fake = SecurityFake(attributesStatus: errSecInteractionNotAllowed); let network = NetworkFake()
        let store = AppStore(storageURL: file, secrets: KeychainSecretStore(lookup: fake.lookup), transport: network)
        let defaults = UserDefaults(suiteName: "credential-startup-\(UUID())")!
        let mail = MailIntakeController(tokens: KeychainMailTokenStore(lookup: fake.lookup), transport: network, defaults: defaults, accessMode: .live)
        await store.waitForCredentialChecks(); await mail.waitForCredentialChecks()
        await store.pullLeadsOnLaunch(); await mail.refreshAll(store: store, userInitiated: false)
        try check(store.keyAccessNeeded.contains(.pharos) && !store.hasKey(.pharos), "blocked key not represented honestly")
        if case .accessRequired = store.connectorStatus(.pharos) {} else { throw SmokeTestFailure.failed("historical health hid current access requirement") }
        try check(mail.state(.personalGmail) == .accessRequired && mail.state(.infrafabric) == .accessRequired, "blocked sign-ins appeared disconnected")
        let count = fake.history.count
        for _ in 0..<20 { _ = mail.anyConnected; _ = mail.isConfigured(MailAccount.personalGmail.email) }
        try check(fake.history.count == count, "rendered connection state reprobes credentials")
        try check(fake.history.allSatisfy { !$0.interactive && !$0.data } && network.requests == 0, "startup requested auth/data/network after denied probe")
        try check(fake.history.allSatisfy { !$0.mainThread }, "startup lookup blocked the main thread")
        try check(try Data(contentsOf: file) == before && store.workspace.autoPilotEnabled, "startup changed saved owner state/preference")
    }
    static func pharosBackground() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-pharos-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = SecurityFake(); let network = NetworkFake(); let file = try fixture(root)
        let store = AppStore(storageURL: file, secrets: KeychainSecretStore(lookup: fake.lookup), transport: network)
        await store.waitForCredentialChecks()
        try check(store.hasKey(.pharos), "successful attributes did not establish availability")
        await store.pullLeadsOnLaunch()
        try check(fake.history.filter(\.data).count == 1 && fake.history.filter(\.data).allSatisfy { !$0.interactive }, "automatic PHAROS read allowed authentication")
        try check(network.requests == 0 && store.keyAccessNeeded.contains(.pharos) && !store.isPullingLeads, "denied automatic access reached network or kept a running label")
        try check(store.workspace.autoPilotEnabled, "denial disabled the saved preference")
        await store.verifyConnector(.pharos)
        try check(fake.history.last?.interactive == true && fake.history.last?.data == true, "explicit Verify lost normal authentication")
        try check(store.hasKey(.pharos) && !store.keyAccessNeeded.contains(.pharos) && network.requests == 2, "manual access retry did not clear the transient blocked state")
        try check(fake.history.allSatisfy { !$0.mainThread }, "PHAROS lookup ran on the main thread")
    }
    static func mailBackground() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-mail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root); let fake = SecurityFake(); let network = NetworkFake()
        let store = AppStore(storageURL: file, secrets: InMemorySecretStore(), transport: network)
        let mail = MailIntakeController(tokens: KeychainMailTokenStore(lookup: fake.lookup), transport: network, defaults: UserDefaults(suiteName: "credential-mail-\(UUID())")!, accessMode: .live)
        mail.startPeriodic(store: store)
        defer { mail.stopPeriodic() }
        try await eventually { mail.state(.personalGmail) == .accessRequired && mail.state(.infrafabric) == .accessRequired }
        try check(fake.history.filter(\.data).count == 2 && fake.history.allSatisfy { !$0.interactive }, "automatic mail read requested interaction")
        try check(network.requests == 0 && mail.anyConnected && mail.state(.personalGmail) == .accessRequired, "denied access erased connection presence or reached a provider")
        await mail.refresh(.personalGmail, store: store)
        if case .synced(_, 0) = mail.state(.personalGmail) {} else { throw SmokeTestFailure.failed("explicit mail retry failed") }
        try check(network.requests == 2 && fake.history.last?.interactive == true, "explicit Refresh did not retain normal authentication")
        try check(mail.state(.infrafabric) == .accessRequired && mail.credentialAvailability[MailAccount.infrafabric.email] == .accessRequired, "retry modified another account")
        try check(fake.history.allSatisfy { !$0.mainThread }, "mail lookup ran on the main thread")
    }
    static func delayedStartup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-delayed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let api = DelayedStore(delayProbes: true, probeResult: .accessRequired)
        let tokens = DelayedStore(delayProbes: true)
        defer { api.release(); tokens.release() }
        let network = NetworkFake()
        let store = AppStore(storageURL: try fixture(root), secrets: api, transport: network)
        let mail = MailIntakeController(tokens: tokens, transport: network, defaults: UserDefaults(suiteName: "credential-delayed-\(UUID())")!, accessMode: .live)
        try check(api.mainThreadCalls == 0 && tokens.mainThreadCalls == 0, "constructor performed a blocking lookup")
        try await eventually { api.waitingProbes > 0 && tokens.waitingProbes > 0 }
        try check(store.keyAccessChecking.contains(.pharos) && mail.state(.personalGmail) == .checkingAccess, "pending access was labelled missing or ready")
        let progressed = Progress()
        await Task { @MainActor in progressed.value = true }.value
        try check(progressed.value && !api.timedOut && !tokens.timedOut && api.waitingProbes > 0 && tokens.waitingProbes > 0, "main actor did not progress while I/O was held")
        let apiWaiting = Progress(), mailWaiting = Progress()
        let apiDrain = Task { apiWaiting.value = true; await store.waitForCredentialChecks() }
        let mailDrain = Task { mailWaiting.value = true; await mail.waitForCredentialChecks() }
        try await eventually { apiWaiting.value && mailWaiting.value }
        store.setAPIKey("synthetic-replacement", for: .pharos)
        mail.disconnect(.personalGmail)
        api.release(); tokens.release()
        await apiDrain.value; await mailDrain.value
        try check(store.hasKey(.pharos) && !store.keyAccessNeeded.contains(.pharos) && !store.keyAccessChecking.contains(.pharos), "stale probe overwrote a saved credential change")
        try check(mail.state(.personalGmail) == .notConnected && mail.credentialAvailability[MailAccount.personalGmail.email] == .missing, "stale probe resurrected a disconnected account")
        try check(mail.credentialAvailability[MailAccount.infrafabric.email] == .available, "another sign-in changed")
        try check(network.requests == 0 && store.workspace.autoPilotEnabled && api.mainThreadCalls == 0 && tokens.mainThreadCalls == 0, "delayed checks changed preferences, reached a provider or blocked main")
    }
    static func delayedRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-delayed-read-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = DelayedStore(delayProbes: false, delayReads: true)
        defer { fake.release() }
        let network = NetworkFake()
        let checked = AppStore(storageURL: try fixture(root), secrets: fake, transport: network)
        await checked.waitForCredentialChecks()
        let pending = Task { await checked.verifyConnector(.pharos) }
        try await eventually { fake.waitingReads > 0 }
        let progressed = Progress()
        await Task { @MainActor in progressed.value = true }.value
        try check(progressed.value && !fake.timedOut && fake.mainThreadCalls == 0, "manual lookup blocked the main actor")
        checked.setAPIKey("synthetic-new-key", for: .pharos)
        checked.setEndpoint("https://new-pharos.example.test", for: .pharos)
        fake.release()
        let accepted = await pending.value
        try check(!accepted && network.requests == 0 && checked.hasKey(.pharos), "superseded lookup used an old connection or overwrote current key state")
        try check(checked.workspace.connectorHealth[SyncTarget.pharos.rawValue] == nil, "stale lookup overwrote the new connection's health")
    }
    static func stoppedRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-stopped-read-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let api = DelayedStore(delayProbes: false, delayReads: true)
        let tokens = DelayedStore(delayProbes: false, delayReads: true)
        defer { api.release(); tokens.release() }
        let network = NetworkFake()
        let store = AppStore(storageURL: try fixture(root), secrets: api, transport: network)
        let mail = MailIntakeController(tokens: tokens, transport: network, defaults: UserDefaults(suiteName: "credential-stopped-read-\(UUID())")!, accessMode: .live)
        await store.waitForCredentialChecks(); await mail.waitForCredentialChecks()
        let pharos = Task { await store.pullLeadsOnLaunch() }
        let inbox = Task { await mail.refresh(.personalGmail, store: store) }
        try await eventually { api.waitingReads > 0 && tokens.waitingReads > 0 }
        store.stopPulling()
        mail.disconnect(.personalGmail)
        api.release(); tokens.release()
        await pharos.value; await inbox.value
        try check(!api.timedOut && !tokens.timedOut && network.requests == 0, "a pending read started a request after Stop/Disconnect")
        try check(!store.workspace.autoPilotEnabled && !store.isPullingLeads && store.workspace.syncJobs.isEmpty, "late completion restarted Auto-Pilot or persisted a cancelled job")
        try check(mail.state(.personalGmail) == .notConnected && mail.credentialAvailability[MailAccount.personalGmail.email] == .missing, "late completion restored a disconnected account")
    }
    static func twentyDelayedApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("twenty-delayed-approval-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = DelayedStore(delayProbes: false, delayReads: true)
        defer { credentials.release() }
        let transport = IntegrationTests.FakeTwenty(key: "synthetic-old")
        let store = AppStore(storageURL: try fixture(root), secrets: credentials, transport: transport)
        await store.waitForCredentialChecks()
        store.twentyPacing = .zero
        store.setEndpoint("https://twenty.example.test", for: .twenty)
        var company = Company(); company.name = "Approved synthetic company"; try check(store.add(company), "fixture failed")
        _ = store.previewTwentyPush()
        let pending = Task { await store.pushToTwenty() }
        try await eventually { credentials.waitingReads > 0 }
        company.name = "Unapproved edit during authentication"; try check(store.update(company), "edit failed")
        credentials.release()
        let job = await pending.value
        try check(!credentials.timedOut && job.status == "failed" && job.error?.lowercased().contains("preview") == true && transport.methodLog.isEmpty, "unpreviewed data crossed the delayed credential boundary")
    }
    final class PausedTwenty: HTTPTransport, @unchecked Sendable {
        let backend = IntegrationTests.FakeTwenty(key: "synthetic-old")
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false, first = true
        var waiting: Bool { lock.withLock { continuation != nil } }
        func release() {
            let pending = lock.withLock { released = true; let value = continuation; continuation = nil; return value }
            pending?.resume()
        }
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            let response = try await backend.send(request)
            let pause = lock.withLock { if !first { return false }; first = false; return true }
            if pause {
                await withCheckedContinuation { pending in
                    let resume = lock.withLock { if released { return true }; continuation = pending; return false }
                    if resume { pending.resume() }
                }
            }
            return response
        }
    }
    static func twentyMidPushApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("twenty-mid-push-approval-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PausedTwenty(); defer { transport.release() }
        let store = AppStore(storageURL: try fixture(root), secrets: InMemorySecretStore([.twenty: "synthetic-old"]), transport: transport)
        store.twentyPacing = .zero
        store.setEndpoint("https://twenty.example.test", for: .twenty)
        var company = Company(); company.name = "Approved synthetic company"; try check(store.add(company), "company fixture failed")
        var contact = Contact(); contact.firstName = "Approved"; contact.companyID = company.id; try check(store.add(contact), "contact fixture failed")
        _ = store.previewTwentyPush()
        let pending = Task { await store.pushToTwenty() }
        try await eventually { transport.waiting }
        contact.firstName = "Unapproved while company request pending"; try check(store.update(contact), "contact edit failed")
        transport.release()
        let stopped = await pending.value
        try check(stopped.status == "failed" && stopped.error?.lowercased().contains("preview") == true && transport.backend.count("companies") == 1 && transport.backend.count("people") == 0, "a mid-push edit sent unapproved contact data")
        try check(store.workspace.twentyLinks.count == 1, "completed company receipt was lost")
        _ = store.previewTwentyPush()
        let resumed = await store.pushToTwenty()
        try check(resumed.status == "synced" && transport.backend.count("companies") == 1 && transport.backend.count("people") == 1, "fresh preview failed to resume without duplicates: \(resumed.status), \(resumed.error ?? "no error"), companies=\(transport.backend.count("companies")), people=\(transport.backend.count("people"))")
        let name = transport.backend.all("people").first?["name"] as? [String: Any]
        try check(name?["firstName"] as? String == contact.firstName, "fresh approved contact edit was not exported")
    }
}
