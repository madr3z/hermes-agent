import Foundation

public struct ChatClarifyQuestion: Identifiable, Equatable {
    public let id: String
    public let text: String
    public let choices: [String]
    public let multiSelect: Bool
    public func answer(picks: Set<String>, text: String) -> String? {
        let written = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = choices.filter { picks.contains($0) }
        if multiSelect {
            let values = selected + (written.isEmpty ? [] : [written])
            guard !values.isEmpty, let data = try? JSONEncoder().encode(values) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        return !written.isEmpty ? written : selected.first
    }
    public func displayAnswer(_ value: String) -> String {
        if multiSelect, let values = try? JSONDecoder().decode([String].self, from: Data(value.utf8)) { return values.joined(separator: ", ") }
        return value
    }
}

public struct ChatHumanRequest: Identifiable, Equatable {
    public enum Kind: Equatable {
        case approval(queueID: String, command: String, description: String, choices: [String])
        case clarify(questions: [ChatClarifyQuestion], answers: [String: JSON])
    }
    public let id: String
    public let sessionID: String
    public var kind: Kind
    public init?(_ frame: JSON, runtimeID: String) {
        let params = frame["params"]
        guard let id = frame["id"].string, !id.isEmpty,
              params["session_id"].string == runtimeID, !runtimeID.isEmpty else { return nil }
        self.id = id; sessionID = runtimeID
        switch frame["method"].string {
        case "approval":
            guard let queueID = params["request_id"].string, !queueID.isEmpty else { return nil }
            let choices = params["choices"].array.compactMap(\.string).filter {
                ["once", "session", "always", "deny"].contains($0)
                && ($0 != "session" || params["allow_session"] != .bool(false))
                && ($0 != "always" || params["allow_permanent"] != .bool(false))
            }
            guard !choices.isEmpty else { return nil }
            kind = .approval(queueID: queueID, command: params["command"].string ?? "", description: params["description"].string ?? "", choices: Array(Set(choices)).sorted { Self.order($0) < Self.order($1) })
        case "clarify":
            let rows = params["questions"].array
            let questions = rows.compactMap { row -> ChatClarifyQuestion? in
                guard let qid = row["qid"].string, !qid.isEmpty, let question = row["question"].string, !question.isEmpty else { return nil }
                return ChatClarifyQuestion(id: qid, text: question, choices: row["choices"].array.compactMap(\.string), multiSelect: row["multi_select"].bool)
            }
            guard !questions.isEmpty, questions.count <= 5, questions.count == rows.count, Set(questions.map(\.id)).count == questions.count else { return nil }
            let answers: [String: JSON]
            if case .object(let values) = params["answers"] { answers = values.filter { key, value in questions.contains { $0.id == key } && (value.string != nil || value == .null) } }
            else { answers = [:] }
            kind = .clarify(questions: questions, answers: answers)
        default: return nil
        }
    }
    private static func order(_ choice: String) -> Int { ["once": 0, "session": 1, "always": 2, "deny": 3][choice] ?? 4 }
    public static func choiceLabel(_ choice: String) -> String {
        ["once": "Allow once", "session": "Allow for this chat", "always": "Always allow this command", "deny": "Deny"][choice] ?? choice
    }
}

@MainActor public struct ChatRequestsClient {
    public typealias Request = (String, [String: JSON]) async throws -> JSON
    public let profile: String
    public let sessionID: String
    private let request: Request
    public init(profile: String, sessionID: String, request: @escaping Request) {
        self.profile = profile; self.sessionID = sessionID; self.request = request
    }
    public func answer(_ item: ChatHumanRequest, choice: String? = nil, cancel: Bool = false) async throws -> Bool {
        guard item.sessionID == sessionID else { throw GatewayError.message("This request belongs to a different chat.") }
        var result: [String: JSON] = [:]
        switch item.kind {
        case .approval(_, _, _, let choices):
            guard let choice, choices.contains(choice), !cancel else { throw GatewayError.message("Choose one of this request’s offered actions.") }
            result["choice"] = .string(choice)
        case .clarify:
            guard cancel else { throw GatewayError.message("Submit or skip each question explicitly.") }
        }
        let reply = try await request("request.answer", params(["id": .string(item.id), "result": .object(result)]))
        return try accepted(reply)
    }
    public func lock(_ item: ChatHumanRequest, questionID: String, answer: String?) async throws -> (active: Bool, remaining: [String]) {
        guard item.sessionID == sessionID, case .clarify(let questions, _) = item.kind, questions.contains(where: { $0.id == questionID }) else {
            throw GatewayError.message("This question does not belong to the current chat request.")
        }
        let reply = try await request("clarify.lock", params(["request_id": .string(item.id), "question_id": .string(questionID), "answer": answer.map(JSON.string) ?? .null]))
        return (try accepted(reply), reply["remaining"].array.compactMap(\.string))
    }
    public func received(_ item: ChatHumanRequest) async throws {
        guard item.sessionID == sessionID, case .approval(let queueID, _, _, _) = item.kind else { return }
        _ = try await request("approval.received", params(["request_id": .string(queueID)]))
    }
    private func params(_ extra: [String: JSON]) -> [String: JSON] {
        ["profile": .string(profile), "session_id": .string(sessionID)].merging(extra) { _, value in value }
    }
    private func accepted(_ reply: JSON) throws -> Bool {
        switch reply["status"].string {
        case "ok": return true
        case "expired": return false
        default: throw GatewayError.message("The gateway did not confirm this answer. Refresh before trying again.")
        }
    }
}
