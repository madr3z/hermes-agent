import SwiftUI

struct BotAvatar: View {
    @ScaledMetric(relativeTo: .title2) private var size = 44
    var body: some View {
        Image(systemName: "person")
            .font(.title2.weight(.light))
            .foregroundStyle(DispatchStyle.forest)
            .frame(width: size, height: size)
            .background(DispatchStyle.wash, in: Circle())
            .accessibilityHidden(true)
    }
}

struct BotIdentityLabel: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let name: String
    let detail: String
    var body: some View {
        HStack(spacing: 14) {
            if !typeSize.isAccessibilitySize { BotAvatar() }
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(DispatchStyle.serif(25, relativeTo: .title3))
                Text(detail).font(.subheadline).foregroundStyle(DispatchStyle.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

struct PhoneFeatureRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let detail: String
    let systemImage: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium)).foregroundStyle(DispatchStyle.forest)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(DispatchStyle.ink)
                Text(detail).font(.subheadline).foregroundStyle(DispatchStyle.secondary)
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
            Image(systemName: systemImage).foregroundStyle(DispatchStyle.forest)
                .font(.body).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.subheadline).foregroundStyle(DispatchStyle.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
