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

/// Check 2 (14:03): the one URL form the lead pipeline uses to match its fetch, score and draft lines. Scheme and host are
/// lowercased, a default port (80/443) and the fragment are dropped, and one trailing slash is dropped (the root stays `/`).
/// The path keeps its case, so `/a`, `/A`, `/a/b` and `/b` stay different. A query string is never written to the log; it is
/// kept as a short hash (`?q=<16 hex>`), so two URLs that differ only by query never match. Canonicalising twice changes nothing.
enum URLCanonical {
    static func register(for url: URL?) -> String {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty else { return "-" }
        var port = ""
        if let value = parts.port, !((scheme == "https" && value == 443) || (scheme == "http" && value == 80)) { port = ":\(value)" }
        var path = parts.percentEncodedPath
        if path.isEmpty { path = "/" }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        var query = ""
        if let raw = parts.percentEncodedQuery, !raw.isEmpty { query = "?q=" + (isHashedQuery(raw) ? String(raw.dropFirst(2)) : hash(raw)) }
        return "\(scheme)://\(host)\(port)\(path)\(query)"
    }

    /// For a value read back from a log or a record. Anything that is not an absolute URL stays as it is (e.g. `-`).
    static func register(_ value: String?) -> String {
        guard let value, let url = URL(string: value), url.host != nil else { return value ?? "-" }
        return register(for: url)
    }

    private static func isHashedQuery(_ raw: String) -> Bool {
        raw.count == 18 && raw.hasPrefix("q=") && raw.dropFirst(2).allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// FNV-1a 64-bit: stable across runs and platforms, Foundation-only.
    private static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x100000001b3 }
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
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
    /// Every write that did not reach the file (Argus red 12). Each failure is also printed to stderr, never dropped.
    var failures: [String] { lock.withLock { failed } }
    init(url: URL) { self.url = url }
    func write(_ line: CWAuditLine) {
        lock.withLock {
            let data = Data((line.text + "\n").utf8)
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !manager.fileExists(atPath: url.path), !manager.createFile(atPath: url.path, contents: nil) {
                    throw CocoaError(.fileWriteUnknown)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                let failure = "audit write failed (\(url.lastPathComponent)): \(line.surface)/\(line.action) result=\(line.result): \(error.localizedDescription)"
                failed.append(failure)
                FileHandle.standardError.write(Data(("CW-AUDIT " + failure + "\n").utf8))
            }
        }
    }
}

/// Fans one line out to several sinks (for example the log file and the in-app report).
struct CompositeAuditSink: CWAuditSink {
    var sinks: [any CWAuditSink]
    func write(_ line: CWAuditLine) { sinks.forEach { $0.write(line) } }
}
