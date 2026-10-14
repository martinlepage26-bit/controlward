import Foundation

enum GTMEvents {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw GTMError.invalid(message) }
    }

    static func text(_ value: String, name: String, maximum: Int = 500) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try require(!result.isEmpty && result.count <= maximum, "\(name) is required and must be at most \(maximum) characters.")
        return result
    }

    static func reference(_ value: String) throws -> String {
        let result = try text(value, name: "Evidence reference", maximum: 1000)
        if result.lowercased().hasPrefix("http://") || result.lowercased().hasPrefix("https://") {
            guard var url = URLComponents(string: result), url.host != nil, url.user == nil, url.password == nil else {
                throw GTMError.invalid("Use an evidence URL without credentials.")
            }
            url.query = nil
            url.fragment = nil
            return url.string ?? result
        }
        return result
    }

    static func importBatch(_ batch: GTMImportBatch, profileID: UUID, into workspace: inout PersistentWorkspace, now: Date) throws -> Int {
        try require(batch.schemaVersion == 1, "Unsupported account-evidence import version.")
        try require(batch.accounts.count <= 100 && batch.events.count <= 1000, "Import at most 100 accounts and 1,000 events at once.")
        try require(workspace.accountIntelligence.profiles.contains { $0.id == profileID }, "Choose a saved offer first.")
        let source = try text(batch.source, name: "Source", maximum: 120)
        var accountMap: [String: UUID] = [:]
        var domains: [String: String] = [:]
        var names: [String: String] = [:]
        var externalIDs = Set<String>()
        for account in batch.accounts {
            let key = try text(account.externalID, name: "External account ID", maximum: 200)
            try require(externalIDs.insert(key).inserted, "Duplicate account IDs within the import.")
            let name = try text(account.name, name: "Account name", maximum: 200)
            let domain = AccountIdentity.domain(account.domain)
            try require(account.domain.isEmpty || domain != nil, "Use a valid business domain, or leave it blank for manual identity review.")
            domains[key] = domain ?? ""
            names[key] = name
            if let link = workspace.accountIntelligence.externalAccounts.first(where: { $0.source == source && $0.externalID == key }) {
                try require(workspace.companies.contains { $0.id == link.companyID }, "A previously imported account was deleted. Resolve it before replaying this source.")
                accountMap[key] = link.companyID
                continue
            }
            let matches = AccountIdentity.candidates(for: domain ?? "", companies: workspace.companies)
            if matches.count > 1 { continue } // Remains visibly unresolved. Never merge a shared domain.
            let company: Company
            if let match = matches.first, match.name.caseInsensitiveCompare(name) == .orderedSame { company = match }
            else {
                var created = Company()
                created.name = name
                created.domain = domain ?? ""
                created.createdAt = now.ISO8601Format()
                workspace.companies.append(created)
                company = created
            }
            accountMap[key] = company.id
            workspace.accountIntelligence.externalAccounts.append(GTMExternalAccount(source: source, externalID: key, companyID: company.id))
        }
        var added = 0
        for input in batch.events {
            let external = try text(input.accountExternalID, name: "Event account ID", maximum: 200)
            try require(domains[external] != nil, "Every event must reference an account included in this import.")
            let event = GTMEvent(profileID: profileID, source: source,
                                 sourceEventID: try text(input.sourceEventID, name: "Source event ID", maximum: 200),
                                 sourceAccountID: external, accountName: names[external] ?? "",
                                 actionKey: try text(input.actionKey, name: "Buyer action key", maximum: 200),
                                 candidateCompanyID: accountMap[external], domain: domains[external] ?? "", kind: input.kind,
                                 occurredAt: input.occurredAt, receivedAt: now,
                                 reference: try reference(input.reference), isBotOrInternal: input.isBotOrInternal)
            try require(event.occurredAt.timeIntervalSince1970.isFinite, "Event time is invalid.")
            if let previous = workspace.accountIntelligence.events.first(where: { $0.profileID == profileID && $0.source == source && $0.sourceEventID == event.sourceEventID }) {
                try require(previous.sourceAccountID == event.sourceAccountID && previous.actionKey == event.actionKey && previous.kind == event.kind && previous.occurredAt == event.occurredAt &&
                            previous.reference == event.reference && previous.domain == event.domain && previous.isBotOrInternal == event.isBotOrInternal,
                            "An existing event ID has different content. Retract the original and use a new source event ID.")
                continue
            }
            workspace.accountIntelligence.events.append(event)
            added += 1
        }
        return added
    }
}

@MainActor
extension AppStore {
    var gtm: GTMWorkspace { workspace.accountIntelligence }

    @discardableResult
    func createGTMProfile(name: String, criteria: [String], now: Date = .now) throws -> UUID {
        try GTMEvents.require(criteria.count == 4, "Define all four fit criteria.")
        let profile = GTMProfile(name: try GTMEvents.text(name, name: "Offer name", maximum: 120),
                                 criteria: try criteria.map { try GTMEvents.text($0, name: "Fit criterion") }, createdAt: now)
        try commitGTM { $0.accountIntelligence.profiles.append(profile) }
        return profile.id
    }

    func reviewGTMIdentity(companyID: UUID, reason: String, suppression: String, now: Date = .now) throws {
        guard let company = companies.first(where: { $0.id == companyID }) else { throw GTMError.invalid("Account no longer exists.") }
        let review = GTMIdentityReview(companyID: companyID, companyName: company.name, domain: AccountIdentity.domain(company.domain),
                                      reason: try GTMEvents.text(reason, name: "Identity evidence"), suppressionReason: String(suppression.prefix(500)), reviewedAt: now)
        try commitGTM { $0.accountIntelligence.identities.append(review) }
    }

    func saveGTMFit(_ assessment: GTMFitAssessment) throws {
        try GTMEvents.require(companies.contains { $0.id == assessment.companyID } && gtm.profiles.contains { $0.id == assessment.profileID }, "Account or offer no longer exists.")
        try GTMEvents.require(assessment.evidence.count == 4, "Assess all four criteria, using Unknown when evidence is missing.")
        var cleaned = assessment
        for index in cleaned.evidence.indices {
            if cleaned.evidence[index].result != .unknown {
                cleaned.evidence[index].reference = try GTMEvents.reference(cleaned.evidence[index].reference)
            }
        }
        cleaned.exclusionReason = String(cleaned.exclusionReason.prefix(500))
        try commitGTM { $0.accountIntelligence.assessments.append(cleaned) }
    }

    @discardableResult
    func importGTM(data: Data, profileID: UUID, now: Date = .now) throws -> Int {
        try GTMEvents.require(data.count <= 2_000_000, "Import files must be smaller than 2 MB.")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let batch = try decoder.decode(GTMImportBatch.self, from: data)
        var added = 0
        try commitGTM { added = try GTMEvents.importBatch(batch, profileID: profileID, into: &$0, now: now) }
        return added
    }

    func reviewGTMEvent(eventID: UUID, companyID: UUID, reason: String, now: Date = .now) throws {
        guard let event = gtm.events.first(where: { $0.id == eventID }) else { throw GTMError.invalid("Event no longer exists.") }
        try GTMEvents.require(event.occurredAt <= now && event.receivedAt <= now, "Future-dated evidence cannot be validated yet.")
        try GTMEvents.require(!gtm.retractions.contains { $0.eventID == eventID }, "Retracted evidence cannot be restored by review.")
        try GTMEvents.require(!event.isBotOrInternal && event.kind.parameters != nil, "Research, outbound and internal traffic cannot become buyer activity.")
        try GTMEvents.require(companies.contains { $0.id == companyID }, "Select an existing account.")
        let review = GTMEventReview(eventID: eventID, companyID: companyID, reason: try GTMEvents.text(reason, name: "Validation evidence"), reviewedAt: now)
        try commitGTM { $0.accountIntelligence.reviews.append(review) }
    }

    func recordGTMEvent(companyID: UUID, profileID: UUID, kind: GTMEventKind, actionKey: String, occurredAt: Date, reference: String, now: Date = .now) throws {
        try GTMEvents.require(companies.contains { $0.id == companyID } && gtm.profiles.contains { $0.id == profileID }, "Account or offer no longer exists.")
        try GTMEvents.require(kind.parameters != nil && occurredAt <= now, "Record a past, verified buyer action.")
        let proof = try GTMEvents.reference(reference)
        let event = GTMEvent(profileID: profileID, source: "manual", sourceEventID: UUID().uuidString,
                             sourceAccountID: companyID.uuidString, accountName: companies.first { $0.id == companyID }?.name ?? "",
                             actionKey: try GTMEvents.text(actionKey, name: "Buyer action key", maximum: 200), candidateCompanyID: companyID,
                             domain: companies.first { $0.id == companyID }?.domain ?? "", kind: kind, occurredAt: occurredAt,
                             receivedAt: now, reference: proof, isBotOrInternal: false)
        try commitGTM {
            $0.accountIntelligence.events.append(event)
            $0.accountIntelligence.reviews.append(GTMEventReview(eventID: event.id, companyID: companyID, reason: proof, reviewedAt: now))
        }
    }

    func retractGTMEvent(eventID: UUID, reason: String, now: Date = .now) throws {
        try GTMEvents.require(gtm.events.contains { $0.id == eventID }, "Event no longer exists.")
        if gtm.retractions.contains(where: { $0.eventID == eventID }) { return }
        let retraction = GTMRetraction(eventID: eventID, reason: try GTMEvents.text(reason, name: "Retraction reason"), retractedAt: now)
        try commitGTM { $0.accountIntelligence.retractions.append(retraction) }
    }

    func saveGTMObservation(_ observation: GTMObservation, now: Date = .now) throws {
        try GTMEvents.require(companies.contains { $0.id == observation.companyID } && gtm.profiles.contains { $0.id == observation.profileID }, "Account or offer no longer exists.")
        try GTMEvents.require(observation.startsAt <= observation.throughAt && observation.throughAt <= now, "Observation window must end in the past and start before it ends.")
        var clean = observation
        clean.source = try GTMEvents.text(clean.source, name: "Observed source", maximum: 120)
        clean.reference = try GTMEvents.reference(clean.reference)
        try commitGTM { $0.accountIntelligence.observations.append(clean) }
    }

    func gtmPreview(profileID: UUID, now: Date = .now) -> [GTMScoreSnapshot] {
        guard let profile = gtm.profiles.first(where: { $0.id == profileID }) else { return [] }
        return companies.map { AccountScoring.evaluate(company: $0, profile: profile, workspace: workspace, now: now) }
    }

    func saveGTMSnapshots(profileID: UUID, now: Date = .now) throws {
        let snapshots = gtmPreview(profileID: profileID, now: now)
        try GTMEvents.require(!snapshots.isEmpty, "Add an account and choose an offer first.")
        try commitGTM { $0.accountIntelligence.snapshots.append(contentsOf: snapshots) }
    }

    @discardableResult
    func createGTMReviewTasks(profileID: UUID, now: Date = .now) throws -> Int {
        guard let profile = gtm.profiles.first(where: { $0.id == profileID }) else { throw GTMError.invalid("Choose an offer first.") }
        var count = 0
        try commitGTM { workspace in
            for company in workspace.companies {
                let snapshot = AccountScoring.evaluate(company: company, profile: profile, workspace: workspace, now: now)
                guard snapshot.queue.eligible, !workspace.accountIntelligence.taskLinks.contains(where: { $0.companyID == company.id && $0.profileID == profileID }) else { continue }
                var task = CRMTask()
                task.title = "Review \(company.name) · \(profile.name)"
                task.companyID = company.id
                task.details = "\(snapshot.queue.label). Local account review; no outreach sent.\n" + snapshot.reasons.joined(separator: "\n")
                task.createdAt = now.ISO8601Format()
                task.dueDate = CalendarCRM.dayString(now)
                workspace.tasks.append(task)
                workspace.accountIntelligence.snapshots.append(snapshot)
                workspace.accountIntelligence.taskLinks.append(GTMTaskLink(companyID: company.id, profileID: profileID, taskID: task.id, snapshotID: snapshot.id, createdAt: now))
                count += 1
            }
        }
        return count
    }
}
