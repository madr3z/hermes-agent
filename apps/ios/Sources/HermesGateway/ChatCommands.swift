import Foundation

public struct ChatCommandInvocation: Equatable, Sendable {
    public let name: String
    public let argument: String
    public init?(_ text: String) {
        guard text.hasPrefix("/") else { return nil }
        let remainder = text.dropFirst()
        let token = remainder.prefix { !$0.isWhitespace }
        guard !token.contains("/") else { return nil }
        name = token.lowercased()
        argument = remainder.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ChatCommand: Identifiable, Equatable, Sendable {
    public let id: String
    public let description: String
    public let availability: String
    public let subcommands: [String]?
    public init(name: String, description: String, metadata: JSON) {
        id = name; self.description = description
        availability = metadata["mobile"].string ?? "unsupported"
        if case .array(let rows) = metadata["mobile_subcommands"] { subcommands = rows.compactMap(\.string) }
        else { subcommands = nil }
    }
}

public struct ChatCommandCatalog: Equatable, Sendable {
    public let commands: [ChatCommand]
    private let canonical: [String: String]
    public let warning: String?
    public init(_ result: JSON) throws {
        guard case .array(let pairs) = result["pairs"] else { throw GatewayError.message("The gateway did not return its command catalog.") }
        commands = pairs.compactMap { pair in
            guard pair.array.count == 2, let name = pair.array[0].string, let description = pair.array[1].string else { return nil }
            return ChatCommand(name: name, description: description, metadata: result["commands"][name])
        }
        if case .object(let aliases) = result["canon"] { canonical = aliases.compactMapValues(\.string) }
        else { canonical = [:] }
        warning = result["warning"].string
    }
    public func command(named name: String) -> ChatCommand? {
        let name = "/" + name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let key = canonical[name] ?? name
        return commands.first { $0.id == key }
    }
}

public struct ChatCommandCompletion: Identifiable, Equatable, Sendable {
    public let text: String
    public let display: String
    public let detail: String
    public let replaceFrom: Int
    public var id: String { text }
    public init(_ row: JSON, replaceFrom: Int) {
        text = row["text"].string ?? ""
        display = row["display"].string ?? text
        detail = row["meta"].string ?? ""
        self.replaceFrom = replaceFrom
    }
    public func applying(to query: String) -> String {
        let prefix = String(query.prefix(max(0, min(replaceFrom, query.count))))
        return prefix + (prefix.hasSuffix("/") && text.hasPrefix("/") ? String(text.dropFirst()) : text)
    }
}

public enum ChatCommandOutcome: Equatable, Sendable {
    case output(String)
    case native(String)
    case prefill(String, notice: String?)
    case send(String, display: String, notice: String?)
}

@MainActor public struct ChatCommandsClient {
    private let profile: String
    private let sessionID: String
    private let request: (String, [String: JSON]) async throws -> JSON
    public init(profile: String, sessionID: String, request: @escaping (String, [String: JSON]) async throws -> JSON) {
        self.profile = profile; self.sessionID = sessionID; self.request = request
    }
    public func catalog() async throws -> ChatCommandCatalog { try ChatCommandCatalog(try await call("commands.catalog")) }
    public func complete(_ text: String) async throws -> [ChatCommandCompletion] {
        guard text.hasPrefix("/") else { return [] }
        let result = try await call("complete.slash", ["text": .string(text)])
        return result["items"].array.map { ChatCommandCompletion($0, replaceFrom: Int(result["replace_from"].number ?? 1)) }
    }
    public func execute(_ text: String) async throws -> ChatCommandOutcome {
        guard let invocation = ChatCommandInvocation(text), !invocation.name.isEmpty else { return .native("help") }
        return try await execute(invocation, visible: text, remainingAliases: 4)
    }
    private func execute(_ invocation: ChatCommandInvocation, visible: String, remainingAliases: Int) async throws -> ChatCommandOutcome {
        let catalog = try await catalog()
        guard let command = catalog.command(named: invocation.name) else {
            throw GatewayError.message("This command is not in this bot’s current catalog. Refresh Commands before trying again.")
        }
        if command.availability == "native" {
            guard invocation.argument.isEmpty else { throw GatewayError.message("Open \(command.id) without arguments, then use its native controls. Your draft is kept.") }
            return .native(String(command.id.dropFirst()))
        }
        guard ["server", "dispatch"].contains(command.availability) else {
            throw GatewayError.message("\(command.id) needs a Mac or terminal control that this iPhone app does not provide. Your draft and attachments are kept.")
        }
        if let subcommands = command.subcommands {
            let first = invocation.argument.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            guard subcommands.contains(first) else {
                throw GatewayError.message("On iPhone, \(command.id) supports: \(subcommands.map { $0.isEmpty ? "no argument" : $0 }.joined(separator: ", ")). Use your Mac for other actions.")
            }
        }
        let raw: JSON
        do {
            if command.availability == "dispatch" {
                raw = try await call("command.dispatch", ["name": .string(invocation.name), "arg": .string(invocation.argument)])
            } else {
                raw = try await call("slash.exec", ["command": .string(String(command.id.dropFirst()) + (invocation.argument.isEmpty ? "" : " " + invocation.argument))])
            }
        }
        catch GatewayError.rpc(let code, let message) where command.availability == "server" && code == 4018 && message.hasPrefix("skill command:") {
            // This explicit refusal occurs before command execution. Uncertain failures never fall back.
            raw = try await call("command.dispatch", ["name": .string(invocation.name), "arg": .string(invocation.argument)])
        }
        switch raw["type"].string {
        case nil, "exec", "plugin":
            let output = [raw["output"].string, raw["warning"].string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            return .output(output.isEmpty ? "The gateway returned no command output." : output)
        case "prefill":
            guard let message = raw["message"].string else { throw GatewayError.message("The gateway returned an incomplete command response.") }
            return .prefill(message, notice: raw["notice"].string)
        case "send", "skill":
            guard let message = raw["message"].string else { throw GatewayError.message("The gateway returned an incomplete command response.") }
            return .send(message, display: raw["display"].string ?? visible, notice: raw["notice"].string)
        case "alias":
            guard remainingAliases > 0, let target = raw["target"].string, let next = ChatCommandInvocation(target.hasPrefix("/") ? target : "/" + target) else {
                throw GatewayError.message("This command alias could not be resolved.")
            }
            return try await execute(next, visible: visible, remainingAliases: remainingAliases - 1)
        default: throw GatewayError.message("This command needs a client action that this iPhone app does not support.")
        }
    }
    private func call(_ method: String, _ extra: [String: JSON] = [:]) async throws -> JSON {
        guard !sessionID.isEmpty else { throw GatewayError.message("Reconnect Bot Chat before using commands.") }
        return try await request(method, extra.merging(["session_id": .string(sessionID), "profile": .string(profile)]) { _, owner in owner })
    }
}
