import Foundation

/// A module may navigate inside its own origin. Following an ordinary external
/// link is an explicit browser action; redirects never open another application.
enum WorkspaceModule: String, CaseIterable, Sendable {
    case projects, email

    var title: String { self == .projects ? "Project Control" : "Email Aggregator" }
    var website: URL? {
        self == .email ? URL(string: "https://email-aggregator-ext-ol5f.bolt.host/") : nil
    }
    var dataStoreID: UUID {
        // Separate persistent WebKit stores; neither shares CRM connector keys.
        UUID(uuidString: self == .projects
             ? "02B8B9B4-8554-412A-986A-199E60ABF722"
             : "BA168B30-4C75-4BAF-932C-6915234E57DF")!
    }
}

enum ModuleNavigation: Equatable { case embedded, external, download, blocked }

struct WorkspaceModulePolicy {
    let module: WorkspaceModule
    let projectDocument: URL?

    func navigation(to url: URL, userInitiated: Bool, mainFrame: Bool, download: Bool = false) -> ModuleNavigation {
        guard mainFrame, url.user == nil, url.password == nil else { return .blocked }
        let scheme = url.scheme?.lowercased()
        if module == .projects, download, scheme == "blob" { return .download }
        if module == .projects, url.isFileURL, let projectDocument,
           url.standardizedFileURL.path == projectDocument.standardizedFileURL.path,
           url.query == nil { return .embedded }
        if module == .email, scheme == "https", url.host?.lowercased() == module.website?.host,
           url.port == nil || url.port == 443 { return .embedded }
        if userInitiated, scheme == "https" || scheme == "http" { return .external }
        return .blocked
    }
}
