import Foundation

public struct RoutineDetails: Identifiable, Equatable, Sendable {
    public let id: String
    public let profile: String
    public let name: String
    public let prompt: String
    public let schedule: String
    public let enabled: Bool
    public let state: String
    public let noAgent: Bool
    public let hasScript: Bool
    public let delivery: String
    public init(_ row: JSON, profile: String, id: String) throws {
        guard row["id"].string == id, row["profile"].string == profile else {
            throw GatewayError.message("The gateway did not confirm this task’s owner. Refresh this bot’s schedule.")
        }
        self.id = id; self.profile = profile
        name = row["name"].string ?? id
        guard let prompt = row["prompt"].string else { throw GatewayError.message("Full instructions are unavailable. Use your Mac to edit this task.") }
        self.prompt = prompt
        schedule = row["schedule_display"].string ?? row["schedule"]["display"].string ?? "Unknown schedule"
        enabled = row["enabled"] != .bool(false)
        state = row["state"].string ?? (enabled ? "scheduled" : "paused")
        noAgent = row["no_agent"].bool
        hasScript = !(row["script"].string ?? "").isEmpty
        delivery = row["deliver"].string ?? "local"
    }
    public var displayName: String {
        let tag = "[bot:\(profile)] "
        return name.hasPrefix(tag) ? String(name.dropFirst(tag.count)) : name
    }
}

public struct RoutineEditDraft: Equatable, Sendable {
    public var name: String
    public var instruction: String
    public var changeSchedule = false
    public var schedule = ""
    public init(_ job: RoutineDetails) { name = job.displayName; instruction = job.prompt }
    public mutating func rebase(from previous: RoutineDetails, to current: RoutineDetails) {
        if name == previous.displayName { name = current.displayName }
        if instruction == previous.prompt { instruction = current.prompt }
    }
    public func updates(original: RoutineDetails) throws -> [String: JSON] {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 100 else { throw GatewayError.message("Enter a task name up to 100 characters.") }
        var updates: [String: JSON] = [:]
        let tag = "[bot:\(original.profile)] "
        let savedName = original.name.hasPrefix(tag) ? tag + title : title
        if savedName != original.name { updates["name"] = .string(savedName) }
        if instruction != original.prompt { updates["prompt"] = .string(instruction) }
        if changeSchedule {
            let replacement = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !replacement.isEmpty else { throw GatewayError.message("Enter the replacement schedule or keep the existing schedule.") }
            updates["schedule"] = .string(replacement)
        }
        return updates
    }
}

public struct RoutineRun: Identifiable, Equatable, Sendable {
    public let profile: String
    public let jobID: String
    public let id: String
    public let title: String
    public let preview: String
    public let startedAt: Date?
    public let endedAt: Date?
    public let scriptOutput: Bool
    public let schedulerOwned: Bool
    public init(_ row: JSON, profile: String, jobID: String) throws {
        guard let id = row["id"].string, row["profile"].string == profile,
              (row["source"].string == "cron" && id.hasPrefix("cron_\(jobID)_") && String(id.dropFirst("cron_\(jobID)_".count)).range(of: "^[0-9]{8}_[0-9]{6}$", options: .regularExpression) != nil)
              || (row["source"].string == "cron_output" && id.hasPrefix("cron_output:\(jobID):")) else {
            throw GatewayError.message("The gateway returned history without this task’s exact owner.")
        }
        self.id = id; self.profile = profile; self.jobID = jobID
        title = row["title"].string ?? "Scheduled run"
        preview = row["preview"].string ?? ""
        startedAt = row["started_at"].number.map(Date.init(timeIntervalSince1970:))
        endedAt = row["ended_at"].number.map(Date.init(timeIntervalSince1970:))
        scriptOutput = row["source"].string == "cron_output"
        schedulerOwned = row["scheduler_owned"].bool
    }
}

public struct RoutineRunUnconfirmed: LocalizedError {
    public let errorDescription: String?
    public init(_ error: Error) { errorDescription = error.localizedDescription }
}

@MainActor public struct RoutineOperationsClient {
    public typealias HTTP = (String, String, JSON?, String, [URLQueryItem]) async throws -> JSON
    public let profile: String
    public let jobID: String
    private let http: HTTP
    public init(profile: String, jobID: String, http: @escaping HTTP) {
        self.profile = profile; self.jobID = jobID; self.http = http
    }
    public func details() async throws -> RoutineDetails {
        let result = try await call()
        return try RoutineDetails(result, profile: profile, id: jobID)
    }
    public func runs(limit: Int = 20) async throws -> [RoutineRun] {
        guard [20, 100].contains(limit) else { throw GatewayError.message("Choose the latest 20 or 100 runs.") }
        let result = try await call(suffix: "/runs", query: [URLQueryItem(name: "limit", value: String(limit))])
        guard case .array(let rows) = result["runs"] else { throw GatewayError.message("The gateway did not return task history.") }
        return try rows.map { try RoutineRun($0, profile: profile, jobID: jobID) }
    }
    public func update(_ draft: RoutineEditDraft, original: RoutineDetails) async throws -> JSON {
        guard original.id == jobID, original.profile == profile else { throw GatewayError.message("This edit belongs to another bot’s task.") }
        let updates = try draft.updates(original: original)
        guard !updates.isEmpty else { throw GatewayError.message("No task settings changed.") }
        let current = try await details()
        guard current == original else { throw GatewayError.message("This task changed on the gateway. Refresh it and review your edit again. Your draft is kept.") }
        return try await call(method: "PUT", body: .object(["updates": .object(updates)]))
    }
    public func runNow(reviewed: RoutineDetails) async throws -> JSON {
        guard reviewed.id == jobID, reviewed.profile == profile else { throw GatewayError.message("This run request belongs to another bot’s task.") }
        guard try await details() == reviewed else { throw GatewayError.message("This task changed after review. Refresh it before running.") }
        do { return try await call(suffix: "/trigger", method: "POST", body: .object([:])) }
        catch { throw RoutineRunUnconfirmed(error) }
    }
    public func messages(run: RoutineRun, offset: Int = 0) async throws -> SavedChatPage {
        guard run.profile == profile, run.jobID == jobID, !run.scriptOutput, run.id.hasPrefix("cron_\(jobID)_") else { throw GatewayError.message("This record has an output preview only, not a saved agent transcript.") }
        let reader = SavedChatsClient(profile: profile) { path, owner, query in
            try await http(path, owner, nil, "GET", query)
        }
        return try await reader.messages(id: run.id, offset: offset)
    }
    private func call(suffix: String = "", method: String = "GET", body: JSON? = nil, query: [URLQueryItem] = []) async throws -> JSON {
        guard jobID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw GatewayError.message("This task has an invalid route ID.")
        }
        let result = try await http("api/cron/jobs/\(jobID)" + suffix, profile, body, method, [URLQueryItem(name: "strict_profile", value: "true")] + query)
        guard result["profile"].string == profile else {
            throw GatewayError.message("Exact task ownership is unavailable through this gateway. Update the controller and bot runtime before using these controls.")
        }
        return result
    }
}
