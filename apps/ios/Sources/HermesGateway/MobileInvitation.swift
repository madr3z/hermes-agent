import Foundation

/// A push identifies a local controller. It cannot supply a URL or a bot identity.
public struct MobilePush: Equatable {
    public let controllerID: UUID
    public let invitationID: UUID
    public let expiresAt: Date
    public init(_ value: JSON) throws {
        guard let controller = value["controller_id"].string.flatMap(UUID.init(uuidString:)),
              let invitation = value["invitation_id"].string.flatMap(UUID.init(uuidString:)),
              let expiry = value["expires_at"].number, expiry.isFinite else {
            throw GatewayError.message("Invalid Hermes invitation.")
        }
        controllerID = controller; invitationID = invitation; expiresAt = Date(timeIntervalSince1970: expiry)
    }
    public func isCurrent(at now: Date = Date()) -> Bool { expiresAt > now && expiresAt.timeIntervalSince(now) <= 3600 }
}

public struct MobileInvitation {
    public let id: UUID
    public let guestID: UUID
    public let name: String
    public let reason: String
    public let state: String
    public let kind: String
    public let profile: String
    public init(_ value: JSON, push: MobilePush, allowedGuests: Set<UUID>, now: Date = Date(), accepting: Bool = false) throws {
        guard value["invitation_id"].string.flatMap(UUID.init(uuidString:)) == push.invitationID,
              let guest = value["guest_id"].string.flatMap(UUID.init(uuidString:)), allowedGuests.contains(guest),
              value["profile"].string == "default", let kind = value["kind"].string,
              ["call", "notification"].contains(kind),
              let expiry = value["expires_at"].number, expiry.isFinite,
              abs(expiry - push.expiresAt.timeIntervalSince1970) < 1,
              push.isCurrent(at: now),
              let state = value["state"].string,
              accepting ? state == "accepted" && kind == "call" : state == "pending" else {
            throw GatewayError.message("This invitation expired, was answered, or no longer belongs to an enabled bot.")
        }
        id = push.invitationID; guestID = guest; self.kind = kind; self.state = state; profile = "default"
        name = String((value["name"].string ?? "Hermes").prefix(100))
        reason = String((value["reason"].string ?? "").prefix(500))
    }
}
