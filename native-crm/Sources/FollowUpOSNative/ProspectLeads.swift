import Foundation
import Darwin
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

    func snapshot() throws -> [ProspectRecord] {
        try lock.withLock {
            guard let fileURL else { return stored }
            return try withFileLock(fileURL) {
                guard FileManager.default.fileExists(atPath: fileURL.path) else { return stored }
                let data = try Data(contentsOf: fileURL)
                return try JSONDecoder.iso.decode([ProspectRecord].self, from: data)
            }
        }
    }

    /// Reloads disk under a per-store cross-process lock, mutates, and atomically persists. A malformed existing file or a
    /// failed write is an error; it is never replaced with an empty register.
    @discardableResult
    func transaction<T>(_ mutation: (inout [ProspectRecord]) throws -> T) throws -> T {
        try lock.withLock {
            guard let fileURL else { return try mutation(&stored) }
            return try withFileLock(fileURL) {
                var fresh = stored
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    fresh = try JSONDecoder.iso.decode([ProspectRecord].self, from: Data(contentsOf: fileURL))
                }
                let result = try mutation(&fresh)
                try SecureFiles.writePrivate(JSONEncoder.iso.encode(fresh), to: fileURL)
                stored = fresh
                return result
            }
        }
    }

    func replace(_ records: [ProspectRecord]) {
        lock.withLock {
            stored = records
            if let fileURL, let data = try? JSONEncoder.iso.encode(records) {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func withFileLock<T>(_ fileURL: URL, _ body: () throws -> T) throws -> T {
        try SecureFiles.ensurePrivateDirectory(fileURL.deletingLastPathComponent())
        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }
}

/// Pulls prospects into the Leads list (S3-R2, S3-R4, S3-R5).
enum ProspectIngest {
    struct DuplicateApproval: Sendable {
        var action: String
        var expectedID: String?
    }

    struct Result: Equatable, Sendable {
        var added: [String] = []
        var merged: [String] = []
        var rejected: [String: String] = [:]
        var held: [String] = []
        var storageError: String?
    }

    /// Dedupe key order is source id, then email, then phone (the existing lead rule).
    /// LIVE-R6: an email, phone or domain match only merges records of the same organisation, so two prospects on
    /// different own domains that share a line (a switchboard, a provincial number) never merge into one id.
    static func duplicate(of record: ProspectRecord, in existing: [ProspectRecord]) -> ProspectRecord? {
        if let match = existing.first(where: { $0.id == record.id }) { return match }
        let candidates = existing.filter { sameOwnDomain($0, record) }
        if let email = record.email.map(MailAddress.bare), !email.isEmpty,
           let match = candidates.first(where: { $0.email.map(MailAddress.bare) == email }) { return match }
        if let phone = record.phone.map(digits), phone.count >= 10,
           let match = candidates.first(where: { $0.phone.map(digits) == phone }) { return match }
        if let domain = ProspectIdentity.normalizedDomain(record.businessDomain),
           let match = existing.first(where: { ProspectIdentity.normalizedDomain($0.businessDomain) == domain }) { return match }
        return nil
    }

    static func sameOwnDomain(_ a: ProspectRecord, _ b: ProspectRecord) -> Bool {
        guard let left = ProspectIdentity.normalizedDomain(a.businessDomain), let right = ProspectIdentity.normalizedDomain(b.businessDomain) else { return true }
        return left == right
    }

    static func digits(_ text: String) -> String {
        let only = text.filter(\.isNumber)
        return only.count == 11 && only.hasPrefix("1") ? String(only.dropFirst()) : only
    }

    /// Local only. `egress` exists so tests can prove ingest sends nothing: production passes nil, and tests
    /// pass a recording transport that must see 0 requests (no `/api/items`, no other host).
    static func ingest(_ incoming: [ProspectRecord], into store: ProspectLeadsStore, config: ICPConfig, now: Date,
                       audit: any CWAuditSink, egress: (any LeadTransport)? = nil,
                       duplicateApproval: DuplicateApproval? = nil) async -> Result {
        var result = Result()
        do {
            try store.transaction { records in
                if let duplicateApproval {
                    guard incoming.count == 1 else { throw LeadPipelineRefusal(code: "refused:batch-approval") }
                    let current = duplicate(of: incoming[0], in: records)?.id
                    guard current == duplicateApproval.expectedID else { throw LeadPipelineRefusal(code: "refused:duplicate-changed") }
                    let permitted = current == nil ? duplicateApproval.action == "create" : duplicateApproval.action == "update"
                    guard permitted else { throw LeadPipelineRefusal(code: "refused:duplicate-approval") }
                }
                for var record in incoming {
                    let missing = LeadDefinition.sourceEvidence(record)
                    if !missing.isEmpty { result.rejected[record.id] = missing.joined(separator: ", "); continue }
                    // LIVE-R6: a record with an evidence URL off its own domain is refused outright and audited.
                    if let offending = EvidenceDomain.offDomain(record, config: config).first {
                        result.rejected[record.id] = "refused:cross-domain-evidence"
                        audit.write(CWAuditLine(ts: now, surface: "leads", action: "ingest", register: URLCanonical.register(offending), target: record.id,
                                                source: "controlward", result: "refused:cross-domain-evidence"))
                        continue
                    }
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
            }
        } catch {
            result.storageError = (error as? LeadPipelineRefusal)?.code ?? "storage-failed"
        }
        audit.write(CWAuditLine(ts: now, surface: "leads", action: "ingest", register: "-", target: "leads-list", source: "controlward",
                                result: result.storageError ?? (result.rejected.isEmpty ? "ok" : "partial:rejected-\(result.rejected.count)"),
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
