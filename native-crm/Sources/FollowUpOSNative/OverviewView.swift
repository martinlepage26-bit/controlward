import SwiftUI
import AppKit

struct CWCard: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content.padding(padding)
            .background(CWPalette.card, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}
extension View { func cwCard(_ padding: CGFloat = 14) -> some View { modifier(CWCard(padding: padding)) } }

struct BronzeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10.5, weight: .semibold)).lineLimit(1).fixedSize().foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(CWPalette.bronzeGradient, in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Procedural starfield + nebula used only in the top hero band.
struct NebulaBanner: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [CWPalette.nebulaDeep, CWPalette.nebulaMid, CWPalette.nebulaHaze]),
                startPoint: CGPoint(x: size.width, y: 0), endPoint: CGPoint(x: size.width * 0.35, y: size.height)))
            let glows: [(Double, Double, Double, Color, Double)] = [
                (0.72, 0.30, 0.32, CWPalette.nebulaGlowCool, 0.8), (0.92, 0.55, 0.24, CWPalette.nebulaGlowWarm, 0.6), (0.55, 0.45, 0.28, CWPalette.nebulaGlowBlue, 0.75), (0.80, 0.40, 0.10, .white, 0.55)]
            for (x, y, r, color, alpha) in glows {
                let center = CGPoint(x: size.width * x, y: size.height * y)
                let radius = size.width * r
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                         with: .radialGradient(Gradient(colors: [color.opacity(alpha), .clear]), center: center, startRadius: 0, endRadius: radius))
            }
            var rng = SeededRandom(seed: 17)
            for _ in 0..<700 {
                let p = CGPoint(x: rng.next() * size.width, y: rng.next() * size.height)
                let s = rng.next() < 0.93 ? 1.0 : 2.2
                ctx.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: s, height: s)), with: .color(.white.opacity(0.35 + rng.next() * 0.6)))
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0.18), .init(color: .black, location: 0.42)], startPoint: .leading, endPoint: .trailing))
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .accessibilityHidden(true)
    }
}

struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

struct Sparkline: View {
    var values: [Double]
    var color: Color
    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            if pts.count > 1 {
                ZStack {
                    Path { p in p.move(to: CGPoint(x: pts[0].x, y: geo.size.height)); pts.forEach { p.addLine(to: $0) }; p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height)) }
                        .fill(LinearGradient(colors: [color.opacity(0.45), color.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.addLines(pts) }.stroke(color, lineWidth: 1.6)
                }
            } else {
                Path { p in p.move(to: CGPoint(x: 0, y: geo.size.height - 1)); p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 1)) }
                    .stroke(color.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }.frame(width: 52, height: 30).accessibilityHidden(true)
    }
    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1, let maxV = values.max(), maxV > 0 else { return [] }
        let lastIndex = Double(values.count - 1)
        let width: Double = Double(size.width)
        let height: Double = Double(size.height)
        let plotHeight: Double = height - 3
        let maxValue: Double = Double(maxV)
        return values.enumerated().map { (i: Int, v) -> CGPoint in
            let x: Double = width * Double(i) / lastIndex
            let scaled: Double = plotHeight * Double(v) / maxValue
            let y: Double = height - scaled - 1
            return CGPoint(x: x, y: y)
        }
    }
}

struct CWMiniMark: View {
    var body: some View {
        ControlWardLogo(size: 18).padding(3).background(CWPalette.sidebarTop, in: RoundedRectangle(cornerRadius: 5))
    }
}

struct SegmentTabs: View {
    var tabs: [String]
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs.indices, id: \.self) { i in
                Button { selection = i } label: {
                    Text(tabs[i]).font(.system(size: 9, weight: .medium)).lineLimit(1).fixedSize()
                        .foregroundStyle(selection == i ? .white : CWPalette.ink.opacity(0.75))
                        .padding(.horizontal, 5).padding(.vertical, 4)
                        .background(selection == i ? CWPalette.tabSelected : .clear, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain)
            }
        }.padding(2).background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct MiniSearch: View {
    var prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(CWPalette.gray)
                TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 10))
            }.padding(.horizontal, 7).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.12)))
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(CWPalette.gray)
                .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.12)))
        }
    }
}

struct PanelHeader: View {
    var title: String
    var action: String?
    var run: () -> Void = {}
    var body: some View {
        // Keep the full title and button text: when both don't fit on one line, the button drops below.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) { titleRow; Spacer(minLength: 4); button }
            VStack(alignment: .leading, spacing: 6) { titleRow; button }
        }
    }
    private var titleRow: some View {
        HStack(spacing: 7) {
            CWMiniMark()
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(CWPalette.ink).fixedSize()
        }
    }
    @ViewBuilder private var button: some View {
        if let action { Button(action, action: run).buttonStyle(BronzeButtonStyle()) }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var navigation: WorkspaceNavigation
    @EnvironmentObject private var modules: WorkspaceModules
    @Binding var search: String
    @State private var record: WorkspaceRecord?
    @State private var projects: ProjectModuleSnapshot?
    @State private var projectError: String?

    private static let toronto = TimeZone(identifier: "America/Toronto") ?? .current
    private var snapshot: OverviewSnapshot {
        OverviewSnapshot.make(opportunities: store.opportunities, tasks: store.tasks, leads: store.leads, companies: store.companies,
                              today: CalendarCRM.dayString())
    }

    var body: some View {
        let s = snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                hero
                if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { searchResults }
                HStack(spacing: 14) {
                    kpi("chart.bar.fill", "Open opportunities", s.openOpportunities, color: CWPalette.green, dot: s.openOpportunitiesChangeIsPositive ? nil : CWPalette.gray, arrow: s.openOpportunitiesChangeIsPositive)
                    kpi("dollarsign.circle", "Est. value", s.estimatedValue, color: CWPalette.goldLight, dot: CWPalette.bronze)
                    kpi("checkmark.square", "Due this week", s.dueThisWeek, color: CWPalette.blue, dot: CWPalette.bronze)
                    kpi("waveform.path.ecg", "Follow-ups", s.followUps, color: CWPalette.red, dot: s.followUpsOverdue > 0 ? CWPalette.red : CWPalette.gray)
                }
                LeadFunnelStrip()
                RatioRow(leading: OverviewSnapshot.middleRowSplit, spacing: 14) {
                    nextActions(s).frame(minHeight: 120, alignment: .top)
                    pipelineOverview(s).frame(minHeight: 120, alignment: .top)
                }
                HStack(alignment: .top, spacing: 14) {
                    ProjectsPanel(snapshot: projects, error: projectError) { navigation.show(.projects) }
                    LeadsPanel()
                    EmailPanel()
                    SettingsPanel()
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .background(alignment: .top) { NebulaBanner().frame(height: 250) }
        .background(CWPalette.canvas)
        .sheet(item: $record) { RecordProjectSheet(record: $0) }
        .task { await loadProjects() }
    }

    private func loadProjects() async {
        do { projects = try await modules.controller(for: .projects).projectSnapshot() }
        catch { projectError = "Open Projects to load Project Control." }
    }

    private var hero: some View {
        let now = Date.now
        var cal = Calendar(identifier: .gregorian); cal.timeZone = Self.toronto
        let style = Date.FormatStyle(date: .complete, time: .omitted, locale: Locale(identifier: "en_CA"), timeZone: Self.toronto)
        let first = OverviewSnapshot.greetingName(fullName: NSFullUserName(), userName: NSUserName()) ?? ""
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(OverviewSnapshot.greeting(hour: cal.component(.hour, from: now)))\(first.isEmpty ? "" : ", \(first)").")
                    .font(.system(size: 28, weight: .semibold)).foregroundStyle(CWPalette.ink)
                Text("Here is what needs your attention today.").font(.system(size: 14)).foregroundStyle(CWPalette.ink.opacity(0.7))
                if PreviewData.isShowing(store) {
                    Label("Preview data: synthetic records, not your workspace", systemImage: "eyedropper.halffull")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(CWPalette.red, in: Capsule())
                        .accessibilityLabel("Preview data")
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(now.formatted(style)).font(.system(size: 12, weight: .medium))
                Text("\(store.business.name)  ·  \(store.business.industry)").font(.system(size: 10.5))
            }.foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 2).padding(.top, 6)
        }.padding(.top, 6).padding(.bottom, 2)
    }

    private var searchResults: some View {
        let matches = store.records(search: search)
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(matches.count) matches for “\(search)”").font(.caption.weight(.semibold)).foregroundStyle(CWPalette.gray)
            ForEach(matches.prefix(8)) { row in
                Button { record = row } label: {
                    HStack { Text(row.title).fontWeight(.medium); Text(row.kind.capitalized).font(.caption).foregroundStyle(CWPalette.gray); Spacer(); Image(systemName: "link") }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.cwCard()
    }

    private func kpi(_ symbol: String, _ label: String, _ m: OverviewSnapshot.Metric, color: Color, dot: Color?, arrow: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(CWPalette.goldIcon).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased()).font(.system(size: 9, weight: .medium)).tracking(0.4).foregroundStyle(CWPalette.gray).lineLimit(1).minimumScaleFactor(0.8)
                Text(m.value).font(.system(size: 26, weight: .semibold)).foregroundStyle(CWPalette.ink).monospacedDigit()
                HStack(spacing: 4) {
                    if arrow { Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold)).foregroundStyle(CWPalette.green) }
                    else if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                    Text(m.detail).font(.system(size: 10.5)).foregroundStyle(arrow ? CWPalette.green : (dot == CWPalette.gray ? CWPalette.gray : CWPalette.ink.opacity(0.75))).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Sparkline(values: m.trend, color: color)
        }.frame(maxWidth: .infinity).cwCard()
    }

    private func nextActions(_ s: OverviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Next actions").font(.system(size: 13, weight: .semibold)).foregroundStyle(CWPalette.ink)
                Text("\(s.nextActions.count)").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.black.opacity(0.07), in: Capsule())
                Spacer()
                Button { navigation.directory("tasks", filter: .open) } label: { Label("View all", systemImage: "arrow.right").labelStyle(TrailingIcon()) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(CWPalette.blue)
            }
            if s.nextActions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No open tasks.").font(.system(size: 12, weight: .medium))
                    Text("Add a task, or turn reviewed email and signals into follow-up work.").font(.system(size: 11)).foregroundStyle(CWPalette.gray)
                }.padding(.vertical, 18)
            }
            ForEach(Array(s.nextActions.enumerated()), id: \.element.id) { index, action in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Button { try? store.completeTask(action.id, completed: true) } label: {
                            Circle().stroke(CWPalette.gray.opacity(0.6), lineWidth: 1.3).frame(width: 18, height: 18)
                        }.buttonStyle(.plain).help("Mark complete").accessibilityLabel("Complete \(action.title)")
                        if index < s.nextActions.count - 1 { Rectangle().fill(CWPalette.gray.opacity(0.3)).frame(width: 1).frame(maxHeight: .infinity) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(action.title).font(.system(size: 12, weight: .medium)).foregroundStyle(CWPalette.ink)
                        if let due = action.dueDate {
                            Text(action.overdue ? "Overdue · \(due)" : action.dueToday ? "Today" : due)
                                .font(.system(size: 10.5)).foregroundStyle(action.overdue ? CWPalette.red : CWPalette.gray)
                        }
                    }
                    Spacer()
                    Text(action.context.isEmpty ? "Task" : action.context).font(.system(size: 10)).foregroundStyle(CWPalette.ink.opacity(0.7))
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
                }.frame(minHeight: 40)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).cwCard(16)
    }

    private func pipelineOverview(_ s: OverviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pipeline overview").font(.system(size: 13, weight: .semibold)).foregroundStyle(CWPalette.ink)
                Spacer()
                Button { navigation.show(.pipeline) } label: { Label("View pipeline", systemImage: "arrow.right").labelStyle(TrailingIcon()) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(CWPalette.blue)
            }
            HStack(alignment: .top, spacing: 6) {
                ForEach(s.pipeline) { column in
                    VStack(alignment: .leading, spacing: 6) {
                        Rectangle().fill(CWPalette.stage[column.stage] ?? .gray).frame(height: 3)
                        HStack(spacing: 2) { Text(column.stage.label).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7); Spacer(); Text("\(column.items.count)").font(.system(size: 10)).foregroundStyle(CWPalette.gray) }
                            .padding(.horizontal, 7)
                        ForEach(column.items.prefix(3)) { opp in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(opp.name).font(.system(size: 10, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                                if let amount = opp.amount { Text(OverviewSnapshot.currency(amount)).font(.system(size: 10)) }
                                if let company = store.companies.first(where: { $0.id == opp.companyID })?.name { Text(company).font(.system(size: 9.5)).foregroundStyle(CWPalette.gray) }
                            }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
                                .background(CWPalette.card, in: RoundedRectangle(cornerRadius: 6)).shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                .padding(.horizontal, 5)
                        }
                    }.padding(.bottom, 6).frame(maxWidth: .infinity, minHeight: 92, alignment: .top)
                        .background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.06)))
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).cwCard(16)
    }
}

struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 4) { configuration.title; configuration.icon } }
}

/// Auto-Pilot only runs `AppStore.runAutomations()`, which is local-only: it creates
/// tasks and qualifies signals in the workspace file. It never calls a mail, Kairos or
/// network API, so it cannot send outreach. Off by default.
enum AutoPilot {
    static let storageKey = "controlward.autoPilot"
    static let defaultEnabled = false
    static let interval: Duration = .seconds(300)
}

// MARK: - Bottom panels

struct ProjectsPanel: View {
    var snapshot: ProjectModuleSnapshot?
    var error: String?
    var open: () -> Void
    @State private var tab = 0
    @State private var search = ""
    private var rows: [ProjectModuleRecord] {
        let all = snapshot?.projects ?? []
        let filtered = all.filter { p in
            switch tab { case 1: p.status.lowercased() == "active"; case 2: p.status.lowercased() == "planning"; case 3: p.status.lowercased() == "completed"; default: true }
        }
        return search.isEmpty ? filtered : filtered.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }
    private func count(_ s: String) -> Int { (snapshot?.projects ?? []).filter { $0.status.lowercased() == s }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            PanelHeader(title: "Projects", action: "+ New project", run: open)
            SegmentTabs(tabs: ["All (\(snapshot?.projects.count ?? 0))", "Active (\(count("active")))", "Planning (\(count("planning")))", "Completed (\(count("completed")))"], selection: $tab)
            MiniSearch(prompt: "Search projects...", text: $search)
            if rows.isEmpty {
                Text(error ?? "No projects in Project Control yet.").font(.system(size: 10.5)).foregroundStyle(CWPalette.gray).padding(.vertical, 12)
            }
            ForEach(rows.prefix(3)) { p in
                Button(action: open) {
                    HStack(spacing: 9) {
                        Image(systemName: "folder").foregroundStyle(CWPalette.blue).frame(width: 30, height: 30).background(CWPalette.blue.opacity(0.1), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text(p.workspace).font(.system(size: 9.5)).foregroundStyle(CWPalette.gray).lineLimit(1)
                        }
                        Spacer()
                        StatusPill(text: p.status)
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(CWPalette.gray)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, minHeight: 200, alignment: .top).cwCard(12)
    }
}

struct StatusPill: View {
    var text: String
    var body: some View {
        let s = text.lowercased()
        let (bg, fg): (Color, Color) = s == "active" ? (CWPalette.mint, CWPalette.activeText) : s == "planning" ? (CWPalette.planningFill, CWPalette.planningText) : s == "completed" ? (CWPalette.completedFill, CWPalette.completedText) : (Color.black.opacity(0.06), CWPalette.gray)
        Text(text.capitalized).font(.system(size: 9, weight: .semibold)).foregroundStyle(fg).padding(.horizontal, 6).padding(.vertical, 2).background(bg, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct Avatar: View {
    var name: String
    var color: Color
    var body: some View {
        Text(OverviewSnapshot.initials(name)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 30, height: 30).background(color, in: Circle())
    }
}

/// Prospecting funnel read from the local Leads folder: stages, not raw row counts. Nothing leaves the Mac.
struct LeadFunnelStrip: View {
    @State private var funnel: LeadFunnel?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 18)).foregroundStyle(CWPalette.goldIcon)
            Text("PROSPECTING").font(.system(size: 9, weight: .medium)).tracking(0.4).foregroundStyle(CWPalette.gray)
            if let funnel {
                ForEach(Array(funnel.stages.enumerated()), id: \.offset) { index, stage in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(CWPalette.gray) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(stage.value)").font(.system(size: 18, weight: .semibold)).monospacedDigit().foregroundStyle(CWPalette.ink)
                        Text(stage.label).font(.system(size: 9.5)).foregroundStyle(CWPalette.gray).lineLimit(1)
                    }
                }
            } else {
                Text("No local lead search yet.").font(.system(size: 10.5)).foregroundStyle(CWPalette.gray)
            }
            Spacer(minLength: 0)
        }
        .cwCard(12)
        .task { load() }
    }

    private func load() {
        guard let directory = ICPConfig.defaultDirectory(bundle: AppResources.bundle),
              let environment = try? LeadPipelineEnvironment.load(configDirectory: directory) else { return }
        funnel = environment.funnel()
    }
}

struct LeadsPanel: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var navigation: WorkspaceNavigation
    @State private var tab = 0
    @State private var search = ""
    private let filters: [PipelineFilter] = [.open, .all, .won, .lost]
    var body: some View {
        let rows = store.filteredLeads(filter: filters[tab], search: search)
        VStack(alignment: .leading, spacing: 9) {
            PanelHeader(title: "Pipeline", action: "+ Add lead") { navigation.show(.pipeline) }
            HStack { SegmentTabs(tabs: ["Open", "All", "Won", "Lost"], selection: $tab); Spacer() }
            MiniSearch(prompt: "Search leads...", text: $search)
            if rows.isEmpty { Text("No leads here yet.").font(.system(size: 10.5)).foregroundStyle(CWPalette.gray).padding(.vertical, 12) }
            ForEach(rows.prefix(3)) { lead in
                Button { navigation.show(.pipeline) } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Avatar(name: lead.name, color: [CWPalette.goldLight, CWPalette.blue, CWPalette.teal][abs(lead.name.hashValue) % 3])
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(lead.name).font(.system(size: 11, weight: .semibold))
                                    .lineLimit(PipelineRowLayout.nameLineLimit).truncationMode(.tail)
                                    .frame(minWidth: PipelineRowLayout.nameMinWidth, alignment: .leading)
                                    .layoutPriority(PipelineRowLayout.namePriority)
                                    .help(lead.name)
                                if lead.status == .new { Text("NEW").font(.system(size: 7.5, weight: .bold)).padding(.horizontal, 3).background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 3)).fixedSize().layoutPriority(PipelineRowLayout.accessoryPriority) }
                            }
                            if !lead.company.isEmpty { Text(lead.company).font(.system(size: 9.5)).foregroundStyle(CWPalette.gray).lineLimit(1).truncationMode(.tail) }
                            Text(PipelineRowLayout.metaLine(amount: lead.quoteAmount.map(OverviewSnapshot.currency), status: lead.status.label, createdAt: lead.createdAt))
                                .font(.system(size: 9.5)).foregroundStyle(CWPalette.bronze).lineLimit(1).truncationMode(.tail)
                        }.layoutPriority(PipelineRowLayout.namePriority)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, minHeight: 200, alignment: .top).cwCard(12)
    }
}

struct EmailPanel: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var navigation: WorkspaceNavigation
    @State private var tab = 0
    @State private var search = ""
    var body: some View {
        let sorted = store.mail.sorted { $0.receivedAt > $1.receivedAt }
        let byTab = tab == 2 ? sorted.filter { !$0.reviewed } : sorted
        let rows = search.isEmpty ? byTab : byTab.filter { $0.subject.localizedCaseInsensitiveContains(search) || $0.sender.localizedCaseInsensitiveContains(search) }
        let inputs = rows.map {
            MailOverviewInput(sourceID: $0.sourceID, provider: $0.provider, accountID: $0.accountID, sender: $0.sender, subject: $0.subject, receivedAt: $0.receivedAt)
        }
        let sections = MailOverviewLayout.sections(from: inputs)
        let fit = MailOverviewLayout.project(inputs)
        VStack(alignment: .leading, spacing: 9) {
            PanelHeader(title: "Email Aggregator", action: "Import metadata") { navigation.show(.email) }
            HStack { SegmentTabs(tabs: ["Inbox", "All accounts", "Unread", "Starred"], selection: $tab); Spacer() }
            HStack(spacing: 8) {
                MiniSearch(prompt: "Search emails...", text: $search)
                if tab != 3 {
                    Text("\(fit.shownCount)")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(CWPalette.ink)
                        .accessibilityLabel("\(fit.shownCount) messages")
                }
            }
            if store.mail.isEmpty {
                Text("No mail accounts connected. Import metadata to see messages here.").font(.system(size: 10.5)).foregroundStyle(CWPalette.gray).padding(.vertical, 12)
            } else if tab == 3 {
                Text("Starring is not available for imported metadata.").font(.system(size: 10.5)).foregroundStyle(CWPalette.gray).padding(.vertical, 12)
            } else if sections.isEmpty {
                Text("No messages match.").font(.system(size: 10.5)).foregroundStyle(CWPalette.gray).padding(.vertical, 12)
            }
            if tab != 3 && !sections.isEmpty {
                // The overview ScrollView is the scroll port, so every line stays reachable at 1280×800.
                ForEach(sections) { section in
                    HStack(spacing: 6) {
                        Text(section.platform).font(.system(size: 10, weight: .semibold)).foregroundStyle(CWPalette.ink)
                        Text("\(section.lines.count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(CWPalette.gray)
                            .accessibilityLabel("\(section.lines.count) \(section.platform)")
                    }
                    ForEach(section.lines) { line in
                        EmailOverviewLine(line: line, reviewed: store.mail.first { $0.sourceID == line.sourceID }?.reviewed ?? false) {
                            navigation.show(.email)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, minHeight: 200, alignment: .top).cwCard(12)
    }
}

struct EmailOverviewLine: View {
    var line: MailPlatformLine
    var reviewed: Bool
    var open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(reviewed ? .clear : CWPalette.blue).frame(width: 5, height: 5).padding(.top, 12)
                Avatar(name: line.sender, color: CWPalette.teal)
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.sender).font(.system(size: 10.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(line.subject).font(.system(size: 9.5)).foregroundStyle(CWPalette.gray).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text(String(line.receivedAt.prefix(10))).font(.system(size: 9)).foregroundStyle(CWPalette.gray)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct SettingsPanel: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var navigation: WorkspaceNavigation
    @State private var name = ""
    @State private var industry = ""
#if DEBUG && CONTEXTWARD_ACCEPTANCE
    @State private var autoPilot = false
#else
    @AppStorage(AutoPilot.storageKey) private var autoPilot = AutoPilot.defaultEnabled
#endif
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(title: "Settings")
            VStack(alignment: .leading, spacing: 5) {
                Text("Workspace settings").font(.system(size: 10.5, weight: .semibold))
                Text("Manage the business identity used across the CRM.").font(.system(size: 9)).foregroundStyle(CWPalette.gray).fixedSize(horizontal: false, vertical: true)
                TextField("Workspace name", text: $name).textFieldStyle(.roundedBorder).font(.system(size: 10))
                HStack {
                    Text("Industry").font(.system(size: 10))
                    Picker("", selection: $industry) { ForEach(Industries.all, id: \.self) { Text($0) } }.labelsHidden().controlSize(.small)
                }
                HStack { Spacer(); Button("Save changes") { store.saveBusiness(BusinessProfile(name: name, industry: industry)) }
                    .buttonStyle(BronzeButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }.padding(7).background(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.08)))
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(get: { store.automationRules.contains { $0.enabled } },
                                     set: { on in store.automationRules.forEach { store.setAutomation($0, enabled: on) } })) {
                    Text("Automation").font(.system(size: 10.5, weight: .semibold))
                }.toggleStyle(.switch).controlSize(.mini).tint(CWPalette.green)
                Text("Runs local rules only (tasks, signal routing). Never sends outreach.").font(.system(size: 9)).foregroundStyle(CWPalette.gray).fixedSize(horizontal: false, vertical: true)
                Toggle("Auto-Pilot (every five minutes while open)", isOn: $autoPilot).toggleStyle(.checkbox).font(.system(size: 9.5))
            }.padding(7).background(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.08)))
            VStack(alignment: .leading, spacing: 4) {
                Text("API keys").font(.system(size: 10.5, weight: .semibold))
                Text("Keys are stored in the macOS Keychain and are write-only here. \(store.savedKeys.count) saved.").font(.system(size: 9)).foregroundStyle(CWPalette.gray).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button { navigation.show(.settings) } label: { Label("Manage keys", systemImage: "key") }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(CWPalette.bronze).padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(CWPalette.bronze)) }
            }.padding(7).background(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.08)))
        }
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .top).cwCard(12)
        .onAppear { name = store.business.name; industry = store.business.industry }
        .task(id: autoPilot) {
            // Gated off unless the user ticks Auto-Pilot. runAutomations() is local-only.
            guard autoPilot else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: AutoPilot.interval)
                if Task.isCancelled || !autoPilot { break }
                _ = store.runAutomations()
            }
        }
    }
}

/// True when the Overview is showing synthetic records (preview build or synthetic mail import).
enum PreviewData {
    @MainActor static func isShowing(_ store: AppStore) -> Bool {
#if DEBUG && CONTEXTWARD_ACCEPTANCE
        true
#else
        PreviewBadge.isShowing(environment: ProcessInfo.processInfo.environment, mail: store.mail)
#endif
    }
}

/// Two children side by side at a fixed width ratio (the mockup's 45/55 middle row),
/// both stretched to the taller child's height.
struct RatioRow: Layout {
    var leading: CGFloat
    var spacing: CGFloat
    private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let usable = max(0, total - spacing)
        return (usable * leading, usable * (1 - leading))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 900
        let (a, b) = widths(total)
        var h: CGFloat = 0
        for (view, w) in zip(subviews, [a, b]) { h = max(h, view.sizeThatFits(ProposedViewSize(width: w, height: nil)).height) }
        return CGSize(width: total, height: h)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (a, b) = widths(bounds.width)
        var x = bounds.minX
        for (view, w) in zip(subviews, [a, b]) {
            view.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}
