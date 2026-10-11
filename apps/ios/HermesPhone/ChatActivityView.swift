import SwiftUI
import HermesGateway

/// One stable row. Tokens do not generate VoiceOver announcements.
struct ChatActivityView: View {
    let activity: ChatActivityState
    let botName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if activity.isVisible {
            HStack(alignment: .top, spacing: 10) {
                if activity.isAnimating {
                    if reduceMotion {
                        Image(systemName: "ellipsis.bubble").foregroundStyle(.tint).accessibilityHidden(true)
                    } else {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    }
                } else {
                    Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(activity.title).font(.subheadline.weight(.medium))
                        .accessibilityLabel("\(botName): \(activity.title)")
                    if let detail = activity.detail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chatActivity")
        }
    }
}
