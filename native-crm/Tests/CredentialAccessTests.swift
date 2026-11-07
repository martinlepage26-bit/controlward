import Foundation
import LocalAuthentication
import Security

@MainActor enum CredentialAccessTests {
    static func run() async -> Bool {
        let cases: [(String, () async throws -> Void)] = [
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
        private var probes = 0, reads = 0, mainCalls = 0
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
            let before = lock.withLock { values[key] }; wait(probe: false); return before
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
