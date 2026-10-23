import Foundation

/// Slice 2: Project Control writes with audit (wind-acceptance-tests.md §2). Fake bridge, synthetic records only.
enum ProjectControlTests {
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { try PortableCheck.expect(condition(), message) }

    static func writer(_ fake: FakeProjectBridge, sink: MemoryAuditSink) -> ProjectControlWriter {
        ProjectControlWriter(bridge: fake.bridge, sink: sink, now: MailControlKit.fixedClock)
    }

    static func run() async -> Bool {
        await PortableCheck.suite("Project Control writes", [
            ("PC write: capture writes one receipt and one audit line", {
                let fake = FakeProjectBridge()
                let sink = MemoryAuditSink()
                let ledger = ReceiptLedger()
                let first = await writer(fake, sink: sink).capture(recordKey: "contacts:rec7f3a", item: ProjectFixture.item(), expectedRegister: ProjectFixture.loopback) { ledger.record($0) }
                try expect(first.failure == nil && first.recordedReceipt, "capture failed: \(first.status)")
                try expect(ledger.receipts.count == 1 && fake.posts == 1, "receipts \(ledger.receipts.count), posts \(fake.posts)")
                try expect(sink.lines.count == 1, "\(sink.lines.count) audit lines")
                let line = sink.lines[0]
                try expect(line.surface == "project-control" && line.action == "capture" && line.result == "ok" && line.receipt == "item-rec7f3a", "line: \(line.text)")
                try expect(line.register == ProjectFixture.loopback, "register \(line.register)")
                try expect(!line.text.contains("Synthetic summary"), "the summary leaked into the audit line")

                fake.duplicate = true
                let again = await writer(fake, sink: sink).capture(recordKey: "contacts:rec7f3a", item: ProjectFixture.item(), expectedRegister: ProjectFixture.loopback) { ledger.record($0) }
                try expect(again.failure == nil && !again.recordedReceipt, "a duplicate wrote a receipt or failed")
                try expect(ledger.receipts.count == 1, "a 409 wrote a second receipt")
                try expect(sink.lines.count == 2 && sink.lines[1].result == "duplicate", "duplicate line: \(sink.lines.last?.text ?? "none")")
            }),
            ("PC write: every refusal is audited with 0 POSTs and no receipt", {
                let cases: [(String, FakeProjectBridge, ProjectCapture, String?)] = [
                    ("refused:register-changed", FakeProjectBridge(), ProjectFixture.item(), "http://127.0.0.1:9999/other"),
                    ("refused:unsupported-source", FakeProjectBridge(), ProjectFixture.item("arbitrary-source"), ProjectFixture.loopback),
                    ("refused:synthetic-non-loopback", FakeProjectBridge(register: ProjectFixture.remote), ProjectFixture.item("email-aggregator-synthetic"), ProjectFixture.remote),
                    ("refused:register-disconnected", FakeProjectBridge(connected: false), ProjectFixture.item(), ProjectFixture.loopback),
                ]
                for (code, fake, item, expected) in cases {
                    let sink = MemoryAuditSink()
                    let ledger = ReceiptLedger()
                    let result = await writer(fake, sink: sink).capture(recordKey: "contacts:rec7f3a", item: item, expectedRegister: expected) { ledger.record($0) }
                    try expect(result.audit.result == code, "expected \(code), got \(result.audit.result)")
                    try expect(fake.posts == 0, "\(code): \(fake.posts) POSTs")
                    try expect(ledger.receipts.isEmpty, "\(code): a receipt was written")
                    try expect(sink.lines.count == 1 && result.failure != nil, "\(code): \(sink.lines.count) lines")
                }
                let synthetic = FakeProjectBridge()
                let allowed = await writer(synthetic, sink: MemoryAuditSink()).capture(recordKey: "mail:x", item: ProjectFixture.item("email-aggregator-synthetic"), expectedRegister: ProjectFixture.loopback) { _ in }
                try expect(allowed.audit.result == "ok", "synthetic capture to loopback was refused: \(allowed.audit.result)")
            }),
            ("PC write: a bridge HTTP error is audited as error:<status> with no receipt", {
                let fake = FakeProjectBridge()
                fake.failure = "Capture failed (HTTP 503)."
                let sink = MemoryAuditSink()
                let ledger = ReceiptLedger()
                let result = await writer(fake, sink: sink).capture(recordKey: "contacts:rec7f3a", item: ProjectFixture.item(), expectedRegister: ProjectFixture.loopback) { ledger.record($0) }
                try expect(result.audit.result == "error:503" && ledger.receipts.isEmpty, "got \(result.audit.result)")
            }),
            ("PC write: link and unlink each write one audit line", {
                let sink = MemoryAuditSink()
                let writer = writer(FakeProjectBridge(), sink: sink)
                var links: [String] = []
                writer.link("link", recordKey: "contacts:rec7f3a", register: ProjectFixture.loopback, projectID: "p1") { links.append("p1") }
                writer.link("unlink", recordKey: "contacts:rec7f3a", register: ProjectFixture.loopback, projectID: "p1") { links.removeAll() }
                try expect(sink.lines.map(\.action) == ["link", "unlink"], "actions: \(sink.lines.map(\.action))")
                try expect(sink.lines.allSatisfy { $0.result == "ok" && $0.target == "p1" && $0.surface == "project-control" }, "lines: \(sink.lines.map(\.text))")
                let problems = ProjectAuditCheck.problems(writes: [("link", "p1"), ("unlink", "p1")], lines: sink.lines)
                try expect(problems.isEmpty, problems.joined(separator: "; "))
            }),
        ])
    }
}
