import Foundation

@MainActor
enum AgentResearchTests {
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
