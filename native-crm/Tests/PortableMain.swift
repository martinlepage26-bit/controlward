import Foundation

/// Entry point for bin/test-portable. The Mac smoke runner calls the same suites from NativeSmokeTests.
@main
struct PortableTestMain {
    static func main() async {
        let plan: [(String, () async -> Bool)] = [
            ("MailActionOutcomeTests", { await MailActionOutcomeTests.run() }),
            ("LeadPipelineTests", { await LeadPipelineTests.run() }),
            ("LeadPipelinePlantedReds", { await LeadPipelinePlantedReds.run() }),
            ("MailControlTests", { await MailControlTests.run() }),
            ("ProjectControlTests", { await ProjectControlTests.run() }),
            ("MailControlPlantedReds", { await MailControlPlantedReds.run() }),
            ("LeadgenSliceTests", { await LeadgenSliceTests.run() }),
        ]
        let asked = PortableSuiteFilter.names
        let chosen = asked.isEmpty ? plan : plan.filter { asked.contains($0.0) }
        if !asked.isEmpty, chosen.count != Set(asked).count {
            let known = Set(plan.map(\.0))
            print("unknown suite \(asked.filter { !known.contains($0) }.joined(separator: " "))")
            print("suites: \(plan.map(\.0).joined(separator: " "))")
            exit(2)
        }
        var ok = true
        for (_, run) in chosen {
            ok = await run() && ok
        }
        if !ok {
            print("PORTABLE TESTS FAILED")
            exit(1)
        }
        print("PORTABLE TESTS PASSED")
    }
}
