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
    public let canPostpone: Bool
    public let messageID: String?
    public init(_ value: JSON, push: MobilePush, allowedGuests: Set<UUID>, now: Date = Date(), accepting: Bool = false, readingNotification: Bool = false) throws {
        guard value["invitation_id"].string.flatMap(UUID.init(uuidString:)) == push.invitationID,
              let guest = value["guest_id"].string.flatMap(UUID.init(uuidString:)), allowedGuests.contains(guest),
              value["profile"].string == "default", let kind = value["kind"].string,
              ["call", "notification"].contains(kind),
              let expiry = value["expires_at"].number, expiry.isFinite,
              abs(expiry - push.expiresAt.timeIntervalSince1970) < 1,
              let state = value["state"].string,
              readingNotification ? kind == "notification" && ["pending", "expired"].contains(state)
                : push.isCurrent(at: now) && (accepting ? state == "accepted" && kind == "call" : state == "pending") else {
            throw GatewayError.message("This invitation expired, was answered, or no longer belongs to an enabled bot.")
        }
        canPostpone = value["can_postpone"].bool
        id = push.invitationID; guestID = guest; self.kind = kind; self.state = state; profile = "default"
        name = String((value["name"].string ?? "Hermes").prefix(100))
        reason = String((value["reason"].string ?? "").prefix(500))
        messageID = kind == "notification" ? value["message_id"].string : nil
    }
}

/// Server-owned reschedule. It is bound to a saved controller and an allowed bot.
public struct MobileDeferredCall: Identifiable {
    public let id: UUID
    public let controllerID: UUID
    public let guestID: UUID
    public let name: String
    public let scheduledAt: Date
    public init(_ value: JSON, controllerID: UUID, allowedGuests: Set<UUID>) throws {
        guard let id = value["invitation_id"].string.flatMap(UUID.init(uuidString:)),
              let guest = value["guest_id"].string.flatMap(UUID.init(uuidString:)), allowedGuests.contains(guest),
              value["profile"].string == "default", value["kind"].string == "call",
              value["state"].string == "postponed", value["deferred_state"].string == "scheduled",
              let due = value["scheduled_at"].number, due.isFinite else {
            throw GatewayError.message("This call is no longer scheduled.")
        }
        self.id = id; self.controllerID = controllerID; guestID = guest
        name = String((value["name"].string ?? "Hermes").prefix(100))
        scheduledAt = Date(timeIntervalSince1970: due)
    }
    public static func validateTime(_ date: Date, now: Date = Date()) throws {
        guard date.timeIntervalSince1970.isFinite, date >= now.addingTimeInterval(60), date <= now.addingTimeInterval(7 * 86400) else {
            throw GatewayError.message("Choose a time from one minute to seven days from now.")
        }
    }
}
