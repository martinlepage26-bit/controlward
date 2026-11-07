import Foundation

/// Local record deletion unlinks live relationships. History, imported evidence, exclusion
/// policy and task/capture receipts remain; no provider or project register is modified.
enum RecordDeletion {
    enum Kind: String, CaseIterable {
        case leads, contacts, companies, opportunities, tasks, notes
        var label: String {
            switch self {
            case .leads: "Lead"
            case .contacts: "Contact"
            case .companies: "Company"
            case .opportunities: "Opportunity"
            case .tasks: "Task"
            case .notes: "Note"
            }
        }
    }

    static func contains(_ id: UUID, kind: Kind, in w: PersistentWorkspace) -> Bool {
        switch kind {
        case .leads: w.leads.contains { $0.id == id }
        case .contacts: w.contacts.contains { $0.id == id }
        case .companies: w.companies.contains { $0.id == id }
        case .opportunities: w.opportunities.contains { $0.id == id }
        case .tasks: w.tasks.contains { $0.id == id }
        case .notes: w.notes.contains { $0.id == id }
        }
    }

    static func apply(_ id: UUID, kind: Kind, to w: inout PersistentWorkspace) {
        guard contains(id, kind: kind, in: w) else { return }
        switch kind {
        case .contacts:
            w.contacts.removeAll { $0.id == id }
            for i in w.leads.indices where w.leads[i].contactID == id { w.leads[i].contactID = nil }
            for i in w.opportunities.indices where w.opportunities[i].contactID == id { w.opportunities[i].contactID = nil }
            for i in w.tasks.indices where w.tasks[i].contactID == id { w.tasks[i].contactID = nil }
            for i in w.notes.indices where w.notes[i].contactID == id { w.notes[i].contactID = nil }
            for i in w.signals.indices where w.signals[i].contactID == id { w.signals[i].contactID = nil }
            for i in w.audits.indices where w.audits[i].contactID == id { w.audits[i].contactID = nil }
            for i in w.controlWard.mail.indices where w.controlWard.mail[i].contactID == id { w.controlWard.mail[i].contactID = nil }
        case .companies:
            w.companies.removeAll { $0.id == id }
            for i in w.leads.indices where w.leads[i].companyID == id { w.leads[i].companyID = nil }
            for i in w.contacts.indices where w.contacts[i].companyID == id { w.contacts[i].companyID = nil }
            for i in w.opportunities.indices where w.opportunities[i].companyID == id { w.opportunities[i].companyID = nil }
            for i in w.tasks.indices where w.tasks[i].companyID == id { w.tasks[i].companyID = nil }
            for i in w.notes.indices where w.notes[i].companyID == id { w.notes[i].companyID = nil }
            for i in w.signals.indices where w.signals[i].companyID == id { w.signals[i].companyID = nil }
            for i in w.audits.indices where w.audits[i].companyID == id { w.audits[i].companyID = nil }
            for i in w.controlWard.mail.indices where w.controlWard.mail[i].companyID == id { w.controlWard.mail[i].companyID = nil }
        case .opportunities:
            w.opportunities.removeAll { $0.id == id }
            for i in w.tasks.indices where w.tasks[i].opportunityID == id { w.tasks[i].opportunityID = nil }
            for i in w.notes.indices where w.notes[i].opportunityID == id { w.notes[i].opportunityID = nil }
        case .tasks:
            guard let task = w.tasks.first(where: { $0.id == id }) else { return }
            w.tasks.removeAll { $0.id == id }
            for i in w.leads.indices {
                let lead = w.leads[i]
                let lastLegacyAction = lead.followUpTaskID == nil && task.leadID == lead.id
                    && task.title == "Follow up with \(lead.name)"
                    && !w.tasks.contains { $0.leadID == lead.id && $0.title == task.title }
                if lead.followUpTaskID == id || lastLegacyAction {
                    w.leads[i].followUpTaskID = nil
                    w.leads[i].nextFollowUp = nil
                }
            }
            // Mail, GTM and remediation task receipts are intentional tombstones:
            // a repeated import/review must not recreate deliberately deleted work.
        case .notes:
            w.notes.removeAll { $0.id == id }
        case .leads:
            guard let lead = w.leads.first(where: { $0.id == id }) else { return }
            for i in w.tasks.indices where w.tasks[i].id == lead.followUpTaskID ||
                (w.tasks[i].leadID == id && w.tasks[i].title == "Follow up with \(lead.name)") {
                w.tasks[i].status = .done; w.tasks[i].reminderAt = nil
            }
            w.leads.removeAll { $0.id == id }
            for i in w.contacts.indices where w.contacts[i].leadID == id { w.contacts[i].leadID = nil }
            for i in w.opportunities.indices where w.opportunities[i].leadID == id { w.opportunities[i].leadID = nil }
            for i in w.tasks.indices where w.tasks[i].leadID == id { w.tasks[i].leadID = nil }
            for i in w.signals.indices where w.signals[i].leadID == id { w.signals[i].leadID = nil }
            for i in w.audits.indices where w.audits[i].leadID == id { w.audits[i].leadID = nil }
            if let source = lead.sourceID, source.hasPrefix("leadgen:"), !w.dismissedLeadSources.contains(source) {
                w.dismissedLeadSources.append(source)
            }
        }
        let key = "\(kind.rawValue):\(id.uuidString.lowercased())"
        w.controlWard.projectLinks.removeAll { $0.recordKey == key }
    }
}
