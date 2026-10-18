import SwiftUI

enum CRMTheme {
    static let ink = Color(red: 0.106, green: 0.141, blue: 0.188)
    static let paper = Color(red: 0.969, green: 0.961, blue: 0.941)
    static let amber = Color(red: 0.910, green: 0.639, blue: 0.239)
    static let amberDark = Color(red: 0.529, green: 0.341, blue: 0.071)
    static let slate = Color(red: 0.357, green: 0.392, blue: 0.447)
    static let steel = Color(red: 0.243, green: 0.424, blue: 0.557)
    static let moss = Color(red: 0.298, green: 0.478, blue: 0.369)
    static let rust = Color(red: 0.710, green: 0.282, blue: 0.184)
    static let border = Color(red: 0.894, green: 0.878, blue: 0.839)
}

extension LeadStatus {
    var color: Color {
        switch self {
        case .new: CRMTheme.slate
        case .contacted: CRMTheme.steel
        case .quoteSent: CRMTheme.amber
        case .won: CRMTheme.moss
        case .lost: CRMTheme.rust
        }
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(CRMTheme.ink)
    }
}

struct MetricCard: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(value)
                    .font(.system(.title3, design: .monospaced, weight: .bold))
            }
            .foregroundStyle(CRMTheme.amber)
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .background(CRMTheme.ink, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(CRMTheme.border, lineWidth: 1)
            }
    }
}

extension View {
    func crmCard() -> some View { modifier(CardModifier()) }
}

/// Colours sampled from the approved mockup (water-visual-fidelity.md).
enum CWPalette {
    fileprivate static func hex(_ v: UInt32) -> Color { Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255) }
    static let canvas = hex(0xF7F6F4)
    static let card = hex(0xFEFEFE)
    static let sidebarTop = hex(0x0F273A)
    static let sidebarBottom = hex(0x0A2234)
    static let selectedFill = hex(0x3C3B36)
    static let bronze = hex(0x774C14)
    static let goldLight = hex(0xB98A3E)
    static let goldIcon = hex(0xCFB381)
    static let teal = hex(0x31B1C3)
    static let ink = hex(0x051736)
    static let gray = hex(0x6B7280)
    static let tabSelected = hex(0x081E32)
    static let green = hex(0x0DA97A)
    static let blue = hex(0x177EF4)
    static let red = hex(0xE5484D)
    static let mint = hex(0xA0E9D1)
    static let progress = hex(0x01A680)
    // Nebula hero (dark, as in the mockup: ~#20313D mid tone)
    static let nebulaDeep = hex(0x0E2233)
    static let nebulaMid = hex(0x20313D)
    static let nebulaHaze = hex(0x6A97A6)
    static let nebulaGlowCool = hex(0x8FC3D6)
    static let nebulaGlowWarm = hex(0xE8B978)
    static let nebulaGlowBlue = hex(0x4F86AE)
    // Status pills
    static let activeText = hex(0x0B7A57)
    static let planningFill = hex(0xFDE3C4)
    static let planningText = hex(0xA35B12)
    static let completedFill = hex(0xD6E6FB)
    static let completedText = hex(0x1E5BB8)
    static let bronzeLight = hex(0x9A6A28)
    static let stageLead = hex(0x177EF4)
    static let stageQualified = hex(0xDF9B2E)
    static let stageProposal = hex(0x0DA97A)
    static let stageNegotiation = hex(0x8043E3)
    static let stageWon = hex(0x0F9EBB)
    static let stage: [OpportunityStage: Color] = [.lead: stageLead, .qualified: stageQualified, .proposal: stageProposal, .negotiation: stageNegotiation, .won: stageWon]
    static let bronzeGradient = LinearGradient(colors: [bronzeLight, bronze], startPoint: .top, endPoint: .bottom)
}

