import SwiftUI
import HermesGateway

struct ChatMessageView: View {
    let message: ChatMessage
    let client: GatewayClient?
    let profile: String
    let storedSessionID: String?
    var botName = "Hermes"
    var body: some View {
        if let name = message.toolName {
            DisclosureGroup {
                ScrollView(.horizontal) {
                    Text(message.text).font(.callout.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }.padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    if message.toolRunning { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "checkmark.circle").foregroundStyle(DispatchStyle.secondary) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name.replacingOccurrences(of: "_", with: " ").capitalized).font(.subheadline.weight(.medium))
                        Text(message.toolRunning ? "Working…" : "View result").font(.caption).foregroundStyle(DispatchStyle.secondary)
                    }
                }
            }.padding(12).background(DispatchStyle.wash, in: RoundedRectangle(cornerRadius: 16))
        } else {
            HStack(alignment: .top) {
                if message.role == "user" { Spacer(minLength: 36) }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        if message.role != "user" { Image(systemName: "sparkles").foregroundStyle(DispatchStyle.forest).accessibilityHidden(true) }
                        Text(message.role == "user" ? "You" : botName).foregroundStyle(DispatchStyle.secondary)
                    }.font(.caption.weight(.semibold))
                    if message.voice { Label("GPT Live", systemImage: "waveform").font(.caption).foregroundStyle(DispatchStyle.secondary) }
                    let content = ChatContent.parse(message.text)
                    ForEach(content.blocks) { block in
                        if block.kind == .code { ChatCodeBlock(block: block) }
                        else { ChatMarkdown(text: block.text) }
                    }
                    ForEach(content.attachments) { attachment in
                        ChatFileCard(attachment: attachment, client: client, profile: profile, storedSessionID: storedSessionID)
                    }
                }.padding(message.role == "user" ? 16 : 0)
                    .background(message.role == "user" ? DispatchStyle.wash : Color.clear, in: RoundedRectangle(cornerRadius: 20))
                if message.role != "user" { Spacer(minLength: 12) }
            }
        }
    }
}

private struct ChatMarkdown: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let heading = line.prefix(while: { $0 == "#" }).count
                let isHeading = (1...6).contains(heading) && line.dropFirst(heading).hasPrefix(" ")
                let quote = line.hasPrefix("> ")
                let list = line.hasPrefix("- ") || line.hasPrefix("* ")
                let body = isHeading ? String(line.dropFirst(heading + 1)) : quote || list ? String(line.dropFirst(2)) : line
                HStack(alignment: .top, spacing: 8) {
                    if list { Text("•") }
                    if quote { RoundedRectangle(cornerRadius: 2).fill(DispatchStyle.forest.opacity(0.4)).frame(width: 3) }
                    Text((try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body))
                        .font(isHeading ? DispatchStyle.serif(heading <= 2 ? 25 : 22, relativeTo: .headline) : .body)
                        .lineSpacing(4)
                        .foregroundStyle(DispatchStyle.ink)
                        .textSelection(.enabled)
                        .accessibilityAddTraits(isHeading ? .isHeader : [])
                }.fixedSize(horizontal: false, vertical: true)
                .padding(.top, isHeading ? 4 : 0)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            // Gateway paths are attachment cards. Never open them with the OS URL handler.
            ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
}

private struct ChatCodeBlock: View {
    let block: ChatContent.Block
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(block.language.isEmpty ? "Code" : block.language, systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption.weight(.medium)).foregroundStyle(DispatchStyle.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { UIPasteboard.general.string = block.text; copied = true }.font(.subheadline).frame(minHeight: 44)
                    .accessibilityLabel(copied ? "Code copied" : "Copy code")
            }
            ScrollView(.horizontal) { Text(block.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }
        }.padding(14).background(DispatchStyle.wash, in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: block.text) { _, _ in copied = false }
    }
}
