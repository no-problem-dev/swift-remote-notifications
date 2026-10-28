import UserNotifications

/// Whether this app may show notifications, as the system answers it.
///
/// Every state is worth reporting, not only the ones that can receive an alert: a server that
/// hears about `denied` and `notDetermined` devices can count how many people a notification
/// could reach and how many it could not.
///
/// The raw values are the strings a ``DeviceRegistration`` is encoded with.
public enum NotificationAuthorization: String, Sendable, Codable, CaseIterable {
    /// The person has not been asked yet.
    case notDetermined = "not_determined"
    /// The person said no, or turned notifications off in Settings.
    case denied
    /// The person said yes.
    case authorized
    /// Notifications are delivered quietly to Notification Center without having asked.
    case provisional
    /// An App Clip's temporary permission.
    case ephemeral

    /// Whether a device in this state is worth registering with APNs for alerts.
    ///
    /// `provisional` and `ephemeral` count: their notifications are delivered, only quietly or
    /// for a limited time.
    public var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: true
        case .notDetermined, .denied: false
        }
    }

    /// The state the system reports as `status`.
    ///
    /// A status added to the SDK after this package was written reads as `denied`: a device
    /// that cannot be shown to deliver is not counted as reachable.
    public init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized: self = .authorized
        case .provisional: self = .provisional
        #if os(iOS)
        case .ephemeral: self = .ephemeral
        #endif
        @unknown default: self = .denied
        }
    }
}
