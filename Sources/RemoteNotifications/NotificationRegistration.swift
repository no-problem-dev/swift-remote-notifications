import Foundation
import UserNotifications

/// Something that went wrong while keeping the registration current.
///
/// Neither is retried here. The next ``NotificationRegistration/refresh()`` — at the next launch
/// or the next time the app comes to the foreground — tries again from the start.
public enum RegistrationFailure: Error {
    /// The system could not get a token from APNs. Common on a simulator without a signed-in
    /// account, or when the app lacks the Push Notifications capability.
    case apns(any Error)
    /// The app's `send` closure threw. The registration is sent again on the next refresh.
    case send(any Error)
}

/// This device's registration for remote notifications: the permission, the APNs token, and
/// telling the app's server about both.
///
/// It knows nothing about the server. The app passes `send`, which receives a
/// ``DeviceRegistration`` and delivers it wherever the app's backend expects it:
///
/// ```swift
/// let registration = NotificationRegistration { registration in
///     try await api.registerDevice(registration)
/// }
///
/// // At launch and each time the app comes to the foreground
/// await registration.refresh()
///
/// // From the app delegate
/// registration.didRegisterForRemoteNotifications(deviceToken: deviceToken)
/// registration.didFailToRegisterForRemoteNotifications(error: error)
/// ```
///
/// ## What a refresh does
///
/// - When the person allows notifications (``NotificationAuthorization/allowsDelivery``), it asks
///   the system for a token. The token comes back through the app delegate, and the
///   registration is sent with it
/// - When they do not, it sends the registration straight away with the last token the device
///   had (or none), so the server can count devices it cannot reach
/// - **A registration equal to the last one `send` accepted is not sent again.** Calling
///   `refresh()` on every launch and every return to the foreground costs one permission read
///   and nothing on the network unless the token, the permission, the time zone, the language,
///   the app version or the environment has changed
/// - Sends never overlap. A change that arrives while one is in flight is sent after it, and
///   only the newest state is sent
@MainActor
public final class NotificationRegistration {

    private let permission: any NotificationPermission
    private let application: any RemoteNotificationRegistering
    private let store: any RegistrationStore
    private let environment: APNsEnvironment
    private let context: @Sendable () -> DeviceContext
    private let send: @Sendable (DeviceRegistration) async throws -> Void
    private let onFailure: @MainActor (RegistrationFailure) -> Void

    private var pending: DeviceRegistration?
    private var isSending = false

    /// - Parameters:
    ///   - environment: The APNs gateway the token belongs to. ``APNsEnvironment/current``
    ///     follows the build configuration
    ///   - store: Where the token and the last accepted registration are kept between launches
    ///   - context: The time zone, language and app version, read each time a registration is
    ///     built
    ///   - permission: Reads and asks for the permission. The system's by default
    ///   - application: Asks for the token. `UIApplication.shared` by default
    ///   - onFailure: Told when the system gives no token or `send` throws
    ///   - send: Delivers a registration to the app's server. Throw when it did not arrive, and
    ///     the same registration is sent again on the next refresh
    public init(
        environment: APNsEnvironment = .current,
        store: any RegistrationStore = UserDefaultsRegistrationStore(),
        context: @escaping @Sendable () -> DeviceContext = { .current },
        permission: any NotificationPermission = SystemNotificationPermission(),
        application: (any RemoteNotificationRegistering)? = nil,
        onFailure: @escaping @MainActor (RegistrationFailure) -> Void = { _ in },
        send: @escaping @Sendable (DeviceRegistration) async throws -> Void
    ) {
        self.environment = environment
        self.store = store
        self.context = context
        self.permission = permission
        self.application = application ?? Self.systemApplication
        self.onFailure = onFailure
        self.send = send
    }

    // MARK: - Permission

    /// The permission as it stands now.
    public func authorization() async -> NotificationAuthorization {
        await permission.authorization()
    }

    /// Asks the person for permission, then refreshes the registration with the answer.
    ///
    /// - Parameters:
    ///   - options: What notifications may do once allowed
    ///   - provisional: Deliver quietly to Notification Center without showing a prompt. The
    ///     person decides from the first notification whether to keep them
    /// - Returns: The permission after the request
    @discardableResult
    public func requestAuthorization(
        options: UNAuthorizationOptions = [.alert, .badge, .sound],
        provisional: Bool = false
    ) async throws -> NotificationAuthorization {
        _ = try await permission.requestAuthorization(options: provisional ? options.union(.provisional) : options)
        return await refresh()
    }

    // MARK: - Registration

    /// Brings the server's view of this device up to date. Call it at every launch and every
    /// time the app comes to the foreground — the permission may have changed in Settings.
    ///
    /// - Returns: The permission it found
    @discardableResult
    public func refresh() async -> NotificationAuthorization {
        let authorization = await permission.authorization()
        if authorization.allowsDelivery {
            application.registerForRemoteNotifications()
        } else {
            await submit(token: store.token, authorization: authorization)
        }
        return authorization
    }

    /// Forward `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` here.
    public func didRegisterForRemoteNotifications(deviceToken: Data) {
        Task { await receive(deviceToken: deviceToken) }
    }

    /// Forward `application(_:didFailToRegisterForRemoteNotificationsWithError:)` here.
    public func didFailToRegisterForRemoteNotifications(error: any Error) {
        onFailure(.apns(error))
    }

    func receive(deviceToken: Data) async {
        let token = deviceToken.lowercaseHex
        store.token = token
        await submit(token: token, authorization: await permission.authorization())
    }

    func submit(token: String?, authorization: NotificationAuthorization) async {
        let context = context()
        pending = DeviceRegistration(
            token: token,
            apnsEnvironment: environment,
            timeZone: context.timeZone,
            locale: context.locale,
            appVersion: context.appVersion,
            authorization: authorization
        )
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }

        while let next = pending {
            pending = nil
            guard next != store.lastSent else { continue }
            do {
                try await send(next)
                store.lastSent = next
            } catch {
                onFailure(.send(error))
            }
        }
    }
}
