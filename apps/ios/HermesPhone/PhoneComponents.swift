import SwiftUI

struct BotAvatar: View {
    @ScaledMetric(relativeTo: .title2) private var size = 44
    var body: some View {
        Image(systemName: "sparkles")
            .font(.title2.weight(.medium))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityHidden(true)
    }
}

struct BotIdentityLabel: View {
    let name: String
    let detail: String
    var body: some View {
        HStack(spacing: 12) {
            BotAvatar()
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

struct PhoneNotice: View {
    let title: String
    let message: String
    var systemImage = "exclamationmark.triangle"
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.tint)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
