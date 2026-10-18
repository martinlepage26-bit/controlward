import SwiftUI

@main
struct FollowUpOSApp: App {
    @StateObject private var store = makeStore()

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
                .frame(minWidth: 940, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 854)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
