import Foundation

@MainActor
enum BuildInfoTests {
    static func run() -> Bool {
        let tests: [(String, () throws -> Void)] = [
            ("Build: stamped plist shows version, build and short commit", stamped),
            ("Build: dirty tree is flagged in the About line", dirty),
            ("Build: missing or malformed commit reads as unknown", unknown),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try test(); print("PASS  \(name)") } catch { failures += 1; print("FAIL  \(name): \(error)") }
        }
        print("Build info tests: \(tests.count - failures)/\(tests.count) passed")
        return failures == 0
    }
    private static func expect(_ c: Bool, _ m: String) throws { if !c { throw SmokeTestFailure.failed(m) } }
    static let sha = "001c7cdbde602a2287b7a40f4911f2e8559b2448"

    static func stamped() throws {
        let b = BuildInfo(info: ["CFBundleShortVersionString": "1.1.1", "CFBundleVersion": "104", BuildInfo.commitKey: sha, BuildInfo.dirtyKey: false])
        try expect(b.commit == sha && b.shortCommit == "001c7cd" && !b.dirty, "fields")
        try expect(b.aboutVersion == "1.1.1 (104, 001c7cd)", b.aboutVersion)
    }
    static func dirty() throws {
        let b = BuildInfo(info: ["CFBundleShortVersionString": "1.1.1", "CFBundleVersion": "104", BuildInfo.commitKey: sha, BuildInfo.dirtyKey: true])
        try expect(b.aboutVersion == "1.1.1 (104, 001c7cd, uncommitted changes)", b.aboutVersion)
    }
    static func unknown() throws {
        try expect(BuildInfo(info: ["CFBundleShortVersionString": "1.1.1", "CFBundleVersion": "103"]).aboutVersion == "1.1.1 (103, commit unknown)", "missing")
        for bad in ["", "001c7cd", "XYZ" + String(sha.dropFirst(3)), sha + "\n<script>"] {
            try expect(BuildInfo(info: [BuildInfo.commitKey: bad]).commit == nil, "accepted \(bad)")
        }
    }
}
