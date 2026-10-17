import AppKit
import Foundation
import WebKit

@MainActor
struct ModuleRenderingTests {
    static var checks = 0
    func expect(_ value: Bool) throws {
        guard value else { throw ControlWardError.invalid("WebKit behavior assertion failed.") }
        Self.checks += 1
    }
    var document: URL { URL(fileURLWithPath: CommandLine.arguments[1]) }
    func wait(_ script: String, in view: WKWebView) async throws {
        for _ in 0..<100 {
            if let value = try? await view.evaluateJavaScript(script), value as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ControlWardError.invalid("WebKit test did not reach its expected state.")
    }

    func dashboardRendersAndPreservesEdits() async throws {
        _ = NSApplication.shared
        let controller = WorkspaceWebController(module: .projects, document: document, dataStore: .nonPersistent())
        controller.webView.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        controller.start()
        try await wait("typeof window.controlWard === 'object'", in: controller.webView)
        let snapshot = try await controller.projectSnapshot()
        try expect(!snapshot.connected)
        try expect(controller.failure == nil)
        // Fill an actual control. Revisiting a retained module must not reload it.
        _ = try await controller.webView.evaluateJavaScript("document.getElementById('navConn').click(); document.getElementById('cfgUrl').value='https://synthetic.example.test'; true;")
        controller.start()
        let draft = try await controller.webView.evaluateJavaScript("document.getElementById('cfgUrl').value")
        try expect(draft as? String == "https://synthetic.example.test")
        let assets = try await controller.webView.evaluateJavaScript("Array.from(document.images).filter(x=>x.getAttribute('src') && !x.getAttribute('src').startsWith('data:')).every(x=>x.complete && x.naturalWidth>0)")
        try expect(assets as? Bool == true)
        // A native capture cannot silently write into a standalone snapshot.
        var refused = false
        do { _ = try await controller.capture(ProjectCapture(source: "controlward-record", sourceID: "synthetic-task", summary: "Synthetic test")) }
        catch { refused = true }
        try expect(refused)
    }

    func connectedCaptureIfRequested() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["CONTROLWARD_TEST_WORKER"] else { return }
        guard let base = URL(string: endpoint), base.host == "127.0.0.1", base.scheme == "http" else {
            throw ControlWardError.invalid("Connected tests require the disposable loopback Worker.")
        }
        var request = URLRequest(url: base.appendingPathComponent("api/bootstrap"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["secret": "controlward-test-only", "label": "Synthetic WebKit test"])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any], let token = body["token"] as? String else {
            throw ControlWardError.invalid("Disposable register bootstrap failed.")
        }
        let controller = WorkspaceWebController(module: .projects, document: document, dataStore: .nonPersistent())
        controller.start(); try await wait("typeof window.controlWard === 'object'", in: controller.webView)
        _ = try await controller.webView.callAsyncJavaScript("document.getElementById('navConn').click(); document.getElementById('cfgUrl').value=url; document.getElementById('cfgTok').value=token; document.getElementById('connectBtn').click(); return true;", arguments: ["url": endpoint, "token": token], in: nil, contentWorld: .page)
        try await wait("window.controlWard.snapshot().connected", in: controller.webView)
        let snapshot = try await controller.projectSnapshot()
        try expect(snapshot.connected && snapshot.register == endpoint)
        let item = ProjectCapture(source: "controlward-record", sourceID: "native-webkit-synthetic", summary: "Quoted \"subject\" <test> \(UUID().uuidString)", metadata: ["record_type": "tasks"])
        let first = try await controller.capture(item, expectedRegister: endpoint)
        let second = try await controller.capture(item, expectedRegister: endpoint)
        try expect(first.id == second.id && !first.duplicate && second.duplicate)
        try expect(first.register == endpoint)
        var refused = false
        do { _ = try await controller.capture(item, expectedRegister: "https://different.example.test") } catch { refused = true }
        try expect(refused)
        request = URLRequest(url: base.appendingPathComponent("api/state")); request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (stateData, _) = try await URLSession.shared.data(for: request)
        let state = try JSONSerialization.jsonObject(with: stateData) as? [String: Any]
        let rows = (state?["items"] as? [[String: Any]] ?? []).filter { $0["source_id"] as? String == item.sourceID }
        try expect(rows.count == 1 && rows[0]["summary"] as? String == item.summary && rows[0]["project_id"] is NSNull)
    }

    func storageIsIsolatedAndUnsafeNavigationIsDenied() async throws {
        let first = WorkspaceWebController(module: .projects, document: document, dataStore: .nonPersistent())
        let second = WorkspaceWebController(module: .projects, document: document, dataStore: .nonPersistent())
        first.start(); second.start()
        try await wait("typeof window.controlWard === 'object'", in: first.webView)
        try await wait("typeof window.controlWard === 'object'", in: second.webView)
        _ = try await first.webView.evaluateJavaScript("localStorage.setItem('controlward-isolation-test','synthetic'); true")
        let isolated = try await second.webView.evaluateJavaScript("localStorage.getItem('controlward-isolation-test') === null")
        try expect(isolated as? Bool == true)
        _ = try await first.webView.evaluateJavaScript("location.href='https://example.test/refused-navigation'; true")
        for _ in 0..<30 {
            if first.failure != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try expect(first.failure != nil)
        try expect(first.webView.url?.isFileURL == true)
    }
}

@main
@MainActor
struct WebKitTestRunner {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let tests = ModuleRenderingTests()
                try await tests.dashboardRendersAndPreservesEdits()
                try await tests.storageIsIsolatedAndUnsafeNavigationIsDenied()
                try await tests.connectedCaptureIfRequested()
                print("WebKit integration tests: \(ModuleRenderingTests.checks) assertions passed")
                exit(0)
            } catch { print("FAIL WebKit integration: \(error)"); exit(1) }
        }
        app.run()
    }
}
