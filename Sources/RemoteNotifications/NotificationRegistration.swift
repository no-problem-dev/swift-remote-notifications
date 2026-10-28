import Foundation
import UserNotifications

/// Something that went wrong while keeping the registration current.
///
/// None is retried here. The next ``NotificationRegistration/refresh()`` — at the next launch
/// or the next time the app comes to the foreground — tries again from the start.
public enum RegistrationFailure: Error {
    /// The system could not get a token from APNs. Common on a simulator without a signed-in
    /// account, or when the app lacks the Push Notifications capability.
    case apns(any Error)
    /// The app's `send` closure threw. The registration is sent again on the next refresh.
    case send(any Error)
    /// The app's `unregister` closure threw. The token is unregistered again on the next refresh,
    /// unless someone registers it first.
    case unregister(any Error)
}

/// This device's registration for remote notifications: the permission, the APNs token, the
/// account the token delivers to, and telling the app's server about all three.
///
/// It knows nothing about the server. The app passes `send`, which receives a
/// ``DeviceRegistration`` and delivers it for the signed-in account, and `unregister`, which tells
/// the server a token no longer belongs to anyone:
///
/// ```swift
/// let registration = NotificationRegistration(
///     send: { registration in try await api.registerDevice(registration) },
///     unregister: { token in try await api.unregisterDevice(token: token) }
/// )
///
/// // Once the session is known — at every launch, and after each sign-in or account switch
/// await registration.signIn(account: user.id)
///
/// // At launch and each time the app comes to the foreground
/// await registration.refresh()
///
/// // Before ending the session
/// await registration.signOut()
///
/// // From the app delegate
/// registration.didRegisterForRemoteNotifications(deviceToken: deviceToken)
/// registration.didFailToRegisterForRemoteNotifications(error: error)
/// ```
///
/// ## The token and the account
///
/// An APNs token belongs to the app's installation, not to whoever is signed in. When a second
/// account signs in on the same device the token does not change, so the server only learns of
/// the switch if it is told. The registration therefore keeps the account it last registered the
/// token for, and treats a different account as a change:
///
/// - ``signIn(account:)`` with a different account sends the registration again, so the server
///   moves the token to that account. With the same account — an anonymous account linked to
///   Apple or Google keeps its id — nothing is sent
/// - ``signOut()`` asks the server to drop the token, so the device stops receiving the previous
///   account's notifications even if no one signs in after. If `unregister` throws, the token is
///   kept and unregistered on the next refresh. Call it **before** ending the session, while the
///   app can still authenticate the request
/// - ``forgetAccount()`` is for after the server has deleted the account and its devices: the
///   registration forgets what it sent, without a request
///
/// Until the app calls ``signIn(account:)``, nothing is registered.
///
/// ## What a refresh does
///
/// - When the person allows notifications (``NotificationAuthorization/allowsDelivery``), it asks
///   the system for a token. The token comes back through the app delegate, and the
///   registration is sent with it
/// - When they do not, it sends the registration straight away with the last token the device
///   had (or none), so the server can count devices it cannot reach
/// - **A registration equal to the last one `send` accepted for the same account is not sent
///   again.** Calling `refresh()` on every launch and every return to the foreground costs one
///   permission read and nothing on the network unless the account, the token, the permission,
///   the time zone, the language, the app version or the environment has changed
/// - A token left over from a ``signOut()`` that did not reach the server is unregistered first
/// - Requests never overlap. A change that arrives while one is in flight is sent after it, and
///   only the newest state is sent
@MainActor
public final class NotificationRegistration {

    private let permission: any NotificationPermission
    private let application: any RemoteNotificationRegistering
    private let store: any RegistrationStore
    private let environment: APNsEnvironment
    private let context: @Sendable () -> DeviceContext
    private let send: @Sendable (DeviceRegistration) async throws -> Void
    private let unregister: @Sendable (String) async throws -> Void
    private let onFailure: @MainActor (RegistrationFailure) -> Void

    /// The newest state of the device, built by the last refresh or token.
    private var device: DeviceRegistration?
    private var isSyncing = false
    private var syncAgain = false

    /// - Parameters:
    ///   - environment: The APNs gateway the token belongs to. ``APNsEnvironment/current``
    ///     follows the build configuration
    ///   - store: Where the token, the account and what the server holds are kept between
    ///     launches
    ///   - context: The time zone, language and app version, read each time a registration is
    ///     built
    ///   - permission: Reads and asks for the permission. The system's by default
    ///   - application: Asks for the token. `UIApplication.shared` by default
    ///   - onFailure: Told when the system gives no token, or `send` or `unregister` throws
    ///   - send: Delivers a registration to the app's server, for the account signed in now.
    ///     Throw when it did not arrive, and the same registration is sent again on the next
    ///     refresh
    ///   - unregister: Tells the app's server that this token (lowercase hex) no longer delivers
    ///     to anyone. Throw when it did not arrive, and it is tried again on the next refresh
    public init(
        environment: APNsEnvironment = .current,
        store: any RegistrationStore = UserDefaultsRegistrationStore(),
        context: @escaping @Sendable () -> DeviceContext = { .current },
        permission: any NotificationPermission = SystemNotificationPermission(),
        application: (any RemoteNotificationRegistering)? = nil,
        onFailure: @escaping @MainActor (RegistrationFailure) -> Void = { _ in },
        send: @escaping @Sendable (DeviceRegistration) async throws -> Void,
        unregister: @escaping @Sendable (String) async throws -> Void
    ) {
        self.environment = environment
        self.store = store
        self.context = context
        self.permission = permission
        self.application = application ?? Self.systemApplication
        self.onFailure = onFailure
        self.send = send
        self.unregister = unregister
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

    // MARK: - Account

    /// The account this device's notifications are delivered to, or `nil` when no one is signed
    /// in.
    public var account: String? { store.account }

    /// Says who is signed in, and refreshes the registration for them.
    ///
    /// Call it whenever the session is known: at every launch once the app has its user, after a
    /// sign-in, and after switching accounts. A different account than the one the token was
    /// last registered for is sent again even though the token is the same — the server moves
    /// the token to the new account. The same account sends nothing.
    ///
    /// - Parameter account: An identifier the app's server recognises for this person, such as
    ///   the user id. It is kept on the device and compared, never sent by this package
    /// - Returns: The permission it found
    @discardableResult
    public func signIn(account: String) async -> NotificationAuthorization {
        store.account = account
        return await refresh()
    }

    /// Stops this device receiving the signed-in account's notifications.
    ///
    /// Call it before ending the session, while the app can still authenticate `unregister`.
    /// Nothing is registered again until the next ``signIn(account:)``. If `unregister` throws,
    /// the token is unregistered on the next refresh — or moved by the next sign-in, whichever
    /// comes first.
    public func signOut() async {
        if let token = store.registered?.registration.token ?? store.token {
            store.tokenToUnregister = token
        }
        store.account = nil
        store.registered = nil
        await sync()
    }

    /// Forgets the account without telling the server.
    ///
    /// For after the app's server has deleted the account and the devices with it. Nothing is
    /// registered again until the next ``signIn(account:)``.
    public func forgetAccount() {
        store.account = nil
        store.registered = nil
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
        }
        // A device that has never had a token waits for the one just asked for. Otherwise the
        // token it has is sent now — after a sign-in it would not change, so waiting for the
        // system to hand it over again would leave the server on the previous account.
        if authorization.allowsDelivery, store.token == nil {
            await sync()
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
        device = DeviceRegistration(
            token: token,
            apnsEnvironment: environment,
            timeZone: context.timeZone,
            locale: context.locale,
            appVersion: context.appVersion,
            authorization: authorization
        )
        await sync()
    }

    /// Brings the server in line with the store and ``device``, one request at a time. A call
    /// that arrives while one is running makes it go round once more.
    private func sync() async {
        guard !isSyncing else {
            syncAgain = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            syncAgain = false
            await unregisterLeftover()
            await registerIfChanged()
        } while syncAgain
    }

    private func unregisterLeftover() async {
        guard let token = store.tokenToUnregister else { return }
        do {
            try await unregister(token)
            if store.tokenToUnregister == token { store.tokenToUnregister = nil }
        } catch {
            onFailure(.unregister(error))
        }
    }

    private func registerIfChanged() async {
        guard let account = store.account, let device else { return }
        let next = RegisteredDevice(account: account, registration: device)
        guard next != store.registered else { return }
        do {
            try await send(device)
        } catch {
            onFailure(.send(error))
            return
        }
        // Signed out or switched while the request was in flight: what the server holds is no
        // longer what the store should remember.
        guard store.account == account else { return }
        store.registered = next
        if store.tokenToUnregister == device.token { store.tokenToUnregister = nil }
    }
}
