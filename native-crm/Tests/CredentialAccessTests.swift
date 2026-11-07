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
    final class SecurityFake: @unchecked Sendable {
        struct Call: Sendable { var service: String; var account: String; var data: Bool; var interactive: Bool }
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
                lock.withLock { calls.append(Call(service: query[kSecAttrService as String] as? String ?? "", account: query[kSecAttrAccount as String] as? String ?? "", data: data, interactive: interactive)) }
                if !data { return .init(status: attributesStatus, data: nil) }
                if attributesStatus == errSecItemNotFound { return .init(status: errSecItemNotFound, data: nil) }
                return interactive ? .init(status: errSecSuccess, data: Data("synthetic-credential".utf8)) : .init(status: errSecInteractionNotAllowed, data: nil)
            }
        }
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
        await store.pullLeadsOnLaunch(); await mail.refreshAll(store: store, userInitiated: false)
        try check(store.keyAccessNeeded.contains(.pharos) && !store.hasKey(.pharos), "blocked key not represented honestly")
        if case .accessRequired = store.connectorStatus(.pharos) {} else { throw SmokeTestFailure.failed("historical health hid current access requirement") }
        try check(mail.state(.personalGmail) == .accessRequired && mail.state(.infrafabric) == .accessRequired, "blocked sign-ins appeared disconnected")
        let count = fake.history.count
        for _ in 0..<20 { _ = mail.anyConnected; _ = mail.isConfigured(MailAccount.personalGmail.email) }
        try check(fake.history.count == count, "rendered connection state reprobes credentials")
        try check(fake.history.allSatisfy { !$0.interactive && !$0.data } && network.requests == 0, "startup requested auth/data/network after denied probe")
        try check(try Data(contentsOf: file) == before && store.workspace.autoPilotEnabled, "startup changed saved owner state/preference")
    }
    static func pharosBackground() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-pharos-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = SecurityFake(); let network = NetworkFake(); let file = try fixture(root)
        let store = AppStore(storageURL: file, secrets: KeychainSecretStore(lookup: fake.lookup), transport: network)
        try check(store.hasKey(.pharos), "successful attributes did not establish availability")
        await store.pullLeadsOnLaunch()
        try check(fake.history.filter(\.data).count == 1 && fake.history.filter(\.data).allSatisfy { !$0.interactive }, "automatic PHAROS read allowed authentication")
        try check(network.requests == 0 && store.keyAccessNeeded.contains(.pharos) && !store.isPullingLeads, "denied automatic access reached network or kept a running label")
        try check(store.workspace.autoPilotEnabled, "denial disabled the saved preference")
        await store.verifyConnector(.pharos)
        try check(fake.history.last?.interactive == true && fake.history.last?.data == true, "explicit Verify lost normal authentication")
        try check(store.hasKey(.pharos) && !store.keyAccessNeeded.contains(.pharos) && network.requests == 2, "manual access retry did not clear the transient blocked state")
    }
    static func mailBackground() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-mail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root); let fake = SecurityFake(); let network = NetworkFake()
        let store = AppStore(storageURL: file, secrets: InMemorySecretStore(), transport: network)
        let mail = MailIntakeController(tokens: KeychainMailTokenStore(lookup: fake.lookup), transport: network, defaults: UserDefaults(suiteName: "credential-mail-\(UUID())")!, accessMode: .live)
        mail.startPeriodic(store: store)
        defer { mail.stopPeriodic() }
        for _ in 0..<200 {
            if mail.state(.personalGmail) == .accessRequired && mail.state(.infrafabric) == .accessRequired { break }
            await Task.yield()
        }
        try check(fake.history.filter(\.data).count == 2 && fake.history.allSatisfy { !$0.interactive }, "automatic mail read requested interaction")
        try check(network.requests == 0 && mail.anyConnected && mail.state(.personalGmail) == .accessRequired, "denied access erased connection presence or reached a provider")
        await mail.refresh(.personalGmail, store: store)
        if case .synced(_, 0) = mail.state(.personalGmail) {} else { throw SmokeTestFailure.failed("explicit mail retry failed") }
        try check(network.requests == 2 && fake.history.last?.interactive == true, "explicit Refresh did not retain normal authentication")
        try check(mail.state(.infrafabric) == .accessRequired && mail.credentialAvailability[MailAccount.infrafabric.email] == .accessRequired, "retry modified another account")
    }
}
