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

    func archiveViewsRenderInNativeWebKit() async throws {
        let controller = WorkspaceWebController(module: .projects, document: document, dataStore: .nonPersistent())
        controller.webView.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        controller.start()
        try await wait("typeof window.controlWard === 'object'", in: controller.webView)
        let script = #"""
        window.fetch = async function(){return {ok:true,json:async()=>({schema:1,stream_id:'synthetic',through:2,next:2,done:true,capture_started:'2026-11-09T00:00:00Z',coverage:'Synthetic retained baseline',rows:[
        {seq:1,captured_at:'2026-11-09T00:00:00Z',entity:'projects',entity_id:'test-project',operation:'baseline',before_json:null,after_json:JSON.stringify({id:'test-project',title:'Native archive project'})},
        {seq:2,captured_at:'2026-11-09T00:00:01Z',entity:'notes',entity_id:'test-note',operation:'insert',before_json:null,after_json:JSON.stringify({id:'test-note',project_id:'test-project',body:'Native evidence <script>untrusted</script>'})}
        ]})};};
        document.getElementById('navArchive').click();document.getElementById('archiveLoad').click();true;
        """#
        _ = try await controller.webView.evaluateJavaScript(script)
        try await wait("document.getElementById('archiveStatus').textContent.includes('2 retained records')", in: controller.webView)
        try expect((try await controller.webView.evaluateJavaScript("document.getElementById('archiveBody').textContent.includes('Native archive project')")) as? Bool == true)
        _ = try await controller.webView.evaluateJavaScript("document.querySelector('[data-archive-tab=evidence]').click();true")
        try expect((try await controller.webView.evaluateJavaScript("document.getElementById('archiveBody').textContent.includes('Native evidence') && !document.querySelector('#archiveBody script')")) as? Bool == true)
        _ = try await controller.webView.evaluateJavaScript("document.querySelector('[data-archive-tab=graph]').click();true")
        try await wait("document.getElementById('archiveGraphFrame')?.dataset.ready === 'true'", in: controller.webView)
        try expect((try await controller.webView.evaluateJavaScript("document.getElementById('archiveGraphFrame').dataset.nodeCount === '2'")) as? Bool == true)
        try expect(!(try await controller.projectSnapshot()).connected)
    }

    func hostedProjectsMigrationIfRequested() async throws {
        guard ProcessInfo.processInfo.environment["CONTROLWARD_TEST_HOSTED_PROJECTS"] == "1" else { return }
        // Disposable WebKit storage; a deliberately invalid fixture credential
        // only exercises read/authentication paths on the owning service.
        let data = WKWebsiteDataStore.nonPersistent()
        let legacy = WorkspaceWebController(module: .projects, document: document, dataStore: data)
        legacy.start()
        try await wait("typeof window.controlWard === 'object'", in: legacy.webView)
        _ = try await legacy.webView.evaluateJavaScript("localStorage.setItem('pc-config-v4',JSON.stringify({url:'https://project-control.ml-c38.workers.dev',token:'synthetic-migration-fixture'}));true")
        let hosted = WorkspaceWebController(module: .projects, document: document, dataStore: data, hostedProjects: true)
        hosted.start()
        for _ in 0..<300 {
            if hosted.webView.url?.absoluteString == "https://project-control.ml-c38.workers.dev/",
               let ready = try? await hosted.webView.evaluateJavaScript("typeof window.controlWard === 'object' && JSON.parse(localStorage.getItem('pc-config-v4')||'{}').token === 'synthetic-migration-fixture'"), ready as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try expect(hosted.webView.url?.absoluteString == "https://project-control.ml-c38.workers.dev/")
        try expect((try await hosted.webView.evaluateJavaScript("JSON.parse(localStorage.getItem('pc-config-v4')||'{}').token === 'synthetic-migration-fixture'")) as? Bool == true)
        try expect((try await legacy.webView.evaluateJavaScript("JSON.parse(localStorage.getItem('pc-config-v4')||'{}').token === 'synthetic-migration-fixture'")) as? Bool == true)
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

    func projectOpensStayInTheirRegister() async throws {
        let controller = WorkspaceWebController(module: .projects, document: document, dataStore: .nonPersistent())
        controller.start(); try await wait("typeof window.controlWard === 'object'", in: controller.webView)
        let register = "https://first.example.test", other = "https://second.example.test"
        let projectID = "quoted \" id <script>"
        // Exercise the native WKWebView call boundary with a held first snapshot
        // and a changed second snapshot. No account, provider or real register.
        func configure(secondRegister: String, connected: Bool = true) async throws {
            _ = try await controller.webView.callAsyncJavaScript("""
                window.searchOpenCalls = [];
                let reads = 0;
                window.controlWard = {
                    snapshot() { reads++; return { connected: reads === 1 || secondConnected,
                        online: true, register: reads === 1 ? firstRegister : secondRegister,
                        projects: [{id: knownID, title: 'Synthetic project', status: 'active', workspace: 'Test'}] }; },
                    openProject(id) { if (id !== knownID) return false; window.searchOpenCalls.push(id); return true; }
                };
                return true;
                """, arguments: ["firstRegister": register, "secondRegister": secondRegister,
                                  "secondConnected": connected, "knownID": projectID], in: nil, contentWorld: .page)
        }
        try await configure(secondRegister: register)
        try await controller.openProject(projectID, expectedRegister: register)
        let opened = try await controller.webView.evaluateJavaScript("window.searchOpenCalls") as? [String]
        try expect(opened == [projectID])

        try await configure(secondRegister: other)
        var refused = false
        do { try await controller.openProject(projectID, expectedRegister: register) } catch { refused = true }
        let changedCalls = try await controller.webView.evaluateJavaScript("window.searchOpenCalls.length") as? Int
        try expect(refused && changedCalls == 0)

        try await configure(secondRegister: register, connected: false)
        refused = false
        do { try await controller.openProject(projectID, expectedRegister: register) } catch { refused = true }
        let disconnectedCalls = try await controller.webView.evaluateJavaScript("window.searchOpenCalls.length") as? Int
        try expect(refused && disconnectedCalls == 0)

        try await configure(secondRegister: register)
        refused = false
        do { try await controller.openProject("absent", expectedRegister: register) } catch { refused = true }
        let absentCalls = try await controller.webView.evaluateJavaScript("window.searchOpenCalls.length") as? Int
        try expect(refused && absentCalls == 0)

        refused = false
        do { try await controller.openProject(projectID, expectedRegister: " ") } catch { refused = true }
        try expect(refused)
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
            try await tests.archiveViewsRenderInNativeWebKit()
                try await tests.storageIsIsolatedAndUnsafeNavigationIsDenied()
                try await tests.projectOpensStayInTheirRegister()
                try await tests.connectedCaptureIfRequested()
                try await tests.hostedProjectsMigrationIfRequested()
                print("WebKit integration tests: \(ModuleRenderingTests.checks) assertions passed")
                exit(0)
            } catch { print("FAIL WebKit integration: \(error)"); exit(1) }
        }
        app.run()
    }
}
