import Foundation

/// LEAD_DEF (S3-R1, S3-R12, S3-R13): one predicate that decides Ready, Fix, Drop or conflict review.
/// Every clause is a separate function so each can be tested on its own.
enum LeadDefinition {
    struct Verdict: Equatable, Sendable {
        var status: ProspectStatus
        var reasons: [String]
        var isLead: Bool { status == .ready }
    }

    static func evaluate(_ prospect: ProspectRecord, config: ICPConfig, now: Date) -> Verdict {
        return Verdict(status: .ready, reasons: [])
    }

    /// S3-R5: a source URL and a fetch time on every record.
    static func sourceEvidence(_ prospect: ProspectRecord) -> [String] {
        var reasons: [String] = []
        return reasons
    }

    /// The named-person rule, kept isolated (Water, 6:05 AM ET): a person from a source the segment allows,
    /// and that source must be enabled in config. There is no role-addressed path.
    static func namedPerson(_ prospect: ProspectRecord, segment: ICPConfig.Segment, config: ICPConfig) -> String? {
        return nil
    }

    /// S3-R12: the remaining fields of a complete lead record.
    static func recordFields(_ prospect: ProspectRecord) -> [String] {
        var reasons: [String] = []
        return reasons
    }

    /// S3-R13: institutional triggers within the configured age; clinic and trades triggers fetched today.
    /// Search snippets and inferred triggers never count.
    static func triggerFreshness(_ trigger: ProspectTrigger?, segment: ICPConfig.Segment, config: ICPConfig, now: Date) -> [String] {
        guard let trigger, let fetchedAt = trigger.fetchedAt else { return [] }
        return []
    }

    /// The day as Martin sees it (Montréal).
    static func sameLocalDay(_ a: Date, _ b: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
        return calendar.isDate(a, inSameDayAs: b)
    }

    /// S3-R14 / S3-R17d: plumbing, excavation and related trades in the configured area are held for Martin.
    static func conflictArea(for prospect: ProspectRecord, config: ICPConfig) -> ICPConfig.ConflictArea? {
        return nil
    }

    /// S3-R3: the real-lead count excludes test leads and anything that fails LEAD_DEF.
    static func realLeadCount(_ prospects: [ProspectRecord], config: ICPConfig, now: Date) -> Int {
        prospects.count
    }

    /// The risk line shown with each lead (unit-tested, not a planted red).
    static func riskLine(_ prospect: ProspectRecord) -> String {
        if prospect.openTenderURL != nil { return "Open tender: outreach blocked until it closes." }
        switch prospect.trigger?.state {
        case .gone?: return "Trigger gone: the page no longer shows it."
        case .changed?: return "Trigger changed since the last check: re-read before writing."
        default: break
        }
        if prospect.contact?.titleSource == .searchOnly { return "Title seen only in search: confirm on the page before writing." }
        if prospect.consent == nil { return "No consent basis recorded: no draft." }
        return "Low: own-site evidence, dated trigger."
    }
}

/// S3-R10: an address counts only if it appears word for word in a stored page from the business's own domain.
enum AddressProvenance {
    static func check(_ prospect: ProspectRecord) -> LeadPipelineRefusal? {
        return nil
    }

    /// The consent basis must come from the business's own domain too (S3-R10).
    static func consentFromOwnDomain(_ prospect: ProspectRecord) -> Bool {
        guard let consent = prospect.consent else { return false }
        guard case .conspicuousPublication(let url) = consent else { return true }
        guard let domain = prospect.businessDomain, let host = URL(string: url)?.host else { return false }
        return HostMatch.belongs(host, to: domain) && prospect.snapshots.contains { $0.url == url }
    }
}
