import Foundation

@MainActor enum DiscoveryIntelligenceTests {
    static func run() async -> Bool {
        let cases: [(String, () async throws -> Void)] = [
            ("read-only context refresh preserves outreach and separates aggregate metrics", contextRefresh),
            ("partial/malformed API responses retain the preceding discovery snapshot", contextFailure),
            ("reviewed links and fit are atomic, idempotent and survive backup/reload", reviewedAssociations),
            ("website groups deduplicate; identity suggestions require explicit source evidence", identityEvidence),
            ("fit, recent enquiries and supported contact routes remain independent", separateAssessments),
            ("legacy research decodes and unsafe or invalid context is refused", compatibility),
            ("context save failure publishes nothing and retry survives reload", contextSaveFailure),
            ("changing a connection during refresh rejects its stale response", changedConnection),
            ("ignored, reclassified and absent source rows never retain current-interest priority", sourceEligibility),
        ]
        var failed = 0
        for (name, test) in cases {
            do { try await test(); print("PASS Discovery intelligence: \(name)") }
            catch { failed += 1; print("FAIL Discovery intelligence: \(name): \(error)") }
        }
        print("Discovery intelligence tests: \(cases.count - failed)/\(cases.count) passed")
        return failed == 0
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw SmokeTestFailure.failed(message) }
    }
    private static func encoded(_ workspace: PersistentWorkspace) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(workspace)
    }
    private static func context() -> KairosDiscoveryContext {
        KairosDiscoveryContext(endpoint: "https://kairos.example.test", fetchedAt: Date.now.ISO8601Format(), strategyRevision: UUID(),
            strategy: KairosStrategy(positioning: "Practical AI support", audience: "Clinics using AI", updatedAt: "2026-11-01T00:00:00Z"),
            insights: KairosInsights(window: "30d", totals: .init(posts: 10, impressions: 1_000_000, engagements: 10_000, follows: 50), pillars: [.init(name: "AI tools", posts: 3, avg_score: 80)]),
            disabledPlatforms: ["x", "linkedin", "instagram"])
    }
    private static func response(_ object: [String: Any], status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(status: status, headers: [:], body: try JSONSerialization.data(withJSONObject: object))
    }
    private static func responses(insightsStatus: Int = 200, strategyDate: String = "2026-11-01T00:00:00Z") throws -> [HTTPResponse] {
        [try response(["strategy": ["positioning": "Practical AI support", "audience": "Clinics using AI", "updatedAt": strategyDate]]),
         try response(["disabledPlatforms": ["instagram"], "conversations": [
            ["id": "one", "author_handle": "Synthetic enquiry", "intent": "lead", "priority": 1, "status": "open", "last_message_at": Date.now.ISO8601Format(), "platform": "instagram", "latest_message": "I need help with our AI workflow"],
            ["id": "ignored", "author_handle": "Ignored", "intent": "lead", "priority": 1, "status": "ignored", "last_message_at": Date.now.ISO8601Format(), "platform": "x"],
            ["id": "community", "author_handle": "Community", "intent": "community", "priority": 4, "status": "open", "last_message_at": Date.now.ISO8601Format(), "platform": "x"]]]),
         try response(["window": "30d", "totals": ["posts": 10, "impressions": 1_000_000, "engagements": 500, "follows": 3], "pillars": [["name": "Workflow", "posts": 2, "avg_score": 80.5]]], status: insightsStatus)]
    }
    private static func enquiry() -> Lead {
        var lead = Lead.blank(); lead.name = "Synthetic enquiry"; lead.sourceID = "kairos:one"
        lead.sourceMessage = "I need help with our AI workflow"; lead.sourcePlatform = "instagram"; lead.sourceUpdatedAt = Date.now.addingTimeInterval(-60).ISO8601Format()
        lead.outreachDraft = "Owner's unsent draft"; lead.lastMessage = "Owner's earlier outgoing context"
        lead.history = [FollowUpEvent(date: "2026-11-01", message: "Owner's recorded follow-up")]
        return lead
    }

    private static func contextRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cw-discovery-context-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DiscoveryTests.FakeTransport(try responses() + responses(strategyDate: "2026-11-02T00:00:00Z") + responses())
        let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore([.kairos: "synthetic-discovery-key"]), transport: transport, reviewMode: false)
        var original = enquiry(); original.status = .quoteSent; original.sourceUpdatedAt = "2026-01-01T00:00:00Z"
        try store.commitWorkspace { $0.leads = [original] }
        let saved = await store.refreshKairosDiscovery()
        try check(saved && store.leads.count == 1, "context refresh failed or imported ignored/non-lead records")
        let lead = store.leads[0]
        try check(lead.id == original.id && lead.status == .quoteSent && lead.outreachDraft == original.outreachDraft && lead.lastMessage == original.lastMessage && lead.history == original.history, "incoming context overwrote identity/outreach")
        try check(store.websiteResearch.enquiryBusinessLinks == nil, "refresh silently associated an identity")
        try check(store.websiteResearch.kairosContext?.disabledPlatforms == ["instagram"], "pause state was lost")
        let revision = store.websiteResearch.kairosContext!.strategyRevision
        let repeated = await store.refreshKairosDiscovery()
        try check(repeated && store.websiteResearch.kairosContext?.strategyRevision == revision && store.leads.count == 1, "same targeting invalidates fit or duplicates a lead")
        try check(transport.requests.allSatisfy { $0.httpMethod == "GET" && ["/v1/strategy", "/v1/inbox", "/v1/insights"].contains($0.url?.path ?? "") }, "context refresh performed a provider write or an unrelated request")
        try check(!String(decoding: Data(contentsOf: store.storageURL), as: UTF8.self).contains("synthetic-discovery-key"), "context persisted a credential")
        let reloaded = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
        try check(reloaded.websiteResearch == store.websiteResearch, "context did not survive reload")
        try check(store.delete(store.leads[0]), "enquiry deletion failed")
        let afterDelete = await store.refreshKairosDiscovery()
        try check(afterDelete && store.leads.isEmpty && store.workspace.dismissedLeadSources.contains("kairos:one"), "context refresh recreated a deliberately deleted enquiry")
    }

    private static func contextFailure() async throws {
        for malformed in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("cw-discovery-context-failure-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let transport = DiscoveryTests.FakeTransport(malformed ? [try response([:])] : try responses(insightsStatus: 500))
            let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore([.kairos: "synthetic-key"]), transport: transport, reviewMode: false)
            try store.commitWorkspace { $0.websiteResearch.kairosContext = context(); $0.leads = [enquiry()] }
            let cache = store.websiteResearch, leads = store.leads
            let saved = await store.refreshKairosDiscovery()
            try check(!saved && store.websiteResearch == cache && store.leads == leads, "partial failure published a new strategy, enquiry or metric")
            try check(store.latestSyncJob(for: .kairos)?.status == "failed", "old success masks failure")
        }
    }

    private static func reviewedAssociations() async throws {
        let (candidate, research, _) = try await DiscoveryTests.researchFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cw-discovery-links-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("data"), retained = root.appendingPathComponent("retained")
        let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore())
        let incoming = enquiry()
        try store.commitWorkspace { $0.websiteResearch.merge(candidate, result: research); $0.leads = [incoming] }
        let key = DiscoveryIntelligence.businessKey(candidate, research: research), before = try encoded(store.workspace)
        try FileManager.default.moveItem(at: directory, to: retained); try Data("write blocker".utf8).write(to: directory)
        try check(!store.linkDiscoveryEnquiry(sourceID: incoming.sourceID!, businessKey: key, reason: "Owner verified the enquiry concerns this business"), "failed save reported a successful association")
        try check(!store.reviewDiscoveryFit(businessKey: key, decision: .fits, reason: "Owner-reviewed offer fit", strategyRevision: nil), "failed save published a fit review")
        try check(try encoded(store.workspace) == before, "failed save changed the in-memory workspace")
        try FileManager.default.removeItem(at: directory); try FileManager.default.moveItem(at: retained, to: directory)
        try check(store.linkDiscoveryEnquiry(sourceID: incoming.sourceID!, businessKey: key, reason: "Owner verified the enquiry concerns this business"), "association retry failed")
        let link = store.websiteResearch.enquiryBusinessLinks?[incoming.sourceID!]
        try check(link?.incomingExcerpt == incoming.sourceMessage && link?.incomingAt == incoming.sourceUpdatedAt && link?.businessSourceURL == candidate.sourceURL && link?.reason?.isEmpty == false, "association lost the evidence used for confirmation")
        try check(store.reviewDiscoveryFit(businessKey: key, decision: .fits, reason: "Owner-reviewed offer fit", strategyRevision: nil), "fit review failed")
        let disk = try Data(contentsOf: store.storageURL)
        try check(store.linkDiscoveryEnquiry(sourceID: incoming.sourceID!, businessKey: key, reason: "Owner verified the enquiry concerns this business") && store.reviewDiscoveryFit(businessKey: key, decision: .fits, reason: "Owner-reviewed offer fit", strategyRevision: nil), "repeated decision failed")
        try check(try Data(contentsOf: store.storageURL) == disk && store.leads == [incoming], "replay changed bytes or CRM/outreach history")
        let reload = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
        try check(reload.websiteResearch == store.websiteResearch, "reviewed association did not persist")
        let backup = root.appendingPathComponent("backup.json"); try store.exportControlWardBackup(to: backup)
        try check(try AppStore.readControlWardBackup(Data(contentsOf: backup)).workspace.websiteResearch == store.websiteResearch, "backup lost the reviews")
        try check(!store.linkDiscoveryEnquiry(sourceID: "manual", businessKey: key), "non-KAIROS record was linked")
        let previouslyLinked = store.websiteResearch
        try check(store.linkDiscoveryEnquiry(sourceID: incoming.sourceID!, businessKey: nil), "unlink failed")
        var merged = store.websiteResearch; merged.mergePreservingNewest(previouslyLinked)
        try check(merged.enquiryBusinessLinks?[incoming.sourceID!]?.businessKey == nil, "older research resurrected a removed association")
        try check(store.delete(incoming) && store.websiteResearch.enquiryBusinessLinks?[incoming.sourceID!]?.incomingExcerpt == nil, "deleting an enquiry retained a hidden message excerpt")
    }

    private static func identityEvidence() async throws {
        let (candidate, research, _) = try await DiscoveryTests.researchFixture()
        var cache = WebsiteResearchCache(); cache.merge(candidate, result: research)
        var alias = candidate; alias.sourceID = "website:alias"
        var aliasResearch = research; aliasResearch.record.id = "cw:" + alias.sourceID; aliasResearch.checkedAt = research.checkedAt.addingTimeInterval(1)
        cache.merge(alias, result: aliasResearch)
        let groups = DiscoveryIntelligence.businesses(cache)
        try check(groups.count == 1 && groups[0].aliases.count == 2 && groups[0].verifiedWebsite, "same website did not form one evidenced group")
        var incoming = enquiry(); incoming.name = candidate.name; incoming.sourceMessage = candidate.name
        try check(DiscoveryIntelligence.suggestion(incoming, for: groups[0]) == nil, "same name created an identity match")
        let host = DiscoveryIntelligence.host(candidate.website)!
        incoming.name = "https://" + host; incoming.sourceMessage = "Please help with a workflow."
        try check(DiscoveryIntelligence.suggestion(incoming, for: groups[0]) == nil, "an author handle supplied unsupported website identity")
        incoming.name = groups[0].supportedContacts.first { $0.kind == .email }?.value ?? ("person@" + host)
        try check(DiscoveryIntelligence.suggestion(incoming, for: groups[0]) == nil, "an author handle supplied unsupported mailbox identity")
        incoming.sourceMessage = "Please review https://\(host).unrelated.test"
        try check(DiscoveryIntelligence.suggestion(incoming, for: groups[0]) == nil, "substring domain created a match")
        incoming.sourceMessage = "Please review https://\(host)/about"
        try check(DiscoveryIntelligence.suggestion(incoming, for: groups[0]) != nil && cache.enquiryBusinessLinks == nil, "explicit website evidence missing or suggestion auto-confirmed")
        var unverified = groups[0]; unverified.research = nil
        try check(unverified.supportedContacts.isEmpty && DiscoveryIntelligence.suggestion(incoming, for: unverified) == nil, "listing input counted as a verified contact/business")
        var a = candidate, b = candidate; a.sourceID = "a"; b.sourceID = "b"; a.website = "https://etsy.com/shop/a"; b.website = "https://etsy.com/shop/b"
        var shared = WebsiteResearchCache(); shared.discover([a,b])
        try check(DiscoveryIntelligence.businesses(shared).count == 2, "shared platform merged unrelated businesses")
        a.website = "https://unlisted-directory.example.test/business/a"; b.website = "https://unlisted-directory.example.test/business/b"
        shared = WebsiteResearchCache(); shared.discover([a,b])
        try check(DiscoveryIntelligence.businesses(shared).count == 2, "unresearched arbitrary directory inputs merged by host")
    }

    private static func separateAssessments() async throws {
        let (candidate, research, _) = try await DiscoveryTests.researchFixture()
        var cache = WebsiteResearchCache(); cache.merge(candidate, result: research); cache.kairosContext = context()
        let key = DiscoveryIntelligence.businessKey(candidate, research: research)
        let unknown = DiscoveryIntelligence.attention(cache: cache, leads: [])[0]
        try check(unknown.fit == .unassessed && unknown.recentOpenEnquiries.isEmpty && unknown.interestLabel.contains("unknown"), "content performance or AI use became offer fit/buyer intent")
        let incoming = enquiry(); var duplicate = incoming; duplicate.id = UUID()
        cache.kairosContext!.enquiryStates = [incoming.sourceID!: .init(intent: "lead", status: "open", lastMessageAt: incoming.sourceUpdatedAt!, hasIncomingText: true)]
        cache.enquiryBusinessLinks = [incoming.sourceID!: .init(businessKey: key, confirmedAt: Date.now.ISO8601Format())]
        var assessment = DiscoveryIntelligence.attention(cache: cache, leads: [incoming, duplicate])[0]
        try check(assessment.enquiries.count == 1 && assessment.recentOpenEnquiries.count == 1 && !assessment.business.supportedContacts.isEmpty, "enquiry dedupe or independent contact evidence failed")
        cache.fitReviews = [key: .init(decision: .fits, reason: "Owner reviewed the audience", reviewedAt: Date.now.ISO8601Format(), strategyRevision: cache.kairosContext!.strategyRevision)]
        try check(DiscoveryIntelligence.attention(cache: cache, leads: [incoming])[0].fit == .fits, "explained fit was not used")
        cache.kairosContext!.strategyRevision = UUID()
        try check(DiscoveryIntelligence.attention(cache: cache, leads: [incoming])[0].fit == .unassessed, "changed targeting kept a stale fit decision")
        for state in ["closed", "old", "future", "missing"] {
            var row = incoming
            if state == "closed" { row.status = .won }
            if state == "old" { row.sourceUpdatedAt = Date.now.addingTimeInterval(-40 * 86_400).ISO8601Format() }
            if state == "future" { row.sourceUpdatedAt = Date.now.addingTimeInterval(86_400).ISO8601Format() }
            if state == "missing" { row.sourceMessage = nil }
            assessment = DiscoveryIntelligence.attention(cache: cache, leads: [row])[0]
            try check(assessment.recentOpenEnquiries.isEmpty, "\(state) enquiry became current interest")
        }
    }

    private static func compatibility() async throws {
        let legacy = try JSONDecoder().decode(WebsiteResearchCache.self, from: Data(#"{"candidates":[],"results":{}}"#.utf8))
        try legacy.validate(); try check(legacy.kairosContext == nil && legacy.fitReviews == nil && legacy.enquiryBusinessLinks == nil, "old cache no longer decodes")
        for invalidEndpoint in ["https://user:password@example.test", "https://example.test?api_key=synthetic"] {
            var value = context(); value.endpoint = invalidEndpoint
            do { try value.validate(); throw SmokeTestFailure.failed("unsafe endpoint accepted") } catch ResearchStorageError.invalidCache {}
        }
        var invalid = context(); invalid.insights.totals.impressions = -1
        do { try invalid.validate(); throw SmokeTestFailure.failed("negative metrics accepted") } catch ResearchStorageError.invalidCache {}
        let emptyStrategy = try KairosClient(endpoint: "https://kairos.example.test", apiKey: "synthetic-key", transport: DiscoveryTests.FakeTransport([try response(["strategy": NSNull()])]))
        let noStrategy = try await emptyStrategy.strategy()
        try check(noStrategy == nil, "strategy:null was not retained as unknown targeting")
        let nullable = try JSONDecoder().decode(KairosInsights.self, from: JSONSerialization.data(withJSONObject: ["window":"30d", "totals":["posts":0,"impressions":0,"engagements":0,"follows":0], "pillars":[["name":"Untested topic","posts":0,"avg_score":NSNull()]]]))
        try check(nullable.pillars.first?.avg_score == nil, "absent metrics became a fabricated content score")
    }

    private static func contextSaveFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cw-discovery-snapshot-save-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("data"), retained = root.appendingPathComponent("retained")
        let transport = DiscoveryTests.FakeTransport(try responses() + responses())
        let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore([.kairos: "synthetic-key"]), transport: transport, reviewMode: false)
        try store.commitWorkspace { $0.websiteResearch.kairosContext = context() }
        let before = try encoded(store.workspace)
        try FileManager.default.moveItem(at: directory, to: retained); try Data("write blocker".utf8).write(to: directory)
        let failed = await store.refreshKairosDiscovery()
        try check(!failed && (try encoded(store.workspace)) == before, "failed context commit published a partial success")
        try FileManager.default.removeItem(at: directory); try FileManager.default.moveItem(at: retained, to: directory)
        let saved = await store.refreshKairosDiscovery()
        try check(saved && store.leads.count == 1, "context retry lost or duplicated an enquiry")
        let reopened = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore())
        try check(try encoded(reopened.workspace) == encoded(store.workspace), "retried context failed to survive reload")
    }

    private final class SwitchingTransport: HTTPTransport, @unchecked Sendable {
        let inner: DiscoveryTests.FakeTransport
        let lock = NSLock()
        var firstAction: (@MainActor @Sendable () -> Void)?
        init(_ responses: [HTTPResponse]) { inner = DiscoveryTests.FakeTransport(responses) }
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            let action = lock.withLock { let action = firstAction; firstAction = nil; return action }
            if let action { await action() }
            return try await inner.send(request)
        }
    }

    private static func changedConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cw-discovery-changed-connection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SwitchingTransport(try responses())
        let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore([.kairos: "synthetic-key"]), transport: transport, reviewMode: false)
        transport.firstAction = { store.setEndpoint("https://different.example.test", for: .kairos) }
        let saved = await store.refreshKairosDiscovery()
        try check(!saved && store.leads.isEmpty && store.websiteResearch.kairosContext == nil, "old connection populated the changed workspace")
    }

    private static func sourceEligibility() async throws {
        let (candidate, research, _) = try await DiscoveryTests.researchFixture()
        var packets = try responses()
        for mode in ["ignored", "reclassified", "absent", "no-text"] {
            var next = try responses()
            var body = try JSONSerialization.jsonObject(with: next[1].body) as! [String: Any]
            var rows = body["conversations"] as! [[String: Any]]
            var row = rows[0]
            if mode == "ignored" { row["status"] = "ignored" }
            if mode == "reclassified" { row["intent"] = "community" }
            if mode == "no-text" { row["latest_message"] = NSNull() }
            rows = mode == "absent" ? [] : [row]; body["conversations"] = rows
            next[1] = try response(body); packets += next
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cw-discovery-source-state-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storageURL: root.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore([.kairos: "synthetic-key"]), transport: DiscoveryTests.FakeTransport(packets), reviewMode: false)
        try store.commitWorkspace { $0.websiteResearch.merge(candidate, result: research) }
        let first = await store.refreshKairosDiscovery(); try check(first, "initial source snapshot failed")
        let key = DiscoveryIntelligence.businessKey(candidate, research: research)
        try check(store.linkDiscoveryEnquiry(sourceID: "kairos:one", businessKey: key, reason: "Synthetic identity reviewed"), "source association failed")
        try check(DiscoveryIntelligence.attention(cache: store.websiteResearch, leads: store.leads)[0].recentOpenEnquiries.count == 1, "current recorded source interest was not recognized")
        let retained = store.leads
        for mode in ["ignored", "reclassified", "absent", "no-text"] {
            let refreshed = await store.refreshKairosDiscovery()
            let attention = DiscoveryIntelligence.attention(cache: store.websiteResearch, leads: store.leads)[0]
            try check(refreshed && attention.recentOpenEnquiries.isEmpty && attention.enquiries.count == 1, "\(mode) source retained current interest or lost retained evidence")
            try check(store.leads[0].id == retained[0].id && store.leads[0].status == retained[0].status && store.leads[0].history == retained[0].history && store.leads[0].outreachDraft == retained[0].outreachDraft,
                      "\(mode) source changed owner workflow/history")
            if mode == "absent" { try check(store.leads == retained && attention.interestReasons[0].contains("absence is not retraction"), "bounded absence became a destructive retraction") }
        }
    }
}
