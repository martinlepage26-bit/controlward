import Foundation

/// Entry point for bin/test-crm-core: the CRM model layer and lead workflow without SwiftUI, AppKit or the Keychain.
/// The Mac smoke runner (bin/test-native-app) calls the same suite from NativeSmokeTests.
@main
struct CRMCoreTestMain {
    static func main() async {
        guard await CRMWorkflowTests.run() else {
            print("CRM CORE TESTS FAILED")
            exit(1)
        }
        print("CRM CORE TESTS PASSED")
    }
}
