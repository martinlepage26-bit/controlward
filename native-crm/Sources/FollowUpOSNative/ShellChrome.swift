import SwiftUI
import AppKit

/// Sidebar order from the approved mockup. Saved views is reachable from the profile menu.
extension WorkspaceSection {
    static let sidebarOrder: [WorkspaceSection] = [.overview, .projects, .email, .pipeline, .operations, .intelligence, .integrations,
                                                    .contacts, .companies, .opportunities, .tasks, .notes, .activity, .security, .settings]
}

struct CWSidebar: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var navigation: WorkspaceNavigation
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ControlWardLogo(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ControlWard").font(.system(size: 15, weight: .semibold)).lineLimit(1).fixedSize().foregroundStyle(.white)
                    Text("PHAROS CRM").font(.system(size: 7.5, weight: .medium)).tracking(1.5).foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))
            .padding(.horizontal, 10).padding(.top, 30).padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(WorkspaceSection.sidebarOrder) { section in
                        let selected = (navigation.section ?? .overview) == section
                        Button { navigation.show(section) } label: {
                            HStack(spacing: 11) {
                                Image(systemName: section.symbol).frame(width: 18).foregroundStyle(selected ? CWPalette.goldIcon : .white.opacity(0.85))
                                Text(section.rawValue).foregroundStyle(.white).lineLimit(1)
                                Spacer()
                            }
                            .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6.5)
                            .background(selected ? CWPalette.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? CWPalette.goldIcon.opacity(0.8) : .clear, lineWidth: 1))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }.padding(.horizontal, 10)
            }
            Divider().overlay(.white.opacity(0.12))
            Button { navigation.show(.settings) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "globe").foregroundStyle(.white.opacity(0.85))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.business.name).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                        Text(store.business.industry).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.7))
                    }.foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
                }.padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Workspace \(store.business.name), \(store.business.industry)")
        }
        .background {
            ZStack {
                LinearGradient(colors: [CWPalette.sidebarTop, CWPalette.sidebarBottom], startPoint: .top, endPoint: .bottom)
                Canvas { ctx, size in
                    var rng = SeededRandom(seed: 3)
                    for _ in 0..<140 {
                        let p = CGPoint(x: rng.next() * size.width, y: rng.next() * size.height)
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: 1, height: 1)), with: .color(.white.opacity(0.1 + rng.next() * 0.25)))
                    }
                }
            }.ignoresSafeArea()
        }
    }
}

struct CWTopBar: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var navigation: WorkspaceNavigation
    @Binding var search: String
    @FocusState private var searchFocused: Bool
    var body: some View {
        let fullName = NSFullUserName()
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(CWPalette.gray)
                TextField("Search leads, projects, emails, or anything...", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused)
                    .onSubmit { navigation.show(.overview) }
                Text("⌘K").font(.system(size: 10, weight: .medium)).foregroundStyle(CWPalette.gray)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.15)))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(CWPalette.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.08)))
            .frame(maxWidth: 480)
            .background { Button("") { searchFocused = true }.keyboardShortcut("k", modifiers: .command).opacity(0) }
            Spacer()
            Menu {
                Button("Contact") { navigation.directory("contacts") }
                Button("Company") { navigation.directory("companies") }
                Button("Opportunity") { navigation.directory("opportunities") }
                Button("Task") { navigation.directory("tasks") }
                Button("Note") { navigation.directory("notes") }
                Button("Lead") { navigation.show(.pipeline) }
                Button("Project") { navigation.show(.projects) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus"); Text("New")
                    Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 14)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }.font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(CWPalette.bronzeGradient, in: RoundedRectangle(cornerRadius: 7))
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Button { navigation.show(.activity) } label: { Image(systemName: "bell").font(.system(size: 15)).foregroundStyle(CWPalette.ink) }
                .buttonStyle(.plain).help("Activity")
            Menu {
                Button("Saved views") { navigation.show(.views) }
                Button("Settings") { navigation.show(.settings) }
                Button("Security") { navigation.show(.security) }
            } label: { HStack(spacing: 8) {
                Text(OverviewSnapshot.initials(fullName)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(CWPalette.teal, in: Circle())
                Text(fullName).font(.system(size: 12)).foregroundStyle(CWPalette.ink)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(CWPalette.gray)
            } }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}
