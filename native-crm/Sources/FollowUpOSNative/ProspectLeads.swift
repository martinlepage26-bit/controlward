import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ControlWard's own Leads list for prospects. It is a local JSON file; nothing is filed in Project Control.
final class ProspectLeadsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProspectRecord] = []
    let fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), let records = try? JSONDecoder.iso.decode([ProspectRecord].self, from: data) {
            stored = records
        }
    }

    var records: [ProspectRecord] { lock.withLock { stored } }

    func replace(_ records: [ProspectRecord]) {
        lock.withLock {
            stored = records
            if let fileURL, let data = try? JSONEncoder.iso.encode(records) {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}

/// Pulls prospects into the Leads list (S3-R2, S3-R4, S3-R5).
enum ProspectIngest {
    struct Result: Equatable, Sendable {
        var added: [String] = []
        var merged: [String] = []
        var rejected: [String: String] = [:]
        var held: [String] = []
    }

    /// Dedupe key order is source id, then email, then phone (the existing lead rule).
    static func duplicate(of record: ProspectRecord, in existing: [ProspectRecord]) -> ProspectRecord? {
        if let match = existing.first(where: { $0.id == record.id }) { return match }
        if let email = record.email.map(MailAddress.bare), !email.isEmpty,
           let match = existing.first(where: { $0.email.map(MailAddress.bare) == email }) { return match }
        if let phone = record.phone.map(digits), phone.count >= 10,
           let match = existing.first(where: { $0.phone.map(digits) == phone }) { return match }
        if let domain = ProspectIdentity.normalizedDomain(record.businessDomain),
           let match = existing.first(where: { ProspectIdentity.normalizedDomain($0.businessDomain) == domain }) { return match }
        return nil
    }

    static func digits(_ text: String) -> String {
        let only = text.filter(\.isNumber)
        return only.count == 11 && only.hasPrefix("1") ? String(only.dropFirst()) : only
    }

    /// Local only. `egress` exists so tests can prove ingest sends nothing: production passes nil, and tests
    /// pass a recording transport that must see 0 requests (no `/api/items`, no other host).
    static func ingest(_ incoming: [ProspectRecord], into store: ProspectLeadsStore, config: ICPConfig, now: Date,
                       audit: any CWAuditSink, egress: (any LeadTransport)? = nil) async -> Result {
        var result = Result()
        var records = store.records
        for var record in incoming {
            let missing = LeadDefinition.sourceEvidence(record)
            if !missing.isEmpty { result.rejected[record.id] = missing.joined(separator: ", "); continue }
            let verdict = LeadDefinition.evaluate(record, config: config, now: now)
            record.status = verdict.status
            record.reasons = verdict.reasons
            record.risk = LeadDefinition.riskLine(record)
            if verdict.status == .conflictReview { result.held.append(record.id) }
            if let existing = duplicate(of: record, in: records), let index = records.firstIndex(of: existing) {
                records[index] = merge(existing, record)
                result.merged.append(existing.id)
            } else {
                records.append(record)
                result.added.append(record.id)
            }
        }
        store.replace(records)
        audit.write(CWAuditLine(ts: now, surface: "leads", action: "ingest", register: "-", target: "leads-list", source: "controlward",
                                result: result.rejected.isEmpty ? "ok" : "partial:rejected-\(result.rejected.count)",
                                receipt: "added-\(result.added.count)-merged-\(result.merged.count)"))
        _ = egress
        return result
    }

    private static func merge(_ old: ProspectRecord, _ new: ProspectRecord) -> ProspectRecord {
        var merged = new
        merged.id = old.id
        if merged.email == nil { merged.email = old.email }
        if merged.phone == nil { merged.phone = old.phone }
        return merged
    }

    /// What the Leads list shows: Ready and Fix. Conflict-review records are shown to Martin separately, never listed.
    static func listed(_ records: [ProspectRecord]) -> [ProspectRecord] {
        records.filter { $0.status == .ready || $0.status == .fix }
    }

    static func heldForMartin(_ records: [ProspectRecord]) -> [ProspectRecord] {
        records.filter { $0.status == .conflictReview }
    }
}

/// Text shown for one prospect row. Any RBQ-derived data carries its credit line (S3-R15).
enum ProspectDisplay {
    static func attribution(for record: ProspectRecord, config: ICPConfig) -> String? {
        guard record.dataAttribution != nil || !record.rbqCategories.isEmpty else { return nil }
        return RBQOpenData.source(config)?.attribution ?? "Source: RBQ / Données Québec, CC BY 4.0"
    }

    static func lines(for record: ProspectRecord, config: ICPConfig) -> [String] {
        var lines = ["\(record.organisation) · \(record.segment ?? "no segment") · \(record.status.rawValue)"]
        if let contact = record.contact { lines.append("\(contact.name)\(contact.title.map { ", \($0)" } ?? "") (\(contact.titleSource?.rawValue ?? "no title source"))") }
        if let trigger = record.trigger { lines.append("Trigger (\(trigger.state.rawValue)): \(trigger.summary)") }
        if let fit = record.fit { lines.append("Fit: \(fit)") }
        if let research = record.research {
            let facts = research.observedFacts
            var seen: [String] = []
            if !facts.serviceCategories.isEmpty { seen.append("services: \(facts.serviceCategories.joined(separator: ", "))") }
            if !facts.serviceAreas.isEmpty { seen.append("areas: \(facts.serviceAreas.joined(separator: ", "))") }
            if !facts.languagesSeen.isEmpty { seen.append("languages: \(facts.languagesSeen.joined(separator: "/"))") }
            if let contact = facts.contactPageURL { seen.append("contact page: \(contact)") }
            seen.append("booking: \(facts.bookingURL ?? "none seen")")
            lines.append("Observed: \(seen.joined(separator: " · "))")
            let assessment = research.assessment
            if assessment.requiresManualReview {
                lines.append("Assessment: needs manual review\(assessment.unknowns.isEmpty ? "" : " (unknown: \(assessment.unknowns.joined(separator: ", ")))")")
            } else if let offer = assessment.potentialOffer {
                lines.append("Assessment: \(offer) · \(assessment.supportingEvidence.count) evidence excerpt(s)")
            }
        }
        lines.append("Risk: \(record.risk ?? LeadDefinition.riskLine(record))")
        if !record.reasons.isEmpty { lines.append("Fix: \(record.reasons.joined(separator: "; "))") }
        if !record.rbqCategories.isEmpty { lines.append("RBQ licence sub-categories: \(record.rbqCategories.joined(separator: ", "))") }
        if let note = record.linkedinNote { lines.append("LinkedIn: \(note)") }
        if let source = record.sourceURL, let fetched = record.fetchedAt { lines.append("Evidence: \(source) · \(CWAuditLine.timestamp(fetched))") }
        if let attribution = attribution(for: record, config: config) { lines.append(attribution) }
        return lines
    }
}

/// The rule `/v1/leads/push` applies (mirrored in pharos-api): only test leads and inbound form leads (S3-R16).
enum LeadPushPolicy {
    /// Same rule as pharos-api (Argus red 11): a test lead needs a real JSON `true`, not 1 or "true"; an inbound lead
    /// needs a form source that is not blank once trimmed.
    static func check(_ payload: [String: Any]) -> LeadPipelineRefusal? {
        if isJSONTrue(payload["test"]) { return nil }
        if let provenance = payload["provenance"] as? [String: Any], provenance["kind"] as? String == "inbound_form",
           let form = provenance["form_source"] as? String, !form.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return LeadPipelineRefusal(code: "refused:push-not-inbound")
    }

    /// True only for a Swift `true` or a boolean decoded from JSON. NSNumber(1) bridges to Bool in Foundation, so the
    /// boolean class is checked (CFBoolean on macOS, __NSCFBoolean in swift-corelibs-foundation).
    static func isJSONTrue(_ value: Any?) -> Bool {
        guard let value else { return false }
        if type(of: value) == Bool.self { return value as? Bool == true }
        guard let number = value as? NSNumber else { return false }
        #if canImport(Darwin)
        return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
        #else
        return String(describing: type(of: number)) == "__NSCFBoolean" && number.boolValue
        #endif
    }
}
