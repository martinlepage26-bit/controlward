import SwiftUI
import AppKit

struct ControlWardLogo: View {
    var size: CGFloat

    var body: some View {
        let image = Self.logoURL.flatMap(NSImage.init(contentsOf:)) ?? NSImage(size: NSSize(width: size, height: size))
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("ControlWard logo")
    }

    /// The .app build copies SwiftPM's resource bundle into Contents/Resources.
    /// `Bundle.module` does not look there and falls back to the absolute .build
    /// path, which the App Sandbox blocks (and traps on), so check the app first.
    private static let logoURL: URL? = {
        AppResources.bundle?.url(forResource: "controlward-mark", withExtension: "png")
    }()
}

struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ZStack(alignment: .bottom) {
            if case .blocked(let reason) = store.recoveryState {
                ContentUnavailableView("Workspace recovery required", systemImage: "exclamationmark.shield.fill", description: Text(reason))
                    .padding(40)
            } else if store.business.name.isEmpty {
                OnboardingView()
            } else {
                MainWorkspaceView()
            }

            if let notice = store.notice {
                Text(notice)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(CRMTheme.ink, in: Capsule())

                    .padding(.bottom, 20)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.notice)
        .background(CRMTheme.paper)
        .tint(CRMTheme.amberDark)
        .preferredColorScheme(.light)
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @State private var businessName = ""
    @State private var industry = Industries.all[0]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    ControlWardLogo(size: 86)
                    HStack(spacing: 0) {
                        Text("Control")
                            .foregroundStyle(CRMTheme.ink)
                        Text("Ward")
                            .foregroundStyle(CRMTheme.amberDark)
                    }
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    Text("Relationships, email intake, market signals, and project decisions in one desktop workspace.")
                        .foregroundStyle(.secondary)
                }

                TextField("Business name", text: $businessName, prompt: Text("e.g. Tremblay Renovations"))
                    .textFieldStyle(.roundedBorder)

                Picker("Industry", selection: $industry) {
                    ForEach(Industries.all, id: \.self) { Text($0) }
                }

                Button("Create my workspace") {
                    store.createWorkspace(name: businessName, industry: industry)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .disabled(businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(width: 410)
            .crmCard()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case projects = "Projects"
    case email = "Email"
    case activity = "Activity"
    case pipeline = "Pipeline"
    case operations = "Operations"
    case intelligence = "Account intelligence"
    case integrations = "Integrations"
    case contacts = "Contacts"
    case companies = "Companies"
    case opportunities = "Opportunities"
    case tasks = "Tasks"
    case notes = "Notes"
    case views = "Saved views"
    case security = "Security"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .projects: "rectangle.3.group.bubble"
        case .email: "envelope"
        case .activity: "clock.arrow.circlepath"
        case .pipeline: "rectangle.3.group"
        case .operations: "arrow.triangle.branch"
        case .intelligence: "scope"
        case .integrations: "square.3.layers.3d"
        case .contacts: "person.2"
        case .companies: "building.2"
        case .opportunities: "chart.bar.xaxis"
        case .tasks: "checklist"
        case .notes: "note.text"
        case .views: "line.3.horizontal.decrease.circle"
        case .security: "lock.shield"
        case .settings: "gearshape"
        }
    }
}

struct MainWorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var modules = WorkspaceModules()
    @StateObject private var navigation = WorkspaceNavigation()
    @State private var search = ""

    var body: some View {
        HStack(spacing: 0) {
            CWSidebar().frame(width: 212)
            VStack(spacing: 0) {
                CWTopBar(search: $search)
            // Embedded content must size within the pane rather than enlarge the
            // native split view beyond the window and overlap its titlebar.
            GeometryReader { geometry in
                Group {
                    switch navigation.section ?? .overview {
                    case .overview: OverviewView(search: $search)
                    case .projects: WorkspaceModuleView(controller: modules.controller(for: .projects))
                    case .email: MailWorkspaceView()
                    case .activity: WorkspaceActivityView()
                    case .pipeline: PipelineView()
                    case .operations: IntegratedOpsView()
                    case .intelligence: AccountIntelligenceView()
                    case .integrations: IntegrationCenterView()
                    case .contacts: directory(.contacts)
                    case .companies: directory(.companies)
                    case .opportunities: directory(.opportunities)
                    case .tasks: directory(.tasks)
                    case .notes: directory(.notes)
                    case .views: SavedViewsView()
                    case .security: SecurityView()
                    case .settings: SettingsView()
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(CWPalette.canvas)
            }
            }
        }
        .background(CWPalette.canvas)
        .environmentObject(modules)
        .environmentObject(navigation)
        .task {
            await store.pullLeadsOnLaunch()
            await store.scheduleTaskReminders()
        }
    }

    private func directory(_ kind: DirectoryKind) -> some View {
        DirectoryView(kind: kind,
                      initialFilter: navigation.directoryKind == kind.rawValue ? navigation.directoryFilter : .all,
                      initialSearch: navigation.directoryKind == kind.rawValue ? navigation.directorySearch : "")
            .id("\(kind.rawValue)-\(navigation.requestID)")
    }
}
