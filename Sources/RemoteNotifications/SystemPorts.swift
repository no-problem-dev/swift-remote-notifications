import UserNotifications
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Reads and asks for the notification permission.
///
/// ``SystemNotificationPermission`` is the real one. Tests and previews pass their own.
public protocol NotificationPermission: Sendable {
    /// The permission as it stands now.
    func authorization() async -> NotificationAuthorization
    /// Shows the system prompt if the person has not answered yet, and reports whether the
    /// permission was granted.
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
}

/// The permission held by `UNUserNotificationCenter.current()`.
public struct SystemNotificationPermission: NotificationPermission {

    public init() {}

    public func authorization() async -> NotificationAuthorization {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return NotificationAuthorization(status)
    }

    public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }
}

/// Asks the system for an APNs device token.
///
/// The token arrives later, in the app delegate's
/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`, which the app forwards to
/// ``NotificationRegistration/didRegisterForRemoteNotifications(deviceToken:)``.
/// `UIApplication` and `NSApplication` conform.
@MainActor
public protocol RemoteNotificationRegistering: AnyObject {
    func registerForRemoteNotifications()
}

#if canImport(UIKit)
extension UIApplication: RemoteNotificationRegistering {}
#elseif canImport(AppKit)
extension NSApplication: RemoteNotificationRegistering {}
#endif

extension NotificationRegistration {
    /// `UIApplication.shared`, or `NSApplication.shared` on macOS.
    static var systemApplication: any RemoteNotificationRegistering {
        #if canImport(UIKit)
        UIApplication.shared
        #elseif canImport(AppKit)
        NSApplication.shared
        #endif
    }
}
