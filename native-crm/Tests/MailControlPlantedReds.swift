import Foundation

/// Planted reds for Slices 1, 2 and 4 (wind-acceptance-tests.md §1d, §2, §4). Each case feeds a bad input
/// or a broken component; a case "fails" (RED-OK) when the code catches it. Slice 1 and 2 cases must also
/// make 0 HTTP requests / 0 POSTs. Each slice prints `expected N failures, got N: OK`.
enum MailControlPlantedReds {
    typealias Probe = () async -> String?

    /// Drops every line for one action, standing in for a code path that forgot its audit line.
    final class DroppingSink: CWAuditSink, @unchecked Sendable {
        let inner = MemoryAuditSink()
        let drop: String
        init(drop: String) { self.drop = drop }
        func write(_ line: CWAuditLine) { if line.action != drop { inner.write(line) } }
    }

    /// A connector that never touches the network.
    struct OfflineConnector: MailboxConnecting {
        var providerID = "gmail"
        var accountID = "owner@example.test"
        func supports() -> [MailActionSupport] { GmailScopePolicy.support(granted: MailFixture.allScopes) }
        func fetchBody(sourceID: String) async throws -> MailMessageBody { MailMessageBody(sourceID: sourceID, plain: "x", html: "") }
        func perform(_ command: MailCommand) async throws -> MailCommandReceipt {
            MailCommandReceipt(action: command.action, sourceID: command.sourceID, draftID: nil, location: "inbox")
        }
    }

    static func slice1() -> [(String, Probe)] {
        func refused(_ command: MailCommand, policy: MailSendPolicy = .off, expected: String) -> Probe {
            {
                let http = CountingMailHTTP()
                let result = await MailControlKit.runner(MailControlKit.gmail(http), sink: MemoryAuditSink(), policy: policy).perform(command) {}
                return result.audit.result == expected && http.count == 0 ? "\(result.audit.result), 0 requests" : nil
            }
        }
        return [
            ("unconfirmed reply", refused(MailFixture.command(.reply, confirmed: false), expected: "refused:unconfirmed")),
            ("unconfirmed trash", refused(MailFixture.command(.trash, confirmed: false), expected: "refused:unconfirmed")),
            ("\\n in Subject", refused(MailFixture.command(.reply, compose: MailFixture.compose(subject: "Hi\nBcc: x@example.test")), expected: "refused:invalid-compose")),
            ("empty To", refused(MailFixture.command(.forward, compose: MailFixture.compose(to: [])), expected: "refused:invalid-compose")),
            ("recipient outside the allowlist", refused(MailFixture.command(.reply, compose: MailFixture.compose(to: [MailFixture.outsider])),
                                                        policy: .testMode([MailFixture.allowed]), expected: "refused:recipient-not-allowlisted")),
            ("fake connector issuing DELETE", {
                let http = CountingMailHTTP()
                let result = await MailControlKit.runner(DeletingConnector(http: NoDeleteMailHTTP(inner: http)), sink: MemoryAuditSink()).perform(MailFixture.command(.trash)) {}
                return result.audit.result == "refused:permanent-delete" && http.count == 0 ? "refused:permanent-delete, 0 requests" : nil
            }),
            ("action missing its audit line", {
                let sink = DroppingSink(drop: "markRead")
                let runner = MailActionRunner(connector: OfflineConnector(), sink: sink, now: MailControlKit.fixedClock)
                _ = await runner.perform(MailFixture.command(.archive)) {}
                _ = await runner.perform(MailFixture.command(.markRead)) {}
                let problems = MailAuditCheck.problems(actions: [("archive", MailFixture.sourceID), ("markRead", MailFixture.sourceID)], lines: sink.inner.lines, forbidden: MailControlKit.forbidden)
                return problems.isEmpty ? nil : "audit check: \(problems[0])"
            }),
        ]
    }

    static func slice2() -> [(String, Probe)] {
        func refused(_ fake: FakeProjectBridge, _ item: ProjectCapture, expectedRegister: String?, code: String) -> Probe {
            {
                let ledger = ReceiptLedger()
                let result = await ProjectControlTests.writer(fake, sink: MemoryAuditSink()).capture(recordKey: "contacts:rec7f3a", item: item, expectedRegister: expectedRegister) { ledger.record($0) }
                return result.audit.result == code && fake.posts == 0 && ledger.receipts.isEmpty ? "\(code), 0 POSTs, no receipt" : nil
            }
        }
        return [
            ("register changed", refused(FakeProjectBridge(), ProjectFixture.item(), expectedRegister: "http://127.0.0.1:9999/other", code: "refused:register-changed")),
            ("unsupported source", refused(FakeProjectBridge(), ProjectFixture.item("arbitrary-source"), expectedRegister: ProjectFixture.loopback, code: "refused:unsupported-source")),
            ("synthetic capture to a non-loopback register", refused(FakeProjectBridge(register: ProjectFixture.remote), ProjectFixture.item("email-aggregator-synthetic"),
                                                                     expectedRegister: ProjectFixture.remote, code: "refused:synthetic-non-loopback")),
            ("409 trying to write a second receipt", {
                let fake = FakeProjectBridge()
                fake.duplicate = true
                let ledger = ReceiptLedger()
                ledger.record(ProjectModuleReceipt(id: "item-rec7f3a", duplicate: false, register: ProjectFixture.loopback))
                let result = await ProjectControlTests.writer(fake, sink: MemoryAuditSink()).capture(recordKey: "contacts:rec7f3a", item: ProjectFixture.item(), expectedRegister: ProjectFixture.loopback) { ledger.record($0) }
                return result.audit.result == "duplicate" && ledger.receipts.count == 1 ? "duplicate, still 1 receipt" : nil
            }),
            ("write missing its audit line", {
                let sink = DroppingSink(drop: "capture")
                _ = await ProjectControlWriter(bridge: FakeProjectBridge().bridge, sink: sink, now: MailControlKit.fixedClock)
                    .capture(recordKey: "contacts:rec7f3a", item: ProjectFixture.item(), expectedRegister: ProjectFixture.loopback) { _ in }
                let problems = ProjectAuditCheck.problems(writes: [("capture", "controlward-record:rec7f3a")], lines: sink.inner.lines)
                return problems.isEmpty ? nil : "audit check: \(problems[0])"
            }),
        ]
    }

    static func slice4() -> [(String, Probe)] {
        func mutated(_ provider: String, _ change: (inout MailActionSupport) -> Void) -> [MailConnectorDocument] {
            MailConnectorCatalog.all.map { document in
                guard document.providerID == provider else { return document }
                var copy = document
                change(&copy.actions[0])
                return copy
            }
        }
        func caught(_ problems: [String]) -> String? { problems.isEmpty ? nil : problems[0] }
        return [
            ("catalog entry with an empty reason", { caught(MailPlatformConsistency.problems(mutated("metadata-import") { $0.reason = "  " })) }),
            ("enabled action on hosted-aggregator", { caught(MailPlatformConsistency.problems(mutated("hosted-aggregator") { $0.enabled = true; $0.reason = "" })) }),
            ("UI-model reason differs from the gate reason", {
                let broken: MailPlatformConsistency.Display = { support in
                    (support.map { MailActionButtonModel(action: $0.action, title: $0.action.title, enabled: $0.enabled, help: $0.enabled ? $0.action.help : "Unavailable.") },
                     MailActionDisplay.captionLines(support))
                }
                return caught(MailPlatformConsistency.problems(MailConnectorCatalog.all, display: broken))
            }),
        ]
    }

    static func run() async -> Bool {
        var ok = true
        for (name, expected, cases) in [("Slice 1", 7, slice1()), ("Slice 2", 5, slice2()), ("Slice 4", 3, slice4())] {
            var failures = 0
            for (label, probe) in cases {
                if let outcome = await probe() {
                    failures += 1
                    print("  RED-OK [\(name)] \(label): \(outcome)")
                } else {
                    print("  RED-MISSED [\(name)] \(label): the planted bad input was accepted")
                }
            }
            let good = failures == expected && cases.count == expected
            if !good { ok = false }
            print("\(name) planted reds: expected \(expected) failures, got \(failures): \(good ? "OK" : "MISMATCH")")
        }
        return ok
    }
}
