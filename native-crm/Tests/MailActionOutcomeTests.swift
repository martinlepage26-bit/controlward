import Foundation

enum MailActionOutcomeTests {
    private struct LocalRowError: Error {}

    static func run() async -> Bool {
        await PortableCheck.suite("Mail action outcome", [
            ("Mail trash: partial local-row failure reports failure (U4)", {
                let outcome = MailActionOutcomes.afterRemoteSuccess(.trash) { throw LocalRowError() }
                try PortableCheck.expect(outcome.failure != nil, "a Trash whose local row could not be removed was reported as success")
                try PortableCheck.expect(outcome.auditResult == "partial:local-row", "audit result for a partial Trash was \(outcome.auditResult), expected partial:local-row")
                try PortableCheck.expect(outcome.status.contains("Moved to Trash in the mailbox"), "the status no longer says the remote Trash happened")
            }),
            ("Mail trash: full success reports success", {
                var removed = false
                let outcome = MailActionOutcomes.afterRemoteSuccess(.trash) { removed = true }
                try PortableCheck.expect(removed, "the local row was not removed")
                try PortableCheck.expect(outcome.failure == nil && outcome.auditResult == "ok", "a complete Trash was not reported as ok")
            }),
            ("Mail actions other than Trash never touch the local row", {
                for action in MailboxAction.allCases where action != .trash {
                    var touched = false
                    let outcome = MailActionOutcomes.afterRemoteSuccess(action) { touched = true }
                    try PortableCheck.expect(!touched, "\(action) removed the local row")
                    try PortableCheck.expect(outcome.failure == nil && outcome.auditResult == "ok", "\(action) was not ok")
                }
            }),
        ])
    }
}
