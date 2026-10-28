# ``RemoteNotifications``

The device side of remote notifications: permission, the APNs device token, and taps — with
the server left to the app.

## Overview

The package never learns a URL. Where a registration goes and where an opened notification is
reported are closures the app passes in, so the same code serves any backend.

``NotificationRegistration`` keeps the server's view of the device current. Call
``NotificationRegistration/refresh()`` at every launch and every return to the foreground. When
the person allows notifications it asks the system for a token; when the token arrives through
the app delegate it builds a ``DeviceRegistration`` — the token, the ``APNsEnvironment`` it is
valid on, the time zone, the language, the app version and the ``NotificationAuthorization`` —
and hands it to `send`. A device that does not allow notifications is reported too, with the last
token it had, so the server can count who it cannot reach. A registration equal to the last one
accepted is not sent again.

``NotificationCenterDelegate`` is the `UNUserNotificationCenterDelegate`. It shows notifications
that arrive while the app is open, gives each opened notification to the app as a
``NotificationOpen`` with its `route`, and reports its `send_id`.

```swift
final class AppDelegate: NSObject, UIApplicationDelegate {
    let registration = NotificationRegistration { try await api.registerDevice($0) }
    let notifications = NotificationCenterDelegate(
        reportOpened: { try await api.reportOpened($0) },
        onOpen: { open in Router.shared.pendingRoute = open.route }
    )

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = notifications
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        registration.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        registration.didFailToRegisterForRemoteNotifications(error: error)
    }
}
```

### Apps that use Firebase

Firebase swizzles the app delegate by default and swallows
`application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`. Set
`FirebaseAppDelegateProxyEnabled` to `NO` in Info.plist, or the token never reaches
``NotificationRegistration``.

### Testing

The system is reached only through ``NotificationPermission``, ``RemoteNotificationRegistering``
and ``RegistrationStore``. Pass fakes of all three and the whole registration flow runs under
`swift test` on a Mac, with no simulator.

## Topics

### Registering the device

- ``NotificationRegistration``
- ``DeviceRegistration``
- ``DeviceContext``
- ``APNsEnvironment``
- ``RegistrationFailure``

### Permission

- ``NotificationAuthorization``
- ``NotificationPermission``
- ``SystemNotificationPermission``

### Opened notifications

- ``NotificationCenterDelegate``
- ``NotificationOpen``
- ``PayloadKeys``

### Keeping state between launches

- ``RegistrationStore``
- ``UserDefaultsRegistrationStore``
- ``InMemoryRegistrationStore``

### The system's side

- ``RemoteNotificationRegistering``
