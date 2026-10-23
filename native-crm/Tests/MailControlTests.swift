import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Slices 1 and 4 hardening (wind-acceptance-tests.md §1d, §4). Synthetic fixtures only.
enum MailControlTests {
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { try PortableCheck.expect(condition(), message) }
    private struct LocalRowError: Error {}

    static func run() async -> Bool {
        await PortableCheck.suite("Mail control", [
            ("Mail UI: dialog Cancel produces no command and no request", {
                for kind in MailDialogKind.allCases {
                    let action: MailboxAction = kind == .send ? .reply : .trash
                    for input in [MailDialogInput.cancelButton, .escapeKey, .returnKey] {
                        let http = CountingMailHTTP()
                        let sink = MemoryAuditSink()
                        let runner = MailControlKit.runner(MailControlKit.gmail(http), sink: sink)
                        let command = MailDialogDecisions.command(input, in: kind, action: action, sourceID: MailFixture.sourceID, compose: kind == .send ? MailFixture.compose() : nil)
                        try expect(command == nil, "\(kind) dialog \(input) produced a command")
                        if let command { _ = await runner.perform(command) {} }
                        try expect(http.count == 0, "\(kind) dialog \(input) made \(http.count) requests")
                        try expect(sink.lines.isEmpty, "\(kind) dialog \(input) wrote an audit line")
                    }
                    try expect(MailDialogDecisions.cancelIsDefault(kind), "\(kind) dialog default is not Cancel")
                    let confirmed = MailDialogDecisions.command(.confirmButton, in: kind, action: action, sourceID: MailFixture.sourceID, compose: kind == .send ? MailFixture.compose() : nil)
                    try expect(confirmed?.confirmed == true, "\(kind) dialog confirm button did not confirm")
                }
            }),
            ("Mail audit: 9 actions, 9 lines", {
                let http = CountingMailHTTP()
                let sink = MemoryAuditSink()
                let runner = MailControlKit.runner(MailControlKit.gmail(http), sink: sink)
                var ran: [(action: String, target: String)] = []
                let read = await runner.read(sourceID: MailFixture.sourceID)
                try expect(read.body?.plain == MailFixture.bodyText, "read did not return the body")
                ran.append(("read", MailFixture.sourceID))
                for action in MailboxAction.allCases {
                    let result = await runner.perform(MailFixture.command(action)) {}
                    try expect(result.failure == nil, "\(action) failed: \(result.failure ?? "")")
                    ran.append((action.rawValue, MailFixture.sourceID))
                }
                let problems = MailAuditCheck.problems(actions: ran, lines: sink.lines, forbidden: MailControlKit.forbidden)
                try expect(problems.isEmpty, problems.joined(separator: "; "))
                try expect(sink.lines.allSatisfy { $0.surface == "gmail" && $0.result == "ok" }, "a line is not surface=gmail result=ok")
                let reply = sink.lines.first { $0.action == "reply" }
                try expect(reply?.receipt == "sent7f3a", "reply receipt is \(reply?.receipt ?? "nil"), expected the sent id")
                try expect(sink.lines.first { $0.action == "trash" }?.receipt == "trash", "trash receipt is not trash")
                print("Mail audit: \(ran.count) actions, \(sink.lines.count) lines")
            }),
            ("Mail send: test mode refuses non-allowlisted recipients", {
                let policy = MailSendPolicy.testMode([MailFixture.allowed])
                for action in [MailboxAction.reply, .replyAll, .forward] {
                    for compose in [MailFixture.compose(to: [MailFixture.outsider]),
                                    MailFixture.compose(to: [MailFixture.allowed, "Someone <\(MailFixture.outsider)>"]),
                                    MailCompose(draftID: nil, to: [MailFixture.allowed], cc: [MailFixture.outsider], subject: "s", body: "b"),
                                    MailFixture.compose(to: ["not an address"])] {
                        let http = CountingMailHTTP()
                        let sink = MemoryAuditSink()
                        let result = await MailControlKit.runner(MailControlKit.gmail(http), sink: sink, policy: policy).perform(MailFixture.command(action, compose: compose)) {}
                        try expect(result.audit.result == "refused:recipient-not-allowlisted", "\(action) to \(compose.to + compose.cc) gave \(result.audit.result)")
                        try expect(http.count == 0, "\(action) refusal made \(http.count) requests")
                        try expect(sink.lines.count == 1, "\(action) refusal wrote \(sink.lines.count) lines")
                    }
                }
                let http = CountingMailHTTP()
                let ok = await MailControlKit.runner(MailControlKit.gmail(http), sink: MemoryAuditSink(), policy: policy).perform(MailFixture.command(.reply, compose: MailFixture.compose(to: ["Allowed <ALLOWED@example.test>"]))) {}
                try expect(ok.audit.result == "ok", "an allowlisted reply was refused: \(ok.audit.result)")
                let draft = await MailControlKit.runner(MailControlKit.gmail(CountingMailHTTP()), sink: MemoryAuditSink(), policy: policy).perform(MailFixture.command(.editDraft, compose: MailFixture.compose(to: [MailFixture.outsider]))) {}
                try expect(draft.audit.result == "ok", "a draft (no send) was refused by the send allowlist")
                try expect(MailSendPolicy.fromEnvironment([:]) == .off, "test mode is on without the environment key")
                try expect(MailSendPolicy.fromEnvironment([MailSendPolicy.environmentKey: "a@example.test, b@example.test"]).allowlist == ["a@example.test", "b@example.test"], "environment allowlist did not parse")
                try expect(MailSendPolicy.fromEnvironment([MailSendPolicy.environmentKey: ""]).allowlist == [], "an empty allowlist must refuse everything, not turn test mode off")
            }),
            ("Mail trash: a local-row failure audits partial:local-row", {
                let sink = MemoryAuditSink()
                let result = await MailControlKit.runner(MailControlKit.gmail(CountingMailHTTP()), sink: sink).perform(MailFixture.command(.trash)) { throw LocalRowError() }
                try expect(result.failure != nil, "a partial Trash was reported as success")
                try expect(sink.lines.map(\.result) == ["partial:local-row"], "audit was \(sink.lines.map(\.result))")
            }),
            ("Mail send: refusals and errors are audited with 0 retries", {
                let unconfirmedHTTP = CountingMailHTTP()
                let sink = MemoryAuditSink()
                let unconfirmed = await MailControlKit.runner(MailControlKit.gmail(unconfirmedHTTP), sink: sink).perform(MailFixture.command(.reply, confirmed: false)) {}
                try expect(unconfirmed.audit.result == "refused:unconfirmed" && unconfirmedHTTP.count == 0, "unconfirmed reply: \(unconfirmed.audit.result), \(unconfirmedHTTP.count) requests")
                let reconnectHTTP = CountingMailHTTP(status: 401)
                let reconnect = await MailControlKit.runner(MailControlKit.gmail(reconnectHTTP), sink: sink).perform(MailFixture.command(.archive)) {}
                try expect(reconnect.audit.result == "refused:needs-reconnect" && reconnectHTTP.count == 1, "401: \(reconnect.audit.result), \(reconnectHTTP.count) requests")
                let readOnly = await MailControlKit.runner(MailControlKit.gmail(CountingMailHTTP(), scopes: [GmailScopePolicy.readonly]), sink: sink).perform(MailFixture.command(.trash)) {}
                try expect(readOnly.audit.result == "refused:unsupported", "read-only trash gave \(readOnly.audit.result)")
            }),
            ("Mail transport: DELETE is refused before the network", {
                let http = CountingMailHTTP()
                let sink = MemoryAuditSink()
                let result = await MailControlKit.runner(DeletingConnector(http: NoDeleteMailHTTP(inner: http)), sink: sink).perform(MailFixture.command(.trash)) {}
                try expect(result.audit.result == "refused:permanent-delete", "DELETE gave \(result.audit.result)")
                try expect(http.count == 0, "DELETE reached the network")
            }),
            ("Mail body: rendered without the HTML importer and with no remote URL (S1-R7)", {
                let html = MailHTMLSanitizer.render(mime: "text/html", raw: #"<p>Hello <a href="https://tracker.example.test/c?u=1">there</a></p><img src="https://pixel.example.test/p.gif"><div>Line two</div>"#)
                let text = MailBodyText.plain(fromSanitizedHTML: html)
                try expect(text.contains("Hello there") && text.contains("Line two"), "visible text lost: \(text)")
                try expect(!text.contains("tracker.example.test") && !text.contains("pixel.example.test"), "a URL survived into the rendered text")
                let source = try String(contentsOf: MailControlTests.sourceURL("MailActionViews.swift"), encoding: .utf8)
                try expect(!source.contains("DocumentType.html") && !source.contains("NSAttributedString(data:"), "MailActionViews.swift still imports HTML through NSAttributedString")
                try expect(source.contains("MailBodyText.plain(fromSanitizedHTML:"), "MailHTMLView does not render through MailBodyText")
            }),
            ("Mail platforms: disabled reason is identical in catalog, UI model and gate", {
                let problems = MailPlatformConsistency.problems(MailConnectorCatalog.all)
                try expect(problems.isEmpty, problems.joined(separator: "; "))
                for granted in [Set<String>(), [GmailScopePolicy.readonly], [GmailScopePolicy.sendOnly]] {
                    let scoped = MailConnectorDocument(providerID: "gmail-scoped", summary: "", routedThrough: nil, actions: GmailScopePolicy.support(granted: granted))
                    let scopedProblems = MailPlatformConsistency.problems([scoped])
                    try expect(scopedProblems.isEmpty, scopedProblems.joined(separator: "; "))
                }
                for provider in MailConnectorCatalog.all.map(\.providerID) {
                    let disabled = DisabledMailbox(providerID: provider, accountID: "owner@example.test", reason: MailConnectorCatalog.disabledReason(providerID: provider))
                    let support = disabled.supports()
                    for item in support {
                        let help = MailActionDisplay.buttons(support).first { $0.action == item.action }?.help
                        var gateError = ""
                        do { _ = try await disabled.perform(MailFixture.command(item.action)) } catch { gateError = error.localizedDescription }
                        try expect(help == disabled.reason && gateError == disabled.reason, "\(provider) \(item.action): help and gate differ from the reason")
                        try expect(MailActionDisplay.captionLines(support).contains("\(item.action.title): \(disabled.reason)"), "\(provider) caption is missing \(item.action)")
                    }
                }
            }),
            ("Mail platforms: an unknown provider routes to metadata-import, disabled with a reason", {
                let route = MailConnectorRouting.route(sourceID: "outlook:abc", provider: "outlook-365", synthetic: false, accountID: "owner@example.test", signIns: [], aliases: [:], connected: [])
                guard case .disabled(let provider, let reason) = route else { throw PortableCheckFailure(description: "unknown provider was not disabled") }
                try expect(provider == "metadata-import", "routed to \(provider)")
                try expect(reason == MailConnectorCatalog.disabledReason(providerID: "metadata-import") && !reason.isEmpty, "reason differs from the catalog")
            }),
        ])
    }

    /// Source files are read relative to this test file, so the check runs the same on the Mac and on Linux.
    static func sourceURL(_ name: String, file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FollowUpOSNative").appendingPathComponent(name)
    }
}
