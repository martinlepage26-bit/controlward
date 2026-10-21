import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Actions

/// Mailbox changes the Email tab can ask a connector to perform.
/// Delete is Trash. Nothing in this list permanently erases a message.
enum MailboxAction: String, CaseIterable, Sendable {
    case reply, replyAll, forward, editDraft, trash, archive, markRead, markUnread

    var title: String {
        switch self {
        case .reply: "Reply"
        case .replyAll: "Reply all"
        case .forward: "Forward"
        case .editDraft: "Edit draft"
        case .trash: "Delete"
        case .archive: "Archive"
        case .markRead: "Mark read"
        case .markUnread: "Mark unread"
        }
    }

    var help: String {
        switch self {
        case .reply: "Reply to the sender. Nothing is sent until you confirm."
        case .replyAll: "Reply to the sender and the other recipients. Nothing is sent until you confirm."
        case .forward: "Forward the message. Nothing is sent until you confirm."
        case .editDraft: "Save a draft. This does not send."
        case .trash: "Move the message to Trash. It is not erased."
        case .archive: "Archive the message by taking it out of the inbox."
        case .markRead: "Mark the message read."
        case .markUnread: "Mark the message unread."
        }
    }

    /// Sending and Trash change the mailbox only after an explicit confirmation.
    var sends: Bool { self == .reply || self == .replyAll || self == .forward }
    var requiresConfirmation: Bool { sends || self == .trash }
}

struct MailActionSupport: Equatable, Identifiable, Sendable {
    var action: MailboxAction
    var enabled: Bool
    /// Empty when the action is enabled. A disabled action always carries a reason.
    var reason: String
    var id: String { action.rawValue }
}

struct MailCompose: Equatable, Sendable {
    var draftID: String?
    var to: [String]
    var cc: [String]
    var subject: String
    var body: String
}

struct MailCommand: Equatable, Sendable {
    var action: MailboxAction
    var sourceID: String
    var compose: MailCompose?
    var confirmed: Bool
}

struct MailCommandReceipt: Equatable, Sendable {
    var action: MailboxAction
    var sourceID: String
    var draftID: String?
    /// inbox, archive, trash, draft, or sent. Trash still has the message.
    var location: String?
}

enum MailboxError: LocalizedError, Equatable {
    case confirmationRequired(MailboxAction)
    case unsupported(MailboxAction, String)
    case bodyUnavailable(String)
    case invalidCompose(String)
    case needsReconnect
    case http(Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .confirmationRequired(let action):
            "Confirm \(action.title.lowercased()) before it changes the mailbox. Nothing was changed."
        case .unsupported(_, let reason): reason
        case .bodyUnavailable(let reason): reason
        case .invalidCompose(let reason): reason
        case .needsReconnect: "The mailbox sign-in cannot do this. Choose Connect again. Nothing was changed."
        case .http(let status): "The mailbox returned HTTP \(status). Nothing was changed."
        case .unreadable(let what): "\(what) could not be read."
        }
    }
}

enum MailCommandGate {
    static func validate(_ command: MailCommand, support: [MailActionSupport]) throws {
        guard let item = support.first(where: { $0.action == command.action }) else {
            throw MailboxError.unsupported(command.action, "\(command.action.title) is not declared by this connector.")
        }
        guard item.enabled else {
            let reason = item.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MailboxError.unsupported(command.action, reason.isEmpty ? "\(command.action.title) is not available for this mailbox." : reason)
        }
        if command.action.requiresConfirmation && !command.confirmed {
            throw MailboxError.confirmationRequired(command.action)
        }
        if command.action.sends {
            guard let compose = command.compose else { throw MailboxError.invalidCompose("Nothing to send.") }
            guard !compose.to.isEmpty else { throw MailboxError.invalidCompose("Add a recipient before sending.") }
            try rejectHeaderBreaks(compose)
        }
        if command.action == .editDraft {
            guard let compose = command.compose else { throw MailboxError.invalidCompose("Nothing to save.") }
            try rejectHeaderBreaks(compose)
        }
    }

    private static func rejectHeaderBreaks(_ compose: MailCompose) throws {
        let fields = compose.to + compose.cc + [compose.subject]
        guard fields.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) else {
            throw MailboxError.invalidCompose("An address or the subject contains a line break.")
        }
    }
}

enum MailUserDecision: Equatable, Sendable { case confirm, cancel }

enum MailActionResolution: Equatable, Sendable {
    case cancelled
    case ready(MailCommand)
}

/// What the Email tab does with the confirmation dialog. Cancel never produces a command.
enum MailActionResolver {
    static func resolve(action: MailboxAction, sourceID: String, compose: MailCompose?, decision: MailUserDecision) -> MailActionResolution {
        if action.requiresConfirmation && decision == .cancel { return .cancelled }
        let confirmed = action.requiresConfirmation && decision == .confirm
        return .ready(MailCommand(action: action, sourceID: sourceID, compose: compose, confirmed: confirmed))
    }
}

enum MailComposePrefill {
    static func draft(action: MailboxAction, sender: String, recipient: String, subject: String, body: String, account: String) -> MailCompose {
        let quoted = body.isEmpty ? "" : "\n\n---\n\(body)"
        switch action {
        case .reply:
            return MailCompose(draftID: nil, to: [sender], cc: [], subject: prefixed("Re:", subject), body: quoted)
        case .replyAll:
            let cc = addresses(in: recipient).filter {
                $0.caseInsensitiveCompare(account) != .orderedSame && $0.caseInsensitiveCompare(sender) != .orderedSame
            }
            return MailCompose(draftID: nil, to: [sender], cc: cc, subject: prefixed("Re:", subject), body: quoted)
        case .forward:
            return MailCompose(draftID: nil, to: [], cc: [], subject: prefixed("Fwd:", subject), body: quoted)
        case .editDraft:
            return MailCompose(draftID: nil, to: [sender], cc: [], subject: subject, body: body)
        case .trash, .archive, .markRead, .markUnread:
            return MailCompose(draftID: nil, to: [], cc: [], subject: subject, body: body)
        }
    }

    static func addresses(in header: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}") else { return [] }
        let range = NSRange(header.startIndex..., in: header)
        return pattern.matches(in: header, range: range).compactMap { match in
            Range(match.range, in: header).map { header[$0].lowercased() }
        }
    }

    private static func prefixed(_ prefix: String, _ subject: String) -> String {
        subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)"
    }
}

// MARK: - Overview

struct MailOverviewInput: Equatable, Sendable {
    var sourceID: String
    var provider: String
    var accountID: String
    var sender: String
    var subject: String
    var receivedAt: String
}

struct MailPlatformLine: Equatable, Identifiable, Sendable {
    var sourceID: String
    var platform: String
    var accountID: String
    var sender: String
    var subject: String
    var receivedAt: String
    var id: String { sourceID }
}

struct MailPlatformSection: Equatable, Identifiable, Sendable {
    var platform: String
    var lines: [MailPlatformLine]
    var id: String { platform }
}

/// The overview email list. Every line the connectors returned is in the scroll
/// content. The overview ScrollView is the scroll port for an 1280×800 window,
/// so a list taller than the pane scrolls instead of being clipped.
enum MailOverviewLayout {
    static let referenceWidth: CGFloat = 1280
    static let referenceHeight: CGFloat = 800
    static let sidebarWidth: CGFloat = 212
    static let topBarHeight: CGFloat = 48
    static let lineHeight: CGFloat = 36
    /// There is no row cap. A nil cap is the contract the overview renders.
    static let lineCap: Int? = nil

    static var paneHeight: CGFloat { referenceHeight - topBarHeight }

    struct Fit: Equatable, Sendable {
        var shownCount: Int
        var returnedCount: Int
        var contentHeight: CGFloat
        var viewportHeight: CGFloat
        var paneHeight: CGFloat

        var reachable: Bool {
            MailOverviewLayout.lineCap == nil
                && shownCount == returnedCount
                && viewportHeight > 0
                && viewportHeight <= paneHeight
                && paneHeight < MailOverviewLayout.referenceHeight
                && contentHeight == CGFloat(shownCount) * MailOverviewLayout.lineHeight
        }

        func lineReachable(_ index: Int) -> Bool {
            reachable && index >= 0 && index < shownCount
        }
    }

    static func platformName(_ provider: String) -> String {
        switch provider {
        case "gmail": "Gmail"
        case "google-workspace": "Google Workspace"
        case "icloud-forward": "iCloud"
        case "cloudflare-forward": "Cloudflare"
        case "synthetic": "Synthetic"
        case "hosted-aggregator": "Email Aggregator"
        default: provider.isEmpty ? "Mailbox" : provider
        }
    }

    static func sections(from messages: [MailOverviewInput]) -> [MailPlatformSection] {
        let sorted = messages.sorted { lhs, rhs in
            if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt > rhs.receivedAt }
            return lhs.sourceID < rhs.sourceID
        }
        var order: [String] = []
        var grouped: [String: [MailPlatformLine]] = [:]
        for message in sorted {
            let platform = platformName(message.provider)
            if grouped[platform] == nil {
                order.append(platform)
                grouped[platform] = []
            }
            grouped[platform]?.append(MailPlatformLine(
                sourceID: message.sourceID, platform: platform, accountID: message.accountID,
                sender: message.sender, subject: message.subject, receivedAt: message.receivedAt))
        }
        return order.map { MailPlatformSection(platform: $0, lines: grouped[$0] ?? []) }
    }

    static func lines(from messages: [MailOverviewInput]) -> [MailPlatformLine] {
        sections(from: messages).flatMap(\.lines)
    }

    static func project(_ messages: [MailOverviewInput]) -> Fit {
        let shown = lines(from: messages).count
        // The overview page is the scroll port. Content stays the full line
        // count, including when that is taller than a 1280×800 pane.
        return Fit(shownCount: shown, returnedCount: messages.count,
                   contentHeight: CGFloat(shown) * lineHeight,
                   viewportHeight: paneHeight, paneHeight: paneHeight)
    }
}

// MARK: - Bodies

struct MailMessageBody: Equatable, Sendable {
    var sourceID: String
    var plain: String
    var html: String

    /// The full source body. HTML when the message has it, otherwise plain text.
    var raw: String { html.isEmpty ? plain : html }
    var mime: String { html.isEmpty ? "text/plain" : "text/html" }
    var safeHTML: String { MailHTMLSanitizer.render(mime: mime, raw: raw) }
    /// Text placed in a reply or forward. Prefers the plain part so markup is not quoted.
    /// HTML quotes use the sanitized body, so scripts are not copied into the draft.
    var quoteText: String {
        if !plain.isEmpty { return plain }
        let text = MailHTMLSanitizer.visibleText(safeHTML)
        return text.isEmpty ? raw : text
    }
}

/// Renders a message body without truncating it. Remote images are removed.
/// Scripts and other active content are removed. The original `raw` string is
/// what callers compare to the connector source; this type does not store it.
enum MailHTMLSanitizer {
    static func render(mime: String, raw: String) -> String {
        if mime.lowercased() == "text/plain" {
            return "<article><pre>" + escape(raw) + "</pre></article>"
        }
        return sanitizeHTML(raw)
    }

    static func visibleText(_ html: String) -> String {
        var text = ""
        var inTag = false
        var quote: Character?
        for character in html {
            if inTag {
                if let current = quote {
                    if character == current { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    inTag = false
                }
            } else if character == "<" {
                inTag = true
            } else {
                text.append(character)
            }
        }
        return decodeEntities(text)
    }

    static func sanitizeHTML(_ html: String) -> String {
        var cleaned = stripComments(html)
        for tag in ["script", "style", "iframe", "object", "embed", "svg", "math", "noscript", "applet", "form", "head"] {
            cleaned = stripElement(cleaned, tag: tag, removeContent: true)
        }
        for tag in ["link", "meta", "base"] {
            cleaned = stripElement(cleaned, tag: tag, removeContent: false)
        }
        return rewriteTags(cleaned)
    }

    static func isRemoteReference(_ raw: String) -> Bool {
        let value = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("javascript:") || value.hasPrefix("vbscript:") || value.hasPrefix("data:text/html") { return true }
        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("//") { return true }
        if value.contains("http://") || value.contains("https://") { return true }
        return false
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttr(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&#58;", with: ":")
        result = result.replacingOccurrences(of: "&#47;", with: "/")
        return result
    }

    private static func stripComments(_ html: String) -> String {
        var output = ""
        var cursor = html.startIndex
        while cursor < html.endIndex {
            if html[cursor...].hasPrefix("<!--") {
                let search = html.index(cursor, offsetBy: 4)
                if let end = html.range(of: "-->", range: search..<html.endIndex) {
                    cursor = end.upperBound
                    continue
                }
                break
            }
            output.append(html[cursor])
            cursor = html.index(after: cursor)
        }
        return output
    }

    private static func stripElement(_ html: String, tag: String, removeContent: Bool) -> String {
        var output = ""
        var cursor = html.startIndex
        while cursor < html.endIndex {
            if opens(html, at: cursor, tag: tag) {
                guard let tagEnd = endOfTag(html, from: cursor) else { break }
                let beforeEnd = html.index(before: tagEnd)
                let selfClosing = beforeEnd >= cursor && html[beforeEnd] == "/"
                if !removeContent || selfClosing {
                    cursor = html.index(after: tagEnd)
                    continue
                }
                let afterStart = html.index(after: tagEnd)
                if let close = findClose(html, tag: tag, from: afterStart), let closeEnd = endOfTag(html, from: close) {
                    cursor = html.index(after: closeEnd)
                    continue
                }
                break
            }
            output.append(html[cursor])
            cursor = html.index(after: cursor)
        }
        return output
    }

    private static func opens(_ html: String, at index: String.Index, tag: String) -> Bool {
        let prefix = "<" + tag
        guard let end = html.index(index, offsetBy: prefix.count, limitedBy: html.endIndex),
              html.distance(from: index, to: end) == prefix.count,
              html[index..<end].lowercased() == prefix else { return false }
        if end < html.endIndex {
            let next = html[end]
            if next.isLetter || next.isNumber { return false }
        }
        return true
    }

    private static func findClose(_ html: String, tag: String, from start: String.Index) -> String.Index? {
        var cursor = start
        let needle = "</" + tag
        while cursor < html.endIndex {
            if let end = html.index(cursor, offsetBy: needle.count, limitedBy: html.endIndex),
               html.distance(from: cursor, to: end) == needle.count,
               html[cursor..<end].lowercased() == needle {
                let boundaryOK = end == html.endIndex || !html[end].isLetter
                if boundaryOK { return cursor }
            }
            cursor = html.index(after: cursor)
        }
        return nil
    }

    private static func endOfTag(_ html: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var cursor = start
        while cursor < html.endIndex {
            let character = html[cursor]
            if let current = quote {
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return cursor
            }
            cursor = html.index(after: cursor)
        }
        return nil
    }

    private static func rewriteTags(_ html: String) -> String {
        var output = ""
        var cursor = html.startIndex
        while cursor < html.endIndex {
            if html[cursor] == "<", let end = endOfTag(html, from: cursor) {
                output += sanitizeTag(String(html[cursor...end]))
                cursor = html.index(after: end)
            } else {
                output.append(html[cursor])
                cursor = html.index(after: cursor)
            }
        }
        return output
    }

    private static let blockedTags: Set<String> = ["script", "style", "iframe", "object", "embed", "svg", "math", "noscript", "applet", "form", "link", "meta", "base"]
    private static let mediaTags: Set<String> = ["img", "image", "source", "video", "audio", "track"]

    private static func sanitizeTag(_ tag: String) -> String {
        guard tag.first == "<", tag.last == ">" else { return escape(tag) }
        let inner = tag.dropFirst().dropLast()
        if inner.hasPrefix("!--") || inner.hasPrefix("!") { return "" }
        let closing = inner.first == "/"
        let nameSource = String(closing ? inner.dropFirst() : inner)
        let name = tagName(nameSource)
        if name.isEmpty || blockedTags.contains(name) { return "" }
        if closing { return "</\(name)>" }
        var kept: [(String, String)] = []
        var blockedImage = false
        for (key, value) in attributes(in: nameSource) {
            let lowered = key.lowercased()
            if lowered.hasPrefix("on") { continue }
            if lowered == "style" {
                let cleaned = stripRemoteCSS(value)
                if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { kept.append((key, cleaned)) }
                continue
            }
            let remoteMedia = lowered == "src" || lowered == "srcset" || lowered == "poster" || lowered == "background"
                || (lowered == "href" && mediaTags.contains(name)) || lowered == "xlink:href"
            if remoteMedia && isRemoteReference(value) {
                blockedImage = true
                continue
            }
            if lowered == "href" && isRemoteReference(value) && (value.lowercased().contains("javascript:") || decodeEntities(value).lowercased().hasPrefix("javascript:")) {
                continue
            }
            kept.append((key, value))
        }
        var pieces = ["<\(name)"]
        for (key, value) in kept { pieces.append("\(key)=\"\(escapeAttr(value))\"") }
        if blockedImage { pieces.append("data-remote-image=\"blocked\"") }
        return pieces.joined(separator: " ") + ">"
    }

    private static func tagName(_ source: String) -> String {
        let trimmed = source.drop { $0.isWhitespace || $0 == "/" }
        let name = trimmed.prefix { $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" }
        return name.lowercased()
    }

    private static func attributes(in source: String) -> [(String, String)] {
        var rest = Substring(source).drop { $0.isWhitespace || $0 == "/" }
        rest = rest.drop { $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" }
        var pairs: [(String, String)] = []
        while !rest.isEmpty {
            rest = rest.drop { $0.isWhitespace || $0 == "/" }
            if rest.isEmpty { break }
            let name = rest.prefix { !$0.isWhitespace && $0 != "=" && $0 != "/" && $0 != ">" }
            if name.isEmpty { break }
            rest = rest.dropFirst(name.count)
            rest = rest.drop { $0.isWhitespace }
            var value = ""
            if rest.first == "=" {
                rest = rest.dropFirst().drop { $0.isWhitespace }
                if let quote = rest.first, quote == "\"" || quote == "'" {
                    rest = rest.dropFirst()
                    let raw = rest.prefix { $0 != quote }
                    value = String(raw)
                    rest = rest.dropFirst(raw.count)
                    if rest.first == quote { rest = rest.dropFirst() }
                } else {
                    let raw = rest.prefix { !$0.isWhitespace && $0 != ">" }
                    value = String(raw)
                    rest = rest.dropFirst(raw.count)
                }
            }
            pairs.append((String(name), value))
        }
        return pairs
    }

    static func stripRemoteCSS(_ css: String) -> String {
        var result = ""
        var rest = Substring(css)
        while let range = rest.range(of: "url(", options: .caseInsensitive) {
            result.append(contentsOf: rest[..<range.lowerBound])
            let after = rest[range.upperBound...]
            var quote: Character?
            var end: Substring.Index?
            var cursor = after.startIndex
            while cursor < after.endIndex {
                let character = after[cursor]
                if let current = quote {
                    if character == current { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ")" {
                    end = cursor
                    break
                }
                cursor = after.index(after: cursor)
            }
            guard let end else {
                result.append(contentsOf: rest[range.lowerBound...])
                return result
            }
            let inside = after[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            let unquoted = inside.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if isRemoteReference(String(unquoted)) {
                result.append("url(\"\")")
            } else {
                result.append(contentsOf: rest[range.lowerBound...end])
            }
            rest = after[after.index(after: end)...]
        }
        result.append(contentsOf: rest)
        return result
    }
}

// MARK: - Connector catalog

struct MailConnectorDocument: Equatable, Sendable {
    var providerID: String
    var summary: String
    /// When set, actions are performed by that connector rather than a second mailbox API.
    var routedThrough: String?
    var actions: [MailActionSupport]
}

/// What each connector implements. Disabled actions include the reason the
/// Email tab shows. None of them permanently delete mail.
enum MailConnectorCatalog {
    static let permanentlyDeletesMail = false
    private static let gmailSummary = "Bodies are fetched when a message is opened and are not written into the metadata store. Delete moves mail to Trash and does not call messages.delete. Refresh tokens stay in the Keychain."

    static let all: [MailConnectorDocument] = [
        document(providerID: "gmail", summary: "Gmail. \(gmailSummary)", routedThrough: nil, enabled: true, reason: ""),
        document(providerID: "google-workspace", summary: "Google Workspace uses the same Gmail connector. \(gmailSummary)", routedThrough: "gmail", enabled: true, reason: ""),
        document(providerID: "icloud-forward", summary: "iCloud forwarding has no mailbox API. Actions run on the Gmail account the alias forwards into.", routedThrough: "gmail", enabled: false,
                 reason: "iCloud mail is a forward into Gmail. Connect that Gmail account to reply, archive, or move mail to Trash."),
        document(providerID: "cloudflare-forward", summary: "Cloudflare forwarding has no mailbox API. Actions run on the Gmail account the alias forwards into.", routedThrough: "gmail", enabled: false,
                 reason: "Cloudflare forwarding has no mailbox API. Connect the Gmail account it forwards into."),
        document(providerID: "metadata-import", summary: "A metadata import stores subject, sender, recipient, and date. It has no mailbox connector.", routedThrough: nil, enabled: false,
                 reason: "Imported metadata has no mailbox connector, so this action cannot read a body or change a mailbox."),
        document(providerID: "synthetic", summary: "Synthetic mail is a local fixture. It has no mailbox connector.", routedThrough: nil, enabled: false,
                 reason: "Synthetic mail is a local fixture with no mailbox connector."),
        document(providerID: "hosted-aggregator", summary: "The hosted Email Aggregator has no mailbox body or write API in ControlWard.", routedThrough: nil, enabled: false,
                 reason: "The hosted Email Aggregator has no mailbox write or body API in ControlWard."),
    ]

    static func document(providerID: String) -> MailConnectorDocument? {
        all.first { $0.providerID == providerID }
    }

    static func disabledReason(providerID: String) -> String {
        let reason = document(providerID: providerID)?.actions.first?.reason ?? ""
        return reason.isEmpty ? "This mailbox connector cannot perform that action." : reason
    }

    private static func document(providerID: String, summary: String, routedThrough: String?, enabled: Bool, reason: String) -> MailConnectorDocument {
        MailConnectorDocument(providerID: providerID, summary: summary, routedThrough: routedThrough,
                              actions: MailboxAction.allCases.map { MailActionSupport(action: $0, enabled: enabled, reason: enabled ? "" : reason) })
    }
}

enum GmailScopePolicy {
    static let modify = "https://www.googleapis.com/auth/gmail.modify"
    static let compose = "https://www.googleapis.com/auth/gmail.compose"
    static let sendOnly = "https://www.googleapis.com/auth/gmail.send"
    static let readonly = "https://www.googleapis.com/auth/gmail.readonly"
    static let fullAccess = "https://mail.google.com/"

    static func canReadBodies(_ granted: Set<String>) -> Bool {
        granted.contains(modify) || granted.contains(readonly) || granted.contains(fullAccess)
    }

    static func support(granted: Set<String>) -> [MailActionSupport] {
        let canModify = granted.contains(modify) || granted.contains(fullAccess)
        let canSend = granted.contains(compose) || granted.contains(sendOnly) || granted.contains(fullAccess)
        let canDraft = granted.contains(compose) || granted.contains(fullAccess)
        let known = !granted.isEmpty
        let modifyReason = known
            ? "This Gmail sign-in cannot change labels or Trash. Choose Connect to grant mailbox modify access."
            : "Mailbox permissions could not be confirmed. Choose Connect again before changing mail."
        let sendReason = known
            ? "This Gmail sign-in cannot send. Choose Connect to grant compose access."
            : "Mailbox permissions could not be confirmed. Choose Connect again before sending."
        let draftReason = known
            ? "This Gmail sign-in cannot edit drafts. Choose Connect to grant compose access."
            : "Mailbox permissions could not be confirmed. Choose Connect again before editing a draft."
        func item(_ action: MailboxAction, enabled: Bool, reason: String) -> MailActionSupport {
            MailActionSupport(action: action, enabled: enabled, reason: enabled ? "" : reason)
        }
        return [
            item(.reply, enabled: canSend, reason: sendReason),
            item(.replyAll, enabled: canSend, reason: sendReason),
            item(.forward, enabled: canSend, reason: sendReason),
            item(.editDraft, enabled: canDraft, reason: draftReason),
            item(.trash, enabled: canModify, reason: modifyReason),
            item(.archive, enabled: canModify, reason: modifyReason),
            item(.markRead, enabled: canModify, reason: modifyReason),
            item(.markUnread, enabled: canModify, reason: modifyReason),
        ]
    }
}

enum MailRoute: Equatable, Sendable {
    case gmail(owner: String, providerID: String)
    case disabled(providerID: String, reason: String)
}

enum MailConnectorRouting {
    static func route(sourceID: String, provider: String, synthetic: Bool, accountID: String, signIns: Set<String>, aliases: [String: String], connected: Set<String>) -> MailRoute {
        if synthetic {
            return .disabled(providerID: "synthetic", reason: MailConnectorCatalog.disabledReason(providerID: "synthetic"))
        }
        guard sourceID.hasPrefix("gmail:") else {
            let providerID = MailConnectorCatalog.document(providerID: provider) == nil ? "metadata-import" : provider
            return .disabled(providerID: providerID, reason: MailConnectorCatalog.disabledReason(providerID: providerID))
        }
        let owner = signIns.first { $0.caseInsensitiveCompare(accountID) == .orderedSame }
            ?? aliases.first { $0.key.caseInsensitiveCompare(accountID) == .orderedSame }?.value
        guard let owner else {
            return .disabled(providerID: provider, reason: "This message is not tied to a Gmail sign-in, so mailbox actions are unavailable.")
        }
        guard connected.contains(where: { $0.caseInsensitiveCompare(owner) == .orderedSame }) else {
            return .disabled(providerID: provider, reason: "Connect \(owner) before replying or changing this message. The body stays in the mailbox until then.")
        }
        return .gmail(owner: owner, providerID: provider)
    }
}

protocol MailboxConnecting: Sendable {
    var providerID: String { get }
    var accountID: String { get }
    func supports() -> [MailActionSupport]
    func fetchBody(sourceID: String) async throws -> MailMessageBody
    func perform(_ command: MailCommand) async throws -> MailCommandReceipt
}

struct DisabledMailbox: MailboxConnecting, Sendable {
    var providerID: String
    var accountID: String
    var reason: String

    func supports() -> [MailActionSupport] {
        MailboxAction.allCases.map { MailActionSupport(action: $0, enabled: false, reason: reason) }
    }

    func fetchBody(sourceID: String) async throws -> MailMessageBody {
        throw MailboxError.bodyUnavailable(reason)
    }

    func perform(_ command: MailCommand) async throws -> MailCommandReceipt {
        try MailCommandGate.validate(command, support: supports())
        throw MailboxError.unsupported(command.action, reason)
    }
}

// MARK: - Gmail connector

struct MailHTTPResponse: Sendable {
    var status: Int
    var body: Data
}

protocol MailHTTPSending: Sendable {
    func send(_ request: URLRequest) async throws -> MailHTTPResponse
}

struct ClosureMailHTTP: MailHTTPSending {
    var handler: @Sendable (URLRequest) async throws -> MailHTTPResponse
    func send(_ request: URLRequest) async throws -> MailHTTPResponse { try await handler(request) }
}

enum Base64URL {
    static func decode(_ value: String) throws -> Data {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder > 0 { text.append(String(repeating: "=", count: 4 - remainder)) }
        guard let data = Data(base64Encoded: text) else { throw MailboxError.unreadable("message body") }
        return data
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct GmailMailboxClient<HTTP: MailHTTPSending>: Sendable {
    var token: String
    var from: String
    var http: HTTP

    private static var root: URL { URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")! }

    func grantedScopes() async -> Set<String> {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/tokeninfo")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        request.httpBody = Data("access_token=\(encoded)".utf8)
        guard let response = try? await http.send(request), response.status == 200,
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let scope = object["scope"] as? String else { return [] }
        return Set(scope.split(separator: " ").map(String.init))
    }

    func fetchBody(sourceID: String) async throws -> MailMessageBody {
        let id = try Self.gmailID(sourceID)
        let url = try Self.url("messages", id, query: [URLQueryItem(name: "format", value: "full")])
        let data = try await send(url: url, method: "GET", json: nil)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { throw MailboxError.unreadable("Gmail message") }
        var extract = Extract()
        try walk(part: payload, into: &extract)
        for pending in extract.pending {
            let attachmentURL = try Self.url("messages", id, "attachments", pending.attachmentID)
            let attachment = try await send(url: attachmentURL, method: "GET", json: nil)
            guard let body = try JSONSerialization.jsonObject(with: attachment) as? [String: Any],
                  let encoded = body["data"] as? String else { throw MailboxError.unreadable("Gmail attachment") }
            let text = try Self.utf8(try Base64URL.decode(encoded))
            if pending.mime == "text/html" { extract.html += text } else { extract.plain += text }
        }
        return MailMessageBody(sourceID: sourceID, plain: extract.plain, html: extract.html)
    }

    func perform(_ command: MailCommand, scopes: Set<String>) async throws -> MailCommandReceipt {
        try MailCommandGate.validate(command, support: GmailScopePolicy.support(granted: scopes))
        let id = try Self.gmailID(command.sourceID)
        switch command.action {
        case .trash:
            _ = try await send(url: try Self.url("messages", id, "trash"), method: "POST", json: [:])
            return MailCommandReceipt(action: .trash, sourceID: command.sourceID, draftID: nil, location: "trash")
        case .archive:
            _ = try await send(url: try Self.url("messages", id, "modify"), method: "POST", json: ["removeLabelIds": ["INBOX"]])
            return MailCommandReceipt(action: .archive, sourceID: command.sourceID, draftID: nil, location: "archive")
        case .markRead:
            _ = try await send(url: try Self.url("messages", id, "modify"), method: "POST", json: ["removeLabelIds": ["UNREAD"]])
            return MailCommandReceipt(action: .markRead, sourceID: command.sourceID, draftID: nil, location: "inbox")
        case .markUnread:
            _ = try await send(url: try Self.url("messages", id, "modify"), method: "POST", json: ["addLabelIds": ["UNREAD"]])
            return MailCommandReceipt(action: .markUnread, sourceID: command.sourceID, draftID: nil, location: "inbox")
        case .editDraft:
            let compose = command.compose!
            let raw = Base64URL.encode(Data(try Self.rfc822(from: from, compose: compose, inReplyTo: nil).utf8))
            if let existing = compose.draftID, !existing.isEmpty {
                let data = try await send(url: try Self.url("drafts", existing), method: "PUT", json: ["id": existing, "message": ["raw": raw]])
                return MailCommandReceipt(action: .editDraft, sourceID: command.sourceID, draftID: try Self.draftID(data), location: "draft")
            }
            let data = try await send(url: try Self.url("drafts"), method: "POST", json: ["message": ["raw": raw]])
            return MailCommandReceipt(action: .editDraft, sourceID: command.sourceID, draftID: try Self.draftID(data), location: "draft")
        case .reply, .replyAll, .forward:
            let compose = command.compose!
            var threadID: String?
            var replyHeader: String?
            if command.action != .forward {
                let headers = try await threadHeaders(id)
                threadID = headers.threadID
                replyHeader = headers.messageID
            }
            let raw = Base64URL.encode(Data(try Self.rfc822(from: from, compose: compose, inReplyTo: replyHeader).utf8))
            var message: [String: Any] = ["raw": raw]
            if let threadID { message["threadId"] = threadID }
            _ = try await send(url: try Self.url("messages", "send"), method: "POST", json: message)
            return MailCommandReceipt(action: command.action, sourceID: command.sourceID, draftID: nil, location: "sent")
        }
    }

    private struct Pending { var mime: String; var attachmentID: String }
    private struct Extract {
        var plain = ""
        var html = ""
        var pending: [Pending] = []
    }

    private func walk(part: [String: Any], into extract: inout Extract) throws {
        let mime = (part["mimeType"] as? String ?? "").lowercased()
        let body = part["body"] as? [String: Any]
        let children = part["parts"] as? [[String: Any]] ?? []
        if mime.hasPrefix("multipart/") || (mime.isEmpty && !children.isEmpty) {
            for child in children { try walk(part: child, into: &extract) }
            return
        }
        if mime == "text/plain" || mime == "text/html" {
            if let encoded = body?["data"] as? String, !encoded.isEmpty {
                let text = try Self.utf8(try Base64URL.decode(encoded))
                if mime == "text/html" { extract.html += text } else { extract.plain += text }
            } else if let attachment = body?["attachmentId"] as? String, !attachment.isEmpty {
                extract.pending.append(Pending(mime: mime, attachmentID: attachment))
            }
            return
        }
        for child in children { try walk(part: child, into: &extract) }
    }

    private struct ThreadHeaders { var threadID: String?; var messageID: String? }

    private func threadHeaders(_ id: String) async throws -> ThreadHeaders {
        let url = try Self.url("messages", id, query: [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "Message-ID"),
        ])
        let data = try await send(url: url, method: "GET", json: nil)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MailboxError.unreadable("Gmail message")
        }
        let headers = (object["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
        let messageID = headers.first {
            ($0["name"] as? String)?.caseInsensitiveCompare("Message-ID") == .orderedSame
        }?["value"] as? String
        return ThreadHeaders(threadID: object["threadId"] as? String, messageID: messageID)
    }

    static func rfc822(from: String, compose: MailCompose, inReplyTo: String?) throws -> String {
        func clean(_ value: String) throws -> String {
            guard !value.contains("\n"), !value.contains("\r") else {
                throw MailboxError.invalidCompose("An address or the subject contains a line break.")
            }
            return value
        }
        var lines = [
            "From: \(try clean(from))",
            "To: \(try compose.to.map(clean).joined(separator: ", "))",
            "Subject: \(try clean(compose.subject))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
        ]
        let cc = try compose.cc.map(clean).joined(separator: ", ")
        if !cc.isEmpty { lines.insert("Cc: \(cc)", at: 2) }
        if let inReplyTo, !inReplyTo.isEmpty {
            let value = try clean(inReplyTo)
            lines.append("In-Reply-To: \(value)")
            lines.append("References: \(value)")
        }
        lines.append("")
        lines.append(compose.body)
        return lines.joined(separator: "\r\n")
    }

    private static func gmailID(_ sourceID: String) throws -> String {
        guard sourceID.hasPrefix("gmail:") else { throw MailboxError.unreadable("Gmail message") }
        let id = String(sourceID.dropFirst("gmail:".count))
        guard !id.isEmpty, !id.contains("/"), id.count <= 200 else { throw MailboxError.unreadable("Gmail message") }
        return id
    }

    private static func utf8(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else { throw MailboxError.unreadable("message body") }
        return text
    }

    private static func draftID(_ data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty else { throw MailboxError.unreadable("Gmail draft") }
        return id
    }

    private static func url(_ parts: String..., query: [URLQueryItem] = []) throws -> URL {
        var url = root
        for part in parts { url.appendPathComponent(part) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw MailboxError.unreadable("Gmail request")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let built = components.url else { throw MailboxError.unreadable("Gmail request") }
        return built
    }

    private func send(url: URL, method: String, json: Any?) async throws -> Data {
        guard method != "DELETE" else { throw MailboxError.unsupported(.trash, "Permanent delete is not available.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let response = try await http.send(request)
        if response.status == 401 || response.status == 403 { throw MailboxError.needsReconnect }
        guard (200..<300).contains(response.status) else { throw MailboxError.http(response.status) }
        return response.body
    }
}

struct GmailMailboxConnector<HTTP: MailHTTPSending>: MailboxConnecting, Sendable {
    var providerID: String
    var accountID: String
    var scopes: Set<String>
    var token: String
    var from: String
    var http: HTTP

    func supports() -> [MailActionSupport] { GmailScopePolicy.support(granted: scopes) }

    func fetchBody(sourceID: String) async throws -> MailMessageBody {
        try await GmailMailboxClient(token: token, from: from, http: http).fetchBody(sourceID: sourceID)
    }

    func perform(_ command: MailCommand) async throws -> MailCommandReceipt {
        try await GmailMailboxClient(token: token, from: from, http: http).perform(command, scopes: scopes)
    }
}
