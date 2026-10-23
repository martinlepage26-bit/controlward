import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// bin/prove-lead-pipeline: Earth's live-proof bar in one command.
//
//   scripted (default): empty temp leads folder -> launch line -> live search through the same pipeline code
//                       the app uses -> ingest into the Leads store -> local drafts -> verify the five checks.
//   --verify-app DIR:   verify a folder written by the app's Leads sheet instead (no network).
//
// It never sends: there is no send path in the pipeline, and check 5 fails on any `action=send` line.

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}
func arguments(_ name: String) -> [String] {
    let args = CommandLine.arguments
    return args.indices.filter { args[$0] == name && $0 + 1 < args.count }.map { args[$0 + 1] }
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

guard let configPath = argument("--config") ?? ProcessInfo.processInfo.environment["CONTROLWARD_CONFIG_DIR"] else {
    fail("missing --config <Resources/config directory>")
}
let configDirectory = URL(fileURLWithPath: configPath, isDirectory: true)
let verifyOnly = argument("--verify-app")
let root: URL
if let verifyOnly {
    root = URL(fileURLWithPath: verifyOnly, isDirectory: true)
} else if let given = argument("--root") {
    root = URL(fileURLWithPath: given, isDirectory: true)
} else {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("controlward-lead-proof-\(Int(Date().timeIntervalSince1970))")
}

let environment: LeadPipelineEnvironment
do { environment = try LeadPipelineEnvironment.load(configDirectory: configDirectory, root: root) } catch { fail("refused to start: \(error)") }
print("Leads folder: \(root.path)")

if verifyOnly == nil {
    if !ProspectLeadsStore(fileURL: environment.storeURL).records.isEmpty || FileManager.default.fileExists(atPath: environment.auditURL.path) {
        fail("the leads folder is not empty; the proof needs an empty store at launch (use a new --root)")
    }
    let audit = environment.audit
    let launch = environment.recordLaunch(audit: audit)
    print("Store at launch: \(launch)")

    if CommandLine.arguments.contains("--rbq-refresh") {
        let (_, guarded) = environment.makeRun(audit: audit)
        do {
            let file = try await RBQOpenData.refreshCache(config: environment.config, transport: guarded, directory: environment.rbqDirectory, now: Date())
            print("RBQ cache: \(file.path) (Source: RBQ / Données Québec, CC BY 4.0)")
        } catch {
            print("RBQ refresh refused or failed: \(error) (continuing without RBQ)")
        }
    }

    let latitude = Double(argument("--lat") ?? "45.5017") ?? 45.5017
    let longitude = Double(argument("--lon") ?? "-73.5673") ?? -73.5673
    let radius = Int(argument("--radius") ?? "3000") ?? 3000
    let limit = Int(argument("--limit") ?? "3") ?? 3
    let segments = arguments("--segment").isEmpty ? environment.config.segments.map(\.id) : arguments("--segment")
    let requests = segments.map { ProspectSearchRun.Request(segmentID: $0, latitude: latitude, longitude: longitude, radiusMeters: radius, limit: limit) }
    print("Searching \(segments.joined(separator: ", ")) around \(latitude),\(longitude) r=\(radius) m, \(limit) sites each (10 s per host)...")
    let reports = await environment.searchAndIngest(requests, audit: audit)
    for (request, report) in zip(requests, reports) {
        let statuses = Dictionary(grouping: report.prospects, by: \.status.rawValue).mapValues(\.count)
        print("  \(request.segmentID): run \(report.runID) candidates=\(report.candidates) records=\(report.prospects.count) \(statuses.sorted { $0.key < $1.key }) drafts=\(report.drafts.count) refusals=\(report.refusals.count) skipped=\(report.skipped.count)")
        for (key, value) in report.refusals.sorted(by: { $0.key < $1.key }) { print("    refused \(key): \(value)") }
        for (key, value) in report.skipped.sorted(by: { $0.key < $1.key }) { print("    skipped \(key): \(value)") }
    }
}

let inputs = environment.proofInputs()
let checks = LeadProofVerifier.verify(storeCountAtLaunch: inputs.launchCount, auditLines: inputs.lines, prospects: inputs.prospects,
                                      drafts: inputs.drafts, config: environment.config)
print("")
print("Earth's live-proof bar (audit: \(environment.auditURL.path))")
for check in checks { print("  [\(check.passed ? "PASS" : "FAIL")] \(check.number). \(check.name): \(check.detail)") }
for record in ProspectIngest.listed(inputs.prospects) + ProspectIngest.heldForMartin(inputs.prospects) {
    print("")
    ProspectDisplay.lines(for: record, config: environment.config).forEach { print("  " + $0) }
}
let passed = checks.allSatisfy(\.passed)
print("")
print(passed ? "LEAD PIPELINE PROOF PASSED" : "LEAD PIPELINE PROOF FAILED")
exit(passed ? 0 : 1)
