import AppKit
import SwiftUI

@main
struct FollowUpOSApp: App {
    @StateObject private var store = makeStore()
    @StateObject private var mail = MailIntakeController()
    @StateObject private var research = AgentResearchCoordinator()

    @MainActor private static func makeStore() -> AppStore {
#if DEBUG && CONTEXTWARD_ACCEPTANCE
        return AppStore(storageURL: PreviewFixture.prepareIfRequested())
#else
        return AppStore()
#endif
    }

    var body: some Scene {
        WindowGroup("ControlWard") {
            RootView()
                .environmentObject(store)
                .environmentObject(mail)
                .environmentObject(research)
                .task {
                    mail.startPeriodic(store: store)
                    research.start(store: store, configDirectory: ICPConfig.defaultDirectory(bundle: AppResources.bundle))
                }
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
