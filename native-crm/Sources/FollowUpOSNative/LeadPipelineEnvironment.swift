import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the lead pipeline keeps its files, and how a run is put together. Used by the app's Prospect search
/// sheet and by bin/prove-lead-pipeline, so both go through exactly the same code path.
struct LeadPipelineEnvironment: Sendable {
    let config: ICPConfig
    let root: URL

    var storeURL: URL { root.appendingPathComponent("prospects.json") }
    var auditURL: URL { root.appendingPathComponent("cw-audit.log") }
    var suppressionURL: URL { root.appendingPathComponent("suppression.json") }
    var draftsURL: URL { root.appendingPathComponent("drafts.json") }
    var rbqDirectory: URL { root.appendingPathComponent("rbq") }
    /// Place ids and normalized domains seen by discovery (no contact data), for the funnel.
    var discoveredURL: URL { root.appendingPathComponent("discovered.json") }

    /// `CONTROLWARD_LEADS_DIR`, else `~/Library/Application Support/ControlWard/leads`.
    static func defaultRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["CONTROLWARD_LEADS_DIR"], !env.isEmpty { return URL(fileURLWithPath: env) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ControlWard/leads")
    }

    /// Loads icp.json and refuses to start if it does not match the confirmed segment list (S3-R9).
    static func load(configDirectory: URL, root: URL = defaultRoot()) throws -> LeadPipelineEnvironment {
        let config = try ICPConfig.load(directory: configDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return LeadPipelineEnvironment(config: config, root: root)
    }

    var audit: FileAuditSink { FileAuditSink(url: auditURL) }

    /// Written once when the Leads screen opens or a proof run starts: how many prospects the store held.
    func recordLaunch(audit: any CWAuditSink, now: Date = Date()) -> Int {
        let count = ProspectLeadsStore(fileURL: storeURL).records.count
        audit.write(CWAuditLine(ts: now, surface: "leads", action: "launch", target: "leads-list", source: "controlward",
                                result: "ok", receipt: "store-\(count)"))
        return count
    }

    /// The RBQ index from the local cache only. Downloading is a separate, explicit step (at most daily).
    /// Throws when the cached file is not the real JSON shape the hold relies on (refused:open-data-schema).
    func cachedRBQIndex() throws -> RBQIndex? {
        guard let source = RBQOpenData.source(config) else { return nil }
        let file = RBQOpenData.cacheFile(in: rbqDirectory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        var index = RBQIndex()
        try RBQOpenData.parse(file: file, source: source) { index.add($0) }
        return index
    }

    func makeRun(inner: any LeadTransport = URLSessionLeadTransport(), audit: any CWAuditSink, clock: any LeadClock = SystemLeadClock(),
                 rbq: RBQIndex? = nil, watchItems: [WatchItem] = []) -> (ProspectSearchRun, GuardedLeadTransport) {
        let guarded = GuardedLeadTransport(config: config, inner: inner, audit: audit, clock: clock)
        var run = ProspectSearchRun(config: config, transport: guarded, audit: audit, clock: clock,
                                    suppression: SuppressionList(storageURL: suppressionURL))
        run.rbq = rbq
        run.watchItems = watchItems
        return (run, guarded)
    }

    /// Search, then pull the results into the Leads list and save the drafts locally. Nothing is sent.
    func searchAndIngest(_ requests: [ProspectSearchRun.Request], inner: any LeadTransport = URLSessionLeadTransport(),
                         audit: any CWAuditSink, clock: any LeadClock = SystemLeadClock()) async -> [ProspectSearchRun.Report] {
        var rbq: RBQIndex?
        var rbqFailure: String?
        do { rbq = try cachedRBQIndex() } catch {
            // A cached RBQ file we cannot read must not switch the conflict hold off: the run goes on, and
            // LeadDefinition keeps the fail-closed hold where the SOS rule still applies (a plumbing or excavation
            // firm in Saguenay, or any required-segment firm whose town cannot be read). The refusal is audited.
            let code = (error as? LeadPipelineRefusal)?.code ?? "error:rbq-cache"
            rbqFailure = code
            audit.write(CWAuditLine(ts: clock.now, surface: "leads", action: "rbq-load", target: RBQOpenData.sourceID, source: "rbq_open_data",
                                    result: code, receipt: "-"))
        }
        var (run, _) = makeRun(inner: inner, audit: audit, clock: clock, rbq: rbq)
        run.rbqFailure = rbqFailure
        var reports: [ProspectSearchRun.Report] = []
        let store = ProspectLeadsStore(fileURL: storeURL)
        for request in requests {
            let report = await run.run(request)
            _ = await ProspectIngest.ingest(report.prospects, into: store, config: config, now: clock.now, audit: audit)
            reports.append(report)
        }
        let places = DiscoveredPlace.merge(reports.flatMap(\.discovered), into: discoveredPlaces())
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.iso.encode(places) { try? data.write(to: discoveredURL, options: .atomic) }
        var drafts = (try? JSONDecoder.iso.decode([OutreachDraft].self, from: Data(contentsOf: draftsURL))) ?? []
        drafts += reports.flatMap(\.drafts)
        if let data = try? JSONEncoder.iso.encode(drafts) { try? data.write(to: draftsURL, options: .atomic) }
        return reports
    }

    /// Reads a finished run back for the proof: launch count, audit lines, stored prospects and drafts.
    func proofInputs() -> (launchCount: Int, lines: [String], prospects: [ProspectRecord], drafts: [OutreachDraft]) {
        let lines = ((try? String(contentsOf: auditURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        let launch = lines.compactMap(CWAuditLine.parse).first { $0["surface"] == "leads" && $0["action"] == "launch" }
        let count = launch?["receipt"].flatMap { Int($0.replacingOccurrences(of: "store-", with: "")) } ?? -1
        let drafts = (try? JSONDecoder.iso.decode([OutreachDraft].self, from: Data(contentsOf: draftsURL))) ?? []
        return (count, lines, ProspectLeadsStore(fileURL: storeURL).records, drafts)
    }

    func discoveredPlaces() -> [DiscoveredPlace] {
        (try? JSONDecoder.iso.decode([DiscoveredPlace].self, from: Data(contentsOf: discoveredURL))) ?? []
    }

    /// The Overview funnel: discovered → usable website → appropriate contact → evidence-backed opportunity.
    func funnel(now: Date = Date()) -> LeadFunnel {
        LeadFunnel.compute(places: discoveredPlaces(), records: ProspectLeadsStore(fileURL: storeURL).records, config: config, now: now)
    }
}
