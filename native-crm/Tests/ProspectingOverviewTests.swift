import Foundation

@MainActor
enum ProspectingOverviewTests {
    static func run() async -> Bool {
        do {
            let expect = PortableCheck.expect
            let now = Date.now.addingTimeInterval(-120)
            let (researcher, _, source) = try QuickScanResearchTests.fixture(now: now)
            let research = await researcher.research(source, segmentID: "clinic")
            let config = researcher.config.interactiveSearch()
            let candidate = try WebsiteResearchQueue.parse("Clinique Exemple Nord | \(LeadKit.homePage)")[0]
            let other = try WebsiteResearchQueue.parse("Unresearched Example | https://another.test/")[0]
            var noSite = other; noSite.sourceID = "osm:node:9002"; noSite.website = nil
            var cache = WebsiteResearchCache(); cache.discover([candidate, other, noSite]); cache.merge(candidate, result: research)
            var lead = Lead.blank(); lead.quickScanResearch = research
            let places = [DiscoveredPlace(placeID: source.osmID, domain: LeadKit.clinicDomain, usableWebsite: true)]
            func snapshot(_ cache: WebsiteResearchCache, records: [ProspectRecord] = [], leads: [Lead] = [], suppression: SuppressionList = SuppressionList(), at: Date? = nil) -> ProspectingOverviewSnapshot {
                ProspectingOverviewSnapshot.make(places: places, records: records, cache: cache, leads: leads, config: config, suppression: suppression, now: at ?? now)
            }
            let merged = snapshot(cache, records: [research.record], leads: [lead])
            try expect(merged.funnel.values == [3, 2, 1, 1], "map, website and CRM copies count once; unchecked websites are not qualified: \(merged.funnel.values)")
            print("  PASS Unified overview: all discovery paths, no duplicate or invented qualification")

            let suppression = SuppressionList()
            suppression.record("info@clinique-exemple.test", at: now, via: "test reply")
            try expect(snapshot(cache, suppression: suppression).funnel.values == [3, 2, 1, 0], "unsubscribed route is not draft-ready")
            try expect(snapshot(cache, at: now.addingTimeInterval(8 * 86_400)).funnel.evidenceBackedOpportunity == 0, "stale research is not draft-ready")
            print("  PASS Unified overview: suppression and freshness gates remain effective")

            var newer = research; newer.checkedAt = now.addingTimeInterval(20); newer.aiUse = []
            var updated = cache; updated.merge(candidate, result: newer)
            try expect(snapshot(updated, records: [research.record], leads: [lead]).funnel.evidenceBackedOpportunity == 0, "newer negative research overrides old CRM evidence")
            var held = research; held.checkedAt = now.addingTimeInterval(30); held.record.segment = "construction_trades"; held.record.status = .conflictReview
            updated.merge(candidate, result: held)
            try expect(snapshot(updated).funnel.evidenceBackedOpportunity == 0, "held trade is not draft-ready")
            print("  PASS Unified overview: current evidence and conflict holds outrank older ready records")

            var fabricated = research.record; fabricated.contact?.name = "Invented Person"
            var changed = research; changed.record = fabricated
            updated.merge(candidate, result: changed)
            try expect(snapshot(updated).funnel.appropriateContact == 0, "a name without source text is not a sourced contact")
            print("  PASS Unified overview: contact fields require literal own-site evidence")

            var test = research.record; test.isTest = true
            let excluded = ProspectingOverviewSnapshot.make(places: [], records: [test], cache: WebsiteResearchCache(), leads: [Lead.blank()], config: config, suppression: SuppressionList(), now: now)
            try expect(excluded.funnel.values == [0, 0, 0, 0], "test records and manual leads do not invent discoveries")
            let closed = [DiscoveredPlace(placeID: source.osmID, domain: LeadKit.clinicDomain, usableWebsite: true, closed: true)]
            try expect(ProspectingOverviewSnapshot.make(places: closed, records: [], cache: cache, leads: [], config: config, suppression: SuppressionList(), now: now).funnel.discovered == 2, "known closed businesses are excluded across sources")
            print("  PASS Unified overview: test and closed records stay out of business counts")

            let root = FileManager.default.temporaryDirectory.appendingPathComponent("controlward-overview-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            try cache.save(root.appendingPathComponent("quick-scan-research.json"))
            try expect(ProspectingOverviewSnapshot.load(root: root, leads: [lead], config: config, now: now).funnel.values == [3, 2, 1, 1], "counts survive file reload")
            let original = Data("broken research".utf8)
            try original.write(to: root.appendingPathComponent("quick-scan-research.json"))
            let partial = ProspectingOverviewSnapshot.load(root: root, leads: [lead], config: config, now: now)
            try expect(!partial.warnings.isEmpty && partial.funnel.discovered == 1, "damaged cache gives explicit partial counts and uses saved CRM evidence")
            try expect(try Data(contentsOf: root.appendingPathComponent("quick-scan-research.json")) == original, "read-only counts preserve corrupt bytes")
            print("  PASS Unified overview: reload and corrupt-source handling retain data")

            try cache.save(root.appendingPathComponent("quick-scan-research.json"))
            try Data("broken unsubscribe records".utf8).write(to: root.appendingPathComponent("suppression.json"))
            let blocked = ProspectingOverviewSnapshot.load(root: root, leads: [], config: config, now: now)
            try expect(blocked.funnel.evidenceBackedOpportunity == 0 && blocked.warnings.contains { $0.contains("Unsubscribe records") }, "unknown exclusions block readiness with a visible reason")
            print("  PASS Unified overview: unavailable exclusions cannot appear draft-ready")
            print("Unified prospecting overview tests: 7/7 passed")
            return true
        } catch { print("Unified prospecting overview tests: FAIL \(error)"); return false }
    }
}
