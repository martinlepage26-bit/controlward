import Foundation

/// Build identity stamped into Info.plist by bin/stamp-build-info at build time.
struct BuildInfo: Equatable, Sendable {
    static let commitKey = "ControlWardGitCommit"
    static let dirtyKey = "ControlWardGitDirty"

    let version: String
    let build: String
    let commit: String?
    let dirty: Bool

    init(info: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? "?"
        build = info["CFBundleVersion"] as? String ?? "?"
        let raw = (info[BuildInfo.commitKey] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        commit = raw.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil ? raw : nil
        dirty = (info[BuildInfo.dirtyKey] as? Bool) ?? false
    }

    static var current: BuildInfo { BuildInfo(info: Bundle.main.infoDictionary ?? [:]) }

    var shortCommit: String? { commit.map { String($0.prefix(7)) } }

    /// "1.1.1 (104, 001c7cd)", "1.1.1 (104, 001c7cd, uncommitted changes)" or "1.1.1 (104, commit unknown)".
    var aboutVersion: String {
        var parts = [build, shortCommit ?? "commit unknown"]
        if dirty { parts.append("uncommitted changes") }
        return "\(version) (\(parts.joined(separator: ", ")))"
    }
}
