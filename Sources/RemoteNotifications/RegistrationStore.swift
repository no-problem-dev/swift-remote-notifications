import Foundation

/// Where the last device token and the last registration the server accepted are kept between
/// launches.
///
/// Keeping them is what lets every launch call ``NotificationRegistration/refresh()`` without
/// sending the same registration again, and lets a device that has turned notifications off
/// still report the token it used to have.
@MainActor
public protocol RegistrationStore: AnyObject {
    /// The last APNs token the system handed over, as lowercase hex.
    var token: String? { get set }
    /// The last registration `send` returned from without throwing.
    var lastSent: DeviceRegistration? { get set }
}

/// Keeps the token and the last registration in `UserDefaults`.
public final class UserDefaultsRegistrationStore: RegistrationStore {

    private let defaults: UserDefaults
    private let tokenKey: String
    private let lastSentKey: String

    /// - Parameters:
    ///   - defaults: The defaults to keep them in. `.standard` unless an extension needs to read
    ///     them through an app group
    ///   - prefix: Put in front of the two keys
    public init(defaults: UserDefaults = .standard, prefix: String = "RemoteNotifications.") {
        self.defaults = defaults
        self.tokenKey = prefix + "token"
        self.lastSentKey = prefix + "lastSent"
    }

    public var token: String? {
        get { defaults.string(forKey: tokenKey) }
        set { defaults.set(newValue, forKey: tokenKey) }
    }

    public var lastSent: DeviceRegistration? {
        get {
            defaults.data(forKey: lastSentKey).flatMap { try? JSONDecoder().decode(DeviceRegistration.self, from: $0) }
        }
        set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: lastSentKey)
        }
    }
}

/// Keeps nothing past the process. Every launch sends its registration again.
public final class InMemoryRegistrationStore: RegistrationStore {
    public var token: String?
    public var lastSent: DeviceRegistration?

    public init(token: String? = nil, lastSent: DeviceRegistration? = nil) {
        self.token = token
        self.lastSent = lastSent
    }
}
