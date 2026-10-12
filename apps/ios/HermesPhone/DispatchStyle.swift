import SwiftUI

enum DispatchStyle {
    static let paper = adaptive(0xF6F3ED, dark: 0x202622)
    static let ink = adaptive(0x171C19, dark: 0xF6F3ED)
    static let secondary = adaptive(0x6B6E68, dark: 0xB9C1BA)
    static let forest = adaptive(0x2D5D52, dark: 0xA3CFBD)
    static let rust = adaptive(0xA44F27, dark: 0xE9AA83)
    static let rule = adaptive(0xDCDAD2, dark: 0x465048)
    static let wash = adaptive(0xE4E6DD, dark: 0x303D34)
    static let button = Color(red: 45 / 255, green: 93 / 255, blue: 82 / 255)

    static func serif(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("Baskerville", size: size, relativeTo: style)
    }
    private static func adaptive(_ light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

enum DispatchTab: String, CaseIterable {
    case today, chats, bots
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .today: return "house"
        case .chats: return "bubble.left"
        case .bots: return "person.2"
        }
    }
}

struct DispatchTabBar: View {
    @Binding var selection: DispatchTab
    var body: some View {
        HStack(spacing: 0) {
            ForEach(DispatchTab.allCases, id: \.self) { tab in
                Button { selection = tab } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol + (selection == tab ? ".fill" : ""))
                            .font(.system(size: 23, weight: .regular))
                        Text(tab.title).font(.caption)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .contentShape(Rectangle())
                    .foregroundStyle(selection == tab ? DispatchStyle.forest : DispatchStyle.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("dispatchTab-" + tab.rawValue)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 2)
        .background(DispatchStyle.paper.ignoresSafeArea(edges: .bottom))
    }
}

struct DispatchAction: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(title).font(.body)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.title3)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(minHeight: 48)
            .foregroundStyle(.white)
            .background(DispatchStyle.button, in: RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain)
    }
}

struct DispatchAvatar: View {
    var symbol = "person"
    var size: CGFloat = 35
    var body: some View {
        Image(systemName: symbol).font(.system(size: 21, weight: .light))
            .foregroundStyle(DispatchStyle.forest)
            .frame(width: size, height: size)
            .background(DispatchStyle.wash, in: Circle())
            .accessibilityHidden(true)
    }
}
