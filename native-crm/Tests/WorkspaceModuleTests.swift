import Foundation

enum WorkspaceModuleTests {
    @MainActor static func run() -> Bool {
        let document = URL(fileURLWithPath: "/app/ProjectControl/project-control.html")
        let projects = WorkspaceModulePolicy(module: .projects, projectDocument: document)
        let email = WorkspaceModulePolicy(module: .email, projectDocument: nil)
        // Preview isolation, synthetic values only. `MailAccount.all` is read only in the DEBUG preview block below.
        var previewNeedsSetup = false
        if case .needsSetup = ConnectorStatus.resolve(endpoint: PreviewIsolation.endpoint(stored: nil), hasKey: true, health: nil) { previewNeedsSetup = true }
        let previewSignIns = Set(MailAccount.preview.filter(\.isSignIn).map(\.email))
        let previewAddresses = MailAccount.preview.flatMap { [$0.email] + ($0.forwardsInto.map { [$0] } ?? []) }
        let shared: [(String, Bool)] = [
            ("bundled dashboard is embedded", projects.navigation(to: document, userInitiated: false, mainFrame: true) == .embedded),
            ("other local files are refused", projects.navigation(to: URL(fileURLWithPath: "/private/example.json"), userInitiated: true, mainFrame: true) == .blocked),
            ("dashboard query cannot import a token", projects.navigation(to: URL(string: "file:///app/ProjectControl/project-control.html?token=synthetic")!, userInitiated: true, mainFrame: true) == .blocked),
            ("email stays on its exact HTTPS origin", email.navigation(to: URL(string: "https://email-aggregator-ext-ol5f.bolt.host/inbox")!, userInitiated: false, mainFrame: true) == .embedded),
            ("lookalike origin is refused", email.navigation(to: URL(string: "https://email-aggregator-ext-ol5f.bolt.host.example.test/")!, userInitiated: false, mainFrame: true) == .blocked),
            ("nonstandard port is refused", email.navigation(to: URL(string: "https://email-aggregator-ext-ol5f.bolt.host:444/")!, userInitiated: false, mainFrame: true) == .blocked),
            ("embedded credentials are refused", email.navigation(to: URL(string: "https://user:synthetic@email-aggregator-ext-ol5f.bolt.host/")!, userInitiated: true, mainFrame: true) == .blocked),
            ("redirects cannot open another app", email.navigation(to: URL(string: "https://example.test/callback")!, userInitiated: false, mainFrame: true) == .blocked),
            ("clicked source link opens externally", projects.navigation(to: URL(string: "https://example.test/source")!, userInitiated: true, mainFrame: true) == .external),
            ("script schemes are refused", email.navigation(to: URL(string: "javascript:alert(1)")!, userInitiated: true, mainFrame: true) == .blocked),
            ("iframe cannot open a browser", email.navigation(to: URL(string: "https://example.test")!, userInitiated: true, mainFrame: false) == .blocked),
            ("dashboard export uses download handling", projects.navigation(to: URL(string: "blob:null/synthetic-export")!, userInitiated: false, mainFrame: true, download: true) == .download),
            ("blob navigation is not an export", projects.navigation(to: URL(string: "blob:null/synthetic-export")!, userInitiated: false, mainFrame: true) == .blocked),
            ("email cannot use project export handling", email.navigation(to: URL(string: "blob:null/synthetic-export")!, userInitiated: false, mainFrame: true, download: true) == .blocked),
            ("module cookie stores are distinct", WorkspaceModule.projects.dataStoreID != WorkspaceModule.email.dataStoreID),
            ("preview endpoint has no default to fall back to", PreviewIsolation.endpoint(stored: nil).isEmpty),
            ("preview hides the production Kairos default", !KairosClient.defaultEndpoint.isEmpty && PreviewIsolation.endpoint(stored: KairosClient.defaultEndpoint).isEmpty),
            ("preview keeps a reserved test endpoint", PreviewIsolation.endpoint(stored: "https://twenty.example.test/rest") == "https://twenty.example.test/rest"),
            ("preview refuses a lookalike test host", PreviewIsolation.endpoint(stored: "https://twenty.example.test.example.com/").isEmpty),
            ("preview connector status needs setup", previewNeedsSetup),
            ("preview endpoint labels carry no URL", SyncTarget.allCases.allSatisfy { !PreviewIsolation.endpointLabel($0).contains("://") }),
            ("preview mail accounts use reserved test names", !previewAddresses.isEmpty && previewAddresses.allSatisfy { PreviewIsolation.isReservedTestHost(String($0.split(separator: "@").last ?? "")) }),
            ("preview aliases forward into a preview sign-in", !previewSignIns.isEmpty && MailAccount.preview.allSatisfy { $0.forwardsInto.map(previewSignIns.contains) ?? true }),
        ]
#if DEBUG && CONTEXTWARD_ACCEPTANCE
        // Empty in-memory preferences, in-memory tokens, no-network transport: the synthetic/nil preview path only.
        let previewMail = MailIntakeController(tokens: InMemoryMailTokenStore(), transport: PreviewNoNetworkHTTPTransport(), preferences: InMemoryPreviewPreferences())
        var previewOAuthConfigured = true
        do { _ = try previewMail.config() } catch { previewOAuthConfigured = false }
        let cases = shared + [
            ("DEBUG preview: Email surfaces list only the synthetic accounts", MailAccount.all == MailAccount.preview),
            ("DEBUG preview: mail states track only synthetic sign-ins", Set(previewMail.states.keys) == previewSignIns),
            ("DEBUG preview: empty preferences leave no OAuth client ID", previewMail.clientID.isEmpty && !previewOAuthConfigured),
        ]
#else
        let cases = shared
#endif
        for (name, passed) in cases { print("\(passed ? "PASS" : "FAIL")  Workspace modules: \(name)") }
        print("Workspace module tests: \(cases.filter(\.1).count)/\(cases.count) passed")
        return cases.allSatisfy(\.1)
    }
}
