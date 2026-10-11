import SwiftUI

struct BotAvatar: View {
    @ScaledMetric(relativeTo: .title2) private var size = 44
    var body: some View {
        Image(systemName: "sparkles")
            .font(.title2.weight(.medium))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityHidden(true)
    }
}

struct BotIdentityLabel: View {
    let name: String
    let detail: String
    var body: some View {
        HStack(spacing: 14) {
            BotAvatar()
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.title3.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

struct PhoneFeatureRow: View {
    let title: String
    let detail: String
    let systemImage: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium)).foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 7)
    }
}

struct PhoneNotice: View {
    let title: String
    let message: String
    var systemImage = "exclamationmark.triangle"
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(.tint)
                .font(.body).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
