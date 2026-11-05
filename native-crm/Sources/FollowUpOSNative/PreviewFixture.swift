#if DEBUG && CONTEXTWARD_ACCEPTANCE
import Foundation

/// Compiled only into the isolated preview, never the release app.
@MainActor enum PreviewFixture {
    static func prepareIfRequested() -> URL {
        guard let mode = ProcessInfo.processInfo.environment["CONTROLWARD_PREVIEW"],
              ["empty", "synthetic"].contains(mode),
              let directory = ProcessInfo.processInfo.environment["FOLLOWUPOS_DATA_DIR"],
              directory.contains("controlward-preview-") else {
            fatalError("Launch this isolated preview with bin/preview-controlward. The normal workspace was not opened.")
        }
        let storage = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("workspace.json")
        if FileManager.default.fileExists(atPath: storage.path) { return storage }
        if mode == "empty" {
            // A named workspace with no records, to show the real empty states.
            var w = PersistentWorkspace()
            w.business.name = "Empty review workspace"; w.business.industry = "Consulting"
            do { try SecureFiles.writePrivate(JSONEncoder().encode(w), to: storage) }
            catch { fatalError("Could not create the isolated empty preview workspace.") }
            return storage
        }
        var w = PersistentWorkspace()
        w.business.name = "Synthetic review workspace"; w.business.industry = "Consulting"
        var company = Company(); company.name = "Érable Studio"; company.domain = "erable.example.test"; company.industry = "Design"
        w.companies = [company]
        var contact = Contact(); contact.firstName = "Camille"; contact.lastName = "Example"; contact.email = "camille@example.test"; contact.companyID = company.id
        w.contacts = [contact]
        var task = CRMTask(); task.title = "Review project brief"; task.details = "Synthetic fixture — no client data"; task.dueDate = CalendarCRM.addDays(1, to: CalendarCRM.dayString()); task.companyID = company.id
        w.tasks = [task]
        var opportunity = Opportunity(); opportunity.name = "Synthetic onboarding review"; opportunity.stage = .proposal; opportunity.companyID = company.id; opportunity.amount = 2400
        w.opportunities = [opportunity]
        var lead = Lead(); lead.name = "Alex Example"; lead.email = "alex@example.test"; lead.company = company.name; lead.nextFollowUp = CalendarCRM.addDays(2, to: CalendarCRM.dayString()); w.leads = [lead]
        var note = CRMNote(); note.title = "Review checklist"; note.body = "All displayed records are synthetic."; note.companyID = company.id; w.notes = [note]
        var signal = Signal(); signal.title = "GAP fixture: clearer handoffs"; signal.source = .imported; signal.sourceID = "gap:synthetic-1"; signal.sourceActive = true; signal.evidence = "Synthetic research fixture for interface review."; signal.nextAction = "Review before creating project work"; signal.priority = 70; signal.fitScore = 60; signal.intentScore = 40; w.signals = [signal]
        w.controlWard.mail = [MailMetadata(sourceID: "synthetic-message-1", subject: "Project review follow-up", sender: "camille@example.test", recipient: "owner@example.test", receivedAt: "2026-10-17T09:00:00Z", provider: "synthetic", accountID: "preview", synthetic: true)]
        w.activity = [ActivityEvent(kind: "preview", message: "Synthetic preview workspace created.")]
        do { try SecureFiles.writePrivate(JSONEncoder().encode(w), to: storage) }
        catch { fatalError("Could not create the isolated preview fixture.") }
        return storage
    }
}
#endif
