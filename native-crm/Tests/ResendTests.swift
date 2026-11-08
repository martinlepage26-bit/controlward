import Foundation

@MainActor enum ResendTests {
    nonisolated static let providerID = "00000000-0000-4000-8000-000000000123"
    static let subject = "Synthetic introduction"
    static let body = "Hello,\nThis is a synthetic message for an offline acceptance test."

    actor FakeHTTP: HTTPTransport {
        enum Reply: Sendable { case accepted, refused, timeout, malformed }
        var requests: [URLRequest] = []
        var replies: [Reply]
        let beforeReply: (@MainActor @Sendable () throws -> Void)?
        init(_ replies: [Reply] = [.accepted], beforeReply: (@MainActor @Sendable () throws -> Void)? = nil) {
            self.replies = replies; self.beforeReply = beforeReply
        }
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            requests.append(request)
            try await beforeReply?()
            switch replies.isEmpty ? .accepted : replies.removeFirst() {
            case .accepted: return HTTPResponse(status: 200, headers: [:], body: Data("{\"id\":\"\(ResendTests.providerID)\"}".utf8))
            case .refused: return HTTPResponse(status: 403, headers: [:], body: Data("private-server-body re_do_not_log".utf8))
            case .timeout: throw URLError(.timedOut)
            case .malformed: return HTTPResponse(status: 200, headers: [:], body: Data("{}".utf8))
            }
        }
        func captured() -> [URLRequest] { requests }
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeTestFailure.failed(message) }
    }

    @MainActor final class StoreBox { var store: AppStore? }

    static func fixture(_ http: FakeHTTP, secrets: (any SecretStore)? = nil, review: Bool = false, privacyOpen: Bool = true) throws -> (AppStore, Lead, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("controlward-resend-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = try LeadKit.config(); config.loi25Gate.open = privacyOpen
        let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"),
            secrets: secrets ?? InMemorySecretStore([.resend: "re_synthetic_test_only"]), reviewMode: review, resendTransport: http, resendConfig: config)
        var lead = Lead(); lead.name = "Synthetic Owner"; lead.email = "owner@example.test"
        lead.outreachDraft = body; lead.nextFollowUp = "2030-01-10"
        let task = CRMTask(title: "Follow up", dueDate: lead.nextFollowUp, leadID: lead.id)
        lead.followUpTaskID = task.id
        try store.commitWorkspace { $0.leads = [lead]; $0.tasks = [task] }
        return (store, lead, root)
    }

    static func preview(_ store: AppStore, _ lead: Lead) throws -> ResendSendPreview {
        guard let result = store.prepareResendSend(leadID: lead.id, subject: subject, body: body) else {
            throw SmokeTestFailure.failed(store.resendFailure ?? "preview unavailable")
        }
        return result
    }

    static func run() async -> Bool {
        let cases: [(String, () async throws -> Void)] = [
            ("packaged configuration uses Contents/Resources and fails closed when missing", {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("controlward-resend-bundle-\(UUID())")
                defer { try? FileManager.default.removeItem(at: root) }
                func fixtureBundle(_ name: String, withConfig: Bool) throws -> Bundle {
                    let app = root.appendingPathComponent(name + ".app")
                    let resources = app.appendingPathComponent("Contents/Resources/FollowUpOSNative_FollowUpOSNative.bundle")
                    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
                    let plist: [String: Any] = ["CFBundleIdentifier": "test.controlward.resend." + name, "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture"]
                    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
                    // Bundle caches resource lookups: complete each fixture before constructing it.
                    if withConfig { try FileManager.default.copyItem(at: LeadKit.configDirectory, to: resources.appendingPathComponent("config")) }
                    guard let main = Bundle(url: app) else { throw SmokeTestFailure.failed("fixture app bundle missing") }
                    return main
                }
                try expect(ResendPolicy.bundledConfig(in: fixtureBundle("Present", withConfig: true))?.sender.from == ResendPolicy.sender, "signed app resource path was not used")
                try expect(ResendPolicy.bundledConfig(in: fixtureBundle("Missing", withConfig: false)) == nil, "missing config did not fail closed")
            }),
            ("the configured privacy gate refuses external recipients and permits owner-only review", {
                let http = FakeHTTP(); let (store, lead, root) = try fixture(http, privacyOpen: false); defer { try? FileManager.default.removeItem(at: root) }
                try expect(store.prepareResendSend(leadID: lead.id, subject: subject, body: body) == nil, "closed privacy gate bypassed")
                var ownLead = lead; ownLead.email = ResendPolicy.sender; _ = store.update(ownLead)
                try expect(store.prepareResendSend(leadID: ownLead.id, subject: subject, body: body) != nil, "owner-only review refused")
                try expect(await http.captured().isEmpty, "review sent a message")
            }),
            ("researched messages still require supported AI/contact evidence and an intact footer", {
                let (researcher, _, candidate) = try QuickScanResearchTests.fixture()
                let research = await researcher.research(candidate, segmentID: "clinic")
                let http = FakeHTTP(); let (store, lead, root) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
                store.resendNow = { LeadKit.now }
                var sourced = lead; sourced.email = research.email!; sourced.quickScanResearch = research
                _ = store.update(sourced)
                let config = store.resendConfig!
                guard let message = research.draft(config: config, suppression: store.suppressionList, now: LeadKit.now) else { throw SmokeTestFailure.failed("research fixture refused") }
                try expect(store.prepareResendSend(leadID: lead.id, subject: message.subject, body: message.body) != nil, "valid researched draft refused")
                let withoutFooter = message.body.replacingOccurrences(of: OutreachDraftBuilder.footer(config: config, language: "fr"), with: "")
                try expect(store.prepareResendSend(leadID: lead.id, subject: message.subject, body: withoutFooter) == nil, "missing footer allowed")
                sourced.quickScanResearch?.aiUse = []; _ = store.update(sourced)
                try expect(store.prepareResendSend(leadID: lead.id, subject: message.subject, body: message.body) == nil, "missing AI evidence allowed")
                try expect(await http.captured().isEmpty, "refused research reached provider")
            }),
            ("preview, cancel and fabricated approval perform zero HTTP", {
                let http = FakeHTTP(); let (store, lead, root) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
                var approved = try preview(store, lead)
                try expect(await http.captured().isEmpty, "preview contacted provider")
                approved.body += " changed"
                try expect(!(await store.sendResend(approved)), "fabricated preview accepted")
                let original = try preview(store, lead); store.cancelResendPreview()
                try expect(!(await store.sendResend(original)), "cancelled preview sent")
                try expect(await http.captured().isEmpty && store.workspace.resendDispatches.isEmpty, "unapproved intent or HTTP")
            }),
            ("acceptance pins sender, payload, idempotency and provider-backed CRM history", {
                let http = FakeHTTP(); let (store, lead, root) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
                let approved = try preview(store, lead)
                try expect(await store.sendResend(approved), store.resendFailure ?? "send failed")
                let calls = await http.captured(); try expect(calls.count == 1, "unexpected request count")
                let call = calls[0], data = try JSONSerialization.jsonObject(with: call.httpBody!) as! [String: Any]
                try expect(call.url?.absoluteString == "https://api.resend.com/emails" && call.httpMethod == "POST", "destination")
                try expect(data["from"] as? String == ResendPolicy.sender && data["reply_to"] as? String == ResendPolicy.sender, "sender changed")
                try expect(data["to"] as? [String] == [lead.email] && data["text"] as? String == body && data["subject"] as? String == subject, "payload changed")
                try expect(call.value(forHTTPHeaderField: "Idempotency-Key") == "controlward/\(approved.id.uuidString.lowercased())", "missing stable request key")
                let saved = store.leads[0]
                try expect(saved.status == .contacted && saved.history.count == 1 && saved.history[0].providerMessageID == providerID, "history/status not backed by receipt")
                try expect(saved.history[0].sender == ResendPolicy.sender && saved.outreachDraft == nil, "sender or draft bookkeeping")
                try expect(saved.nextFollowUp == "2030-01-10" && store.tasks[0].dueDate == saved.nextFollowUp, "existing next action was overwritten")
                try expect(store.workspace.resendDispatches[0].state == .accepted && store.workspace.connectorHealth["resend"] == nil, "acceptance falsely claimed connector health")
                let reloaded = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
                try expect(reloaded.leads[0] == saved && reloaded.workspace.resendDispatches == store.workspace.resendDispatches, "receipt/history lost on restart")
                try expect(reloaded.prepareResendSend(leadID: lead.id, subject: subject, body: body) == nil, "duplicate allowed after restart")
                let duplicateSent = await store.sendResend(approved); let duplicateCalls = await http.captured()
                try expect(!duplicateSent && duplicateCalls.count == 1, "double confirmation sent again")
            }),
            ("missing key and isolated review both refuse without an HTTP request", {
                for review in [false, true] {
                    let http = FakeHTTP(); let (store, lead, root) = try fixture(http, secrets: InMemorySecretStore(), review: review)
                    defer { try? FileManager.default.removeItem(at: root) }
                    let approved = try preview(store, lead)
                    try expect(!(await store.sendResend(approved)), "unconfigured/review send succeeded")
                    try expect(await http.captured().isEmpty && store.leads[0].history.isEmpty && store.workspace.resendDispatches.isEmpty, "unconfigured send produced side effects")
                }
            }),
            ("provider rejection does not mark a draft sent or expose server text", {
                let http = FakeHTTP([.refused]); let (store, lead, root) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
                try expect(!(await store.sendResend(try preview(store, lead))), "refused request logged as success")
                try expect(store.leads[0] == lead && store.workspace.resendDispatches[0].state == .rejected, "refusal changed lead")
                try expect(!(store.resendFailure ?? "").contains("re_do_not_log"), "server body leaked")
            }),
            ("timeout requires fresh review and retries the exact payload with the same key", {
                let http = FakeHTTP([.timeout, .accepted]); let (store, lead, root) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
                let first = try preview(store, lead)
                try expect(!(await store.sendResend(first)) && store.leads[0].history.isEmpty, "timeout invented acceptance")
                try expect(store.workspace.resendDispatches[0].state == .unknown, "unknown outcome not retained")
                try expect(store.prepareResendSend(leadID: lead.id, subject: subject, body: body + " edit") == nil, "edited retry bypassed unknown outcome")
                let retry = try preview(store, lead)
                let retried = await store.sendResend(retry)
                try expect(retry.id == first.id && retried, "exact retry failed")
                let calls = await http.captured()
                try expect(calls.count == 2 && calls[0].httpBody == calls[1].httpBody && calls[0].value(forHTTPHeaderField: "Idempotency-Key") == calls[1].value(forHTTPHeaderField: "Idempotency-Key"), "retry changed payload or key")
                try expect(store.leads[0].history.count == 1, "retry double logged")
            }),
            ("malformed success remains unknown, and expired retries are blocked after restart", {
                let http = FakeHTTP([.malformed]); let (store, lead, root) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
                try expect(!(await store.sendResend(try preview(store, lead))), "missing receipt accepted")
                try store.commitWorkspace { $0.resendDispatches[0].createdAt = ISODates.string(Date.now.addingTimeInterval(-24 * 3600)) }
                let reloaded = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore([.resend: "re_synthetic"]), resendTransport: http, resendConfig: store.resendConfig)
                try expect(reloaded.prepareResendSend(leadID: lead.id, subject: subject, body: body) == nil, "expired retry allowed")
                try expect((await http.captured()).count == 1 && reloaded.leads[0].history.isEmpty, "expired retry produced output")
            }),
            ("lead edits and new unsubscribes invalidate a reviewed message", {
                for suppress in [false, true] {
                    let http = FakeHTTP(); let (store, lead, root) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
                    let approved = try preview(store, lead)
                    if suppress { _ = store.suppressionList.record(lead.email, at: .now, via: "synthetic-test") }
                    else { var changed = lead; changed.notes = "Changed after review"; _ = store.update(changed) }
                    try expect(!(await store.sendResend(approved)), "stale/held approval sent")
                    try expect(await http.captured().isEmpty, "stale approval performed HTTP")
                }
            }),
            ("a lead or key edit during credential access prevents later HTTP", {
                for replaceKey in [false, true] {
                    let delayed = CredentialAccessTests.DelayedStore(delayProbes: false, delayReads: true)
                    try delayed.write("re_synthetic_old", for: .resend)
                    defer { delayed.release() }
                    let http = FakeHTTP(); let (store, lead, root) = try fixture(http, secrets: delayed); defer { try? FileManager.default.removeItem(at: root) }
                    let approved = try preview(store, lead)
                    let send = Task { await store.sendResend(approved) }
                    for _ in 0..<100 where delayed.waitingReads == 0 { try await Task.sleep(for: .milliseconds(10)) }
                    try expect(delayed.waitingReads > 0, "credential wait not exercised")
                    if replaceKey { store.setAPIKey("re_synthetic_new", for: .resend) }
                    else { var changed = lead; changed.email = "changed@example.test"; _ = store.update(changed) }
                    delayed.release()
                    let sent = await send.value; let calls = await http.captured()
                    try expect(!sent && calls.isEmpty, "stale credential approval performed HTTP")
                }
            }),
            ("a second confirmation cannot overlap a request awaiting credential access", {
                let delayed = CredentialAccessTests.DelayedStore(delayProbes: false, delayReads: true)
                try delayed.write("re_synthetic_old", for: .resend); defer { delayed.release() }
                let http = FakeHTTP(); let (store, lead, root) = try fixture(http, secrets: delayed); defer { try? FileManager.default.removeItem(at: root) }
                let approved = try preview(store, lead); let first = Task { await store.sendResend(approved) }
                for _ in 0..<100 where delayed.waitingReads == 0 { try await Task.sleep(for: .milliseconds(10)) }
                try expect(!(await store.sendResend(approved)), "overlapping confirmation allowed")
                delayed.release(); try expect(await first.value, "original request failed")
                try expect((await http.captured()).count == 1 && store.leads[0].history.count == 1, "overlap duplicated send/history")
            }),
            ("restoring an older CRM backup retains a later accepted send receipt", {
                let http = FakeHTTP(); let (store, lead, root) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
                let olderBackup = try JSONEncoder().encode(ControlWardBackup(workspace: store.completeBackupWorkspace()))
                try expect(await store.sendResend(try preview(store, lead)), "send failed")
                try store.restoreControlWardBackup(olderBackup, confirmed: true)
                try expect(store.leads[0].history.isEmpty && store.workspace.resendDispatches[0].state == .accepted, "restore lost the later provider receipt")
                try expect(store.prepareResendSend(leadID: lead.id, subject: subject, body: body) == nil, "restore allowed a known duplicate")
                try expect((await http.captured()).count == 1, "restore sent another message")
            }),
            ("restoring an older backup retains an unknown request and its exact retry key", {
                let http = FakeHTTP([.timeout, .accepted]); let (store, lead, root) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
                let olderBackup = try JSONEncoder().encode(ControlWardBackup(workspace: store.completeBackupWorkspace()))
                let first = try preview(store, lead)
                try expect(!(await store.sendResend(first)), "timeout invented acceptance")
                try store.restoreControlWardBackup(olderBackup, confirmed: true)
                try expect(store.workspace.resendDispatches.count == 1 && store.workspace.resendDispatches[0].state == .unknown, "restore erased unknown request")
                let retry = try preview(store, lead)
                try expect(retry.id == first.id, "restore manufactured another request key")
                try expect(await store.sendResend(retry), "exact retry failed after restore")
                let calls = await http.captured()
                try expect(calls.count == 2 && calls[0].value(forHTTPHeaderField: "Idempotency-Key") == calls[1].value(forHTTPHeaderField: "Idempotency-Key"), "restored retry changed key")
            }),
            ("failure to save the durable intent prevents HTTP", {
                let http = FakeHTTP(); let (store, lead, root) = try fixture(http)
                let saved = root.appendingPathExtension("saved"); defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: saved) }
                let approved = try preview(store, lead)
                try FileManager.default.moveItem(at: root, to: saved); try Data("blocker".utf8).write(to: root)
                let sent = await store.sendResend(approved); let calls = await http.captured()
                try expect(!sent && calls.isEmpty, "HTTP happened without durable intent")
                try expect(store.leads[0].history.isEmpty && store.workspace.resendDispatches.isEmpty, "failed intent changed records")
            }),
            ("an accepted message with a failed CRM save recovers locally without another send", {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("controlward-resend-receipt-\(UUID())")
                let saved = root.appendingPathExtension("saved"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: saved) }
                let http = FakeHTTP(beforeReply: { try FileManager.default.moveItem(at: root, to: saved); try Data("blocker".utf8).write(to: root) })
                var config = try LeadKit.config(); config.loi25Gate.open = true
                let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore([.resend: "re_synthetic"]), resendTransport: http, resendConfig: config)
                var lead = Lead(); lead.name = "Synthetic"; lead.email = "owner@example.test"; lead.outreachDraft = body
                _ = store.add(lead)
                let backup = try JSONEncoder().encode(ControlWardBackup(workspace: store.completeBackupWorkspace()))
                try expect(!(await store.sendResend(try preview(store, lead))), "failed receipt save reported complete")
                try expect(store.pendingResendReceipt != nil && store.leads[0].history.isEmpty, "acceptance recovery lost")
                var restoreRefused = false
                do { try store.restoreControlWardBackup(backup, confirmed: true) }
                catch { restoreRefused = error.localizedDescription.contains("pending Resend receipt") }
                try expect(restoreRefused, "restore did not protect pending accepted receipt")
                try expect(store.prepareResendSend(leadID: lead.id, subject: subject, body: body + " edit") == nil && store.resendFailure?.contains("pending") == true, "a new send could replace the pending receipt")
                try FileManager.default.removeItem(at: root); try FileManager.default.moveItem(at: saved, to: root)
                try expect(store.retrySavingResendReceipt(), "local receipt recovery failed")
                try expect((await http.captured()).count == 1 && store.leads[0].history.count == 1, "recovery resent or double logged")
                let disk = try String(contentsOf: store.storageURL, encoding: .utf8)
                try expect(!disk.contains("re_synthetic"), "credential entered workspace data")
            }),
            ("a newer CRM edit made during HTTP is preserved when acceptance is recorded", {
                let capturedStore = StoreBox()
                let http = FakeHTTP(beforeReply: {
                    guard let store = capturedStore.store else { return }
                    var edited = store.leads[0]; edited.notes = "Newer owner notes"; edited.status = .won
                    _ = store.update(edited)
                })
                let (store, lead, root) = try fixture(http); capturedStore.store = store; defer { try? FileManager.default.removeItem(at: root) }
                try expect(await store.sendResend(try preview(store, lead)), "acceptance not retained")
                try expect(store.leads[0].notes == "Newer owner notes" && store.leads[0].status == .won && store.leads[0].history.count == 1, "approved snapshot overwrote current CRM")
                try expect(store.tasks[0].status == .done, "closed deal reminder reopened")
            }),
            ("header injection and multiple recipients are refused before HTTP", {
                let http = FakeHTTP(); let (store, lead, root) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
                try expect(store.prepareResendSend(leadID: lead.id, subject: "Hello\r\nBcc: other@example.test", body: body) == nil, "header injection accepted")
                var changed = lead; changed.email = "one@example.test,two@example.test"; _ = store.update(changed)
                let invalid = store.prepareResendSend(leadID: lead.id, subject: subject, body: body); let calls = await http.captured()
                try expect(invalid == nil && calls.isEmpty, "multiple recipients accepted")
            }),
        ]
        var failures = 0
        for (name, test) in cases {
            do { try await test(); print("PASS Resend: \(name)") }
            catch { failures += 1; print("FAIL Resend: \(name): \(error)") }
        }
        print("Resend tests: \(cases.count - failures)/\(cases.count) passed")
        fflush(nil) // Preserve case-level diagnostics if the outer native runner terminates on failure.
        return failures == 0
    }
}
