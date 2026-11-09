import Foundation

@MainActor
enum AgentResearchTests {
    private struct OverlapTransport: LeadTransport {
        let inner: FakeLeadTransport
        let beforeReturn: @MainActor @Sendable () throws -> Void
        func send(_ request: URLRequest) async throws -> LeadHTTPResponse {
            let response = try await inner.send(request)
            if request.url?.path == "/intelligence-artificielle" { try await beforeReturn() }
            return response
        }
    }
    static func request(now: Date, url: String = LeadKit.homePage, generation: UUID = UUID()) -> AgentResearchRequest {
        AgentResearchRequest(id: UUID(), batchID: UUID(), workspaceGeneration: generation, query: "Montréal businesses using AI", createdAt: now.addingTimeInterval(-5),
                             expiresAt: now.addingTimeInterval(300), sites: [.init(name: "Clinique Exemple Nord", url: url)])
    }

    static func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("controlward-agent-\(UUID())") }

    // These cases exercise AppStore on MainActor. Keep their runner on the same actor on
    // Swift 6.1 too, rather than sending actor-isolated closures to the portable runner.
    private static func suite(_ cases: [(String, @MainActor () async throws -> Void)]) async -> Bool {
        var passed = 0
        for (label, body) in cases {
            do { try await body(); passed += 1; print("  PASS \(label)") }
            catch { print("  FAIL \(label): \(error)") }
        }
        print("Agent research tests: \(passed)/\(cases.count) passed")
        return passed == cases.count
    }

    static func run() async -> Bool {
        let expect = PortableCheck.expect
        return await suite([
            ("A slower positive fetch cannot promote a draft after a newer negative recheck", {
                let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970 - 120))
                let (researcher, inner, source) = try QuickScanResearchTests.fixture(now: now)
                var negative = await researcher.research(source, segmentID: "clinic")
                let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(), researchRoot: directory)
                let job = request(now: now, generation: store.workspace.researchGeneration)
                let candidate = try job.candidates(now: now)[0]
                negative.record.id = "cw:" + candidate.sourceID; negative.checkedAt = now.addingTimeInterval(60); negative.aiUse = []
                let newer = negative
                let transport = OverlapTransport(inner: inner) { try store.recordWebsiteResearch(candidate, result: newer) }
                let outcome = await AgentResearchCoordinator().execute(job, store: store, root: directory, config: try LeadKit.config().interactiveSearch(), output: directory.appendingPathComponent("result.json"), inner: transport, clock: FakeLeadClock(now))
                try expect(outcome.status == "completed" && outcome.entries.first?.aiEvidenceFound == false && outcome.entries.first?.leadID == nil, "older positive observation published a false ready outcome")
                try expect(store.leads.isEmpty && store.websiteResearch.results[candidate.sourceID] == newer, "older positive observation promoted a draft or regressed saved findings")
            }),
            ("Direct and recovered rechecks replace only lead evidence, preserve owner work and resist older results", {
                let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970 - 120))
                let (researcher, _, source) = try QuickScanResearchTests.fixture(now: now)
                var positive = await researcher.research(source, segmentID: "clinic")
                let candidate = try WebsiteResearchQueue.parse("Clinique Exemple Nord | \(LeadKit.homePage)")[0]
                positive.record.id = "cw:" + candidate.sourceID
                let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(), researchRoot: directory)
                try store.recordWebsiteResearch(candidate, result: positive)
                var lead = Lead.blank(); lead.sourceID = candidate.sourceID; lead.email = positive.email!; lead.quickScanResearch = positive
                lead.outreachDraft = positive.draft(config: researcher.config, suppression: SuppressionList(), now: now)!.body
                lead.companyID = UUID(); lead.contactID = UUID(); lead.followUpTaskID = UUID()
                lead.nextFollowUp = "2026-11-09"; lead.notes = "Owner's private notes"
                try expect(store.add(lead), "fixture lead not saved")
                var negative = positive; negative.checkedAt = now.addingTimeInterval(1)
                negative.contacts = []; negative.record.email = nil; negative.record.route = nil
                try store.recordWebsiteResearch(candidate, result: negative)
                var expected = lead; expected.quickScanResearch = negative
                try expect(store.leads == [expected], "direct recheck left stale findings or changed owner fields")
                try expect(LeadWorkflow.emailDraftIssue(for: store.leads[0], body: lead.outreachDraft!, subject: QuickScanResearchResult.offerSubject, config: researcher.config, suppression: SuppressionList(), now: now.addingTimeInterval(1)) != nil, "negative recheck did not block old draft")
                try store.recordWebsiteResearch(candidate, result: positive)
                try expect(store.leads == [expected], "older overlapping result regressed the current lead evidence")
                negative.checkedAt = now.addingTimeInterval(2); negative.issues = ["Recovered recheck"]
                var delta = WebsiteResearchCache(); delta.merge(candidate, result: negative)
                try delta.save(directory.appendingPathComponent("research-recovery.json"))
                let reopened = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore(), researchRoot: directory)
                expected.quickScanResearch = negative
                try expect(reopened.leads == [expected] && reopened.researchFailure == nil, "recovered negative finding did not govern the reopened lead")
                let again = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore(), researchRoot: directory)
                try expect(again.leads == [expected], "negative evidence or exact owner work lost on another reopen")
            }),
            ("A changed page is fetched and fresh negative findings invalidate an older unsent draft", {
                let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970 - 120))
                let (_, inner, _) = try QuickScanResearchTests.fixture(now: now)
                let config = try LeadKit.config().interactiveSearch()
                let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(), researchRoot: directory)
                let coordinator = AgentResearchCoordinator()
                let first = await coordinator.execute(request(now: now, generation: store.workspace.researchGeneration), store: store, root: directory, config: config, output: directory.appendingPathComponent("first.json"), inner: inner, clock: FakeLeadClock(now))
                try expect(first.entries.first?.leadID != nil, "baseline draft absent")
                let original = store.leads[0], count = inner.urls.count
                let changed = "https://www.clinique-exemple.test/privacy"
                let html = "<h1>Clinique Exemple Nord</h1><p>Alex Fictif, directrice générale</p><address>\(LeadKit.clinicAddress)</address><a href=\"mailto:info@clinique-exemple.test\">Contact</a><p>We do not use AI.</p>"
                for url in [changed, LeadKit.homePage, "https://www.clinique-exemple.test/intelligence-artificielle"] { inner.respond(url, body: html) }
                let second = await coordinator.execute(request(now: now.addingTimeInterval(1), url: changed, generation: store.workspace.researchGeneration), store: store, root: directory, config: config, output: directory.appendingPathComponent("second.json"), inner: inner, clock: FakeLeadClock(now.addingTimeInterval(1)))
                try expect(inner.urls.count > count && inner.urls.contains(changed), "changed input URL reused the previous cached page")
                try expect(second.entries.first?.aiEvidenceFound == false && second.entries.first?.leadID == nil, "negative recheck was reported draft ready")
                let refreshed = store.leads[0]
                try expect(refreshed.id == original.id && store.leads.count == 1 && refreshed.outreachDraft == original.outreachDraft && refreshed.history == original.history && refreshed.nextFollowUp == original.nextFollowUp, "recheck discarded owner work or duplicated the lead")
                try expect(refreshed.quickScanResearch?.hasAIUseEvidence == false, "fresh negative findings did not reach the existing lead")
                try expect(LeadWorkflow.emailDraftIssue(for: refreshed, body: original.outreachDraft!, subject: QuickScanResearchResult.offerSubject, config: config, suppression: SuppressionList(), now: now.addingTimeInterval(1)) != nil, "old ready draft remained usable after a negative recheck")
            }),
            ("Names and URLs produce sourced unsent CRM drafts; replay reuses research without duplicates", {
                // Force an ISO round-up so cache reuse does not depend on sub-millisecond timing.
                let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970 - 120) + 0.0006)
                let (_, inner, _) = try QuickScanResearchTests.fixture(now: now)
                let config = try LeadKit.config().interactiveSearch()
                let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(), researchRoot: directory)
                let coordinator = AgentResearchCoordinator()
                let job = request(now: now, generation: store.workspace.researchGeneration)
                let output = directory.appendingPathComponent("result.json")
                let first = await coordinator.execute(job, store: store, root: directory, config: config, output: output, inner: inner, clock: FakeLeadClock(now))
                try expect(first.status == "completed" && first.entries.first?.leadID != nil, "\(first)")
                try expect(store.leads.count == 1 && store.leads[0].email == "info@clinique-exemple.test", "app discovered contact")
                try expect(store.leads[0].outreachDraft?.contains("99 $ CA") == true && store.leads[0].quickScanResearch?.hasAIUseEvidence == true, "app discovered AI evidence and prepared priced draft")
                try expect(store.leads[0].history.isEmpty && store.leads[0].quoteAmount == nil, "unsent, no invented revenue")
                let count = inner.urls.count
                let second = await coordinator.execute(job, store: store, root: directory, config: config, output: output, inner: inner, clock: FakeLeadClock(now))
                try expect(second.status == "completed" && store.leads.count == 1 && inner.urls.count == count, "cached replay is idempotent")
                try expect(first.entries.first?.reusedResearch == false && second.entries.first?.reusedResearch == true, "fresh and reused findings lack accurate provenance")
                let reopened = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore(), researchRoot: directory)
                try expect(reopened.leads[0].outreachDraft == store.leads[0].outreachDraft, "saved draft survives reload")
                let permissions = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber
                try expect(permissions?.intValue == 0o600, "private result file")
            }),
            ("Invalid or expired requests never reach the network", {
                let now = Date.now
                let config = try LeadKit.config().interactiveSearch()
                let inner = FakeLeadTransport()
                let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(), researchRoot: directory)
                var invalid = [request(now: now, url: "http://127.0.0.1/"), request(now: now, url: "https://localhost/"), request(now: now, url: "file:///etc/hosts")]
                var expired = request(now: now, generation: store.workspace.researchGeneration); expired.expiresAt = now.addingTimeInterval(-1); invalid.append(expired)
                var schema = request(now: now, generation: store.workspace.researchGeneration); schema.schema = 3; invalid.append(schema)
                for var job in invalid {
                    job.workspaceGeneration = store.workspace.researchGeneration
                    let outcome = await AgentResearchCoordinator().execute(job, store: store, root: directory, config: config, output: directory.appendingPathComponent("result.json"), inner: inner, clock: FakeLeadClock(now))
                    try expect(outcome.status == "failed", "invalid request accepted")
                }
                try expect(inner.urls.isEmpty && store.leads.isEmpty, "no network or CRM write")
            }),
            ("Filename binds a job and symlink requests are refused", {
                let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
                let job = request(now: .now)
                let wrong = directory.appendingPathComponent("\(UUID()).json")
                try AgentResearchFiles.write(job, to: wrong)
                do { _ = try AgentResearchFiles.request(wrong); throw PortableCheckFailure(description: "mismatched filename accepted") }
                catch AgentResearchError.invalidRequest {}
                let linked = directory.appendingPathComponent("\(job.id).json")
                try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: wrong)
                do { _ = try AgentResearchFiles.request(linked); throw PortableCheckFailure(description: "symlink accepted") }
                catch AgentResearchError.invalidRequest {}
            }),
            ("AI keywords without actual use are retained as unknown and cannot create a lead", {
                let now = Date.now.addingTimeInterval(-120)
                let (_, inner, _) = try QuickScanResearchTests.fixture("<h1>Clinique Exemple Nord</h1><p>AI is changing our industry</p>", now: now)
                let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(), researchRoot: directory)
                let result = await AgentResearchCoordinator().execute(request(now: now, generation: store.workspace.researchGeneration), store: store, root: directory, config: try LeadKit.config().interactiveSearch(), output: directory.appendingPathComponent("result.json"), inner: inner, clock: FakeLeadClock(now))
                try expect(result.status == "completed" && result.entries.first?.aiEvidenceFound == false && store.leads.isEmpty, "unsupported candidate not promoted")
                try expect(result.entries.first?.issues.contains { $0.contains("Draft withheld:") } == true, "withheld draft explains why")
                try expect(store.websiteResearch.candidates.count == 1, "unknown retained for review")
            }),
            ("CRM save failure reports failure and publishes no lead", {
                let now = Date.now.addingTimeInterval(-120)
                let (_, inner, _) = try QuickScanResearchTests.fixture(now: now)
                let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
                try SecureFiles.ensurePrivateDirectory(directory)
                let blocker = directory.appendingPathComponent("blocker")
                try Data("blocked".utf8).write(to: blocker)
                let store = AppStore(storageURL: blocker.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(), researchRoot: directory)
                let result = await AgentResearchCoordinator().execute(request(now: now, generation: store.workspace.researchGeneration), store: store, root: directory, config: try LeadKit.config().interactiveSearch(), output: directory.appendingPathComponent("result.json"), inner: inner, clock: FakeLeadClock(now))
                try expect(result.status == "failed" && store.leads.isEmpty, "save failure surfaced")
                try expect(try WebsiteResearchCache.load(directory.appendingPathComponent("research-recovery.json")).candidates.count == 1 && inner.urls.isEmpty, "candidate retained for retry before any network request")
            }),
            ("Saved email handoff rechecks exclusions, current evidence, recipient and edited content", {
                let (researcher, _, candidate) = try QuickScanResearchTests.fixture()
                let result = await researcher.research(candidate, segmentID: "clinic")
                let config = researcher.config
                let now = researcher.clock.now
                let message = result.draft(config: config, suppression: SuppressionList(), now: now)!
                var lead = Lead.blank(); lead.email = result.email!; lead.quickScanResearch = result; lead.outreachDraft = message.body
                func issue(_ lead: Lead, _ body: String, _ list: SuppressionList = SuppressionList(), at: Date? = nil) -> String? {
                    let fallback = LeadWorkflow.draft(for: lead, in: PersistentWorkspace(), business: BusinessProfile()).subject
                    let subject = LeadWorkflow.emailSubject(for: lead, body: body, fallback: fallback)
                    return LeadWorkflow.emailDraftIssue(for: lead, body: body, subject: subject, config: config, suppression: list, now: at ?? now)
                }
                try expect(LeadWorkflow.emailSubject(for: lead, body: message.body, fallback: "Introduction") == message.subject, "editor and handoff preserve approved offer subject")
                try expect(issue(lead, message.body) == nil, "valid saved cold draft can be opened for review")
                try expect(issue(lead, message.body.replacingOccurrences(of: "99 $ CA", with: "199 $ CA")) != nil, "different price remains refused")
                let list = SuppressionList(); list.record(lead.email, at: now, via: "unsubscribe")
                try expect(issue(lead, message.body, list) != nil && lead.outreachDraft == message.body, "later unsubscribe blocks handoff without deleting text")
                var changed = lead; changed.email = "other@other.test"
                try expect(issue(changed, message.body) != nil, "changed recipient cannot inherit publication evidence")
                try expect(issue(lead, message.body + "\nSur votre site (https://invented.test), j’ai lu : « made up »") != nil, "edited unsupported citation blocked")
                try expect(issue(lead, message.body, at: now.addingTimeInterval(8 * 86_400)) != nil, "stale saved draft blocked")
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("cw-handoff-\(UUID()).json")
                defer { try? FileManager.default.removeItem(at: file) }
                try Data("broken unsubscribe list".utf8).write(to: file)
                try expect(issue(lead, message.body, SuppressionList(storageURL: file)) != nil, "damaged exclusions block a saved draft")
                var manual = Lead.blank(); manual.email = "warm@example.test"
                try expect(LeadWorkflow.emailSubject(for: manual, body: "Recorded warm follow-up", fallback: "Following up") == "Following up", "ordinary correspondence keeps grounded subject")
                try expect(LeadWorkflow.emailDraftIssue(for: manual, body: "Recorded warm follow-up", subject: "Following up", config: nil, suppression: SuppressionList(), now: now) == nil, "ordinary owner-entered correspondence remains available")
            }),
            ("Mail and Gmail composers preserve exact Unicode text and do not create extra headers", {
                var lead = Lead.blank(); lead.email = "Paul <paul+review@example.test>"
                let subject = "Quick Scan à 99 $ CA & suivi + résultats?"
                let body = "Bonjour Paul,\n99 $ CA + taxes & détails : 50%\n?bcc=other@example.test # fragment\nÉrable • ✅"
                let original = lead
                let now = Date.now
                for destination in LeadWorkflow.EmailDraftDestination.allCases {
                    let url = try LeadWorkflow.emailDraftURL(for: lead, body: body, subject: subject, destination: destination,
                                                            config: nil, suppression: SuppressionList(), now: now)
                    let mailURL: URL
                    if destination == .gmail {
                        let gmail = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                        try expect(gmail.scheme == "https" && gmail.host == "mail.google.com" && gmail.path == "/mail/", "fixed Gmail origin")
                        try expect(gmail.queryItems?.map(\.name) == ["extsrc", "url"] && gmail.queryItems?.first?.value == "mailto", "only compose parameters")
                        mailURL = URL(string: gmail.queryItems!.last!.value!)!
                    } else { mailURL = url }
                    let mail = URLComponents(url: mailURL, resolvingAgainstBaseURL: false)!
                    try expect(mail.scheme == "mailto" && mail.path == "paul+review@example.test", "exact recipient including plus tag")
                    try expect(mail.queryItems?.map(\.name) == ["subject", "body"], "message cannot add a bcc header")
                    try expect(mail.queryItems?.first?.value == subject && mail.queryItems?.last?.value == body, "exact subject/body after both decoding layers")
                    try expect(mail.percentEncodedQuery?.contains("+") == false, "literal plus cannot become a form-encoded space")
                }
                try expect(lead == original && lead.history.isEmpty && lead.outreachDraft == nil, "preparing composers does not log, send or save")
            }),
            ("Both draft destinations enforce current evidence, exclusions and valid message headers", {
                let (researcher, _, candidate) = try QuickScanResearchTests.fixture()
                let result = await researcher.research(candidate, segmentID: "clinic")
                let config = researcher.config, now = researcher.clock.now
                let draft = result.draft(config: config, suppression: SuppressionList(), now: now)!
                var lead = Lead.blank(); lead.email = result.email!; lead.quickScanResearch = result; lead.outreachDraft = draft.body
                let excluded = SuppressionList(); excluded.record(lead.email, at: now, via: "unsubscribe")
                for destination in LeadWorkflow.EmailDraftDestination.allCases {
                    func canPrepare(_ body: String = draft.body, subject: String = draft.subject,
                                    list: SuppressionList = SuppressionList(), at: Date? = nil) -> Bool {
                        (try? LeadWorkflow.emailDraftURL(for: lead, body: body, subject: subject, destination: destination,
                                                        config: config, suppression: list, now: at ?? now)) != nil
                    }
                    try expect(canPrepare(), "valid sourced draft available in each destination")
                    try expect(!canPrepare(list: excluded), "unsubscribe blocks both destinations")
                    try expect(!canPrepare(at: now.addingTimeInterval(8 * 86_400)), "stale evidence blocks both destinations")
                    try expect(!canPrepare(draft.body.replacingOccurrences(of: "99 $ CA", with: "199 $ CA")), "changed offer blocks both destinations")
                    try expect(!canPrepare(" \n "), "empty text refused")
                    try expect(!canPrepare(subject: draft.subject + "\r\nBcc: other@example.test"), "multiline subject refused")
                }
                try expect(lead.outreachDraft == draft.body && lead.history.isEmpty, "refused attempts preserve the unsent draft")
            }),
            ("Cancellation performs no network request and creates no draft", {
                let now = Date.now
                let inner = FakeLeadTransport()
                let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(), researchRoot: directory)
                let config = try LeadKit.config().interactiveSearch()
                let task = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return await AgentResearchCoordinator().execute(request(now: now, generation: store.workspace.researchGeneration), store: store, root: directory, config: config, output: directory.appendingPathComponent("result.json"), inner: inner, clock: FakeLeadClock(now))
                }
                let result = await task.value
                try expect(result.status == "partial" && inner.urls.isEmpty && store.leads.isEmpty, "cancelled before fetch")
            })
        ])
    }
}
