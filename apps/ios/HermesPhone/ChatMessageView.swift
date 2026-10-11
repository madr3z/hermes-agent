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
                Text(message.text).font(.callout.monospaced()).textSelection(.enabled)
            } label: {
                HStack(spacing: 8) {
                    if message.toolRunning { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                    Text(name.replacingOccurrences(of: "_", with: " ")).font(.caption.weight(.medium))
                }
            }.padding(12).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        } else {
            HStack(alignment: .top) {
                if message.role == "user" { Spacer(minLength: 36) }
                VStack(alignment: .leading, spacing: 10) {
                    Text(message.role == "user" ? "You" : botName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if message.voice { Label("GPT Live", systemImage: "waveform").font(.caption).foregroundStyle(.secondary) }
                    let content = ChatContent.parse(message.text)
                    ForEach(content.blocks) { block in
                        if block.kind == .code { ChatCodeBlock(block: block) }
                        else { ChatMarkdown(text: block.text) }
                    }
                    ForEach(content.attachments) { attachment in
                        ChatFileCard(attachment: attachment, client: client, profile: profile, storedSessionID: storedSessionID)
                    }
                }.padding(message.role == "user" ? 14 : 0)
                    .background(message.role == "user" ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 18))
                if message.role != "user" { Spacer(minLength: 12) }
            }
        }
    }
}

private struct ChatMarkdown: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let heading = line.prefix(while: { $0 == "#" }).count
                let isHeading = (1...6).contains(heading) && line.dropFirst(heading).hasPrefix(" ")
                let quote = line.hasPrefix("> ")
                let list = line.hasPrefix("- ") || line.hasPrefix("* ")
                let body = isHeading ? String(line.dropFirst(heading + 1)) : quote || list ? String(line.dropFirst(2)) : line
                HStack(alignment: .top, spacing: 8) {
                    if list { Text("•") }
                    if quote { Rectangle().fill(.secondary).frame(width: 2) }
                    Text((try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body))
                        .font(isHeading ? .headline : .body).textSelection(.enabled)
                }.fixedSize(horizontal: false, vertical: true)
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
                Text(block.language.isEmpty ? "Code" : block.language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { UIPasteboard.general.string = block.text; copied = true }.font(.subheadline).frame(minHeight: 44)
                    .accessibilityLabel(copied ? "Code copied" : "Copy code")
            }
            ScrollView(.horizontal) { Text(block.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }
        }.padding(12).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
