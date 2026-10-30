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

    // The disposable Worker accepts exactly one owner bootstrap, so connected tests share it.
    static var ownerToken: String?
    func disposableWorker() async throws -> (endpoint: String, base: URL, token: String)? {
        guard let endpoint = ProcessInfo.processInfo.environment["CONTROLWARD_TEST_WORKER"] else { return nil }
        guard let base = URL(string: endpoint), base.host == "127.0.0.1", base.scheme == "http" else {
            throw ControlWardError.invalid("Connected tests require the disposable loopback Worker.")
        }
        if let token = Self.ownerToken { return (endpoint, base, token) }
        var request = URLRequest(url: base.appendingPathComponent("api/bootstrap"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["secret": "controlward-test-only", "label": "Synthetic WebKit test"])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any], let token = body["token"] as? String else {
            throw ControlWardError.invalid("Disposable register bootstrap failed.")
        }
        Self.ownerToken = token
        return (endpoint, base, token)
    }
    func ownerCall(_ base: URL, _ path: String, token: String, method: String = "GET", body: [String: Any]? = nil) async throws -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: base.appendingPathComponent(path)); request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }
    func connectedController(_ endpoint: String, token: String) async throws -> WorkspaceWebController {
        let controller = WorkspaceWebController(module: .projects, document: document, dataStore: .nonPersistent())
        controller.start(); try await wait("typeof window.controlWard === 'object'", in: controller.webView)
        _ = try await controller.webView.callAsyncJavaScript("document.getElementById('navConn').click(); document.getElementById('cfgUrl').value=url; document.getElementById('cfgTok').value=token; document.getElementById('connectBtn').click(); return true;", arguments: ["url": endpoint, "token": token], in: nil, contentWorld: .page)
        try await wait("window.controlWard.snapshot().connected", in: controller.webView)
        return controller
    }

    func connectedCaptureIfRequested() async throws {
        guard let (endpoint, base, token) = try await disposableWorker() else { return }
        var request: URLRequest
        let controller = try await connectedController(endpoint, token: token)
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

    // Owner Approve/Reject on Candidate rows (Project Control 7648722) against the disposable Worker.
    func connectedCandidateDecisionsIfRequested() async throws {
        guard let (endpoint, base, token) = try await disposableWorker() else { return }
        func create(_ title: String, origin: String = "Martin-created") async throws -> String {
            let made = try await ownerCall(base, "api/projects", token: token, method: "POST", body: [
                "title": title + " " + UUID().uuidString, "status": "Candidate", "origin_type": origin,
                "workspace": "ws-pharos-internal", "parent_id": "ws-pharos-internal"])
            guard made.status == 201, let id = made.json["id"] as? String, made.json["origin_type"] as? String == origin else {
                throw ControlWardError.invalid("Disposable candidate setup failed (HTTP \(made.status)).")
            }
            return id
        }
        func serverRows() async throws -> [String: [String: Any]] {
            let state = try await ownerCall(base, "api/state", token: token)
            try expect(state.status == 200)
            return Dictionary((state.json["projects"] as? [[String: Any]] ?? []).compactMap { row in (row["id"] as? String).map { ($0, row) } }, uniquingKeysWith: { a, _ in a })
        }
        let approveID = try await create("Synthetic approve candidate")
        let rejectID = try await create("Synthetic reject candidate")
        let suggestionID = try await create("Synthetic suggestion", origin: "AI-suggested")
        let staleID = try await create("Synthetic stale candidate")

        var controller = try await connectedController(endpoint, token: token)
        let view = { controller.webView }
        func status(_ id: String) -> String { "(window.__pc.S.projects.find(function(p){return p.id==='\(id)';})||{}).status" }
        func decisionButtons() async throws -> Int {
            try await view().evaluateJavaScript("document.querySelectorAll('#drawer .candidate-decision [data-act]').length") as? Int ?? -1
        }
        func clearStrap() async throws { _ = try await view().evaluateJavaScript("var s=document.getElementById('strap'); s.textContent=''; s.classList.add('hidden'); true") }
        func click(_ act: String) async throws {
            let clicked = try await view().evaluateJavaScript("(function(){var b=document.querySelector('#drawer [data-act=\"\(act)\"]'); if(!b) return false; b.click(); return true;})()")
            try expect(clicked as? Bool == true)
        }
        let approvedText = "(['Approved. The candidate is now active.','Approuvé. Le candidat est maintenant actif.'].indexOf(document.getElementById('strap').textContent)>=0)"
        let rejectedText = "(['Rejected. The candidate is marked abandoned.','Rejeté. Le candidat est marqué abandonné.'].indexOf(document.getElementById('strap').textContent)>=0)"

        // Suggestions keep their own accept/dismiss flow and never show owner Approve/Reject.
        try await controller.openProject(suggestionID)
        try expect(try await decisionButtons() == 0)
        try expect(!(try await controller.projectSnapshot()).projects.contains { $0.id == suggestionID })

        // Approve and reject are separate rows; deciding one must not touch the other.
        try await controller.openProject(approveID)
        try expect(try await decisionButtons() == 2)
        try await clearStrap(); try await click("approve-candidate")
        try await wait("\(status(approveID))==='Active' && \(approvedText)", in: view())
        try await controller.openProject(rejectID)
        try expect(try await decisionButtons() == 2)
        try await clearStrap(); try await click("reject-candidate")
        try await wait("\(status(rejectID))==='Abandoned' && \(rejectedText)", in: view())
        try expect(try await view().evaluateJavaScript("\(status(approveID))==='Active'") as? Bool == true)

        var rows = try await serverRows()
        try expect(rows[approveID]?["status"] as? String == "Active")
        try expect(rows[rejectID]?["status"] as? String == "Abandoned")
        try expect(rows[suggestionID]?["status"] as? String == "Candidate" && rows[suggestionID]?["origin_type"] as? String == "AI-suggested")
        try expect(rows[staleID]?["status"] as? String == "Candidate")

        // Persistence: a refresh and a full reload both read the decisions back from the register.
        let refreshed = try await controller.projectSnapshot(refresh: true)
        try expect(refreshed.projects.first { $0.id == approveID }?.status == "Active")
        try expect(refreshed.projects.first { $0.id == rejectID }?.status == "Abandoned")
        controller = try await connectedController(endpoint, token: token)
        let reloaded = try await controller.projectSnapshot(refresh: true)
        try expect(reloaded.projects.first { $0.id == approveID }?.status == "Active")
        try expect(reloaded.projects.first { $0.id == rejectID }?.status == "Abandoned")
        try expect(reloaded.projects.first { $0.id == staleID }?.status == "Candidate")
        try expect(!reloaded.projects.contains { $0.id == suggestionID })
        try await controller.openProject(approveID)
        try expect(try await decisionButtons() == 0)

        // Stale revision: another device changes a governing field after this tab loaded the row.
        let loadedRev = try await view().evaluateJavaScript("(window.__pc.S.projects.find(function(p){return p.id==='\(staleID)';})||{}).rev") as? Int
        try expect(loadedRev == 1)
        let other = try await ownerCall(base, "api/projects/\(staleID)", token: token, method: "PATCH", body: ["fields": ["next_action": "Changed on another device"], "expectedRev": 1])
        try expect(other.status == 200)
        try await controller.openProject(staleID)
        try expect(try await decisionButtons() == 2)
        try await clearStrap(); try await click("approve-candidate")
        try await wait("!document.getElementById('conflictModal').classList.contains('hidden')", in: view())
        try expect(try await view().evaluateJavaScript("!\(approvedText) && \(status(staleID))==='Candidate'") as? Bool == true)
        rows = try await serverRows()
        try expect(rows[staleID]?["status"] as? String == "Candidate" && rows[staleID]?["rev"] as? Int == 2)
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
                try await tests.connectedCandidateDecisionsIfRequested()
                print("WebKit integration tests: \(ModuleRenderingTests.checks) assertions passed")
                exit(0)
            } catch { print("FAIL WebKit integration: \(error)"); exit(1) }
        }
        app.run()
    }
}
