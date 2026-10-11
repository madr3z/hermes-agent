import Foundation

public struct SubagentTask: Identifiable, Equatable, Sendable {
    public let id: String
    public let goal: String
    public let status: String
    public let model: String?
    public let parentID: String?
    public let depth: Int
    public let toolCount: Int
    public let lastTool: String?
    public let summary: String?
    public let error: String?
    public let canInterrupt: Bool
    public let canSteer: Bool
    public var isActive: Bool { ["pending", "queued", "running", "streaming", "starting"].contains(status) }
    public var statusLabel: String {
        switch status {
        case "interrupted", "cancelled": return "Stopped"
        case "error", "failed": return "Failed"
        case "timeout": return "Timed out"
        case "completed": return "Completed"
        case "pending", "queued": return "Queued"
        default: return status.capitalized
        }
    }
    public init(_ row: JSON) throws {
        guard let id = row["subagent_id"].string, !id.isEmpty else {
            throw GatewayError.message("The gateway returned a subagent without an ID.")
        }
        self.id = id
        goal = row["goal"].string ?? "Subagent task"
        status = row["status"].string ?? "unknown"
        model = row["model"].string
        parentID = row["parent_id"].string
        depth = Int(row["depth"].number ?? 0)
        toolCount = Int(row["tool_count"].number ?? 0)
        lastTool = row["last_tool"].string
        summary = row["summary"].string
        error = row["error"].string
        // A visible child after reconnect may belong to an older transport generation.
        canInterrupt = row["can_interrupt"].bool && ["pending", "queued", "running", "streaming", "starting"].contains(status)
        canSteer = row["can_steer"].bool && ["pending", "queued", "running", "streaming", "starting"].contains(status)
    }
}

@MainActor public struct SubagentsClient {
    public let profile: String
    public let sessionID: String
    private let request: (String, [String: JSON]) async throws -> JSON
    public init(profile: String, sessionID: String, request: @escaping (String, [String: JSON]) async throws -> JSON) {
        self.profile = profile; self.sessionID = sessionID; self.request = request
    }
    public func list() async throws -> [SubagentTask] {
        let result = try await call("subagent.list")
        guard case .array(let rows) = result["subagents"] else {
            throw GatewayError.message("The gateway did not return a subagent list.")
        }
        return try rows.map(SubagentTask.init)
    }
    public func interrupt(_ task: SubagentTask) async throws -> String {
        guard task.canInterrupt else { throw GatewayError.message("This subagent cannot be stopped from this connection. Refresh its status.") }
        let response = try await call("subagent.interrupt", ["subagent_id": .string(task.id)])
        return response["found"].bool ? "Stop requested. The gateway will report when this subagent ends." : "This subagent is no longer available to stop. Refresh its status."
    }
    public func steer(_ task: SubagentTask, text: String) async throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.canSteer, !text.isEmpty else { throw GatewayError.message("Enter instructions for a subagent that accepts updates.") }
        let response = try await call("subagent.steer", ["subagent_id": .string(task.id), "text": .string(text)])
        guard response["status"].string == "queued" else {
            throw GatewayError.message(response["reason"].string ?? "This subagent is no longer accepting instructions. Refresh its status.")
        }
        return "Instructions queued. The subagent will receive them at its next safe point."
    }
    private func call(_ method: String, _ extra: [String: JSON] = [:]) async throws -> JSON {
        guard !sessionID.isEmpty else { throw GatewayError.message("Open Bot Chat before managing its subagents.") }
        return try await request(method, extra.merging(["profile": .string(profile), "session_id": .string(sessionID)]) { _, owner in owner })
    }
}
