import Foundation

@MainActor
enum ResearchRecoveryTests {
    static func run() async -> Bool {
        let expect = PortableCheck.expect
        var passed = 0
        let cases: [(String, @MainActor () async throws -> Void)] = [
            ("Legacy research migrates once, with original bytes and a private rollback preserved", {
                let directory = AgentResearchTests.root(); defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("workspace.json")
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PersistentWorkspace())) as! [String: Any]
                for key in ["websiteResearch", "researchMigrationComplete", "researchGeneration"] { object.removeValue(forKey: key) }
                let original = try JSONSerialization.data(withJSONObject: object)
                try SecureFiles.writePrivate(original, to: file)
                let candidate = try WebsiteResearchQueue.parse("Example | https://example.test")[0]
                var cache = WebsiteResearchCache(); cache.discover([candidate])
                let legacy = directory.appendingPathComponent("quick-scan-research.json"); try cache.save(legacy)
                let source = try Data(contentsOf: legacy)
                let store = AppStore(storageURL: file, secrets: InMemorySecretStore(), researchRoot: directory)
                try expect(store.websiteResearch == cache && store.workspace.researchMigrationComplete, "research imported")
                let copies = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("before-research-migration-") }
                try expect(copies.count == 1 && Data(contentsOf: copies[0]) == original, "exact original rollback")
                try expect(try Data(contentsOf: legacy) == source, "legacy source preserved")
                _ = AppStore(storageURL: file, secrets: InMemorySecretStore(), researchRoot: directory)
                try expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("before-research-migration-") }.count == 1, "migration not repeated")
                try expect((try FileManager.default.attributesOfItem(atPath: copies[0].path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private rollback")
            }),
            ("Corrupt legacy research remains untouched and prevents a false complete export", {
                let directory = AgentResearchTests.root(); defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("workspace.json")
                var workspace = PersistentWorkspace(); workspace.researchMigrationComplete = false
                try SecureFiles.writePrivate(JSONEncoder().encode(workspace), to: file)
                let corrupt = directory.appendingPathComponent("quick-scan-research.json")
                let original = Data("damaged research fixture".utf8); try SecureFiles.writePrivate(original, to: corrupt)
                let store = AppStore(storageURL: file, secrets: InMemorySecretStore(), researchRoot: directory)
                try expect(store.researchFailure != nil && !store.workspace.researchMigrationComplete, "persistent error")
                do { try store.exportControlWardBackup(to: directory.appendingPathComponent("backup.json")); throw PortableCheckFailure(description: "partial export accepted") }
                catch is PortableCheckFailure { throw PortableCheckFailure(description: "partial export accepted") }
                catch { }
                try expect(try Data(contentsOf: corrupt) == original, "corrupt original preserved")
            }),
            ("Unreviewed research, exact draft, links and exclusions survive export restore and reopen", {
                let directory = AgentResearchTests.root(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(), researchRoot: directory)
                let (researcher, _, source) = try QuickScanResearchTests.fixture()
                var result = await researcher.research(source, segmentID: "clinic")
                let candidates = try WebsiteResearchQueue.parse("Clinique Exemple Nord | \(LeadKit.homePage)\nUnreviewed | https://unreviewed.test")
                result.record.id = "cw:" + candidates[0].sourceID
                try store.recordDiscoveryCandidates(candidates)
                try store.recordWebsiteResearch(candidates[0], result: result)
                var lead = Lead.blank(); lead.name = "Saved example"; lead.email = result.email!; lead.quickScanResearch = result; lead.outreachDraft = "Exact unsent text"; lead.companyID = UUID()
                try expect(store.add(lead), "lead saved")
                try expect(store.suppressionList.record("old@example.test", at: .now, via: "unsubscribe"), "current exclusion saved")
                let exported = directory.appendingPathComponent("backup.json"); try store.exportControlWardBackup(to: exported)
                let data = try Data(contentsOf: exported)
                let value = try AppStore.readControlWardBackup(data)
                try expect(value.schemaVersion == 2 && value.workspace.websiteResearch.candidates.count == 2 && value.workspace.websiteResearch.results.count == 1, "unreviewed evidence included")
                try expect(store.suppressionList.record("new@example.test", at: .now, via: "unsubscribe"), "later exclusion saved")
                let generation = store.workspace.researchGeneration
                try store.restoreControlWardBackup(data, confirmed: true)
                let reopened = AppStore(storageURL: store.storageURL, secrets: InMemorySecretStore(), researchRoot: directory)
                try expect(reopened.websiteResearch == value.workspace.websiteResearch && reopened.leads.first == lead, "research and exact linked draft survive")
                try expect(reopened.workspace.researchGeneration != generation && reopened.workspace.researchGeneration != value.workspace.researchGeneration, "new generation ignores imported generation")
                try expect(reopened.suppressionList.contains("old@example.test") && reopened.suppressionList.contains("new@example.test"), "restore never weakens current exclusions")
                try expect((try FileManager.default.attributesOfItem(atPath: exported.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private export")
            }),
            ("Older backups retain existing research and active research blocks restore and reset", {
                let directory = AgentResearchTests.root(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(), researchRoot: directory)
                try store.recordDiscoveryCandidates(WebsiteResearchQueue.parse("Example | https://example.test"))
                var old = PersistentWorkspace(); old.researchMigrationComplete = false
                let backup = try JSONEncoder().encode(ControlWardBackup(schemaVersion: 1, workspace: old))
                let token = store.beginResearch(); let before = try Data(contentsOf: store.storageURL)
                for action in [ { try store.restoreControlWardBackup(backup, confirmed: true) }, { _ = try store.resetAll(confirmed: true) } ] {
                    var refused = false; do { try action() } catch { refused = true }
                    try expect(refused, "busy mutation refused")
                }
                try expect(try Data(contentsOf: store.storageURL) == before, "busy operations wrote nothing")
                store.endResearch(token)
                try store.restoreControlWardBackup(backup, confirmed: true)
                try expect(store.websiteResearch.candidates.count == 1, "old backup retains current research")
            }),
            ("Failed commit retains a completed observation and recovers once after storage repair", {
                let directory = AgentResearchTests.root(); defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("workspace.json")
                let store = AppStore(storageURL: file, secrets: InMemorySecretStore(), researchRoot: directory)
                let now = Date.now.addingTimeInterval(-120)
                let (_, inner, _) = try QuickScanResearchTests.fixture(now: now)
                let preserved = directory.appendingPathComponent("preserved.json")
                inner.onSend = { request in
                    if request.url?.path == "/intelligence-artificielle" {
                        try? FileManager.default.moveItem(at: file, to: preserved)
                        try? FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
                    }
                }
                let job = AgentResearchTests.request(now: now, generation: store.workspace.researchGeneration)
                let outcome = await AgentResearchCoordinator().execute(job, store: store, root: directory, config: try LeadKit.config().interactiveSearch(), output: directory.appendingPathComponent("result.json"), inner: inner, clock: FakeLeadClock(now))
                try expect(outcome.status == "failed" && !inner.urls.isEmpty && store.leads.isEmpty && store.websiteResearch.results.isEmpty, "failed write not published")
                let delta = try WebsiteResearchCache.load(directory.appendingPathComponent("research-recovery.json"))
                try expect(delta.results.count == 1 && store.researchFailure != nil, "completed evidence retained privately")
                try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: preserved, to: file)
                let recovered = AppStore(storageURL: file, secrets: InMemorySecretStore(), researchRoot: directory)
                try expect(recovered.websiteResearch.results.count == 1 && recovered.leads.isEmpty && recovered.researchFailure == nil, "recovered without promotion")
                let after = try Data(contentsOf: file)
                _ = AppStore(storageURL: file, secrets: InMemorySecretStore(), researchRoot: directory)
                try expect(try Data(contentsOf: file) == after, "consumed delta does not rewrite or duplicate")
                var empty = PersistentWorkspace()
                empty.researchMigrationComplete = true
                try recovered.restoreControlWardBackup(JSONEncoder().encode(ControlWardBackup(workspace: empty)), confirmed: true)
                let restored = AppStore(storageURL: file, secrets: InMemorySecretStore(), researchRoot: directory)
                try expect(restored.websiteResearch.candidates.isEmpty, "deliberate restore never resurrects consumed recovery")
            }),
            ("Restored generation cancels queued work with zero fetches; fresh requests work", {
                let directory = AgentResearchTests.root(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(), researchRoot: directory)
                let now = Date.now.addingTimeInterval(-120)
                let stale = AgentResearchTests.request(now: now, generation: store.workspace.researchGeneration)
                try store.restoreControlWardBackup(JSONEncoder().encode(ControlWardBackup(workspace: PersistentWorkspace())), confirmed: true)
                let (_, inner, _) = try QuickScanResearchTests.fixture(now: now)
                let coordinator = AgentResearchCoordinator(); let output = directory.appendingPathComponent("result.json")
                let cancelled = await coordinator.execute(stale, store: store, root: directory, config: try LeadKit.config().interactiveSearch(), output: output, inner: inner, clock: FakeLeadClock(now))
                try expect(cancelled.status == "cancelled" && inner.urls.isEmpty && store.websiteResearch.candidates.isEmpty, "stale queued request never fetched")
                var fresh = stale; fresh.id = UUID(); fresh.workspaceGeneration = store.workspace.researchGeneration
                let done = await coordinator.execute(fresh, store: store, root: directory, config: try LeadKit.config().interactiveSearch(), output: output, inner: inner, clock: FakeLeadClock(now))
                try expect(done.status == "completed" && store.leads.count == 1, "fresh generation works")
            }),
            ("Damaged exclusion data prevents export restore and saved-draft handoff", {
                let directory = AgentResearchTests.root(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = AppStore(storageURL: directory.appendingPathComponent("workspace.json"), secrets: InMemorySecretStore(), researchRoot: directory)
                let corrupt = directory.appendingPathComponent("suppression.json"); try SecureFiles.writePrivate(Data("damaged fixture".utf8), to: corrupt)
                var refused = 0
                do { try store.exportControlWardBackup(to: directory.appendingPathComponent("bad.json")) } catch { refused += 1 }
                do { try store.restoreControlWardBackup(JSONEncoder().encode(ControlWardBackup(workspace: PersistentWorkspace())), confirmed: true) } catch { refused += 1 }
                try expect(refused == 2 && store.suppressionList.unavailableReason != nil, "corrupt policy never weakened")
            })
        ]
        for (name, action) in cases {
            do { try await action(); passed += 1; print("  PASS \(name)") }
            catch { print("  FAIL \(name): \(error)") }
        }
        print("Research recovery tests: \(passed)/\(cases.count) passed")
        return passed == cases.count
    }
}
