import SwiftUI
import AppKit

struct ContextwardLogo: View {
    var size: CGFloat

    var body: some View {
        let image = Self.logoURL.flatMap(NSImage.init(contentsOf:)) ?? NSImage(size: NSSize(width: size, height: size))
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("Contextward logo")
    }

    /// The .app build copies SwiftPM's resource bundle into Contents/Resources.
    /// `Bundle.module` does not look there and falls back to the absolute .build
    /// path, which the App Sandbox blocks (and traps on), so check the app first.
    private static let logoURL: URL? = {
        if let bundled = Bundle.main.url(forResource: "FollowUpOSNative_FollowUpOSNative", withExtension: "bundle"),
           let resources = Bundle(url: bundled) {
            return resources.url(forResource: "logoContextWard", withExtension: "png")
        }
        return Bundle.module.url(forResource: "logoContextWard", withExtension: "png")
    }()
}

struct RootView: View {
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
                    .shadow(radius: 12, y: 4)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.notice)
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
                    ContextwardLogo(size: 86)
                    HStack(spacing: 0) {
                        Text("Context")
                            .foregroundStyle(CRMTheme.ink)
                        Text("ward")
                            .foregroundStyle(CRMTheme.amberDark)
                    }
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    Text("A native CRM for customer details, follow-ups, and a healthier pipeline.")
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
    case pipeline = "Pipeline"
    case operations = "Operations"
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
        case .pipeline: "rectangle.3.group"
        case .operations: "arrow.triangle.branch"
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
    @State private var selection: WorkspaceSection? = .overview

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 9) {
                        ContextwardLogo(size: 30)
                        HStack(spacing: 0) {
                        Text("Context")
                        Text("ward").foregroundStyle(CRMTheme.amber)
                        }
                    }
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    Text("\(store.business.name) · \(store.business.industry)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 18)

                List(WorkspaceSection.allCases, selection: $selection) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .tag(section)
                }
                .listStyle(.sidebar)

                VStack(spacing: 6) {
                    ContextwardLogo(size: 78)
                    Text("Contextward")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CRMTheme.ink)
                    Text("PHAROS CRM")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(CRMTheme.amberDark)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)

                VStack(alignment: .leading, spacing: 5) {
                    Label("Stored locally", systemImage: "internaldrive")
                        .font(.caption.weight(.semibold))
                    Text("No browser or local server")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            Group {
                switch selection ?? .pipeline {
                case .overview: OverviewView()
                case .pipeline: PipelineView()
                case .operations: IntegratedOpsView()
                case .integrations: IntegrationCenterView()
                case .contacts: DirectoryView(kind: .contacts)
                case .companies: DirectoryView(kind: .companies)
                case .opportunities: DirectoryView(kind: .opportunities)
                case .tasks: DirectoryView(kind: .tasks)
                case .notes: DirectoryView(kind: .notes)
                case .views: SavedViewsView()
                case .security: SecurityView()
                case .settings: SettingsView()
                }
            }
            .background(CRMTheme.paper)
        }
        .task { await store.pullLeadsOnLaunch() }
    }
}
