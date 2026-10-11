import Foundation

public struct BotRoutine: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let schedule: String
    public let prompt: String
    public let enabled: Bool
    public let state: String
    public let nextRun: String?
    public let lastRun: String?
    public let lastStatus: String?
    public let lastError: String?
    public let delivery: String
    public init(_ row: JSON) throws {
        guard let id = row["job_id"].string, !id.isEmpty else { throw GatewayError.message("The gateway returned a task without an ID.") }
        self.id = id
        name = row["name"].string ?? id
        schedule = row["schedule"].string ?? "Unknown schedule"
        prompt = row["prompt_preview"].string ?? ""
        enabled = row["enabled"] != .bool(false)
        state = row["state"].string ?? (enabled ? "scheduled" : "paused")
        nextRun = row["next_run_at"].string; lastRun = row["last_run_at"].string
        lastStatus = row["last_status"].string
        lastError = row["last_error"].string ?? row["last_fire_error"].string ?? row["last_delivery_error"].string
        delivery = row["deliver"].string ?? "local"
    }
    public func displayName(profile: String) -> String {
        let tag = "[bot:\(profile)] "
        return name.hasPrefix(tag) ? String(name.dropFirst(tag.count)) : name
    }
}

public enum RoutineFrequency: String, CaseIterable, Identifiable, Sendable {
    case once = "Once", hourly = "Every hour", daily = "Every 24 hours", weekly = "Every 7 days"
    public var id: String { rawValue }
}

public struct BotRoutineDraft: Equatable, Sendable {
    public var name = ""
    public var instruction = ""
    public var frequency: RoutineFrequency = .daily
    public var date = Date().addingTimeInterval(3600)
    public init() {}
    public func parameters(profile: String, now: Date = Date()) throws -> [String: JSON] {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 100, !task.isEmpty else { throw GatewayError.message("Enter a task name (up to 100 characters) and instructions.") }
        let schedule: String
        switch frequency {
        case .once:
            guard date > now else { throw GatewayError.message("Choose a future date and time.") }
            schedule = ISO8601DateFormatter().string(from: date)
        case .hourly: schedule = "every 1h"
        case .daily: schedule = "every 1d"
        case .weekly: schedule = "every 7d"
        }
        return ["action": .string("add"), "name": .string("[bot:\(profile)] \(title)"), "schedule": .string(schedule),
                "prompt": .string(task), "deliver": .string("bot-chat"), "continuity": .bool(false)]
    }
}

@MainActor public struct BotRoutinesClient {
    public let profile: String
    private let request: (String, [String: JSON]) async throws -> JSON
    public init(profile: String, request: @escaping (String, [String: JSON]) async throws -> JSON) {
        self.profile = profile; self.request = request
    }
    public func list() async throws -> [BotRoutine] {
        let result = try await call(["action": .string("list"), "include_disabled": .bool(true)])
        // An older backend may ignore profile. Never show or mutate another profile's store.
        guard result["scoped"].string == profile else {
            throw GatewayError.message("This gateway cannot confirm which bot owns these tasks. Update its Hermes runtime on your Mac.")
        }
        guard case .array(let rows) = result["jobs"] else { throw GatewayError.message("The gateway did not return a task list.") }
        return try rows.map(BotRoutine.init)
    }
    public func create(_ draft: BotRoutineDraft) async throws -> JSON {
        _ = try await list()
        return try await call(draft.parameters(profile: profile))
    }
    public func setEnabled(id: String, enabled: Bool) async throws -> JSON {
        let jobs = try await list()
        guard let job = jobs.first(where: { $0.id == id }) else { throw GatewayError.message("This task is no longer in this bot's schedule. Refresh the list.") }
        if job.enabled == enabled { return .object(["success": .bool(true)]) }
        return try await call(["action": .string(enabled ? "resume" : "pause"), "name": .string(id)])
    }
    public func remove(id: String) async throws -> JSON {
        guard try await list().contains(where: { $0.id == id }) else { throw GatewayError.message("This task is no longer in this bot's schedule. Refresh the list.") }
        return try await call(["action": .string("remove"), "name": .string(id)])
    }
    private func call(_ parameters: [String: JSON]) async throws -> JSON {
        let result = try await request("cron.manage", parameters.merging(["profile": .string(profile)]) { _, owner in owner })
        if let error = result["error"].string { throw GatewayError.message(error) }
        if result["success"] == .bool(false) { throw GatewayError.message("The gateway did not complete the scheduled task action.") }
        return result
    }
}
