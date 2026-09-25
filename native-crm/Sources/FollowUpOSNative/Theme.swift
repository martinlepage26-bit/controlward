import SwiftUI

enum CRMTheme {
    static let ink = Color(red: 0.106, green: 0.141, blue: 0.188)
    static let paper = Color(red: 0.969, green: 0.961, blue: 0.941)
    static let amber = Color(red: 0.910, green: 0.639, blue: 0.239)
    static let amberDark = Color(red: 0.780, green: 0.522, blue: 0.165)
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
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(CRMTheme.slate)
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
