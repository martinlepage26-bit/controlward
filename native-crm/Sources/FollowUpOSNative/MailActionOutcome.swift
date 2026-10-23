import Foundation

/// What the Email tab reports after a connector accepted a command.
/// Kept free of SwiftUI and AppKit so the portable test runner can compile it.
struct MailActionOutcome: Equatable, Sendable {
    /// Text shown in the message pane.
    var status: String
    /// nil only when every step of the action succeeded. The caller treats non-nil as failure.
    var failure: String?
    /// The CW-AUDIT v1 `result=` value for this action.
    var auditResult: String
}

enum MailActionOutcomes {
    /// Builds the outcome after the remote mailbox accepted `action`.
    /// `removeLocalRow` runs only for Trash and removes the local metadata row.
    static func afterRemoteSuccess(_ action: MailboxAction, removeLocalRow: () throws -> Void) -> MailActionOutcome {
        switch action {
        case .trash:
            do { try removeLocalRow() }
            catch {
                // The remote Trash happened but the local step did not: this is a failure, not a success.
                let text = "Moved to Trash in the mailbox. The local metadata row could not be removed."
                return MailActionOutcome(status: text, failure: text, auditResult: "partial:local-row")
            }
            return MailActionOutcome(status: "Moved to Trash. The message is still in the mailbox Trash and was not erased.", failure: nil, auditResult: "ok")
        case .reply, .replyAll, .forward:
            return MailActionOutcome(status: "Sent.", failure: nil, auditResult: "ok")
        case .editDraft:
            return MailActionOutcome(status: "Draft saved. Nothing was sent.", failure: nil, auditResult: "ok")
        case .archive:
            return MailActionOutcome(status: "Archived.", failure: nil, auditResult: "ok")
        case .markRead:
            return MailActionOutcome(status: "Marked read.", failure: nil, auditResult: "ok")
        case .markUnread:
            return MailActionOutcome(status: "Marked unread.", failure: nil, auditResult: "ok")
        }
    }
}
