import Foundation

@MainActor
enum GTMTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_792_000_000)
    static var checks = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !value() { throw SmokeTestFailure.failed("GTM: " + message) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch { rejected = true }
        try expect(rejected, message)
    }
    static func run() -> Bool {
        do {
            try migrationAndIdentity()
            try importsAndAmbiguity()
            try fitUnknownAndProductIsolation()
            try scoringDedupDecayAndRetraction()
            try sourceWindowsAndQuarantine()
            try taskLifecycleAndBlocking()
            try consecutiveDays()
            try atomicFailure()
            print("Account intelligence tests: \(checks) assertions passed")
            return true
        } catch { print("Account intelligence tests: FAIL \(error)"); return false }
    }
    static func withStore(_ body: (AppStore, UUID, Company) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gtm-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore())
        store.createWorkspace(name: "Synthetic GTM test", industry: "Consulting")
        var company = Company(); company.name = "Synthetic Company"; company.domain = "example.test"
        store.add(company)
        let profile = try store.createGTMProfile(name: "Synthetic offer", criteria: ["Sector", "Size", "Geography", "Need"], now: now)
        try body(store, profile, company)
    }
    static func verified(_ store: AppStore, _ company: Company) throws {
        try store.reviewGTMIdentity(companyID: company.id, reason: "Reviewed synthetic registry", suppression: "", now: now.addingTimeInterval(-20 * 86400))
    }
    static func strong(_ store: AppStore, _ profile: UUID, _ company: Company) throws {
        let evidence = [GTMMatch.match, .nonmatch, .match, .match].map { GTMFitEvidence(result: $0, reference: "Reviewed synthetic evidence") }
        try store.saveGTMFit(GTMFitAssessment(companyID: company.id, profileID: profile, evidence: evidence, assessedAt: now.addingTimeInterval(-20 * 86400)))
    }
    static func add(_ store: AppStore, _ profile: UUID, _ company: Company, _ kind: GTMEventKind, _ key: String, age: Double = 0) throws {
        try store.recordGTMEvent(companyID: company.id, profileID: profile, kind: kind, actionKey: key, occurredAt: now.addingTimeInterval(-age * 86400), reference: "Synthetic \(key)", now: now.addingTimeInterval(-age * 86400))
    }
    static func score(_ store: AppStore, _ profile: UUID, _ company: Company, at date: Date = now) -> GTMScoreSnapshot {
        store.gtmPreview(profileID: profile, now: date).first { $0.companyID == company.id }!
    }
    static func batch(kind: GTMEventKind = .handRaise, date: Date = now, source: String = "fixture") -> GTMImportBatch {
        GTMImportBatch(schemaVersion: 1, source: source,
                       accounts: [.init(externalID: "account-1", name: "Synthetic Company", domain: "example.test")],
                       events: [.init(sourceEventID: "event-1", accountExternalID: "account-1", actionKey: "submission-1", kind: kind, occurredAt: date, reference: "https://example.test/evidence?tracking=omit#fragment", isBotOrInternal: false)])
    }
    static func data(_ batch: GTMImportBatch) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(batch)
    }

    static func migrationAndIdentity() throws {
        var old = PersistentWorkspace()
        var company = Company(); company.name = "Original"; company.domain = "www.example.co.uk"
        var lead = Lead(); lead.companyID = company.id
        old.companies = [company]; old.leads = [lead]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "accountIntelligence")
        let migrated = try JSONDecoder().decode(PersistentWorkspace.self, from: JSONSerialization.data(withJSONObject: json))
        try expect(migrated.companies.first?.id == company.id && migrated.leads.first?.id == lead.id && migrated.leads.first?.companyID == company.id, "legacy IDs and links changed")
        try expect(migrated.accountIntelligence.events.isEmpty, "migration fabricated events")
        try expect(AccountIdentity.domain("HTTPS://WWW.Example.CO.UK/path?x=1") == "example.co.uk", "exact domain normalization")
        try expect(AccountIdentity.candidates(for: "branch.example.co.uk", companies: [company]).isEmpty, "subsidiary collapsed into parent")
        for raw in ["gmail.com", "a@gmail.com", "127.0.0.1", "https://user:pass@example.test", "example..test", "localhost"] {
            try expect(AccountIdentity.domain(raw) == nil, "unsafe domain \(raw) accepted")
        }
        json["accountIntelligence"] = ["schemaVersion": 2]
        try rejects("future schema silently accepted") { _ = try JSONDecoder().decode(PersistentWorkspace.self, from: JSONSerialization.data(withJSONObject: json)) }
    }

    static func importsAndAmbiguity() throws {
        try withStore { store, profile, company in
            var franchise = batch(); franchise.accounts[0].name = "Different franchise location"
            _ = try store.importGTM(data: data(franchise), profileID: profile, now: now)
            try expect(store.companies.count == 2 && store.gtm.events[0].candidateCompanyID != company.id, "different organizations sharing a domain were merged")
        }
        try withStore { store, profile, company in
            let bytes = try data(batch())
            try expect(try store.importGTM(data: bytes, profileID: profile, now: now) == 1, "first import count")
            try expect(try store.importGTM(data: bytes, profileID: profile, now: now) == 0, "second import duplicated event")
            try expect(try store.importGTM(data: bytes, profileID: profile, now: now) == 0, "third import duplicated event")
            try expect(store.companies.count == 1 && store.gtm.events.count == 1, "account/event import was not idempotent")
            for identifier in [profile, store.gtm.events[0].id] {
                let value = identifier.uuidString
                try expect(value[value.index(value.startIndex, offsetBy: 14)] == "4", "generated identifier is not UUID v4")
            }
            try expect(score(store, profile, company).intent == nil, "unvalidated import scored")
            try expect(store.gtm.events[0].reference == "https://example.test/evidence", "URL query/fragment persisted")
            var changed = batch(); changed.events[0].kind = .positiveReply
            let before = store.workspace
            try rejects("conflicting replay accepted") { _ = try store.importGTM(data: data(changed), profileID: profile, now: now) }
            try expect(store.workspace == before, "failed import partially mutated workspace")
            var second = Company(); second.name = "Subsidiary"; second.domain = company.domain; store.add(second)
            _ = try store.importGTM(data: data(batch(source: "other-source")), profileID: profile, now: now)
            let ambiguous = store.gtm.events.last!
            try expect(ambiguous.candidateCompanyID == nil && store.companies.count == 2, "shared domain silently merged or duplicated")
            try store.reviewGTMEvent(eventID: ambiguous.id, companyID: second.id, reason: "Manually confirmed subsidiary contact", now: now)
            try verified(store, second)
            try expect(score(store, profile, second).queue == .handRaiseReview, "explicit ambiguity resolution did not route unknown-fit request")
            try expect(score(store, profile, company).intent == nil, "evidence leaked to parent account")
        }
    }

    static func fitUnknownAndProductIsolation() throws {
        try withStore { store, profile, company in
            try verified(store, company)
            let secondProfile = try store.createGTMProfile(name: "Other offer", criteria: ["A", "B", "C", "D"], now: now)
            let partial = [GTMFitEvidence(result: .match, reference: "Sector source"), GTMFitEvidence(), GTMFitEvidence(), GTMFitEvidence()]
            try store.saveGTMFit(GTMFitAssessment(companyID: company.id, profileID: profile, evidence: partial, assessedAt: now))
            var s = score(store, profile, company)
            try expect(s.fit == 30 && s.coverage == 30 && s.fitBand == "Provisional", "sparse fit was rescaled")
            try strong(store, profile, company)
            s = score(store, profile, company)
            try expect(s.fit == 80 && s.coverage == 100 && s.fitBand == "Strong", "fit weighting incorrect")
            try expect(score(store, secondProfile, company).coverage == 0, "fit leaked across offers")
            var legacy = Signal(); legacy.companyID = company.id; legacy.fitScore = 100; legacy.intentScore = 100; store.add(legacy)
            try expect(score(store, profile, company).intent == nil, "legacy research score became buyer activity")
            try add(store, profile, company, .handRaise, "request")
            try expect(score(store, secondProfile, company).intent == nil, "activity leaked across offers")
        }
    }

    static func scoringDedupDecayAndRetraction() throws {
        try withStore { store, profile, company in
            try verified(store, company); try strong(store, profile, company)
            try add(store, profile, company, .handRaise, "request")
            try add(store, profile, company, .positiveReply, "reply")
            try add(store, profile, company, .webEngagement, "web")
            var s = score(store, profile, company)
            try expect(s.intent == 90 && s.stage == "Purchase" && s.queue == .salesReview, "90-point example incorrect")
            try add(store, profile, company, .handRaise, "same-day-other-request")
            try expect(score(store, profile, company).intent == 90, "same family/day counted twice")
            let reply = store.gtm.events.first { $0.kind == .positiveReply }!
            try store.retractGTMEvent(eventID: reply.id, reason: "Copied request, not a reply", now: now)
            try expect(score(store, profile, company).intent == 65, "retracted event still scored")
            try add(store, profile, company, .positiveReply, "request")
            try expect(score(store, profile, company).intent == 65, "semantic duplicate double-counted across families")
            try add(store, profile, company, .positiveReply, "reply")
            try expect(score(store, profile, company).intent == 65, "retracted action resurrected through a copy")
            s = score(store, profile, company, at: now.addingTimeInterval(100 * 86400))
            try expect(s.intent == nil && !s.queue.eligible, "expired evidence remained eligible")
        }
        try withStore { store, profile, company in
            try add(store, profile, company, .webEngagement, "half-life", age: 7)
            let s = score(store, profile, company)
            try expect(abs((s.contributions.first?.points ?? 0) - 2.5) < 0.0001, "7-day half-life incorrect")
            for i in 0..<20 { try add(store, profile, company, .contentRequest, "content-\(i)", age: Double(i)) }
            let total = score(store, profile, company).contributions.filter { $0.kind == .contentRequest }.reduce(0) { $0 + $1.points }
            try expect(total <= 20.0001, "family cap exceeded")
        }
        for (value, expected) in [(19,"Target"),(20,"Awareness"),(49,"Awareness"),(50,"Consideration"),(69,"Consideration"),(70,"Decision"),(85,"Decision"),(86,"Purchase")] {
            try expect(AccountScoring.stage(value) == expected, "stage boundary \(value)")
        }
        try expect(AccountScoring.stage(nil) == "Unknown", "nil is not unknown")
    }

    static func sourceWindowsAndQuarantine() throws {
        try withStore { store, profile, company in
            try expect(score(store, profile, company).intent == nil, "no data became zero")
            try store.saveGTMObservation(GTMObservation(companyID: company.id, profileID: profile, source: "Reviewed web log", startsAt: now.addingTimeInterval(-91 * 86400), throughAt: now, reference: "Synthetic log receipt"), now: now)
            try expect(score(store, profile, company).intent == 0, "fresh observation did not support zero")
            try expect(score(store, profile, company, at: now.addingTimeInterval(8 * 86400)).intent == nil, "stale source reported zero")
            _ = try store.importGTM(data: data(batch(date: now.addingTimeInterval(86400))), profileID: profile, now: now)
            try rejects("future evidence validated") { try store.reviewGTMEvent(eventID: store.gtm.events[0].id, companyID: company.id, reason: "Future", now: now) }
            try expect(score(store, profile, company).intent == 0, "future event scored")
            _ = try store.importGTM(data: data(batch(kind: .publicListing, source: "listing")), profileID: profile, now: now)
            try rejects("listing validated as activity") { try store.reviewGTMEvent(eventID: store.gtm.events.last!.id, companyID: company.id, reason: "Public", now: now) }
            var bot = batch(source: "bot"); bot.events[0].isBotOrInternal = true
            _ = try store.importGTM(data: data(bot), profileID: profile, now: now)
            try rejects("bot validated") { try store.reviewGTMEvent(eventID: store.gtm.events.last!.id, companyID: company.id, reason: "Bot", now: now) }
        }
    }

    static func taskLifecycleAndBlocking() throws {
        try withStore { store, profile, company in
            try add(store, profile, company, .handRaise, "request")
            try expect(try store.createGTMReviewTasks(profileID: profile, now: now) == 0, "unverified identity routed")
            try verified(store, company)
            try expect(score(store, profile, company).queue == .handRaiseReview, "unknown-fit request hidden")
            try expect(try store.createGTMReviewTasks(profileID: profile, now: now) == 1, "eligible request did not create task")
            try expect(try store.createGTMReviewTasks(profileID: profile, now: now) == 0, "task rerun duplicated")
            let reloaded = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
            try expect(reloaded.gtm == store.gtm && reloaded.tasks == store.tasks, "evidence/task persistence failed")
            try expect(try reloaded.createGTMReviewTasks(profileID: profile, now: now) == 0, "relaunch duplicated task")
            var task = reloaded.tasks[0]; task.status = .done; reloaded.update(task)
            try expect(try reloaded.createGTMReviewTasks(profileID: profile, now: now) == 0, "completed task duplicated")
            reloaded.delete(task)
            try expect(try reloaded.createGTMReviewTasks(profileID: profile, now: now) == 0, "deleted task resurrected")
            let id = store.gtm.events[0].id
            try store.retractGTMEvent(eventID: id, reason: "Invalid request", now: now)
            try expect(store.tasks.count == 1 && !score(store, profile, company).queue.eligible, "retraction deleted task or kept routing")
            var changed = company; changed.domain = "other.test"; store.update(changed)
            try expect(!score(store, profile, changed).identityVerified, "domain edit retained verification")
        }
        try withStore { store, profile, company in
            try verified(store, company); try add(store, profile, company, .handRaise, "request")
            try store.reviewGTMIdentity(companyID: company.id, reason: "Owner instruction", suppression: "Do not pursue", now: now)
            try expect(try store.createGTMReviewTasks(profileID: profile, now: now) == 0, "suppressed account routed")
            try verified(store, company)
            var lead = Lead(); lead.companyID = company.id; store.add(lead)
            var opportunity = Opportunity(); opportunity.leadID = lead.id; opportunity.stage = .proposal; store.add(opportunity)
            try expect(score(store, profile, company).queue == .blocked, "linked open opportunity not respected")
            opportunity.stage = .lost; store.update(opportunity)
            try expect(score(store, profile, company).queue.eligible, "closed opportunity still blocked")
        }
    }

    static func consecutiveDays() throws {
        try withStore { store, profile, company in
            try verified(store, company); try strong(store, profile, company)
            try add(store, profile, company, .handRaise, "older-request", age: 9)
            try add(store, profile, company, .positiveReply, "reply", age: 1)
            try add(store, profile, company, .webEngagement, "web", age: 1)
            try expect(!score(store, profile, company).queue.eligible, "ordinary routing skipped daily stability")
            try store.saveGTMSnapshots(profileID: profile, now: now.addingTimeInterval(-86400))
            try expect(score(store, profile, company).queue == .salesReview, "two-day stability did not qualify")
            try expect(!score(store, profile, company, at: now.addingTimeInterval(2 * 86400)).queue.eligible, "nonconsecutive snapshots qualified")
        }
    }

    static func atomicFailure() throws {
        try withStore { store, profile, company in
            try verified(store, company); try add(store, profile, company, .handRaise, "request")
            let before = store.workspace
            let disk = try Data(contentsOf: store.storageURL)
            try FileManager.default.removeItem(at: store.storageURL)
            try FileManager.default.createDirectory(at: store.storageURL, withIntermediateDirectories: false)
            try rejects("failed persistence reported task creation") { _ = try store.createGTMReviewTasks(profileID: profile, now: now) }
            try expect(store.workspace == before, "failed disk write left an in-memory task")
            try FileManager.default.removeItem(at: store.storageURL)
            try disk.write(to: store.storageURL)
            let reload = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
            try expect(reload.tasks.isEmpty, "failed transaction persisted task")
        }
    }
}
