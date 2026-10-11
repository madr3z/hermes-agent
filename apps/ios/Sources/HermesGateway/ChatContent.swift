import Foundation

public struct ChatAttachment: Identifiable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let isImage: Bool
    public var id: String { path }
    public init?(path: String, name: String? = nil, image: Bool = false) {
        let value: String
        if path.hasPrefix("file://"), let url = URL(string: path), url.host == nil || url.host == "localhost" { value = url.path }
        else { value = path }
        guard !value.isEmpty, !value.contains("://"), !value.hasPrefix("data:"), !value.hasPrefix("//"),
              !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else { return nil }
        self.path = value
        self.name = name?.isEmpty == false ? name! : (value as NSString).lastPathComponent
        isImage = image || ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif"].contains((value as NSString).pathExtension.lowercased())
    }
}

public struct ChatContent: Equatable {
    public struct Block: Equatable, Identifiable {
        public enum Kind: Equatable { case markdown, code }
        public let id: Int
        public let kind: Kind
        public let text: String
        public let language: String
    }
    public let blocks: [Block]
    public let attachments: [ChatAttachment]
    public static func parse(_ text: String) -> ChatContent {
        var blocks: [Block] = [], attachments: [ChatAttachment] = []
        var lines: [String] = [], fence: String?, language = ""
        func flush() {
            let body = lines.joined(separator: "\n")
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(Block(id: blocks.count, kind: fence == nil ? .markdown : .code, text: body, language: language))
            }
            lines = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                if trimmed.hasPrefix(marker) { flush(); fence = nil; language = "" }
                else { lines.append(line) }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush(); fence = String(trimmed.prefix(3)); language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(extract(line, attachments: &attachments))
            }
        }
        flush()
        var seen = Set<String>()
        return ChatContent(blocks: blocks, attachments: attachments.filter { seen.insert($0.path).inserted })
    }
    private static func extract(_ line: String, attachments: inout [ChatAttachment]) -> String {
        // Angle destinations can contain parentheses. Quoted directives keep their literal bytes.
        let pattern = #"(?:@(image|file):|MEDIA:)(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|[^\s]+)|(!?)\[([^\]]*)\]\((<[^>\n]+>|(?:[^()\n]|\([^()\n]*\))+)\)"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let source = line as NSString
        var result = line
        var found: [ChatAttachment] = []
        let codeSpans = inlineCodeSpans(line)
        for match in expression.matches(in: line, range: NSRange(location: 0, length: source.length)).reversed() {
            guard !codeSpans.contains(where: { NSLocationInRange(match.range.location, $0) }) else { continue }
            func value(_ index: Int) -> String { match.range(at: index).location == NSNotFound ? "" : source.substring(with: match.range(at: index)) }
            let directive = !value(2).isEmpty
            var path = directive ? value(2) : value(5)
            let quoted = ["`", "\"", "'", "<"].contains(String(path.prefix(1)))
            if quoted { path = String(path.dropFirst().dropLast()) }
            else if directive && value(1).isEmpty { path = path.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?")) }
            if !directive { path = path.removingPercentEncoding ?? path }
            // Plain web links remain native Markdown links. A bare MEDIA:word is not a file.
            guard (directive && !value(1).isEmpty) || path.contains("/") || (path as NSString).pathExtension.count > 0 else { continue }
            guard let attachment = ChatAttachment(path: path, name: directive ? nil : value(4), image: value(1) == "image" || value(3) == "!") else { continue }
            found.insert(attachment, at: 0)
            if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: "") }
        }
        attachments.append(contentsOf: found)
        return result
    }
    private static func inlineCodeSpans(_ line: String) -> [NSRange] {
        let runs = try! NSRegularExpression(pattern: "`+").matches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        var spans: [NSRange] = [], index = 0
        while index < runs.count {
            let opener = runs[index].range
            if let closing = runs.indices.dropFirst(index + 1).first(where: { runs[$0].range.length == opener.length }) {
                spans.append(NSRange(location: opener.location, length: NSMaxRange(runs[closing].range) - opener.location))
                index = closing + 1
            } else { index += 1 }
        }
        return spans
    }
}

public struct ChatUpload: Identifiable, Equatable {
    public static let maximumBytes = 10 * 1024 * 1024
    public let id: UUID
    public let name: String
    public let data: Data
    public let isImage: Bool
    public var staged: Staged?
    public struct Staged: Equatable { public let path: String; public let reference: String }
    public init(id: UUID = UUID(), name: String, data: Data, isImage: Bool) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw GatewayError.message("Choose a file between 1 byte and 10 MiB.") }
        self.id = id; self.name = (name as NSString).lastPathComponent; self.data = data; self.isImage = isImage
    }
    @MainActor public func stage(request: (String, [String: JSON]) async throws -> JSON) async throws -> Staged {
        if let staged { return staged }
        let result = try await request("file.attach", ["name": .string(name), "data_url": .string("data:application/octet-stream;base64," + data.base64EncodedString())])
        guard result["attached"].bool, let path = result["path"].string, let reference = result["ref_text"].string,
              ChatAttachment(path: path) != nil else { throw GatewayError.message("Gateway returned no attachment receipt.") }
        return Staged(path: path, reference: reference)
    }
}
