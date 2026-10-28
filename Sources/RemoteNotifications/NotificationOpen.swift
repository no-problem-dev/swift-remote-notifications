import UserNotifications

/// The keys in a notification's payload that this package reads.
///
/// They sit at the top level of the APNs payload, beside `aps`:
///
/// ```json
/// {"aps":{"alert":{"title":"…","body":"…"}},"send_id":"snd_123","route":"items/42"}
/// ```
public struct PayloadKeys: Sendable, Equatable {
    /// The key whose value identifies this one delivery, reported back when it is opened.
    public var sendId: String
    /// The key whose value says where in the app to go.
    public var route: String

    public init(sendId: String, route: String) {
        self.sendId = sendId
        self.route = route
    }

    /// `send_id` and `route`.
    public static let standard = PayloadKeys(sendId: "send_id", route: "route")
}

/// A notification the person acted on: which delivery it was, where it points, and what they
/// tapped.
public struct NotificationOpen: Sendable, Equatable {

    /// The delivery's identifier, or `nil` when the payload has none (a notification not sent by
    /// your server, or one sent from a console by hand).
    public var sendId: String?

    /// Where in the app the notification points, or `nil` for "just open the app".
    public var route: String?

    /// `UNNotificationDefaultActionIdentifier` for a tap on the notification itself, or the
    /// identifier of the action button the person chose.
    public var actionIdentifier: String

    public init(sendId: String?, route: String?, actionIdentifier: String) {
        self.sendId = sendId
        self.route = route
        self.actionIdentifier = actionIdentifier
    }

    /// Reads ``sendId`` and ``route`` from a payload.
    ///
    /// A number is accepted for `send_id` and written in decimal. Empty strings and values of any
    /// other type read as absent.
    public init(userInfo: [AnyHashable: Any], actionIdentifier: String, keys: PayloadKeys = .standard) {
        self.sendId = Self.string(userInfo[keys.sendId])
        self.route = Self.string(userInfo[keys.route])
        self.actionIdentifier = actionIdentifier
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: string.isEmpty ? nil : string
        case let int as Int: String(int)
        default: nil
        }
    }
}
