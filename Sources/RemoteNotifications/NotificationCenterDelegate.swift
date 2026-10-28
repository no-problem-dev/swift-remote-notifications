import UserNotifications

/// A `UNUserNotificationCenterDelegate` that shows notifications while the app is open, hands
/// taps to the app, and reports each opened delivery.
///
/// Set it as the center's delegate **before `application(_:didFinishLaunchingWithOptions:)`
/// returns**, or the tap that launched the app is never delivered. The center holds its delegate
/// weakly, so keep a reference:
///
/// ```swift
/// let notifications = NotificationCenterDelegate(
///     reportOpened: { sendId in try await api.reportOpened(sendId) },
///     onOpen: { open in router.pendingRoute = open.route }
/// )
/// UNUserNotificationCenter.current().delegate = notifications
/// ```
///
/// When a notification is opened, `onOpen` is called first, on the main actor, and then
/// `reportOpened` with the payload's `send_id` if it has one. A dismissal
/// (`UNNotificationDismissActionIdentifier`) is neither.
///
/// A tap can launch the app before any view exists. Have `onOpen` store the route somewhere a
/// view reads when it appears rather than navigate directly.
public final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {

    private let keys: PayloadKeys
    private let foregroundPresentation: UNNotificationPresentationOptions
    private let reportOpened: @Sendable (String) async throws -> Void
    private let onOpen: @MainActor @Sendable (NotificationOpen) -> Void
    private let onFailure: @MainActor @Sendable (any Error) -> Void

    /// - Parameters:
    ///   - foregroundPresentation: How a notification that arrives while the app is in the
    ///     foreground is shown. Pass `[]` to show nothing
    ///   - keys: Where `send_id` and `route` are in the payload
    ///   - reportOpened: Tells the app's server a delivery was opened
    ///   - onFailure: Told when `reportOpened` throws. Nothing is retried here
    ///   - onOpen: Receives each opened notification, including its route
    public init(
        foregroundPresentation: UNNotificationPresentationOptions = [.banner, .list, .sound],
        keys: PayloadKeys = .standard,
        reportOpened: @escaping @Sendable (String) async throws -> Void,
        onFailure: @escaping @MainActor @Sendable (any Error) -> Void = { _ in },
        onOpen: @escaping @MainActor @Sendable (NotificationOpen) -> Void
    ) {
        self.foregroundPresentation = foregroundPresentation
        self.keys = keys
        self.reportOpened = reportOpened
        self.onFailure = onFailure
        self.onOpen = onOpen
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(foregroundPresentation)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let open = NotificationOpen(
            userInfo: response.notification.request.content.userInfo,
            actionIdentifier: response.actionIdentifier,
            keys: keys
        )
        let completion = Completion(completionHandler)
        Task { @MainActor in
            guard let sendId = deliver(open) else { return completion() }
            completion()
            await report(sendId)
        }
    }

    /// Hands an open to the app, and returns the delivery to report, if any.
    @MainActor
    func deliver(_ open: NotificationOpen) -> String? {
        guard open.actionIdentifier != UNNotificationDismissActionIdentifier else { return nil }
        onOpen(open)
        return open.sendId
    }

    @MainActor
    func report(_ sendId: String) async {
        do {
            try await reportOpened(sendId)
        } catch {
            onFailure(error)
        }
    }

    @MainActor
    func receive(_ open: NotificationOpen) async {
        guard let sendId = deliver(open) else { return }
        await report(sendId)
    }
}

/// The system's completion handler, carried to the main actor.
///
/// UserNotifications does not mark it `@Sendable`, but it is documented as callable from any
/// thread, and it is called exactly once.
private struct Completion: @unchecked Sendable {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    func callAsFunction() { body() }
}
