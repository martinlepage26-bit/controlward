import Foundation
import SwiftUI

/// Process entry. `FollowUpOSNative leadgen ...` runs the lead-gen CLI (dry-run by default) and exits;
/// anything else launches the app as before.
@main
enum ControlWardEntry {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
#if DEBUG && CONTEXTWARD_ACCEPTANCE
        if CommandLine.arguments.contains("--controlward-chrome-native-messaging") || args.first == LeadgenCLI.subcommand {
            FileHandle.standardError.write(Data("Command-line and native-messaging modes are disabled in the isolated offline preview.\n".utf8))
            exit(1)
        }
#endif
        if CommandLine.arguments.contains("--controlward-chrome-native-messaging") {
            ChromeNativeMessagingHost().run()
            return
        }
        guard args.first == LeadgenCLI.subcommand else {
            ControlWardApplication.main()
            return
        }
        let env = ProcessInfo.processInfo.environment
        let box = LeadgenExitBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let (code, lines) = await LeadgenCLI.run(arguments: Array(args.dropFirst()), environment: env, makeLive: LeadgenCLI.liveDeps(environment: env))
            for line in lines { print(line) }
            box.code = code
            done.signal()
        }
        done.wait()
        exit(box.code)
    }
}

final class LeadgenExitBox: @unchecked Sendable { var code: Int32 = 0 }
