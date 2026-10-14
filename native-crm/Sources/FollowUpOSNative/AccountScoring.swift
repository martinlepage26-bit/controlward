import Foundation

enum AccountScoring {
    static let observationDays = 90.0
    static let freshnessDays = 7.0

    static func stage(_ score: Int?) -> String {
        guard let score else { return "Unknown" }
        switch score {
        case ..<20: return "Target"
        case 20..<50: return "Awareness"
        case 50..<70: return "Consideration"
        case 70..<86: return "Decision"
        default: return "Purchase"
        }
    }

    static func evaluate(company: Company, profile: GTMProfile, workspace: PersistentWorkspace, now: Date) -> GTMScoreSnapshot {
        let gtm = workspace.accountIntelligence
        let assessment = gtm.assessments.last { $0.companyID == company.id && $0.profileID == profile.id && $0.assessedAt <= now }
        let evidence = assessment?.evidence ?? Array(repeating: GTMFitEvidence(), count: 4)
        var fit = 0, coverage = 0
        for (entry, weight) in zip(evidence, GTMProfile.weights) where !entry.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if entry.result != .unknown { coverage += weight }
            if entry.result == .match { fit += weight }
        }
        let fitBand = coverage < 80 ? "Provisional" : fit >= 70 ? "Strong" : fit >= 40 ? "Moderate" : "Weak"
        let verified = AccountIdentity.isVerified(company, in: gtm, at: now)
        let identity = gtm.identities.last { $0.companyID == company.id && $0.reviewedAt <= now }
        let retracted = Set(gtm.retractions.filter { $0.retractedAt <= now }.map(\.eventID))
        let retractedActions = Set(gtm.events.filter { $0.profileID == profile.id && retracted.contains($0.id) }.map(\.actionKey))
        let cutoff = now.addingTimeInterval(-observationDays * 86400)
        var reasons: [String] = ["Fit \(fit)/100; evidence coverage \(coverage)%. Rules v1; not a conversion probability."]
        var candidates: [GTMEvent] = []
        for event in gtm.events where event.profileID == profile.id {
            let review = gtm.reviews.last { $0.eventID == event.id && $0.reviewedAt <= now }
            guard review?.companyID == company.id else { continue }
            guard !retractedActions.contains(event.actionKey), !event.isBotOrInternal, event.kind.parameters != nil,
                  event.receivedAt <= now, event.occurredAt <= now, event.occurredAt >= cutoff else { continue }
            candidates.append(event)
        }
        // Prefer the strongest classification of a shared action, then the freshest event.
        candidates.sort {
            let a = $0.kind.parameters!.weight, b = $1.kind.parameters!.weight
            if a != b { return a > b }
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var actions = Set<String>(), days = Set<String>()
        var familyTotals: [GTMEventKind: Double] = [:]
        var contributions: [GTMContribution] = []
        for event in candidates {
            let day = Int(floor(event.occurredAt.timeIntervalSince1970 / 86400))
            let dayKey = "\(event.kind.rawValue):\(day)"
            guard actions.insert(event.actionKey).inserted, days.insert(dayKey).inserted else { continue }
            let parameters = event.kind.parameters!
            let age = now.timeIntervalSince(event.occurredAt) / 86400
            let decayed = parameters.weight * pow(2, -age / parameters.halfLife)
            let points = max(0, min(decayed, parameters.cap - (familyTotals[event.kind] ?? 0)))
            familyTotals[event.kind, default: 0] += points
            if points > 0 { contributions.append(GTMContribution(eventID: event.id, kind: event.kind, points: points)) }
        }
        let observations = gtm.observations.filter {
            $0.companyID == company.id && $0.profileID == profile.id && $0.startsAt <= cutoff &&
            $0.throughAt <= now && now.timeIntervalSince($0.throughAt) <= freshnessDays * 86400
        }
        let intent: Int? = contributions.isEmpty && observations.isEmpty ? nil : Int(min(100, familyTotals.values.reduce(0, +)).rounded())
        let contributingIDs = Set(contributions.map(\.eventID))
        let freshEvents = candidates.filter { contributingIDs.contains($0.id) && now.timeIntervalSince($0.occurredAt) <= freshnessDays * 86400 }
        let fresh = !freshEvents.isEmpty || !observations.isEmpty
        let handRaise = freshEvents.contains { $0.kind == .handRaise }
        let suppressed = !(identity?.suppressionReason ?? "").isEmpty || !(assessment?.exclusionReason ?? "").isEmpty
        let openOpportunity = workspace.opportunities.contains { opportunity in
            guard !opportunity.stage.isClosed else { return false }
            if opportunity.companyID == company.id { return true }
            if let contactID = opportunity.contactID, workspace.contacts.contains(where: { $0.id == contactID && $0.companyID == company.id }) { return true }
            if let leadID = opportunity.leadID, workspace.leads.contains(where: { $0.id == leadID && $0.companyID == company.id }) { return true }
            return false
        }
        var queue: GTMReviewQueue = .observing
        if !verified { reasons.append("Account identity needs review, or company details changed.") }
        if intent == nil { reasons.append("Buyer activity is unknown. No validated activity or fresh 90-day observation window.") }
        if !fresh { reasons.append("No fresh evidence in the last 7 days. Historical activity does not authorize routing.") }
        if suppressed { reasons.append("Suppressed or excluded: \(identity?.suppressionReason ?? "") \(assessment?.exclusionReason ?? "")") }
        if openOpportunity { reasons.append("An open opportunity already exists; use its existing follow-up.") }
        if !verified || suppressed || openOpportunity { queue = .blocked }
        else if handRaise {
            queue = fitBand == "Strong" ? .salesReview : .handRaiseReview
            reasons.append("A validated recent request qualifies for immediate human review.")
        } else if fitBand == "Strong", fresh, (intent ?? 0) >= 70, Set(freshEvents.map(\.kind)).count >= 2 {
            let today = Int(floor(now.timeIntervalSince1970 / 86400))
            let previous = gtm.snapshots.last { $0.companyID == company.id && $0.profileID == profile.id && Int(floor($0.asOf.timeIntervalSince1970 / 86400)) == today - 1 }
            if let previous, previous.fitBand == "Strong", previous.identityVerified, previous.sourceFresh,
               (previous.intent ?? 0) >= 70, Set(previous.contributions.map(\.kind)).count >= 2, previous.queue != .blocked {
                queue = .salesReview
            } else { reasons.append("Save two consecutive daily eligible snapshots before ordinary activity-based routing.") }
        } else { reasons.append("Review needs a fresh validated request, or strong fit plus 70 activity points from two families.") }
        if coverage < 80 { reasons.append("Missing fit evidence stays unknown; it is not rescaled.") }
        reasons.append("\(contributions.count) distinct scored events; public listings and sent messages contribute no buyer activity.")
        return GTMScoreSnapshot(companyID: company.id, profileID: profile.id, asOf: now, assessmentID: assessment?.id,
                                fit: fit, coverage: coverage, fitBand: fitBand, intent: intent, stage: stage(intent),
                                identityVerified: verified, sourceFresh: fresh, contributions: contributions,
                                observationIDs: observations.map(\.id), reasons: reasons, queue: queue)
    }
}
