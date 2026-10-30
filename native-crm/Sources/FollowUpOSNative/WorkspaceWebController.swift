import AppKit
import Combine
import UniformTypeIdentifiers
import WebKit

@MainActor
final class WorkspaceWebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let module: WorkspaceModule
    let webView: WKWebView
    let document: URL?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    private var started = false
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    init(module: WorkspaceModule, document: URL? = nil, dataStore: WKWebsiteDataStore? = nil) {
        self.module = module
        self.document = document
        let configuration = WKWebViewConfiguration()
#if DEBUG && CONTEXTWARD_ACCEPTANCE
        // Ignore even an explicitly supplied persistent data store in the isolated preview.
        _ = dataStore
        configuration.websiteDataStore = .nonPersistent()
#else
        configuration.websiteDataStore = dataStore ?? WKWebsiteDataStore(forIdentifier: module.dataStoreID)
#endif
        // No script-message handlers, injected scripts or native credential bridge.
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
    }

    func start() {
        guard !started else { return }
        started = true
        reload()
    }

    func reload() {
#if DEBUG && CONTEXTWARD_ACCEPTANCE
        loading = false
        failure = "Web modules are disabled in the isolated offline preview."
        return
#endif
        failure = nil
        loading = true
        if module == .projects, let document,
           FileManager.default.fileExists(atPath: document.path) {
            webView.loadFileURL(document, allowingReadAccessTo: document.deletingLastPathComponent())
        } else if let url = module.website {
            webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
        } else {
            loading = false
            failure = "The bundled Project Control dashboard is missing. Rebuild ControlWard with its resources."
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
#if DEBUG && CONTEXTWARD_ACCEPTANCE
        decisionHandler(.cancel)
        return
#else
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let policy = WorkspaceModulePolicy(module: module, projectDocument: document)
        let decision = policy.navigation(to: url, userInitiated: action.navigationType == .linkActivated,
                                         mainFrame: action.targetFrame?.isMainFrame ?? true,
                                         download: action.shouldPerformDownload)
        switch decision {
        case .embedded: decisionHandler(.allow)
        case .download: decisionHandler(.download)
        case .external:
            decisionHandler(.cancel)
#if !DEBUG || !CONTEXTWARD_ACCEPTANCE
            NSWorkspace.shared.open(url)
#endif
        case .blocked:
            decisionHandler(.cancel)
            // A rejected iframe does not replace the state of its parent page.
            if action.targetFrame?.isMainFrame != false {
                loading = false
                failure = "This navigation is outside the module. Use an ordinary link or open Email Aggregator in your browser."
            }
        }
#endif
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true; failure = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadFailed(error) }
    private func loadFailed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loading = false
        // Provider errors can include callback URLs. Never copy them into app logs or UI.
        failure = "The module could not load. Check your connection and try again. Your saved data has been retained."
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false
        failure = "The module stopped responding. Reload it to continue."
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
#if DEBUG && CONTEXTWARD_ACCEPTANCE
        return nil
#else
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           WorkspaceModulePolicy(module: module, projectDocument: document)
            .navigation(to: url, userInitiated: true, mainFrame: true) == .embedded {
            webView.load(navigationAction.request)
        }
        return nil
#endif
    }

    // File access is owner-selected and stays inside the existing App Sandbox.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
#if DEBUG && CONTEXTWARD_ACCEPTANCE
        completionHandler(nil)
#else
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if module == .projects { panel.allowedContentTypes = [.json] }
        panel.begin { response in completionHandler(response == .OK ? panel.urls : nil) }
#endif
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert(); alert.messageText = module.title; alert.informativeText = message
        alert.addButton(withTitle: "OK"); alert.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = module.title; alert.informativeText = message
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
#if DEBUG && CONTEXTWARD_ACCEPTANCE
        completionHandler(nil)
#else
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        if module == .projects { panel.allowedContentTypes = [.json] }
        panel.begin { [weak self] result in
            let destination = result == .OK ? panel.url : nil
            self?.downloadDestinations[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        }
#endif
    }
    func downloadDidFinish(_ download: WKDownload) {
        // A Project Control export can contain private register data.
        if let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        failure = "The export could not be saved. Try exporting again."
    }
}
