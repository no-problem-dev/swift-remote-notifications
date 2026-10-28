import Foundation

/// What the app's server holds for this device: the account the token delivers to, and the
/// registration it was sent with.
public struct RegisteredDevice: Sendable, Equatable, Codable {
    /// The account passed to ``NotificationRegistration/signIn(account:)``.
    public var account: String
    /// The registration `send` accepted for that account.
    public var registration: DeviceRegistration

    public init(account: String, registration: DeviceRegistration) {
        self.account = account
        self.registration = registration
    }
}

/// Where the token, the signed-in account, what the server holds, and a token still to be
/// unregistered are kept between launches.
///
/// Keeping them is what lets every launch call ``NotificationRegistration/refresh()`` without
/// sending the same registration again, lets a device that has turned notifications off still
/// report the token it used to have, and lets a sign-out that did not reach the server be
/// finished later.
@MainActor
public protocol RegistrationStore: AnyObject {
    /// The last APNs token the system handed over, as lowercase hex.
    var token: String? { get set }
    /// The account signed in now, or `nil` when no one is.
    var account: String? { get set }
    /// What the server accepted last, and for whom.
    var registered: RegisteredDevice? { get set }
    /// A token the server has yet to be told no longer delivers to anyone.
    var tokenToUnregister: String? { get set }
}

/// Keeps the registration's state in `UserDefaults`.
public final class UserDefaultsRegistrationStore: RegistrationStore {

    private let defaults: UserDefaults
    private let prefix: String

    /// - Parameters:
    ///   - defaults: The defaults to keep them in. `.standard` unless an extension needs to read
    ///     them through an app group
    ///   - prefix: Put in front of each key
    public init(defaults: UserDefaults = .standard, prefix: String = "RemoteNotifications.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public var token: String? {
        get { defaults.string(forKey: prefix + "token") }
        set { defaults.set(newValue, forKey: prefix + "token") }
    }

    public var account: String? {
        get { defaults.string(forKey: prefix + "account") }
        set { defaults.set(newValue, forKey: prefix + "account") }
    }

    public var registered: RegisteredDevice? {
        get {
            defaults.data(forKey: prefix + "registered").flatMap { try? JSONDecoder().decode(RegisteredDevice.self, from: $0) }
        }
        set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: prefix + "registered")
        }
    }

    public var tokenToUnregister: String? {
        get { defaults.string(forKey: prefix + "tokenToUnregister") }
        set { defaults.set(newValue, forKey: prefix + "tokenToUnregister") }
    }
}

/// Keeps nothing past the process. Every launch sends its registration again.
public final class InMemoryRegistrationStore: RegistrationStore {
    public var token: String?
    public var account: String?
    public var registered: RegisteredDevice?
    public var tokenToUnregister: String?

    public init(
        token: String? = nil,
        account: String? = nil,
        registered: RegisteredDevice? = nil,
        tokenToUnregister: String? = nil
    ) {
        self.token = token
        self.account = account
        self.registered = registered
        self.tokenToUnregister = tokenToUnregister
    }
}
