import Foundation
import Combine
import Darwin

/// An agent supplies discovery inputs only. Contacts, AI claims, drafts and send instructions are not inputs.
struct AgentResearchRequest: Codable, Equatable, Sendable {
    struct Site: Codable, Equatable, Sendable { var name: String; var url: String }
    var schema = 2
    var id: UUID
    var batchID: UUID
    var workspaceGeneration: UUID? = nil
    var query: String
    var createdAt: Date
    var expiresAt: Date
    var sites: [Site]

    func candidates(now: Date) throws -> [DiscoveryCandidate] {
        guard schema == 2, Self.isV4(id), Self.isV4(batchID),
              workspaceGeneration.map(Self.isV4) == true, !query.isEmpty, query.count <= 1000,
              createdAt <= now.addingTimeInterval(300), expiresAt > now,
              expiresAt > createdAt, expiresAt.timeIntervalSince(createdAt) <= 3600,
              (1...3).contains(sites.count), sites.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 200 && !$0.name.contains("|") && !$0.name.contains("\n") && !$0.url.contains("\n") }) else {
            throw AgentResearchError.invalidRequest
        }
        return try WebsiteResearchQueue.parse(sites.map { $0.name + " | " + $0.url }.joined(separator: "\n")).map { candidate in
            var sourced = candidate
            sourced.query = "Agent discovery target: \(query). Target match requires review; contact and AI use require website evidence."
            return sourced
        }
    }

    static func isV4(_ id: UUID) -> Bool { id.uuidString.split(separator: "-")[2].first == "4" }
}

enum AgentResearchError: Error { case invalidRequest, fileTooLarge, anotherProcessor }

private final class AgentResearchLease {
    let descriptor: Int32
    init?(_ url: URL) {
        let opened = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard opened >= 0 else { return nil }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else { close(opened); return nil }
        descriptor = opened
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

struct AgentResearchOutcome: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var sourceID: String
        var business: String
        var aiEvidenceFound: Bool
        var contactFound: Bool
        var leadID: UUID?
        var issues: [String]
    }
    var id: UUID
    var batchID: UUID
    var query: String
    /// running / completed / partial / cancelled / failed
    var status: String
    var entries: [Entry] = []
    var message = ""
    var updatedAt: Date
}

enum AgentResearchFiles {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try SecureFiles.ensurePrivateDirectory(url.deletingLastPathComponent())
        try SecureFiles.writePrivate(JSONEncoder.iso.encode(value), to: url)
    }

    static func request(_ url: URL) throws -> AgentResearchRequest {
        guard !((try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink ?? false) else { throw AgentResearchError.invalidRequest }
        let data = try Data(contentsOf: url)
        guard data.count <= 32_000 else { throw AgentResearchError.fileTooLarge }
        let value = try JSONDecoder.iso.decode(AgentResearchRequest.self, from: data)
        guard url.deletingPathExtension().lastPathComponent.lowercased() == value.id.uuidString.lowercased() else { throw AgentResearchError.invalidRequest }
        return value
    }
}

/// Receives explicit, local agent requests while the app is open. It does not start an AI agent, use
/// provider credentials, or execute commands from a request. Existing public-site research does all verification.
@MainActor
final class AgentResearchCoordinator: ObservableObject {
    @Published private(set) var summary = "Waiting for an agent research request."
    @Published private(set) var running = false
    @Published private(set) var recent: [AgentResearchOutcome] = []
    private var loop: Task<Void, Never>?
    private var work: Task<AgentResearchOutcome, Never>?
    private var directory: URL?
    private var cancelledByOwner = false
    private var deadlineReached = false
    private var currentBatch: UUID?
    private var lease: AgentResearchLease?

    struct Availability: Codable {
        var schema = 2
        var workspaceGeneration: UUID
        var pid: Int32
        var mode: String
        var reviewID: String?
        var build: String
        var updatedAt: Date
    }

    func start(store: AppStore, configDirectory: URL?) {
        guard loop == nil, let configDirectory else { return }
        let root = store.researchRoot
        directory = root.appendingPathComponent("agent-inbox", isDirectory: true)
        do {
            try SecureFiles.ensurePrivateDirectory(directory!)
            lease = AgentResearchLease(directory!.appendingPathComponent("coordinator.lock"))
            guard lease != nil else { summary = "Another ControlWard instance is handling research for this workspace."; return }
        } catch { summary = "The agent inbox could not be opened."; return }
        loop = Task {
            do {
                let config = try ICPConfig.load(directory: configDirectory).interactiveSearch()
                try publishAvailability(store: store)
                refreshRecent()
                while !Task.isCancelled {
                    try publishAvailability(store: store)
                    await processPending(store: store, root: root, config: config)
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            } catch { summary = "Agent research is unavailable: \(error). No request was sent." }
        }
    }

    func cancel() {
        cancelledByOwner = true
        if let directory, let currentBatch {
            try? AgentResearchFiles.write(["cancelled": true], to: directory.appendingPathComponent("cancel/\(currentBatch.uuidString.lowercased()).json"))
        }
        work?.cancel()
        summary = "Stopping research. Completed findings are retained."
    }

    private func publishAvailability(store: AppStore) throws {
        guard let directory else { return }
        let value = Availability(workspaceGeneration: store.workspace.researchGeneration, pid: ProcessInfo.processInfo.processIdentifier,
                                 mode: StorageLocation.isReview ? "review" : "normal",
                                 reviewID: StorageLocation.reviewID?.uuidString,
                                 build: BuildInfo.current.build, updatedAt: .now)
        try AgentResearchFiles.write(value, to: directory.appendingPathComponent("available.json"))
        try SecureFiles.ensurePrivateDirectory(directory.appendingPathComponent("requests"))
        try SecureFiles.ensurePrivateDirectory(directory.appendingPathComponent("results"))
    }

    private func processPending(store: AppStore, root: URL, config: ICPConfig) async {
        guard let directory else { return }
        // The OS releases this lock after a crash. Two review-app instances cannot process the same inbox together.
        let descriptor = open(directory.appendingPathComponent("processor.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { summary = "The agent inbox could not be locked."; return }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("requests"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var processed = 0
            for url in urls {
                guard !Task.isCancelled else { return }
                let output = directory.appendingPathComponent("results/" + url.lastPathComponent)
                if let data = try? Data(contentsOf: output), let previous = try? JSONDecoder.iso.decode(AgentResearchOutcome.self, from: data), previous.status != "running" { continue }
                guard processed < 100 else { break }
                processed += 1
                do {
                    let request = try AgentResearchFiles.request(url)
                    guard request.workspaceGeneration == store.workspace.researchGeneration else {
                        try AgentResearchFiles.write(AgentResearchOutcome(id: request.id, batchID: request.batchID, query: request.query, status: "cancelled", message: "The workspace was restored or reset. Submit a fresh request for this workspace generation. No website was contacted.", updatedAt: .now), to: output)
                        continue
                    }
                    _ = try request.candidates(now: .now)
                    let cancellation = directory.appendingPathComponent("cancel/\(request.batchID.uuidString.lowercased()).json")
                    if FileManager.default.fileExists(atPath: cancellation.path) {
                        try AgentResearchFiles.write(AgentResearchOutcome(id: request.id, batchID: request.batchID, query: request.query, status: "cancelled", message: "Batch cancelled. No further website requested.", updatedAt: .now), to: output)
                        continue
                    }
                    running = true
                    currentBatch = request.batchID
                    cancelledByOwner = false
                    deadlineReached = false
                    let task = Task { await execute(request, store: store, root: root, config: config, output: output) }
                    work = task
                    let deadline = Task {
                        for _ in 0..<90 {
                            do { try await Task.sleep(for: .seconds(2)) } catch { return }
                            if FileManager.default.fileExists(atPath: cancellation.path) {
                                cancelledByOwner = true; task.cancel(); return
                            }
                            try? publishAvailability(store: store)
                        }
                        deadlineReached = true
                        task.cancel()
                    }
                    var outcome = await task.value
                    deadline.cancel()
                    if deadlineReached { outcome.status = "partial"; outcome.message = "Time limit reached. Completed findings were kept." }
                    if cancelledByOwner { outcome.status = "cancelled"; outcome.message = "Cancelled by the owner. Completed findings were kept." }
                    try AgentResearchFiles.write(outcome, to: output)
                    recent.removeAll { $0.id == outcome.id }; recent.insert(outcome, at: 0)
                    recent = Array(recent.prefix(20))
                    running = false; work = nil
                    let ready = outcome.entries.filter { $0.leadID != nil }.count
                    summary = "Last request: \(outcome.entries.count) websites checked; \(ready) draft(s) ready in Pipeline. \(outcome.message)"
                    if cancelledByOwner { return }
                } catch {
                    // A malformed filename never becomes an output path supplied by a request.
                    if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), AgentResearchRequest.isV4(id) {
                        let outcome = AgentResearchOutcome(id: id, batchID: id, query: "Refused request", status: "failed", message: "Invalid, expired or unreadable research request. No website was contacted.", updatedAt: .now)
                        try? AgentResearchFiles.write(outcome, to: output)
                    }
                    summary = "An invalid or unreadable agent request was refused."
                    running = false; work = nil
                }
                try publishAvailability(store: store)
            }
        } catch { summary = "The agent inbox could not be read; existing data was retained." }
    }

    /// Shared by the app and synthetic native tests. The only network interface is the guarded research transport.
    func execute(_ request: AgentResearchRequest, store: AppStore, root: URL, config: ICPConfig, output: URL,
                 inner: any LeadTransport = URLSessionLeadTransport(), clock: any LeadClock = SystemLeadClock()) async -> AgentResearchOutcome {
        var outcome = AgentResearchOutcome(id: request.id, batchID: request.batchID, query: request.query, status: "running", updatedAt: clock.now)
        let generation = store.workspace.researchGeneration
        guard request.workspaceGeneration == generation else {
            outcome.status = "cancelled"
            outcome.message = "Workspace generation changed. No website was contacted; submit a fresh request."
            try? AgentResearchFiles.write(outcome, to: output)
            return outcome
        }
        let token = store.beginResearch()
        defer { store.endResearch(token) }
        let root = store.researchRoot
        do {
            let candidates = try request.candidates(now: clock.now)
            guard let segment = config.segments.first(where: { $0.osmSelectors.contains("office=company") }) else { throw AgentResearchError.invalidRequest }
            var cache = try store.researchSnapshot().cache
            try store.recordDiscoveryCandidates(candidates)
            let guarded = GuardedLeadTransport(config: config, inner: InteractiveLeadTransport(inner: inner), audit: FileAuditSink(url: root.appendingPathComponent("cw-audit.log")), clock: clock)
            let researcher = QuickScanResearcher(config: config, transport: guarded, clock: clock)
            try AgentResearchFiles.write(outcome, to: output)
            for candidate in candidates {
                guard !Task.isCancelled else { break }
                summary = "Agent research: \(candidate.name). Checking own-site contact and AI-use evidence."
                let source = LeadCandidate(osmID: candidate.sourceID, name: candidate.name, website: candidate.website, tags: [], city: nil,
                                           latitude: 0, longitude: 0, discoveredVia: candidate.sourceURL)
                let result: QuickScanResearchResult
                if let saved = cache.results[candidate.sourceID], saved.complete, saved.researchVersion == QuickScanResearcher.version,
                   // ISO storage rounds to milliseconds; allow only that rounding interval into the future.
                   clock.now.timeIntervalSince(saved.checkedAt) >= -0.001, clock.now.timeIntervalSince(saved.checkedAt) < 3600 {
                    result = saved
                } else { result = await researcher.research(source, segmentID: segment.id) }
                // Load before merging so a manual research run completed during this fetch is retained too.
                guard store.workspace.researchGeneration == generation else { throw AgentResearchError.invalidRequest }
                try store.recordWebsiteResearch(candidate, result: result)
                cache = store.websiteResearch
                var leadID: UUID?
                let assessment = result.draftAssessment(config: config, suppression: store.suppressionList, now: clock.now)
                if assessment.draft != nil {
                    leadID = store.acceptDiscovery(candidate, research: result, researchConfig: config)
                    if leadID == nil { throw GTMError.invalid("The researched lead could not be saved. No draft was published.") }
                }
                outcome.entries.append(.init(sourceID: candidate.sourceID, business: candidate.name, aiEvidenceFound: result.hasAIUseEvidence,
                                              contactFound: result.email != nil, leadID: leadID,
                                              issues: result.issues + result.record.reasons + (assessment.reason.map { ["Draft withheld: " + $0] } ?? [])))
                outcome.updatedAt = clock.now
                try AgentResearchFiles.write(outcome, to: output)
            }
            outcome.status = Task.isCancelled ? "partial" : "completed"
            outcome.message = "Findings are in saved research; eligible unsent drafts are in Pipeline. Nothing sent."
        } catch {
            outcome.status = "failed"
            outcome.message = "Research stopped without discarding existing records: \(error)."
        }
        outcome.updatedAt = clock.now
        do { try AgentResearchFiles.write(outcome, to: output) }
        catch { outcome.status = "failed"; outcome.message = "The result could not be saved. Existing records were retained." }
        return outcome
    }

    func refreshRecent() {
        guard let directory, let urls = try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("results"), includingPropertiesForKeys: nil) else { return }
        recent = urls.compactMap { url in
            guard let data = try? Data(contentsOf: url), data.count <= 2_000_000 else { return nil }
            return try? JSONDecoder.iso.decode(AgentResearchOutcome.self, from: data)
        }.sorted { $0.updatedAt > $1.updatedAt }.prefix(20).map { $0 }
    }
}
