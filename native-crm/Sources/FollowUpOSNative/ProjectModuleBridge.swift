import Foundation
import WebKit

// ProjectModuleRecord, ProjectModuleSnapshot and ProjectModuleReceipt live in ProjectControlWrites.swift (portable).

@MainActor
extension WorkspaceWebController {
    private func projectCall<T: Decodable>(_ body: String, arguments: [String: Any] = [:], as type: T.Type) async throws -> T {
        guard module == .projects else { throw ControlWardError.invalid("This action belongs to Project Control.") }
        start()
        // Bounded readiness wait; the page may already be retained from another section.
        for _ in 0..<50 {
            if let ready = try? await webView.evaluateJavaScript("typeof window.controlWard === 'object'"), ready as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let result: Any?
        do { result = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page) }
        catch { throw ControlWardError.invalid("Project Control did not confirm this action. Open Projects, check its connection, and retry the same record.") }
        guard let result, JSONSerialization.isValidJSONObject(result) else { throw ControlWardError.invalid("Project Control returned an unreadable response.") }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: result))
    }

    func projectSnapshot(refresh: Bool = false) async throws -> ProjectModuleSnapshot {
        try await projectCall(refresh ? "return await window.controlWard.refresh();" : "return window.controlWard.snapshot();", as: ProjectModuleSnapshot.self)
    }

    func capture(_ item: ProjectCapture, expectedRegister: String? = nil) async throws -> ProjectModuleReceipt {
        // JSON arguments are marshalled by WebKit. Subject text is never source code.
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item))
        return try await projectCall("return await window.controlWard.capture(item, expectedRegister);", arguments: ["item": value, "expectedRegister": expectedRegister ?? ""], as: ProjectModuleReceipt.self)
    }

    func openProject(_ id: String) async throws {
        _ = try await projectSnapshot()
        let opened = try await webView.callAsyncJavaScript("return window.controlWard.openProject(id);", arguments: ["id": id], in: nil, contentWorld: .page)
        guard opened as? Bool == true else { throw ControlWardError.invalid("This project is absent from the loaded register. Refresh Projects and check the link.") }
    }
}
