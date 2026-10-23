import Foundation

/// Entry point for bin/test-portable. The Mac smoke runner calls the same suites from NativeSmokeTests.
@main
struct PortableTestMain {
    static func main() async {
        var ok = true
        ok = await MailActionOutcomeTests.run() && ok
        ok = await LeadPipelineTests.run() && ok
        ok = await LeadPipelinePlantedReds.run() && ok
        if !ok {
            print("PORTABLE TESTS FAILED")
            exit(1)
        }
        print("PORTABLE TESTS PASSED")
    }
}
