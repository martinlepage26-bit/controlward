import Foundation

// Red commit: declarations only, so the lead-gen CLI tests compile and fail by name.

struct LeadgenLocalConfig: Codable, Sendable, Equatable {
    struct Prospect: Codable, Sendable, Equatable { let organization: String; let site: String; let publicContactEmail: String }
    struct Consent: Codable, Sendable, Equatable { let basis: String; let source: String; let recordedAt: String }
    let postalAddress: String?
    let prospect: Prospect?
    let paths: [String]?
    let consent: Consent?
    static func load(path: String) throws -> LeadgenLocalConfig { throw LeadgenError.configInvalid("not implemented (red commit)") }
}

actor LeadgenFileLog: LeadgenRunLog {
    let url: URL
    static func directory(environment: [String: String]) -> URL { URL(fileURLWithPath: "/nonexistent") }
    init(directory: URL, stamp: String) { url = directory.appendingPathComponent("not-implemented.log") }
    func write(_ line: String) async {}
}

struct LeadgenLiveDeps: Sendable {
    let fetcher: LeadgenFetching
    let mailbox: LeadgenDraftMailbox
    let d1: LeadgenD1Port
    let log: LeadgenRunLog
    let logPath: String
}

enum LeadgenCLI {
    static func run(arguments: [String], environment: [String: String],
                    makeLive: (LeadgenLocalConfig) throws -> LeadgenLiveDeps) async -> (Int32, [String]) {
        (99, ["not implemented (red commit)"])
    }
}
