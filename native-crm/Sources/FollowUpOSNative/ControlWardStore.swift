import Foundation

struct ControlWardBackup: Codable {
    var schemaVersion = 2
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

    /// Exact address suggestions, never inferred from a name, domain, subject, or message body.
    /// Multiple leads sharing a route remain separate choices. No association is saved here.
    func mailLeadMatches(_ message: MailMetadata) -> [Lead] {
        let senders = Set(MailComposePrefill.addresses(in: message.sender))
        let owners = Set(MailAccount.all.map(\.email) + MailComposePrefill.addresses(in: message.accountID))
        guard senders.count == 1, let sender = senders.first, !owners.contains(sender) else { return [] }
        return leads.filter { lead in
            let contactEmail = contacts.first { $0.id == lead.contactID }?.email ?? ""
            let routes = Set(MailComposePrefill.addresses(in: lead.email) + MailComposePrefill.addresses(in: contactEmail))
            return routes.contains(sender)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func reviewMail(_ id: UUID, reviewed: Bool, contactID: UUID?, companyID: UUID?, leadID: UUID? = nil) throws {
        try commitWorkspace { next in
            guard let i = next.controlWard.mail.firstIndex(where: { $0.id == id }) else { throw ControlWardError.invalid("This message is no longer available.") }
            let lead = next.leads.first { $0.id == leadID }
            guard leadID == nil || lead != nil else { throw ControlWardError.invalid("This lead is no longer available. Review the current records.") }
            if let lead {
                guard contactID == nil || contactID == lead.contactID,
                      companyID == nil || companyID == lead.companyID else {
                    throw ControlWardError.invalid("The selected contact or company conflicts with this lead. Use its existing relationships, or edit the lead first.")
                }
                if let taskID = next.controlWard.mail[i].taskID,
                   let task = next.tasks.first(where: { $0.id == taskID }), task.leadID != lead.id {
                    throw ControlWardError.invalid("This message already has a separate review task. Review its relationships in Tasks before associating another lead.")
                }
            }
            let selectedContact = lead?.contactID ?? contactID
            let selectedCompany = lead?.companyID ?? companyID
            guard selectedContact == nil || next.contacts.contains(where: { $0.id == selectedContact }),
                  selectedCompany == nil || next.companies.contains(where: { $0.id == selectedCompany }) else { throw ControlWardError.invalid("Choose an existing contact or company.") }
            next.controlWard.mail[i].reviewed = reviewed
            next.controlWard.mail[i].contactID = selectedContact
            next.controlWard.mail[i].companyID = selectedCompany
            next.controlWard.mail[i].leadID = leadID
        }
    }

    @discardableResult
    func createMailTask(_ id: UUID) throws -> UUID {
        var taskID: UUID!
        try commitWorkspace { next in
            guard let i = next.controlWard.mail.firstIndex(where: { $0.id == id }) else { throw ControlWardError.invalid("This message is no longer available.") }
            if let existing = next.controlWard.mail[i].taskID {
                guard let task = next.tasks.first(where: { $0.id == existing }) else { throw ControlWardError.invalid("The linked task was deleted. Its receipt is retained; add a new task explicitly if needed.") }
                guard next.controlWard.mail[i].leadID == nil || task.leadID == next.controlWard.mail[i].leadID else {
                    throw ControlWardError.invalid("The linked task belongs to different work. Review its relationships in Tasks first.")
                }
                taskID = existing; return
            }
            let message = next.controlWard.mail[i]
            if let leadID = message.leadID {
                guard let leadIndex = next.leads.firstIndex(where: { $0.id == leadID }) else { throw ControlWardError.invalid("The associated lead no longer exists.") }
                let lead = next.leads[leadIndex]
                if let existing = lead.followUpTaskID {
                    guard let task = next.tasks.first(where: { $0.id == existing }), task.leadID == lead.id else {
                        throw ControlWardError.invalid("The lead's next-action task was deleted or relinked. Review it in Pipeline before creating more work.")
                    }
                    next.controlWard.mail[i].taskID = existing; taskID = existing; return
                }
                guard lead.status.isOpen else { throw ControlWardError.invalid("This lead is closed. Review the record before creating a new next action.") }
                // Do not duplicate an existing lead task whose role is unclear.
                guard !next.tasks.contains(where: { $0.leadID == lead.id && $0.status != .done }) else {
                    throw ControlWardError.invalid("This lead already has open tasks. Choose its next action in Pipeline or Tasks first.")
                }
                var task = CRMTask(); task.title = "Review email: \(message.subject)"
                task.details = "Review the linked email and decide the next action. The association alone does not establish a reply, buying interest or a sent message."
                task.leadID = lead.id; task.contactID = lead.contactID; task.companyID = lead.companyID
                task.dueDate = lead.nextFollowUp
                let opportunities = next.opportunities.filter { $0.leadID == lead.id }
                if opportunities.count == 1 { task.opportunityID = opportunities[0].id }
                next.tasks.insert(task, at: 0); next.leads[leadIndex].followUpTaskID = task.id
                next.controlWard.mail[i].taskID = task.id; taskID = task.id
                next.activity.insert(ActivityEvent(kind: "mail_task", message: "Linked one mail review to a lead next action."), at: 0)
                return
            }
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
        let data = try encoder.encode(ControlWardBackup(workspace: completeBackupWorkspace()))
        guard data.count <= 20_000_000 else { throw ControlWardError.invalid("This complete backup exceeds 20 MB. No partial backup was written.") }
        // Refuse an unrestorable snapshot before creating or replacing a file.
        _ = try Self.readControlWardBackup(data)
        // NSSavePanel grants this file, not permission to chmod its parent. Start a new
        // selected file privately, then replace it atomically; preserve existing backups
        // if the replacement fails. Managed rollback/recovery folders use writePrivate.
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ControlWardError.invalid("The selected backup file could not be created. Nothing was exported.")
            }
        } else { try SecureFiles.restrict(url) }
        try data.write(to: url, options: .atomic)
        try SecureFiles.restrict(url)
    }

    func currentResearchRecoveryDigest() throws -> String? {
        let url = researchRoot.appendingPathComponent("research-recovery.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 20_000_000 else { throw ResearchStorageError.responseTooLarge }
        return SecureFiles.sha256(data)
    }

    func completeBackupWorkspace() throws -> PersistentWorkspace {
        guard case .ready = recoveryState else { throw ControlWardError.invalid("Recover the workspace before exporting a backup.") }
        let snapshot = try researchSnapshot()
        let suppression = suppressionList
        if let reason = suppression.unavailableReason { throw ControlWardError.invalid(reason) }
        var value = workspace
        value.websiteResearch = snapshot.cache
        value.researchMigrationComplete = true
        value.consumedResearchRecovery = snapshot.recoveryDigest
        value.restoredSuppressionEntries = suppression.all
        return value
    }

    func restoreControlWardBackup(_ data: Data, confirmed: Bool) throws {
        guard confirmed else { throw ControlWardError.invalid("Review and confirm the restore first.") }
        guard pendingResendReceipt == nil else { throw ControlWardError.invalid("Save the pending Resend receipt before restoring another workspace.") }
        let restored = try Self.readControlWardBackup(data)
        guard busyTargets.isEmpty, activeResearch.isEmpty else { throw ControlWardError.invalid("Wait for running research and integrations before restoring.") }
        let current = try completeBackupWorkspace()
        let consumed = try currentResearchRecoveryDigest()
        let exclusions = SuppressionList(additionalEntries: current.restoredSuppressionEntries + restored.workspace.restoredSuppressionEntries).all
        // A backup must not redirect existing credentials to imported endpoints or
        // revive a previously queued external write. Those settings stay local.
        let endpoints = workspace.connectorEndpoints
        let currentLinks = workspace.twentyLinks
        let currentDispatches = workspace.resendDispatches
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let rollback = storageURL.deletingLastPathComponent().appendingPathComponent("before-restore-\(UUID().uuidString).json")
        try SecureFiles.writePrivate(try encoder.encode(ControlWardBackup(workspace: current)), to: rollback)
        stopPulling()
        try commitWorkspace { next in
            next = restored.workspace
            // A CRM restore cannot undo a provider's acceptance or erase an unresolved request.
            // Retain current outbound facts; imported requests never run automatically.
            let currentDispatchIDs = Set(currentDispatches.map(\.id))
            next.resendDispatches = currentDispatches + restored.workspace.resendDispatches.filter { !currentDispatchIDs.contains($0.id) }
            // Older backups did not contain unreviewed website research. Keep it explicitly.
            if !restored.workspace.researchMigrationComplete { next.websiteResearch = current.websiteResearch }
            next.researchMigrationComplete = true
            next.researchGeneration = UUID()
            next.consumedResearchRecovery = consumed
            next.restoredSuppressionEntries = exclusions
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
        guard [1, 2].contains(backup.schemaVersion) else { throw ControlWardError.invalid("Unsupported backup version.") }
        let w = backup.workspace
        func records<T: Identifiable>(_ rows: [T], _ name: String, maximum: Int? = nil) throws {
            if let maximum, rows.count > maximum {
                throw ControlWardError.invalid("The backup's \(name) collection exceeds \(maximum) records.")
            }
            var identities = Set<T.ID>()
            guard rows.allSatisfy({ identities.insert($0.id).inserted }) else {
                throw ControlWardError.invalid("The backup's \(name) collection contains repeated identities. Nothing was changed.")
            }
        }
        // Retain the existing per-collection limits. Other history remains
        // bounded by the file limit, without adding a new truncation policy.
        try records(w.contacts, "contacts", maximum: 10_000)
        try records(w.companies, "companies", maximum: 10_000)
        try records(w.opportunities, "opportunities", maximum: 10_000)
        try records(w.tasks, "tasks", maximum: 10_000)
        try records(w.notes, "notes", maximum: 10_000)
        try records(w.leads, "leads", maximum: 10_000)
        try records(w.signals, "signals", maximum: 10_000)
        try records(w.controlWard.mail, "mail", maximum: 10_000)
        try records(w.audits, "audits")
        try records(w.automationRules, "automation rules")
        try records(w.activity, "activity")
        try records(w.syncJobs, "sync jobs")
        try records(w.exposureFindings, "security findings")
        try records(w.savedViews, "saved views")
        try records(w.controlWard.projectLinks, "project links")
        try records(w.controlWard.captures, "capture receipts")
        try records(w.accountIntelligence.profiles, "account profiles")
        try records(w.accountIntelligence.assessments, "fit assessments")
        try records(w.accountIntelligence.events, "account events")
        try records(w.accountIntelligence.observations, "observation windows")
        try records(w.accountIntelligence.snapshots, "score snapshots")
        for lead in w.leads { try records(lead.history, "lead history") }
        for audit in w.audits { try records(audit.transcripts, "audit transcripts") }
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
