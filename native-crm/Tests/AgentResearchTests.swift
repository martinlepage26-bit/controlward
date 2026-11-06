import Foundation

@MainActor
enum AgentResearchTests {
    static func request(now: Date, url: String = LeadKit.homePage) -> AgentResearchRequest {
        AgentResearchRequest(id: UUID(), batchID: UUID(), query: "Montréal businesses using AI", createdAt: now.addingTimeInterval(-5),
                             expiresAt: now.addingTimeInterval(300), sites: [.init(name: "Clinique Exemple Nord", url: url)])
    }

    static func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("controlward-agent-\(UUID())") }

    static func run() async -> Bool {
        let expect = PortableCheck.expect
        return await PortableCheck.suite("Agent research", [
            ("Names and URLs produce sourced unsent CRM drafts; replay reuses research without duplicates", {
                // Force an ISO round-up so cache reuse does not depend on sub-millisecond timing.
                let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970 - 120) + 0.0006)
                let (_, inner, _) = try QuickScanResearchTests.fixture(now: now)
                let config = try LeadKit.config().interactiveSearch()
                let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore())
                let coordinator = AgentResearchCoordinator()
                let job = request(now: now)
                let output = directory.appendingPathComponent("result.json")
                let first = await coordinator.execute(job, store: store, root: directory, config: config, output: output, inner: inner, clock: FakeLeadClock(now))
                try expect(first.status == "completed" && first.entries.first?.leadID != nil, "\(first)")
                try expect(store.leads.count == 1 && store.leads[0].email == "info@clinique-exemple.test", "app discovered contact")
                try expect(store.leads[0].outreachDraft?.contains("99 $ CA") == true && store.leads[0].quickScanResearch?.hasAIUseEvidence == true, "app discovered AI evidence and prepared priced draft")
                try expect(store.leads[0].history.isEmpty && store.leads[0].quoteAmount == nil, "unsent, no invented revenue")
                let count = inner.urls.count
                let second = await coordinator.execute(job, store: store, root: directory, config: config, output: output, inner: inner, clock: FakeLeadClock(now))
                try expect(second.status == "completed" && store.leads.count == 1 && inner.urls.count == count, "cached replay is idempotent")
                let reopened = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
                try expect(reopened.leads[0].outreachDraft == store.leads[0].outreachDraft, "saved draft survives reload")
                let permissions = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber
                try expect(permissions?.intValue == 0o600, "private result file")
            }),
            ("Invalid or expired requests never reach the network", {
                let now = Date.now
                let config = try LeadKit.config().interactiveSearch()
                let inner = FakeLeadTransport()
                let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore())
                var invalid = [request(now: now, url: "http://127.0.0.1/"), request(now: now, url: "https://localhost/"), request(now: now, url: "file:///etc/hosts")]
                var expired = request(now: now); expired.expiresAt = now.addingTimeInterval(-1); invalid.append(expired)
                var schema = request(now: now); schema.schema = 2; invalid.append(schema)
                for job in invalid {
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
                let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore())
                let result = await AgentResearchCoordinator().execute(request(now: now), store: store, root: directory, config: try LeadKit.config().interactiveSearch(), output: directory.appendingPathComponent("result.json"), inner: inner, clock: FakeLeadClock(now))
                try expect(result.status == "completed" && result.entries.first?.aiEvidenceFound == false && store.leads.isEmpty, "unsupported candidate not promoted")
                try expect(try WebsiteResearchCache.load(directory.appendingPathComponent("quick-scan-research.json")).candidates.count == 1, "unknown retained for review")
            }),
            ("CRM save failure reports failure and publishes no lead", {
                let now = Date.now.addingTimeInterval(-120)
                let (_, inner, _) = try QuickScanResearchTests.fixture(now: now)
                let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
                try SecureFiles.ensurePrivateDirectory(directory)
                let blocker = directory.appendingPathComponent("blocker")
                try Data("blocked".utf8).write(to: blocker)
                let store = AppStore(storageURL: blocker.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore())
                let result = await AgentResearchCoordinator().execute(request(now: now), store: store, root: directory, config: try LeadKit.config().interactiveSearch(), output: directory.appendingPathComponent("result.json"), inner: inner, clock: FakeLeadClock(now))
                try expect(result.status == "failed" && store.leads.isEmpty, "save failure surfaced")
                try expect(try WebsiteResearchCache.load(directory.appendingPathComponent("quick-scan-research.json")).results.count == 1, "research retained for retry")
            }),
            ("Cancellation performs no network request and creates no draft", {
                let now = Date.now
                let inner = FakeLeadTransport()
                let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore())
                let config = try LeadKit.config().interactiveSearch()
                let task = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return await AgentResearchCoordinator().execute(request(now: now), store: store, root: directory, config: config, output: directory.appendingPathComponent("result.json"), inner: inner, clock: FakeLeadClock(now))
                }
                let result = await task.value
                try expect(result.status == "partial" && inner.urls.isEmpty && store.leads.isEmpty, "cancelled before fetch")
            })
        ])
    }
}
