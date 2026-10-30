import SwiftUI
import WebKit

enum AppResources {
    static var bundle: Bundle? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.url(forResource: "FollowUpOSNative_FollowUpOSNative", withExtension: "bundle") else { return nil }
            return Bundle(url: url)
        }
        return Bundle.module
    }
}

@MainActor
final class WorkspaceModules: ObservableObject {
    private var controllers: [WorkspaceModule: WorkspaceWebController] = [:]
    func controller(for module: WorkspaceModule) -> WorkspaceWebController {
        if let controller = controllers[module] { return controller }
        let document = AppResources.bundle?.url(forResource: "project-control", withExtension: "html", subdirectory: "ProjectControl")
        #if DEBUG && CONTEXTWARD_ACCEPTANCE
        let controller = WorkspaceWebController(module: module, document: document, dataStore: .nonPersistent())
#else
        let controller = WorkspaceWebController(module: module, document: document)
#endif
        controllers[module] = controller
        return controller
    }
}

struct WorkspaceModuleView: View {
    @ObservedObject var controller: WorkspaceWebController

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.module.title).font(.headline)
                    Text(controller.module == .projects
                         ? "Projects, decisions and intake. Connect your shared register in Sync."
                         : "Hosted prototype · synthetic mail only. Live mailbox sync is not connected.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
#if !DEBUG || !CONTEXTWARD_ACCEPTANCE
                if let url = controller.module.website {
                    Link("Open in browser", destination: url).font(.caption)
                }
#endif
                Button("Reload", systemImage: "arrow.clockwise") { controller.reload() }
                    .disabled(controller.loading)
            }
            .padding(12)
            if controller.loading { ProgressView().progressViewStyle(.linear).accessibilityLabel("Loading module") }
            if let failure = controller.failure {
                HStack {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Try again") { controller.reload() }
                }.padding(12).background(Color.orange.opacity(0.12))
            }
            EmbeddedWorkspaceWebView(controller: controller)
        }
        .navigationTitle(controller.module.title)
        .onAppear { controller.start() }
    }
}

private struct EmbeddedWorkspaceWebView: NSViewRepresentable {
    let controller: WorkspaceWebController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
}
