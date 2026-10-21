import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
enum MailboxTests {
    static func run() async -> Bool {
        let tests: [(String, () async throws -> Void)] = [
            ("Mail overview: every connector line is reachable at 1280x800", overview),
            ("Mail body: fetched length equals the source and remote images are blocked", bodies),
            ("Mail actions: fake mailbox applies each action, and send or trash without confirmation does nothing", actions),
            ("Mail connectors: unsupported actions are disabled with a reason", connectors),
            ("Mail Gmail: writes use the API and never permanently delete", gmail),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS  \(name)") }
            catch { failures += 1; print("FAIL  \(name): \(error)") }
        }
        print("Mailbox tests: \(tests.count - failures)/\(tests.count) passed")
        return failures == 0
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeTestFailure.failed(message) }
    }

    private static func overview() async throws {
        let gmail = FakeMailbox(providerID: "gmail", accountID: "owner@example.test", items: lines(platform: "gmail", count: 12, start: 0))
        let workspace = FakeMailbox(providerID: "google-workspace", accountID: "work@example.test", items: lines(platform: "google-workspace", count: 9, start: 100))
        let forwarded = FakeMailbox(providerID: "icloud-forward", accountID: "alias@example.test", items: lines(platform: "icloud-forward", count: 7, start: 200))
        let returned = gmail.listLines() + workspace.listLines() + forwarded.listLines()
        let sections = MailOverviewLayout.sections(from: returned)
        let fit = MailOverviewLayout.project(returned)
        try expect(MailOverviewLayout.referenceWidth == 1280 && MailOverviewLayout.referenceHeight == 800, "reference window")
        try expect(MailOverviewLayout.lineCap == nil, "overview still caps lines")
        try expect(fit.shownCount == returned.count, "shown \(fit.shownCount) != connectors \(returned.count)")
        try expect(sections.reduce(0) { $0 + $1.lines.count } == returned.count, "a platform dropped lines")
        try expect(sections.first { $0.platform == "Gmail" }?.lines.count == 12, "Gmail count")
        try expect(sections.first { $0.platform == "Google Workspace" }?.lines.count == 9, "Workspace count")
        try expect(sections.first { $0.platform == "iCloud" }?.lines.count == 7, "iCloud count")
        try expect(fit.contentHeight > fit.viewportHeight, "tall list was clipped to the viewport")
        try expect(fit.viewportHeight <= fit.paneHeight, "viewport is taller than the 1280x800 pane")
        try expect(fit.reachable && fit.lineReachable(returned.count - 1), "last line is not reachable")
        let lastIcloud = sections.first { $0.platform == "iCloud" }?.lines.last?.sourceID
        let index = MailOverviewLayout.lines(from: returned).firstIndex { $0.sourceID == lastIcloud }
        try expect(index != nil && fit.lineReachable(index!), "last iCloud line is clipped")
    }

    private static func bodies() async throws {
        let plain = "BODYMARKER-" + String(repeating: "q", count: 4_000)
        let paragraph = String(repeating: "a", count: 8_000)
        let html = "<p>\(paragraph)</p><img src=\"https://cdn.example.test/pixel.png\" alt=\"pic\"><img src=\"//cdn.example.test/b.png\">"
            + "<img srcset=\"https://cdn.example.test/c.png 2x\">"
            + "<div style=\"background:url(https://cdn.example.test/d.png)\">x</div>"
            + "<script>SCRIPT_SHOULD_NOT_SHOW</script>"
            + "<a href=\"javascript:alert(1)\">bad</a><a href=\"https://notes.example.test/read\">notes</a>"
        let plainBox = FakeMailbox(providerID: "gmail", accountID: "owner@example.test", items: [
            FakeMailbox.Item(sourceID: "plain-1", subject: "Plain", sender: "a@example.test", recipient: "owner@example.test", body: plain, mime: "text/plain"),
        ])
        let htmlBox = FakeMailbox(providerID: "gmail", accountID: "owner@example.test", items: [
            FakeMailbox.Item(sourceID: "html-1", subject: "HTML", sender: "a@example.test", recipient: "owner@example.test", body: html, mime: "text/html"),
        ])
        let plainBody = try await plainBox.fetchBody(sourceID: "plain-1")
        try expect(plainBody.raw.count == plain.count && plainBody.raw == plain, "plain body length != source")
        try expect(MailHTMLSanitizer.visibleText(plainBody.safeHTML).count == plain.count, "plain display truncated")
        let htmlBody = try await htmlBox.fetchBody(sourceID: "html-1")
        try expect(htmlBody.raw.count == html.count && htmlBody.raw == html, "html body length != source")
        let visible = MailHTMLSanitizer.visibleText(htmlBody.safeHTML)
        try expect(visible.contains(paragraph) && paragraph.count == 8_000, "html text truncated")
        try expect(!htmlBody.safeHTML.contains("cdn.example.test"), "remote image survived")
        try expect(!htmlBody.safeHTML.lowercased().contains("script_should_not_show"), "script survived")
        try expect(!htmlBody.safeHTML.lowercased().contains("javascript:"), "script URL survived")
        try expect(htmlBody.safeHTML.contains("https://notes.example.test/read"), "ordinary link was removed")
        try expect(htmlBody.safeHTML.contains("data-remote-image=\"blocked\""), "blocked image was not marked")
        try expect(htmlBody.quoteText.contains(paragraph) && !htmlBody.quoteText.localizedCaseInsensitiveContains("SCRIPT_SHOULD_NOT_SHOW"), "quote dropped text or kept a script")

        let encoded = "<img src=\"https&#58;&#47;&#47;cdn.example.test/e.png\">"
        try expect(!MailHTMLSanitizer.sanitizeHTML(encoded).contains("cdn.example.test"), "entity-encoded image survived")

        let http = ScriptedHTTP()
        let attached = String(repeating: "z", count: 3_000)
        http.handler = { request in
            let url = request.url!.absoluteString
            if url.contains("format=full") {
                let payload: [String: Any] = [
                    "mimeType": "text/plain",
                    "body": ["attachmentId": "att-1", "size": attached.utf8.count],
                ]
                return try ScriptedHTTP.json(["id": "m1", "payload": payload])
            }
            if url.contains("/attachments/att-1") {
                return try ScriptedHTTP.json(["data": Base64URL.encode(Data(attached.utf8)), "size": attached.utf8.count])
            }
            return MailHTTPResponse(status: 404, body: Data())
        }
        let client = GmailMailboxClient(token: "synthetic-access", from: "owner@example.test", http: http)
        let fetched = try await client.fetchBody(sourceID: "gmail:m1")
        try expect(fetched.raw.count == attached.count && fetched.raw == attached, "attachment body length != source")
        try expect(http.requests.contains { $0.url!.absoluteString.contains("format=full") }, "body was not fetched in full")
        let metadata = ["sourceID": "gmail:m1", "subject": "Hello", "sender": "a@example.test"]
        let stored = String(decoding: try JSONSerialization.data(withJSONObject: metadata), as: UTF8.self)
        try expect(!stored.contains(attached), "body was written into metadata")
    }

    private static func actions() async throws {
        let source = String(repeating: "m", count: 500)
        let box = sampleBox(body: source)
        let before = box.snapshot()
        let compose = MailCompose(draftID: nil, to: ["a@example.test"], cc: ["c@example.test"], subject: "Re: Hello", body: "Reply\n\n---\n\(source)")
        do {
            _ = try await box.perform(MailCommand(action: .reply, sourceID: "m1", compose: compose, confirmed: false))
            throw SmokeTestFailure.failed("send without confirmation succeeded")
        } catch MailboxError.confirmationRequired(.reply) {}
        try expect(box.snapshot() == before, "unconfirmed send changed the mailbox")
        for action in [MailboxAction.replyAll, .forward, .trash] {
            do {
                _ = try await box.perform(MailCommand(action: action, sourceID: "m1", compose: compose, confirmed: false))
                throw SmokeTestFailure.failed("\(action) without confirmation succeeded")
            } catch MailboxError.confirmationRequired {}
            try expect(box.snapshot() == before, "\(action) without confirmation changed the mailbox")
        }
        let cancelled = MailActionResolver.resolve(action: .reply, sourceID: "m1", compose: compose, decision: .cancel)
        guard case .cancelled = cancelled else { throw SmokeTestFailure.failed("cancel produced a command") }
        try expect(box.snapshot() == before, "cancel changed the mailbox")
        let trashedCancel = MailActionResolver.resolve(action: .trash, sourceID: "m1", compose: nil, decision: .cancel)
        guard case .cancelled = trashedCancel else { throw SmokeTestFailure.failed("trash cancel produced a command") }
        try expect(box.snapshot() == before, "trash cancel changed the mailbox")

        guard case .ready(let send) = MailActionResolver.resolve(action: .reply, sourceID: "m1", compose: compose, decision: .confirm) else {
            throw SmokeTestFailure.failed("confirm did not produce a command")
        }
        let sent = try await box.perform(send)
        try expect(sent.location == "sent" && box.snapshot().sent == [compose], "reply was not sent")
        try expect(box.snapshot().items[0].location == .inbox && box.snapshot().items[0].body == source, "reply altered the original")

        let replyAll = MailComposePrefill.draft(action: .replyAll, sender: "Ada <a@example.test>", recipient: "Owner <owner@example.test>, Casey <c@example.test>", subject: "Hello", body: source, account: "owner@example.test")
        try expect(replyAll.body.contains(source) && source.count == 500, "reply all dropped the body")
        try expect(replyAll.cc == ["c@example.test"], "reply all recipients \(replyAll.cc)")
        _ = try await box.perform(MailCommand(action: .replyAll, sourceID: "m1", compose: replyAll, confirmed: true))

        let forward = MailCompose(draftID: nil, to: ["b@example.test"], cc: [], subject: "Fwd: Hello", body: source)
        _ = try await box.perform(MailCommand(action: .forward, sourceID: "m1", compose: forward, confirmed: true))
        try expect(box.snapshot().sent.contains(forward), "forward was not kept")

        let edited = MailCompose(draftID: nil, to: ["a@example.test"], cc: [], subject: "Hello", body: source + "-draft")
        let draft = try await box.perform(MailCommand(action: .editDraft, sourceID: "m1", compose: edited, confirmed: false))
        try expect(draft.location == "draft" && box.snapshot().items[0].draft?.body == edited.body, "draft was not saved")
        try expect(box.snapshot().sent.count == 3, "saving a draft sent mail")

        let trashed = try await box.perform(MailCommand(action: .trash, sourceID: "m1", compose: nil, confirmed: true))
        try expect(trashed.location == "trash", "trash location")
        try expect(box.snapshot().items.count == 1 && box.snapshot().items[0].sourceID == "m1", "trash erased the message")
        try expect(box.snapshot().items[0].location == .trash && box.snapshot().items[0].body == source, "trashed body changed")

        let restored = sampleBox(body: source)
        _ = try await restored.perform(MailCommand(action: .archive, sourceID: "m1", compose: nil, confirmed: false))
        try expect(restored.snapshot().items[0].location == .archive, "archive")
        _ = try await restored.perform(MailCommand(action: .markRead, sourceID: "m1", compose: nil, confirmed: false))
        try expect(restored.snapshot().items[0].unread == false, "mark read")
        _ = try await restored.perform(MailCommand(action: .markUnread, sourceID: "m1", compose: nil, confirmed: false))
        try expect(restored.snapshot().items[0].unread == true, "mark unread")

        let emptyForward = MailCompose(draftID: nil, to: [], cc: [], subject: "Fwd: Hello", body: source)
        let beforeEmpty = restored.snapshot()
        do {
            _ = try await restored.perform(MailCommand(action: .forward, sourceID: "m1", compose: emptyForward, confirmed: true))
            throw SmokeTestFailure.failed("empty forward sent")
        } catch MailboxError.invalidCompose {}
        try expect(restored.snapshot() == beforeEmpty, "rejected send changed the mailbox")
    }

    private static func connectors() async throws {
        try expect(MailConnectorCatalog.permanentlyDeletesMail == false, "catalog allows permanent delete")
        try expect(!MailboxAction.allCases.map(\.rawValue).contains("delete") && !MailboxAction.allCases.map(\.rawValue).contains("erase"), "erase action exists")
        for document in MailConnectorCatalog.all {
            try expect(document.actions.map(\.action) == MailboxAction.allCases, "\(document.providerID) does not list every action")
            for action in document.actions {
                if action.enabled {
                    try expect(action.reason.isEmpty, "\(document.providerID) \(action.action) enabled with a reason")
                } else {
                    try expect(!action.reason.isEmpty, "\(document.providerID) \(action.action) disabled without a reason")
                }
            }
            try expect(!document.summary.localizedCaseInsensitiveContains("permanently delete"), "\(document.providerID) documents erase")
        }
        let gmail = MailConnectorCatalog.document(providerID: "gmail")!
        try expect(gmail.actions.allSatisfy(\.enabled), "gmail actions are not all implemented")
        try expect(gmail.summary.contains("not written") && gmail.summary.contains("Trash") && gmail.summary.contains("messages.delete") && gmail.summary.contains("Keychain"), "gmail summary")
        try expect(MailConnectorCatalog.document(providerID: "icloud-forward")?.routedThrough == "gmail", "icloud route")
        try expect(MailConnectorCatalog.document(providerID: "hosted-aggregator")?.actions.allSatisfy { !$0.enabled } == true, "hosted aggregator enables writes")

        let disabled = DisabledMailbox(providerID: "synthetic", accountID: "fixture", reason: MailConnectorCatalog.disabledReason(providerID: "synthetic"))
        for action in disabled.supports() {
            try expect(!action.enabled && !action.reason.isEmpty, "synthetic \(action.action) silent")
        }
        do {
            _ = try await disabled.fetchBody(sourceID: "m1")
            throw SmokeTestFailure.failed("synthetic body was invented")
        } catch MailboxError.bodyUnavailable {}
        do {
            _ = try await disabled.perform(MailCommand(action: .trash, sourceID: "m1", compose: nil, confirmed: true))
            throw SmokeTestFailure.failed("synthetic trash succeeded")
        } catch MailboxError.unsupported {}

        let connected: Set<String> = ["owner@example.test"]
        let live = MailConnectorRouting.route(sourceID: "gmail:m1", provider: "icloud-forward", synthetic: false, accountID: "alias@example.test", signIns: ["owner@example.test"], aliases: ["alias@example.test": "owner@example.test"], connected: connected)
        guard case .gmail(let owner, _) = live else { throw SmokeTestFailure.failed("alias was not routed to gmail") }
        try expect(owner == "owner@example.test", "alias owner")
        let offline = MailConnectorRouting.route(sourceID: "gmail:m1", provider: "gmail", synthetic: false, accountID: "owner@example.test", signIns: ["owner@example.test"], aliases: [:], connected: [])
        guard case .disabled(_, let offlineReason) = offline else { throw SmokeTestFailure.failed("disconnected gmail stayed enabled") }
        try expect(!offlineReason.isEmpty, "disconnected reason")
        let imported = MailConnectorRouting.route(sourceID: "fixture-1", provider: "synthetic", synthetic: true, accountID: "fixture", signIns: [], aliases: [:], connected: [])
        guard case .disabled(let provider, let reason) = imported else { throw SmokeTestFailure.failed("synthetic stayed live") }
        try expect(provider == "synthetic" && !reason.isEmpty, "synthetic reason")

        let readonly = GmailScopePolicy.support(granted: [GmailScopePolicy.readonly])
        try expect(readonly.allSatisfy { !$0.enabled && !$0.reason.isEmpty }, "readonly sign-in enables writes")
        try expect(GmailScopePolicy.canReadBodies([GmailScopePolicy.readonly]), "readonly cannot fetch a body")
        let full = GmailScopePolicy.support(granted: [GmailScopePolicy.modify, GmailScopePolicy.compose])
        try expect(full.allSatisfy(\.enabled), "modify+compose does not enable every action")
        let sendOnly = GmailScopePolicy.support(granted: [GmailScopePolicy.sendOnly])
        try expect(sendOnly.first { $0.action == .reply }?.enabled == true, "send scope cannot reply")
        try expect(sendOnly.first { $0.action == .editDraft }?.enabled == false, "send scope silently edits drafts")
        try expect(!(sendOnly.first { $0.action == .editDraft }?.reason ?? "").isEmpty, "draft disable reason")
    }

    private static func gmail() async throws {
        let http = ScriptedHTTP()
        let scopes: Set<String> = [GmailScopePolicy.modify, GmailScopePolicy.compose]
        let client = GmailMailboxClient(token: "synthetic-access", from: "owner@example.test", http: http)
        let body = String(repeating: "b", count: 250)
        let compose = MailCompose(draftID: nil, to: ["a@example.test"], cc: ["c@example.test"], subject: "Re: Hello", body: "Note\n\(body)")
        http.handler = { _ in MailHTTPResponse(status: 500, body: Data("should-not-run".utf8)) }
        do {
            _ = try await client.perform(MailCommand(action: .reply, sourceID: "gmail:m1", compose: compose, confirmed: false), scopes: scopes)
            throw SmokeTestFailure.failed("gmail send without confirmation succeeded")
        } catch MailboxError.confirmationRequired {}
        try expect(http.requests.isEmpty, "unconfirmed send called the mailbox")
        do {
            _ = try await client.perform(MailCommand(action: .trash, sourceID: "gmail:m1", compose: nil, confirmed: false), scopes: scopes)
            throw SmokeTestFailure.failed("gmail trash without confirmation succeeded")
        } catch MailboxError.confirmationRequired {}
        try expect(http.requests.isEmpty, "unconfirmed trash called the mailbox")

        let injected = MailCompose(draftID: nil, to: ["a@example.test"], cc: [], subject: "Hello\nBcc: evil@example.test", body: "x")
        do {
            _ = try await client.perform(MailCommand(action: .forward, sourceID: "gmail:m1", compose: injected, confirmed: true), scopes: scopes)
            throw SmokeTestFailure.failed("header injection sent")
        } catch MailboxError.invalidCompose {}
        try expect(http.requests.isEmpty, "rejected header called the mailbox")

        http.handler = { request in
            let url = request.url!.absoluteString
            if url.contains("format=metadata") {
                return try ScriptedHTTP.json(["id": "m1", "threadId": "t1", "payload": ["headers": [["name": "Message-ID", "value": "<m1@example.test>"]]]])
            }
            return try ScriptedHTTP.json(["id": "sent-1"])
        }
        _ = try await client.perform(MailCommand(action: .reply, sourceID: "gmail:m1", compose: compose, confirmed: true), scopes: scopes)
        let send = http.requests.last!
        try expect(send.httpMethod == "POST" && send.url!.absoluteString.hasSuffix("/messages/send"), "reply did not POST send")
        try expect(http.requests.allSatisfy { $0.httpMethod != "DELETE" }, "a delete request was issued")
        let object = try JSONSerialization.jsonObject(with: send.httpBody!) as! [String: Any]
        let raw = String(data: try Base64URL.decode(object["raw"] as! String), encoding: .utf8)!
        try expect(raw.contains(body) && body.count == 250, "sent body was truncated")
        try expect(raw.contains("In-Reply-To: <m1@example.test>") && (object["threadId"] as? String) == "t1", "reply was not threaded")
        try expect(send.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access", "auth header")

        http.requests.removeAll()
        _ = try await client.perform(MailCommand(action: .trash, sourceID: "gmail:m1", compose: nil, confirmed: true), scopes: scopes)
        let trash = http.requests.last!
        try expect(trash.httpMethod == "POST" && trash.url!.absoluteString.hasSuffix("/messages/m1/trash"), "trash was not messages.trash")
        try expect(http.requests.allSatisfy { $0.httpMethod != "DELETE" }, "trash issued DELETE")

        http.requests.removeAll()
        _ = try await client.perform(MailCommand(action: .archive, sourceID: "gmail:m1", compose: nil, confirmed: false), scopes: scopes)
        let archive = try JSONSerialization.jsonObject(with: http.requests.last!.httpBody!) as! [String: Any]
        try expect((archive["removeLabelIds"] as? [String]) == ["INBOX"], "archive labels")

        http.requests.removeAll()
        _ = try await client.perform(MailCommand(action: .markRead, sourceID: "gmail:m1", compose: nil, confirmed: false), scopes: scopes)
        let read = try JSONSerialization.jsonObject(with: http.requests.last!.httpBody!) as! [String: Any]
        try expect((read["removeLabelIds"] as? [String]) == ["UNREAD"], "mark read")
        http.requests.removeAll()
        _ = try await client.perform(MailCommand(action: .markUnread, sourceID: "gmail:m1", compose: nil, confirmed: false), scopes: scopes)
        let unread = try JSONSerialization.jsonObject(with: http.requests.last!.httpBody!) as! [String: Any]
        try expect((unread["addLabelIds"] as? [String]) == ["UNREAD"], "mark unread")

        http.requests.removeAll()
        http.handler = { _ in try ScriptedHTTP.json(["id": "d1"]) }
        let draft = MailCompose(draftID: "d1", to: ["a@example.test"], cc: [], subject: "Hello", body: body)
        let saved = try await client.perform(MailCommand(action: .editDraft, sourceID: "gmail:m1", compose: draft, confirmed: false), scopes: scopes)
        try expect(saved.draftID == "d1" && saved.location == "draft", "draft receipt")
        try expect(http.requests.last?.httpMethod == "PUT", "draft was not updated")
        try expect(!http.requests.contains { $0.url!.absoluteString.contains("/send") }, "draft edit sent")

        http.requests.removeAll()
        let readonly = GmailMailboxClient(token: "synthetic-access", from: "owner@example.test", http: http)
        do {
            _ = try await readonly.perform(MailCommand(action: .reply, sourceID: "gmail:m1", compose: compose, confirmed: true), scopes: [GmailScopePolicy.readonly])
            throw SmokeTestFailure.failed("readonly send succeeded")
        } catch MailboxError.unsupported {}
        try expect(http.requests.isEmpty, "readonly send called the mailbox")

        http.requests.removeAll()
        http.handler = { _ in try ScriptedHTTP.json(["scope": GmailScopePolicy.readonly]) }
        let granted = await client.grantedScopes()
        let tokenInfo = http.requests.last
        try expect(tokenInfo?.httpMethod == "POST" && tokenInfo?.url?.host == "oauth2.googleapis.com", "tokeninfo")
        try expect(tokenInfo?.url?.query == nil, "token was put in the URL")
        try expect(granted == [GmailScopePolicy.readonly], "scopes")
    }

    private static func lines(platform: String, count: Int, start: Int) -> [FakeMailbox.Item] {
        (0..<count).map { index in
            FakeMailbox.Item(sourceID: "\(platform)-\(index)", subject: "Subject \(index)", sender: "person\(index)@example.test",
                             recipient: "owner@example.test", body: "body", mime: "text/plain",
                             receivedAt: String(format: "2026-10-%02dT00:00:00Z", (start + index) % 28 + 1))
        }
    }

    private static func sampleBox(body: String) -> FakeMailbox {
        FakeMailbox(providerID: "gmail", accountID: "owner@example.test", items: [
            FakeMailbox.Item(sourceID: "m1", subject: "Hello", sender: "Ada <a@example.test>", recipient: "owner@example.test", body: body, mime: "text/plain"),
        ])
    }
}

final class FakeMailbox: MailboxConnecting, @unchecked Sendable {
    struct Item: Equatable {
        enum Location: String, Equatable { case inbox, archive, trash }
        var sourceID: String
        var subject: String
        var sender: String
        var recipient: String
        var body: String
        var mime: String
        var receivedAt: String = "2026-10-18T00:00:00Z"
        var unread = true
        var location: Location = .inbox
        var draft: MailCompose?
    }

    struct Snapshot: Equatable {
        var items: [Item]
        var sent: [MailCompose]
    }

    let providerID: String
    let accountID: String
    private let lock = NSLock()
    private var items: [Item]
    private var sent: [MailCompose] = []
    private let enabled: Bool
    private let disabledReason: String

    init(providerID: String, accountID: String, items: [Item], enabled: Bool = true, disabledReason: String = "") {
        self.providerID = providerID
        self.accountID = accountID
        self.items = items
        self.enabled = enabled
        self.disabledReason = disabledReason
    }

    func supports() -> [MailActionSupport] {
        if enabled { return GmailScopePolicy.support(granted: [GmailScopePolicy.modify, GmailScopePolicy.compose]) }
        return MailboxAction.allCases.map { MailActionSupport(action: $0, enabled: false, reason: disabledReason) }
    }

    func listLines() -> [MailOverviewInput] {
        lock.withLock {
            items.map {
                MailOverviewInput(sourceID: $0.sourceID, provider: providerID, accountID: accountID,
                                  sender: $0.sender, subject: $0.subject, receivedAt: $0.receivedAt)
            }
        }
    }

    func snapshot() -> Snapshot { lock.withLock { Snapshot(items: items, sent: sent) } }

    func fetchBody(sourceID: String) async throws -> MailMessageBody {
        if !enabled { throw MailboxError.bodyUnavailable(disabledReason) }
        return try lock.withLock {
            guard let item = items.first(where: { $0.sourceID == sourceID }) else { throw MailboxError.unreadable("message") }
            if item.mime == "text/html" { return MailMessageBody(sourceID: sourceID, plain: "", html: item.body) }
            return MailMessageBody(sourceID: sourceID, plain: item.body, html: "")
        }
    }

    func perform(_ command: MailCommand) async throws -> MailCommandReceipt {
        try MailCommandGate.validate(command, support: supports())
        return try lock.withLock {
            guard let index = items.firstIndex(where: { $0.sourceID == command.sourceID }) else { throw MailboxError.unreadable("message") }
            switch command.action {
            case .reply, .replyAll, .forward:
                sent.append(command.compose!)
                return MailCommandReceipt(action: command.action, sourceID: command.sourceID, draftID: nil, location: "sent")
            case .editDraft:
                var draft = command.compose!
                if draft.draftID == nil { draft.draftID = "draft-\(command.sourceID)" }
                items[index].draft = draft
                return MailCommandReceipt(action: .editDraft, sourceID: command.sourceID, draftID: draft.draftID, location: "draft")
            case .trash:
                items[index].location = .trash
                return MailCommandReceipt(action: .trash, sourceID: command.sourceID, draftID: nil, location: "trash")
            case .archive:
                items[index].location = .archive
                return MailCommandReceipt(action: .archive, sourceID: command.sourceID, draftID: nil, location: "archive")
            case .markRead:
                items[index].unread = false
                return MailCommandReceipt(action: .markRead, sourceID: command.sourceID, draftID: nil, location: items[index].location.rawValue)
            case .markUnread:
                items[index].unread = true
                return MailCommandReceipt(action: .markUnread, sourceID: command.sourceID, draftID: nil, location: items[index].location.rawValue)
            }
        }
    }
}

final class ScriptedHTTP: MailHTTPSending, @unchecked Sendable {
    let lock = NSLock()
    var requests: [URLRequest] = []
    var handler: @Sendable (URLRequest) throws -> MailHTTPResponse = { _ in MailHTTPResponse(status: 404, body: Data()) }

    func send(_ request: URLRequest) async throws -> MailHTTPResponse {
        let handler = lock.withLock { () -> (@Sendable (URLRequest) throws -> MailHTTPResponse) in
            requests.append(request)
            return self.handler
        }
        return try handler(request)
    }

    static func json(_ object: Any) throws -> MailHTTPResponse {
        MailHTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: object))
    }
}
