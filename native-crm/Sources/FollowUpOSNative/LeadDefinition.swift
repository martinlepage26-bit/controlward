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
        guard let segment = config.segment(prospect.segment) else {
            return Verdict(status: .drop, reasons: ["no matching segment"])
        }
        if let area = conflictArea(for: prospect, config: config) {
            return Verdict(status: .conflictReview, reasons: ["conflict area: \(area.id)"])
        }
        if let area = rbqUnchecked(prospect, config: config) {
            return Verdict(status: .conflictReview, reasons: ["conflict area: \(area.id) (RBQ check: \(prospect.rbqCheck ?? "not run"))"])
        }
        var reasons: [String] = []
        reasons += sourceEvidence(prospect)
        if let reason = namedPerson(prospect, segment: segment, config: config) { reasons.append(reason) }
        reasons += recordFields(prospect)
        reasons += triggerFreshness(prospect.trigger, segment: segment, config: config, now: now)
        if prospect.openTenderURL != nil { reasons.append("open tender") }
        return Verdict(status: reasons.isEmpty ? .ready : .fix, reasons: reasons)
    }

    /// S3-R5: a source URL and a fetch time on every record.
    static func sourceEvidence(_ prospect: ProspectRecord) -> [String] {
        var reasons: [String] = []
        if (prospect.sourceURL ?? "").isEmpty || URL(string: prospect.sourceURL ?? "")?.host == nil { reasons.append("no source URL") }
        if prospect.fetchedAt == nil { reasons.append("no fetch time") }
        return reasons
    }

    /// The named-person rule, kept isolated (Water, 6:05 AM ET): a person from a source the segment allows,
    /// and that source must be enabled in config. There is no role-addressed path.
    static func namedPerson(_ prospect: ProspectRecord, segment: ICPConfig.Segment, config: ICPConfig) -> String? {
        guard let contact = prospect.contact,
              contact.name.split(separator: " ").count >= 2 else { return "no named person" }
        guard segment.allowedContactSources.contains(contact.source.rawValue) else { return "no named person" }
        if contact.source != .ownSite {
            let disabled = config.allowlist.disabledSources.first { $0.id == contact.source.rawValue }
            if disabled?.enabled != true { return "no named person" }
        }
        return nil
    }

    /// S3-R12: the remaining fields of a complete lead record.
    static func recordFields(_ prospect: ProspectRecord) -> [String] {
        var reasons: [String] = []
        if prospect.contact?.titleSource == nil { reasons.append("no title source") }
        if prospect.trigger?.url == nil || prospect.trigger?.fetchedAt == nil { reasons.append("no trigger URL with fetch time") }
        if (prospect.fit ?? "").trimmingCharacters(in: .whitespaces).isEmpty { reasons.append("no fit line") }
        if prospect.route == nil || prospect.route?.value.isEmpty == true { reasons.append("no public contact route") }
        return reasons
    }

    /// S3-R13: institutional triggers within the configured age; clinic and trades triggers fetched today.
    /// Search snippets and inferred triggers never count.
    static func triggerFreshness(_ trigger: ProspectTrigger?, segment: ICPConfig.Segment, config: ICPConfig, now: Date) -> [String] {
        guard let trigger, let fetchedAt = trigger.fetchedAt else { return [] }
        if trigger.origin == .searchSnippet || trigger.origin == .inferred { return ["trigger is a \(trigger.origin.rawValue)"] }
        if !segment.triggers.contains(trigger.kind) { return ["trigger kind not allowed for segment"] }
        if trigger.state == .gone { return ["trigger gone"] }
        guard let rule = config.triggerRules[segment.triggerRule] else { return ["unknown trigger rule"] }
        if rule.maxFetchAgeDays == 0 {
            if !sameLocalDay(fetchedAt, now) { return ["stale trigger"] }
        } else if now.timeIntervalSince(fetchedAt) > Double(rule.maxFetchAgeDays) * 86_400 {
            return ["stale trigger"]
        }
        if trigger.kind == "job_posting", let limit = rule.jobPostingMaxAgeDays {
            guard let published = trigger.publishedAt else { return ["job posting without a date"] }
            if now.timeIntervalSince(published) > Double(limit) * 86_400 { return ["stale trigger"] }
        }
        return []
    }

    /// The day as Martin sees it (Montréal).
    static func sameLocalDay(_ a: Date, _ b: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
        return calendar.isDate(a, inSameDayAs: b)
    }

    /// Argus must-fix 1 (fail closed): a segment listed in an area's `rbq_required_segments` is held unless the RBQ lookup ran and
    /// matched a licence. No file, an unreadable file, a parse error or no match all go to conflict review, never to Ready.
    static func rbqUnchecked(_ prospect: ProspectRecord, config: ICPConfig) -> ICPConfig.ConflictArea? {
        guard prospect.rbqCheck != "matched", let segment = prospect.segment else { return nil }
        return config.conflictAreas.first { ($0.rbqRequiredSegments ?? []).contains(segment) }
    }

    /// S3-R14 / S3-R17d: plumbing, excavation and related trades in the configured area are held for Martin. RBQ licences hold on
    /// exact sub-category codes from config (one JSON record per licence), never on words.
    static func conflictArea(for prospect: ProspectRecord, config: ICPConfig) -> ICPConfig.ConflictArea? {
        let haystack = ([prospect.organisation] + prospect.osmTags + prospect.snapshots.prefix(1).map(\.text)).joined(separator: " ").lowercased()
        return config.conflictAreas.first { area in
            area.osmSelectors.contains { prospect.osmTags.contains($0) }
                || area.keywords.contains { haystack.contains($0.lowercased()) }
                || !rbqHeldCodes(prospect.rbqCategories, area: area).isEmpty
        }
    }

    /// The listed RBQ codes that hold a licence with these sub-categories (also used by bin/prove-rbq-hold, so the proof counts
    /// exactly what the app holds).
    static func rbqHeldCodes(_ licenceCodes: [String], area: ICPConfig.ConflictArea) -> [String] {
        let codes = Set(licenceCodes.map(RBQOpenData.normalizeCode))
        return (area.rbqSubcategoryCodes ?? []).map(RBQOpenData.normalizeCode).filter { code in
            guard codes.contains(code) else { return false }
            // Water 7:20 / 7:26 AM ET (Air's map 10c): a code with a condition does not hold a licence that carries the whole
            // configured bundle or any code with a configured prefix. The codes and prefixes come from icp.json only.
            for condition in area.rbqCodeConditions ?? [] where RBQOpenData.normalizeCode(condition.code) == code {
                let bundle = condition.notHeldIfAllOf.map(RBQOpenData.normalizeCode)
                if !bundle.isEmpty && bundle.allSatisfy(codes.contains) { return false }
                let prefixes = condition.notHeldIfAnyCodeStartsWith.map(RBQOpenData.normalizeCode).filter { !$0.isEmpty }
                if codes.contains(where: { held in prefixes.contains { held.hasPrefix($0) } }) { return false }
            }
            return true
        }
    }

    /// S3-R3: the real-lead count excludes test leads and anything that fails LEAD_DEF.
    static func realLeadCount(_ prospects: [ProspectRecord], config: ICPConfig, now: Date) -> Int {
        prospects.filter { !$0.isTest && $0.provenance != .test && evaluate($0, config: config, now: now).isLead }.count
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
        let refusal = LeadPipelineRefusal(code: "refused:address-provenance")
        guard let address = prospect.address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty,
              prospect.addressSource == .ownSite,
              let domain = prospect.businessDomain,
              let sourceURL = prospect.addressSourceURL, let sourceHost = URL(string: sourceURL)?.host,
              HostMatch.belongs(sourceHost, to: domain) else { return refusal }
        // The contact route must also come from the business's own site: never an RBQ Courriel or phone.
        if let route = prospect.route {
            guard route.source == .ownSite, let routeHost = URL(string: route.sourceURL)?.host,
                  HostMatch.belongs(routeHost, to: domain) else { return refusal }
        }
        let found = prospect.snapshots.contains { snapshot in
            snapshot.url == sourceURL && HostMatch.belongs(snapshot.host, to: domain) && snapshot.text.contains(address)
        }
        return found ? nil : refusal
    }

    /// The consent basis must come from the business's own domain too (S3-R10).
    static func consentFromOwnDomain(_ prospect: ProspectRecord) -> Bool {
        guard let consent = prospect.consent else { return false }
        guard case .conspicuousPublication(let url) = consent else { return true }
        guard let domain = prospect.businessDomain, let host = URL(string: url)?.host else { return false }
        return HostMatch.belongs(host, to: domain) && prospect.snapshots.contains { $0.url == url }
    }
}
