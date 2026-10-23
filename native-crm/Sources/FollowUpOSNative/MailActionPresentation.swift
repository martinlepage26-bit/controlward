import Foundation

// Portable logic behind the Email tab's dialogs, action bar and body view (S1-R4, S1-R7, S4-R1).
// The SwiftUI views in MailActionViews.swift and ControlWardWorkflowViews.swift only read from these.

/// How the user can leave a confirmation dialog.
enum MailDialogInput: String, CaseIterable, Sendable {
    case cancelButton, escapeKey, returnKey, confirmButton
}

enum MailDialogKind: String, CaseIterable, Sendable { case send, trash }

/// Maps dialog input to a decision. Escape is always Cancel. Return activates the default button,
/// and Cancel is the default in both dialogs, so only clicking the confirm button confirms.
enum MailDialogDecisions {
    static func cancelIsDefault(_ kind: MailDialogKind) -> Bool {
        switch kind {
        case .send: MailSendConfirmation.buttons.first { $0.isDefault }?.kind == .cancel
        case .trash: MailTrashConfirmation.buttons.first { $0.isDefault }?.kind == .cancel
        }
    }

    static func decision(_ input: MailDialogInput, in kind: MailDialogKind) -> MailUserDecision {
        switch input {
        case .cancelButton, .escapeKey: .cancel
        case .returnKey: cancelIsDefault(kind) ? .cancel : .confirm
        case .confirmButton: .confirm
        }
    }

    /// The command a dialog produces, or nil. A nil result means nothing reaches the connector.
    static func command(_ input: MailDialogInput, in kind: MailDialogKind, action: MailboxAction, sourceID: String, compose: MailCompose?) -> MailCommand? {
        guard case .ready(let command) = MailActionResolver.resolve(action: action, sourceID: sourceID, compose: compose, decision: decision(input, in: kind)) else { return nil }
        return command
    }
}

/// One action button as the action bar draws it (S4-R1). `help` is the button help and accessibility hint.
struct MailActionButtonModel: Equatable, Identifiable, Sendable {
    var action: MailboxAction
    var title: String
    var enabled: Bool
    var help: String
    var id: String { action.rawValue }
}

enum MailActionDisplay {
    /// The reason shown for a disabled action, the same string the gate throws.
    static func reason(_ item: MailActionSupport) -> String {
        let trimmed = item.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(item.action.title) is not available for this mailbox." : trimmed
    }

    static func buttons(_ support: [MailActionSupport]) -> [MailActionButtonModel] {
        support.map { MailActionButtonModel(action: $0.action, title: $0.action.title, enabled: $0.enabled, help: $0.enabled ? $0.action.help : reason($0)) }
    }

    /// The caption under the bar: one `Action: reason` line per disabled action.
    static func captionLines(_ support: [MailActionSupport]) -> [String] {
        support.filter { !$0.enabled }.map { "\($0.action.title): \(reason($0))" }
    }

    static func caption(_ support: [MailActionSupport]) -> String { captionLines(support).joined(separator: "\n") }
}

/// Checks that a provider's disabled reasons agree everywhere (S4-R1) and that hosted-aggregator never enables an action.
/// `display` and `gate` are injectable so the planted reds can swap in a broken UI model.
enum MailPlatformConsistency {
    typealias Display = @Sendable ([MailActionSupport]) -> (buttons: [MailActionButtonModel], caption: [String])
    typealias Gate = @Sendable (MailCommand, [MailActionSupport]) -> String?

    static let liveDisplay: Display = { (MailActionDisplay.buttons($0), MailActionDisplay.captionLines($0)) }
    static let liveGate: Gate = { command, support in
        do { try MailCommandGate.validate(command, support: support); return nil } catch { return error.localizedDescription }
    }

    static func problems(_ documents: [MailConnectorDocument], display: Display = liveDisplay, gate: Gate = liveGate) -> [String] {
        var problems: [String] = []
        for document in documents {
            let provider = document.providerID
            if Set(document.actions.map(\.action)) != Set(MailboxAction.allCases) || document.actions.count != MailboxAction.allCases.count {
                problems.append("\(provider): does not list all 8 actions")
            }
            if provider == "hosted-aggregator" || provider == "metadata-import" || provider == "synthetic" {
                for item in document.actions where item.enabled { problems.append("\(provider): \(item.action.rawValue) is enabled") }
            }
            let shown = display(document.actions)
            for item in document.actions where !item.enabled {
                let reason = item.reason.trimmingCharacters(in: .whitespacesAndNewlines)
                if reason.isEmpty { problems.append("\(provider): \(item.action.rawValue) is disabled with an empty reason"); continue }
                let help = shown.buttons.first { $0.action == item.action }?.help
                if help != reason { problems.append("\(provider): \(item.action.rawValue) help differs from the catalog reason") }
                if !shown.caption.contains("\(item.action.title): \(reason)") { problems.append("\(provider): \(item.action.rawValue) caption differs from the catalog reason") }
                let command = MailCommand(action: item.action, sourceID: "gmail:fixture", compose: MailCompose(draftID: nil, to: ["a@example.test"], cc: [], subject: "s", body: "b"), confirmed: true)
                if gate(command, document.actions) != reason { problems.append("\(provider): \(item.action.rawValue) gate error differs from the catalog reason") }
            }
        }
        return problems
    }
}

/// Turns sanitized HTML into display text without any HTML importer (S1-R7, closes U5).
/// Nothing here can load a URL: links keep their visible text only and images are dropped.
enum MailBodyText {
    static func plain(fromSanitizedHTML html: String) -> String {
        if true { return html }  // RED STUB: no plain-text conversion yet
        var text = html
        let breaks = ["<br>", "<br/>", "<br />", "</p>", "</div>", "</li>", "</tr>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>", "</blockquote>", "</pre>", "</table>"]
        for tag in breaks { text = text.replacingOccurrences(of: tag, with: "\n" + tag, options: .caseInsensitive) }
        text = text.replacingOccurrences(of: "<li>", with: "• ", options: .caseInsensitive)
        var plain = MailHTMLSanitizer.visibleText(text)
        while plain.contains("\n\n\n") { plain = plain.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return plain.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
