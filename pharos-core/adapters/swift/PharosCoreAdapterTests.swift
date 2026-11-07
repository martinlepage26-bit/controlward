import Foundation

/// Standalone runner for the PHAROS core Swift adapter (pharos-core/adapters/swift/test.sh).
/// Kept out of ControlWard's bin/test-native-app so that suite's count is unchanged in slice 1.
struct AdapterCheckFailure: Error, CustomStringConvertible { var description: String }

func expect(_ c: @autoclosure () throws -> Bool, _ m: String) throws {
    guard try c() else { throw AdapterCheckFailure(description: m) }
}

@main
struct PharosCoreAdapterTestMain {
    static func main() async {
        let cases: [(String, () async throws -> Void)] = [
            ("adapter is disabled by default (no env, no defaults)", {
                let a = PharosCore.makeAdapter(environment: [:], defaults: nil)
                try expect(a.enabled == false, "enabled should be false")
                try expect(a is NoopPharosCoreAdapter, "default should be the no-op adapter")
            }),
            ("disabled adapter returns .disabled for every call", {
                let a = NoopPharosCoreAdapter()
                let r = try await a.requestApproval(contactID: "c1", action: "contact.outreach", payload: ["x": "1"])
                try expect(r == .disabled, "requestApproval should be .disabled")
                try expect(try await a.status(id: "a1") == .disabled, "status should be .disabled")
                try expect(try await a.consume(id: "a1", payload: [:]) == .disabled, "consume should be .disabled")
            }),
            ("only PHAROS_CORE_ENABLED=true enables it", {
                for v in ["", "false", "0", "1", "yes", "TRUE "] {
                    try expect(PharosCore.makeAdapter(environment: ["PHAROS_CORE_ENABLED": v], defaults: nil).enabled == false, "value \(v) must stay disabled")
                }
                try expect(PharosCore.makeAdapter(environment: ["PHAROS_CORE_ENABLED": "true"], defaults: nil).enabled, "true enables")
            }),
            ("pharosCoreEnabled UserDefaults key defaults to false", {
                let suite = "pharos-core-adapter-test-\(UUID().uuidString)"
                let d = UserDefaults(suiteName: suite)!
                defer { d.removePersistentDomain(forName: suite) }
                try expect(PharosCore.makeAdapter(environment: [:], defaults: d).enabled == false, "unset default must be disabled")
            }),
            ("enabled adapter refuses a non-loopback base URL", {
                try expect(PharosCore.makeAdapter(environment: ["PHAROS_CORE_ENABLED": "true", "PHAROS_CORE_URL": "http://10.0.0.5:8787"], defaults: nil).enabled == false,
                           "non-loopback URL must fall back to the disabled adapter")
                try expect(PharosCore.isLoopback(URL(string: "http://127.0.0.1:8787")!), "127.0.0.1 is loopback")
                try expect(!PharosCore.isLoopback(URL(string: "http://example.test")!), "example.test is not loopback")
            }),
        ]
        var passed = 0
        for (label, body) in cases {
            do { try await body(); passed += 1; print("  PASS \(label)") }
            catch { print("  FAIL \(label): \(error)") }
        }
        print("PharosCoreAdapter tests: \(passed)/\(cases.count) passed")
        exit(passed == cases.count ? 0 : 1)
    }
}
