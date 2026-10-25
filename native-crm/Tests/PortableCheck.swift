import Foundation

/// Failure type and runner shared by the portable test files.
/// These files compile without SwiftUI or AppKit, so they run on Linux as well as on the Mac.
struct PortableCheckFailure: Error, CustomStringConvertible, Sendable {
    var description: String
}

/// Command-line suite names. No names means every suite.
/// `./bin/test-portable LeadgenSliceTests` and `./bin/test-native-app LeadgenSliceTests` run one suite at that SHA.
enum PortableSuiteFilter {
    static var names: [String] {
        CommandLine.arguments.dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum PortableCheck {
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw PortableCheckFailure(description: message) }
    }

    /// Runs named cases and prints one line per case plus a suite summary.
    static func suite(_ name: String, _ cases: [(String, () async throws -> Void)]) async -> Bool {
        var passed = 0
        for (label, body) in cases {
            do {
                try await body()
                passed += 1
                print("  PASS \(label)")
            } catch {
                print("  FAIL \(label): \(error)")
            }
        }
        print("\(name) tests: \(passed)/\(cases.count) passed")
        return passed == cases.count
    }
}
