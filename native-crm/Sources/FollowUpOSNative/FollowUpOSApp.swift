import AppKit
import SwiftUI

struct ControlWardApplication: App {
#if DEBUG && CONTEXTWARD_ACCEPTANCE
    @StateObject private var store = PreviewFixture.makeStore()
    @StateObject private var mail = PreviewFixture.makeMailController()
#else
    @StateObject private var store = AppStore()
    @StateObject private var mail = MailIntakeController()
#endif

    var body: some Scene {
        WindowGroup("ControlWard") {
            RootView()
                .environmentObject(store)
                .environmentObject(mail)
#if !DEBUG || !CONTEXTWARD_ACCEPTANCE
                .task { mail.startPeriodic(store: store) }
#endif
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
