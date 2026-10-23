import Foundation

/// One CW-AUDIT v1 line. Shared by mail actions, Project Control writes and the lead pipeline.
///
/// Format (one line, space separated, no PII, subjects, bodies or tokens):
/// `CW-AUDIT v1 ts=<ISO8601 UTC> surface=<gmail|project-control|leads> action=<verb>
///  register=<origin+path|-> target=<id> source=<record key|-> result=<ok|duplicate|refused:<code>|partial:<code>|error:<http>> receipt=<id|->`
struct CWAuditLine: Equatable, Sendable {
    var ts: Date
    var surface: String
    var action: String
    var register: String = "-"
    var target: String = "-"
    var source: String = "-"
    var result: String
    var receipt: String = "-"

    static let fieldOrder = ["ts", "surface", "action", "register", "target", "source", "result", "receipt"]

    var text: String {
        let values = [Self.timestamp(ts), surface, action, register, target, source, result, receipt].map(Self.clean)
        return "CW-AUDIT v1 " + zip(Self.fieldOrder, values).map { "\($0)=\($1)" }.joined(separator: " ")
    }

    /// Values never contain spaces or line breaks, so a line always parses back to the same fields.
    static func clean(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "-" }
        return String(trimmed.unicodeScalars.map { CharacterSet.whitespacesAndNewlines.contains($0) || $0 == "=" ? "_" : Character($0) })
    }

    /// The register is an origin plus path only. Query strings and fragments can carry personal data, so they are dropped.
    static func register(for url: URL?) -> String {
        guard let url, let scheme = url.scheme, let host = url.host else { return "-" }
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        return "\(scheme)://\(host)\(port)\(path)"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Parses a line back into its fields. Returns nil for anything that is not a CW-AUDIT v1 line.
    static func parse(_ line: String) -> [String: String]? {
        guard let start = line.range(of: "CW-AUDIT v1 ") else { return nil }
        var fields: [String: String] = [:]
        for part in line[start.upperBound...].split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            fields[pair[0]] = pair[1]
        }
        return fieldOrder.allSatisfy { fields[$0] != nil } ? fields : nil
    }
}

protocol CWAuditSink: Sendable {
    func write(_ line: CWAuditLine)
}

/// Keeps lines in memory. Used by tests and by the in-app run report.
final class MemoryAuditSink: CWAuditSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CWAuditLine] = []
    var lines: [CWAuditLine] { lock.withLock { stored } }
    func write(_ line: CWAuditLine) { lock.withLock { stored.append(line) } }
}

/// Appends lines to a log file (the app's own CW-AUDIT log). Never truncates.
final class FileAuditSink: CWAuditSink, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var failed: [String] = []
    /// Every write that did not reach the file (red stub: always empty).
    var failures: [String] { lock.withLock { failed } }
    init(url: URL) { self.url = url }
    func write(_ line: CWAuditLine) {
        lock.withLock {
            let data = Data((line.text + "\n").utf8)
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: url.path) { _ = manager.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}

/// Fans one line out to several sinks (for example the log file and the in-app report).
struct CompositeAuditSink: CWAuditSink {
    var sinks: [any CWAuditSink]
    func write(_ line: CWAuditLine) { sinks.forEach { $0.write(line) } }
}
