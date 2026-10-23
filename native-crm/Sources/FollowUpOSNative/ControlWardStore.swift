import Foundation

struct ControlWardBackup: Codable {
    var schemaVersion = 1
    var createdAt = Date.now.ISO8601Format()
    var workspace: PersistentWorkspace
}

@MainActor
extension AppStore {
    var mail: [MailMetadata] { workspace.controlWard.mail }

    @discardableResult
    func importMailMetadata(_ data: Data) throws -> Int {
        try mergeMail(try MailMetadataImport.decode(data), activity: "Imported mail metadata")
    }

    func reviewMail(_ id: UUID, reviewed: Bool, contactID: UUID?, companyID: UUID?) throws {
        try commitWorkspace { next in
            guard let i = next.controlWard.mail.firstIndex(where: { $0.id == id }) else { throw ControlWardError.invalid("This message is no longer available.") }
            guard contactID == nil || next.contacts.contains(where: { $0.id == contactID }),
                  companyID == nil || next.companies.contains(where: { $0.id == companyID }) else { throw ControlWardError.invalid("Choose an existing contact or company.") }
            next.controlWard.mail[i].reviewed = reviewed
            next.controlWard.mail[i].contactID = contactID
            next.controlWard.mail[i].companyID = companyID
        }
    }

    @discardableResult
    func createMailTask(_ id: UUID) throws -> UUID {
        var taskID: UUID!
        try commitWorkspace { next in
            guard let i = next.controlWard.mail.firstIndex(where: { $0.id == id }) else { throw ControlWardError.invalid("This message is no longer available.") }
            if let existing = next.controlWard.mail[i].taskID {
                guard next.tasks.contains(where: { $0.id == existing }) else { throw ControlWardError.invalid("The linked task was deleted. Its receipt is retained; add a new task explicitly if needed.") }
                taskID = existing; return
            }
            let message = next.controlWard.mail[i]
            var task = CRMTask(); task.title = "Review email: \(message.subject)"
            task.details = "Imported email metadata. Review the original message before acting."
            task.contactID = message.contactID; task.companyID = message.companyID
            next.tasks.insert(task, at: 0); next.controlWard.mail[i].taskID = task.id; taskID = task.id
            next.activity.insert(ActivityEvent(kind: "mail_task", message: "Created one review task from mail metadata."), at: 0)
        }
        return taskID
    }

    /// Drops the local metadata row after the mailbox has moved the message to Trash.
    /// This does not erase the message from the mailbox.
    func forgetMailMetadata(id: UUID) throws {
        try commitWorkspace { next in
            guard next.controlWard.mail.contains(where: { $0.id == id }) else {
                throw ControlWardError.invalid("This message is no longer in the local inbox.")
            }
            next.controlWard.mail.removeAll { $0.id == id }
            next.activity.insert(ActivityEvent(kind: "mail_trash", message: "Removed local mail metadata after the mailbox moved the message to Trash."), at: 0)
        }
    }

    /// Writes CW-AUDIT v1 lines (mail actions, Project Control writes) into local Activity, newest first.
    /// The lines carry ids and result codes only, never subjects, senders, bodies or tokens.
    func recordAudit(_ lines: [CWAuditLine]) {
        guard !lines.isEmpty else { return }
        try? commitWorkspace { next in
            for line in lines { next.activity.insert(ActivityEvent(kind: "cw_audit", message: line.text), at: 0) }
        }
    }

    func linkProject(recordKey: String, register: String, projectID: String, title: String) throws {
        guard allWorkspaceRecords.contains(where: { $0.id == recordKey }),
              !projectID.isEmpty, projectID.count <= 80,
              let url = URL(string: register), url.host != nil,
              ["https", "http"].contains(url.scheme ?? ""), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ControlWardError.invalid("Select an existing record and project from the connected register.")
        }
        try commitWorkspace { next in
            next.controlWard.projectLinks.removeAll { $0.recordKey == recordKey && $0.register == register }
            next.controlWard.projectLinks.append(RecordProjectLink(recordKey: recordKey, register: register, projectID: projectID, projectTitle: String(title.prefix(1000))))
        }
    }

    func unlinkProject(_ linkID: UUID) throws {
        try commitWorkspace { $0.controlWard.projectLinks.removeAll { $0.id == linkID } }
    }

    func recordCapture(recordKey: String, register: String, itemID: String) throws {
        guard !itemID.isEmpty else { throw ControlWardError.invalid("The register did not confirm an item ID.") }
        try commitWorkspace { next in
            if !next.controlWard.captures.contains(where: { $0.recordKey == recordKey && $0.register == register && $0.itemID == itemID }) {
                next.controlWard.captures.append(ProjectCaptureReceipt(recordKey: recordKey, register: register, itemID: itemID))
            }
        }
    }

    func completeTask(_ id: UUID, completed: Bool) throws {
        try commitWorkspace { next in
            guard let index = next.tasks.firstIndex(where: { $0.id == id }) else { throw ControlWardError.invalid("Task no longer exists.") }
            next.tasks[index].status = completed ? .done : .todo
        }
        if let task = tasks.first(where: { $0.id == id }) { Task { await scheduleTaskReminder(for: task) } }
    }

    func createSecurityReviewTask(_ findingID: UUID) throws {
        try commitWorkspace { next in
            guard let finding = next.exposureFindings.first(where: { $0.id == findingID }) else { throw ControlWardError.invalid("Finding no longer exists.") }
            if next.controlWard.remediationTasks[findingID] != nil { return }
            var task = CRMTask(); task.title = "Review finding: \(finding.title)"; task.details = finding.detail
            next.tasks.insert(task, at: 0)
            next.controlWard.remediationTasks[findingID] = task.id
        }
    }

    var allWorkspaceRecords: [WorkspaceRecord] {
        func company(_ id: UUID?) -> String { companies.first { $0.id == id }?.name ?? "" }
        var rows = contacts.map { WorkspaceRecord(recordID: $0.id, kind: "contacts", title: $0.displayName, detail: "\($0.email) · \($0.title) · \(company($0.companyID))", createdAt: $0.createdAt, companyID: $0.companyID) }
        rows += companies.map { WorkspaceRecord(recordID: $0.id, kind: "companies", title: $0.name, detail: "\($0.domain) · \($0.industry)", createdAt: $0.createdAt, companyID: $0.id) }
        rows += opportunities.map { WorkspaceRecord(recordID: $0.id, kind: "opportunities", title: $0.name, detail: "\(company($0.companyID)) · \($0.stage.label)", status: $0.stage.rawValue, date: $0.closeDate ?? "", createdAt: $0.createdAt, completed: $0.stage.isClosed, supportsCompletion: true, companyID: $0.companyID) }
        rows += tasks.map { WorkspaceRecord(recordID: $0.id, kind: "tasks", title: $0.title, detail: "\($0.details) · \(company($0.companyID))", status: $0.status.label, date: $0.dueDate ?? "", createdAt: $0.createdAt, completed: $0.status == .done, supportsCompletion: true, companyID: $0.companyID) }
        rows += notes.map { WorkspaceRecord(recordID: $0.id, kind: "notes", title: $0.title, detail: $0.body, createdAt: $0.createdAt, companyID: $0.companyID) }
        rows += leads.map { WorkspaceRecord(recordID: $0.id, kind: "leads", title: $0.name, detail: "\($0.email) · \($0.company)", status: $0.status.label, date: $0.nextFollowUp ?? "", createdAt: $0.createdAt, completed: !$0.status.isOpen, supportsCompletion: true, companyID: $0.companyID) }
        rows += signals.map { WorkspaceRecord(recordID: $0.id, kind: "signals", title: $0.title, detail: $0.evidence, status: $0.sourceActive == false ? "Retired" : $0.status.label, createdAt: $0.capturedAt, companyID: $0.companyID) }
        rows += mail.map { WorkspaceRecord(recordID: $0.id, kind: "mail", title: $0.subject, detail: "\($0.sender) → \($0.recipient)", status: $0.reviewed ? "Reviewed" : "Unreviewed", createdAt: $0.receivedAt, completed: $0.reviewed, supportsCompletion: true, companyID: $0.companyID) }
        return rows
    }

    func records(kind: String? = nil, search: String = "", filter: RecordFilter = .all, sort: RecordSort = .name) -> [WorkspaceRecord] {
        WorkspaceRecord.query(allWorkspaceRecords.filter { kind == nil || $0.kind == kind }, search: search, filter: filter, sort: sort, today: CalendarCRM.dayString())
    }

    func exportControlWardBackup(to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ControlWardBackup(workspace: workspace)).write(to: url, options: .atomic)
        try SecureFiles.restrict(url)
    }

    func restoreControlWardBackup(_ data: Data, confirmed: Bool) throws {
        guard confirmed else { throw ControlWardError.invalid("Review and confirm the restore first.") }
        let restored = try Self.readControlWardBackup(data)
        guard busyTargets.isEmpty else { throw ControlWardError.invalid("Wait for running integrations before restoring.") }
        // A backup must not redirect existing credentials to imported endpoints or
        // revive a previously queued external write. Those settings stay local.
        let endpoints = workspace.connectorEndpoints
        let currentLinks = workspace.twentyLinks
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let rollback = storageURL.deletingLastPathComponent().appendingPathComponent("before-restore-\(UUID().uuidString).json")
        try SecureFiles.writePrivate(try encoder.encode(ControlWardBackup(workspace: workspace)), to: rollback)
        stopPulling()
        try commitWorkspace { next in
            next = restored.workspace
            next.connectorEndpoints = endpoints
            next.connectorHealth = [:]; next.syncJobs = []
            // Retain only current-destination identities for records that still exist.
            // Never trust a backup to supply another account's remote record IDs.
            let survivingKeys = Set(TwentyMapper.plan(next, links: [:]).operations.map(\.localKey))
            next.twentyLinks = currentLinks.filter { survivingKeys.contains($0.key) }
            next.autoPullLeads = false; next.autoPilotEnabled = false
            next.leadInboxCursor = nil; next.leadInboxEpoch = nil
        }
    }

    static func readControlWardBackup(_ data: Data) throws -> ControlWardBackup {
        guard data.count <= 20_000_000 else { throw ControlWardError.invalid("Backups must be under 20 MB.") }
        let backup = try JSONDecoder().decode(ControlWardBackup.self, from: data)
        guard backup.schemaVersion == 1 else { throw ControlWardError.invalid("Unsupported backup version.") }
        let w = backup.workspace
        let groups = [w.contacts.map(\.id), w.companies.map(\.id), w.opportunities.map(\.id), w.tasks.map(\.id), w.notes.map(\.id), w.leads.map(\.id), w.signals.map(\.id), w.controlWard.mail.map(\.id)]
        guard groups.allSatisfy({ $0.count <= 10_000 && Set($0).count == $0.count }) else { throw ControlWardError.invalid("Backup contains repeated identities or oversized collections.") }
        // Backups must satisfy the same metadata/link boundary as a fresh import.
        let messages: [[String: Any]] = w.controlWard.mail.map { mail in
            ["source_id": mail.sourceID, "subject": mail.subject, "sender": mail.sender,
             "recipient": mail.recipient, "received_at": mail.receivedAt, "provider": mail.provider,
             "account_id": mail.accountID, "synthetic": mail.synthetic, "link": mail.link]
        }
        _ = try MailMetadataImport.decode(JSONSerialization.data(withJSONObject: ["schema_version": "controlward.mail.v1", "messages": messages]))
        return backup
    }
}
