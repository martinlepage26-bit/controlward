import AppKit
import SwiftUI


struct FollowUpOSApp: App {
    @StateObject private var store = makeStore()
    @StateObject private var mail = MailIntakeController()

    @MainActor private static func makeStore() -> AppStore {
#if DEBUG && CONTEXTWARD_ACCEPTANCE
        PreviewFixture.prepareIfRequested()
#endif
        return AppStore()
    }

    var body: some Scene {
        WindowGroup("ControlWard") {
            RootView()
                .environmentObject(store)
                .environmentObject(mail)
                .task { mail.startPeriodic(store: store) }
                .frame(minWidth: 940, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 854)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button("About ControlWard") {
                    // The standard panel shows the version line; the commit makes every build traceable.
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: BuildInfo.current.aboutVersion, .version: ""])
                }
            }
        }
    }
}
