import Foundation

// Slice 2 (wind-acceptance-tests.md §2): every Project Control write is checked before any POST and leaves
// exactly one CW-AUDIT v1 line. Portable; the WebKit bridge in ProjectModuleBridge.swift conforms to
// ProjectCaptureBridge, and tests use a fake bridge.

struct ProjectCapture: Codable, Equatable, Sendable {
    var source: String
    var sourceID: String
    var summary: String
    var link: String = ""
    var metadata: [String: String] = [:]
    enum CodingKeys: String, CodingKey { case source, sourceID = "source_id", summary, link, metadata }
}

struct ProjectModuleRecord: Decodable, Identifiable, Sendable {
    var id: String
    var title: String
    var status: String
    var workspace: String
}

struct ProjectModuleSnapshot: Decodable, Sendable {
    var connected: Bool
    var online: Bool
    var register: String
    var pulledAt: String?
    var projects: [ProjectModuleRecord]
}

struct ProjectModuleReceipt: Decodable, Equatable, Sendable {
    var id: String
    var duplicate: Bool
    var register: String
}

/// The two bridge calls a capture needs. `capture` is the only one that POSTs (`/api/items`).
protocol ProjectCaptureBridge: Sendable {
    func projectSnapshot(refresh: Bool) async throws -> ProjectModuleSnapshot
    func capture(_ item: ProjectCapture, expectedRegister: String?) async throws -> ProjectModuleReceipt
}

/// Adapts any pair of closures (the WebKit controller in the app, a fake in tests) to the bridge protocol.
struct ClosureProjectBridge: ProjectCaptureBridge {
    var snapshot: @Sendable (Bool) async throws -> ProjectModuleSnapshot
    var send: @Sendable (ProjectCapture, String?) async throws -> ProjectModuleReceipt
    func projectSnapshot(refresh: Bool) async throws -> ProjectModuleSnapshot { try await snapshot(refresh) }
    func capture(_ item: ProjectCapture, expectedRegister: String?) async throws -> ProjectModuleReceipt { try await send(item, expectedRegister) }
}

/// The register-side refusals (project-control.html `window.controlWard.capture`), mirrored natively so they
/// happen before the bridge is asked to POST.
enum ProjectCaptureRules {
    static let supportedSources: Set<String> = ["controlward-record", "controlward-signal", "controlward-email-import", "email-aggregator-synthetic"]
    static let syntheticSource = "email-aggregator-synthetic"
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    static func isLoopback(register: String) -> Bool {
        guard let host = URL(string: register)?.host?.lowercased() else { return false }
        return loopbackHosts.contains(host)
    }

    /// Returns the refusal code for a capture, or nil when it may be sent.
    static func refusal(snapshot: ProjectModuleSnapshot, item: ProjectCapture, expectedRegister: String?) -> String? {
        guard snapshot.connected else { return "refused:register-disconnected" }
        if let expectedRegister, expectedRegister != snapshot.register { return "refused:register-changed" }
        guard supportedSources.contains(item.source) else { return "refused:unsupported-source" }
        if item.source == syntheticSource && !isLoopback(register: snapshot.register) { return "refused:synthetic-non-loopback" }
        return nil
    }

    static func message(for code: String) -> String {
        switch code {
        case "refused:register-disconnected": "Connect your register in Projects before capturing. Nothing was sent."
        case "refused:register-changed": "The connected register changed. Review the destination again. Nothing was sent."
        case "refused:unsupported-source": "This record type cannot be captured. Nothing was sent."
        case "refused:synthetic-non-loopback": "Synthetic mail can only be captured in a local test register. Nothing was sent."
        default: "Project Control did not confirm this action. Nothing was recorded."
        }
    }
}

struct ProjectWriteResult: Equatable, Sendable {
    var receipt: ProjectModuleReceipt?
    /// True only when a new local receipt was written.
    var recordedReceipt: Bool
    var status: String
    var failure: String?
    var audit: CWAuditLine
}

/// Runs captures and records link/unlink, one audit line each (S2-R1..R3).
struct ProjectControlWriter: Sendable {
    var bridge: any ProjectCaptureBridge
    var sink: any CWAuditSink
    var now: @Sendable () -> Date = { Date() }

    private func line(_ action: String, register: String, target: String, source: String, result: String, receipt: String = "-") -> CWAuditLine {
        CWAuditLine(ts: now(), surface: "project-control", action: action, register: register, target: target, source: source, result: result, receipt: receipt)
    }

    /// `recordReceipt` stores the local receipt (AppStore.recordCapture, on the main actor).
    /// It runs at most once, and never for a duplicate (409) or a refusal.
    func capture(recordKey: String, item: ProjectCapture, expectedRegister: String?,
                 recordReceipt: @escaping @MainActor @Sendable (ProjectModuleReceipt) throws -> Void) async -> ProjectWriteResult {
        let target = "\(item.source):\(item.sourceID)"
        let snapshot: ProjectModuleSnapshot
        do { snapshot = try await bridge.projectSnapshot(refresh: false) } catch {
            let audit = line("capture", register: CWAuditLine.register(for: expectedRegister.flatMap(URL.init(string:))), target: target, source: recordKey, result: "refused:register-disconnected")
            sink.write(audit)
            let text = ProjectCaptureRules.message(for: audit.result)
            return ProjectWriteResult(receipt: nil, recordedReceipt: false, status: text, failure: text, audit: audit)
        }
        let register = CWAuditLine.register(for: URL(string: snapshot.register))
        if let refusal = ProjectCaptureRules.refusal(snapshot: snapshot, item: item, expectedRegister: expectedRegister) {
            let audit = line("capture", register: register, target: target, source: recordKey, result: refusal)
            sink.write(audit)
            let text = ProjectCaptureRules.message(for: refusal)
            return ProjectWriteResult(receipt: nil, recordedReceipt: false, status: text, failure: text, audit: audit)
        }
        let receipt: ProjectModuleReceipt
        do { receipt = try await bridge.capture(item, expectedRegister: expectedRegister ?? snapshot.register) } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "Project Control did not confirm this action. Retry the same record to avoid duplication."
            let audit = line("capture", register: register, target: target, source: recordKey, result: Self.errorCode(text))
            sink.write(audit)
            return ProjectWriteResult(receipt: nil, recordedReceipt: false, status: text, failure: text, audit: audit)
        }
        if receipt.duplicate {
            let audit = line("capture", register: register, target: target, source: recordKey, result: "duplicate", receipt: receipt.id)
            sink.write(audit)
            return ProjectWriteResult(receipt: receipt, recordedReceipt: false, status: "Already captured. The existing inbox item was retained.", failure: nil, audit: audit)
        }
        do {
            try await recordReceipt(receipt)
        } catch {
            let text = "The register confirmed the capture, but its local receipt could not be saved. The original source identity prevents duplicate delivery."
            let audit = line("capture", register: register, target: target, source: recordKey, result: "partial:local-receipt", receipt: receipt.id)
            sink.write(audit)
            return ProjectWriteResult(receipt: receipt, recordedReceipt: false, status: text, failure: text, audit: audit)
        }
        let audit = line("capture", register: register, target: target, source: recordKey, result: "ok", receipt: receipt.id)
        sink.write(audit)
        return ProjectWriteResult(receipt: receipt, recordedReceipt: true, status: "Captured. Open Projects to assign and review the item.", failure: nil, audit: audit)
    }

    /// `error:<http>` when the bridge reported an HTTP status, otherwise `error:unconfirmed`.
    static func errorCode(_ message: String) -> String {
        if let range = message.range(of: #"HTTP (\d{3})"#, options: .regularExpression) {
            return "error:" + message[range].dropFirst(5)
        }
        return "error:unconfirmed"
    }

    /// Link and unlink are local; they still leave one line each (S2-R3). `change` performs the local write.
    @discardableResult
    func link(_ action: String, recordKey: String, register: String, projectID: String, change: () throws -> Void) -> CWAuditLine {
        precondition(action == "link" || action == "unlink")
        let result: String
        do { try change(); result = "ok" } catch { result = "refused:invalid" }
        let audit = line(action, register: CWAuditLine.register(for: URL(string: register)), target: projectID, source: recordKey, result: result)
        sink.write(audit)
        return audit
    }
}

/// Checks Project Control audit lines (S2 planted red 5): each write has exactly one line.
enum ProjectAuditCheck {
    static func problems(writes: [(action: String, target: String)], lines: [CWAuditLine]) -> [String] {
        var problems: [String] = []
        for (action, target) in writes where lines.filter({ $0.action == action && $0.target == target && $0.surface == "project-control" }).count != 1 {
            problems.append("\(action) \(target): expected exactly one audit line")
        }
        if lines.count != writes.count { problems.append("\(lines.count) audit lines for \(writes.count) writes") }
        return problems
    }
}
