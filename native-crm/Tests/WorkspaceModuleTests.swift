import Foundation

enum WorkspaceModuleTests {
    static func run() -> Bool {
        let document = URL(fileURLWithPath: "/app/ProjectControl/project-control.html")
        let projects = WorkspaceModulePolicy(module: .projects, projectDocument: document)
        let email = WorkspaceModulePolicy(module: .email, projectDocument: nil)
        let cases: [(String, Bool)] = [
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
        ]
        for (name, passed) in cases { print("\(passed ? "PASS" : "FAIL")  Workspace modules: \(name)") }
        print("Workspace module tests: \(cases.filter(\.1).count)/\(cases.count) passed")
        return cases.allSatisfy(\.1)
    }
}
