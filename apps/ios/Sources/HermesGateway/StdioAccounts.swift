import Foundation

public struct StdioEnvironmentEntry: Identifiable, Sendable {
    public let id = UUID()
    public var name = ""
    public var value = ""
    public init(name: String = "", value: String = "") { self.name = name; self.value = value }
}

public struct StdioAccountPlan: Sendable {
    public let name: String
    public let parameters: [String: JSON]
    public let secrets: [String: String]
    public init(name: String, command: String, arguments: String = "", environment: [String: String] = [:], secrets entries: [StdioEnvironmentEntry], existingNames: [String] = []) throws {
        var draft = MCPConnectionDraft()
        draft.name = name; draft.transport = "stdio"; draft.target = command; draft.arguments = arguments
        var params = try draft.parameters(existingNames: existingNames)
        let account = params["name"]!.string!
        // A fresh setup owns fresh slots. A concurrent same-name add must not rotate another account's keys.
        let prefix = "MCP_" + account.uppercased().replacingOccurrences(of: "-", with: "_") + "_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "_"
        guard entries.count <= 16 else { throw GatewayError.message("Use at most 16 environment entries.") }
        var env = environment.mapValues(JSON.string)
        var secrets: [String: String] = [:]
        for entry in entries {
            let key = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.range(of: "^[A-Z][A-Z0-9_]{0,95}$", options: .regularExpression) != nil else {
                throw GatewayError.message("Environment names must use uppercase letters, digits or underscores and start with a letter.")
            }
            guard env[key] == nil else { throw GatewayError.message("Use each environment name once.") }
            guard !entry.value.isEmpty, entry.value.utf8.count <= 4096,
                  !entry.value.contains("\n"), !entry.value.contains("\r"), !entry.value.contains("\0") else {
                throw GatewayError.message("Enter a non-empty single-line value of at most 4 KiB for each credential.")
            }
            let slot = prefix + key
            env[key] = .string("${\(slot)}")
            secrets[slot] = entry.value
        }
        guard case .object(var config) = params["config"] else { throw GatewayError.message("The stdio configuration is incomplete.") }
        config["env"] = .object(env); params["config"] = .object(config)
        self.name = account; parameters = params; self.secrets = secrets
    }
}

public struct ICloudAccountDraft: Sendable {
    public static let revision = "8cf9a4f86c6af36f4e6121d8b0e93806611036e9"
    public static let source = URL(string: "https://github.com/ThomasCrouzet/icloud-mcp/tree/" + revision)!
    public var name = "icloud-personal"
    public var email = ""
    public var password = ""
    public var mailAddress = ""
    public var readOnly = true
    public var mailWrite = false
    public var mailSend = false
    public var allowAllRecipients = false
    public var recipients = ""
    public init() {}
    public func plan(existingNames: [String] = [], timeZone: String = TimeZone.current.identifier) throws -> StdioAccountPlan {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let mail = mailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validAddress(email), Self.validAddress(mail.isEmpty ? email : mail) else {
            throw GatewayError.message("Enter a plain email address for the Apple Account and iCloud Mail.")
        }
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatewayError.message("Enter an app-specific password. Do not use your Apple Account password.")
        }
        guard !readOnly || !mailSend else { throw GatewayError.message("Turn off read-only access before enabling mail sending.") }
        var policy = ""
        if mailSend {
            if allowAllRecipients { policy = "*" }
            else {
                let addresses = recipients.components(separatedBy: CharacterSet(charactersIn: ",\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard addresses.allSatisfy(Self.validAddress), Set(addresses.map { $0.lowercased() }).count == addresses.count else {
                    throw GatewayError.message("Enter distinct recipient email addresses, separated by commas or new lines. Choose All recipients explicitly to allow any address.")
                }
                policy = addresses.joined(separator: ",")
            }
        }
        return try StdioAccountPlan(name: name, command: "/opt/hermes-connectors/icloud-mcp", environment: [
            "ICLOUD_EMAIL": email, "ICLOUD_MAIL_ADDRESS": mail.isEmpty ? email : mail,
            "ICLOUD_MCP_ENABLE_MAIL": "true", "ICLOUD_MCP_ENABLE_CONTACTS": "false",
            "ICLOUD_MCP_READ_ONLY": String(readOnly), "ICLOUD_MCP_ENABLE_MAIL_WRITE": String(!readOnly && mailWrite),
            "ICLOUD_MCP_ENABLE_MAIL_SEND": String(mailSend), "ICLOUD_MCP_SMTP_ALLOWED_RECIPIENTS": policy,
            "ICLOUD_MCP_DEFAULT_TZ": timeZone
        ], secrets: [.init(name: "ICLOUD_PASSWORD", value: password)], existingNames: existingNames)
    }
    private static func validAddress(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9.!#$%&'+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$", options: .regularExpression) != nil
    }
}

/// Keeps retry authority only for the same transient setup. It never reveals saved credentials.
@MainActor public final class StdioAccountInstaller {
    public typealias HTTP = (String, String, JSON?) async throws -> JSON
    private var plan: StdioAccountPlan?
    private let client: BotConnectorsClient
    private let http: HTTP
    private var checkedSlots = false
    private var savedSlots = Set<String>()
    public private(set) var canRetry = true
    public private(set) var saved = false
    public init(plan: StdioAccountPlan, client: BotConnectorsClient, http: @escaping HTTP) {
        self.plan = plan; self.client = client; self.http = http
    }
    public func save() async throws {
        guard canRetry, let plan else { throw GatewayError.message("Refresh the account list before starting another setup.") }
        do {
            let names = try await client.mcpServers().map(\.name)
            var draft = MCPConnectionDraft(); draft.name = plan.name; draft.transport = "stdio"; draft.target = "/validation-only"
            do { _ = try draft.parameters(existingNames: names) }
            catch {
                canRetry = false
                throw GatewayError.message("This account name is already in use. Existing accounts were kept. Close this setup and choose a new name; any credentials from an earlier partial attempt remain on this bot.")
            }
            if !checkedSlots {
                let inventory = try await http("api/env", "GET", nil)
                guard !plan.secrets.keys.contains(where: { inventory[$0]["is_set"].bool }) else {
                    canRetry = false
                    throw GatewayError.message("A credential slot is already in use. Choose a new account name. Existing credentials were kept.")
                }
                checkedSlots = true
            }
        } catch {
            if !canRetry { throw error }
            throw GatewayError.message("Could not verify that the account name and credential slots are free. No new credentials were written in this attempt. Refresh and retry.")
        }
        for slot in plan.secrets.keys.sorted() where !savedSlots.contains(slot) {
            do {
                let result = try await http("api/env", "PUT", .object(["key": .string(slot), "value": .string(plan.secrets[slot]!)]))
                guard result["ok"] != .bool(false) else { throw GatewayError.message("Credential write refused.") }
                savedSlots.insert(slot)
            } catch {
                throw GatewayError.message("Credential setup stopped before adding the server. Some credentials may already be saved on this bot. Retry this setup to finish the same account, or close it and manage saved keys from your Mac.")
            }
        }
        canRetry = false
        do {
            let result = try await client.call("mcp.servers.add", plan.parameters)
            guard result["ok"] != .bool(false) else { throw GatewayError.message("Server add refused.") }
            saved = true; self.plan = nil
        } catch {
            self.plan = nil
            throw GatewayError.message("Credentials were saved. The server add did not return a confirmed success. Refresh the account list before another setup. Do not retry this add blindly; keep an existing server or remove its unused keys from your Mac.")
        }
    }
}
