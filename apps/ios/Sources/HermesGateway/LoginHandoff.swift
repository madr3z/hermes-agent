import Foundation

/// UI-only authorization metadata. Never include this value in a model prompt or transcript.
public struct LoginHandoff: Identifiable, Sendable {
    public let id: String
    public let provider: String
    public let name: String
    public let status: String
    public let detail: String
    public let accountReference: String
    public let verifiedIdentity: String?
    public let scopes: [String]
    public let userCode: String
    public let authorizationURL: URL?
    public let verificationURL: URL?
    public let continued: Bool
    public init(_ row: JSON) {
        id = row["id"].string ?? ""
        provider = row["provider"].string ?? ""
        name = row["name"].string ?? ""
        status = row["status"].string ?? "failed"
        detail = row["detail"].string ?? ""
        accountReference = row["account_ref"].string ?? ""
        verifiedIdentity = row["verified_identity"].string
        scopes = row["scopes"].array.compactMap(\.string)
        userCode = row["user_code"].string ?? ""
        authorizationURL = Self.secureURL(row["auth_url"].string)
        let verification = row["verification_url"].string
        verificationURL = verification == "https://auth.openai.com/codex/device" ? URL(string: verification!) : nil
        continued = row["continued"].bool
    }
    private static func secureURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }
    public var canRetry: Bool { ["failed", "expired", "canceled"].contains(status) }
}
