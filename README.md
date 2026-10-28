# RemoteNotifications

The device side of remote notifications — permission, the APNs device token, and taps — with
the server left to the app.

![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017.0%2B%20%7C%20macOS%2014.0%2B-blue.svg)
![SPM](https://img.shields.io/badge/SPM-compatible-green.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

English | [日本語](./README.ja.md)

## Overview

The package never learns a URL. Where a registration goes and where an opened notification is
reported are closures the app passes in, so the same code serves any backend.

- Reads and asks for the permission, provisional included
- On every launch, gets the device token and reports it with the APNs environment, time zone,
  language, app version and permission
- Reports devices that do not allow notifications as well, so the server can count reach
- Knows which account the token is registered for: a sign-in to another account sends the same
  token again so the server moves it, and a sign-out tells the server to drop it
- Sends nothing when nothing has changed since the last registration the server accepted
- On a tap, hands the payload's `route` to the app and reports its `send_id`
- Foreground presentation is a parameter
- Swift 6 strict concurrency; the decision logic runs under `swift test` on a Mac with fakes

## Usage

### Registering the device

```swift
import RemoteNotifications

let registration = NotificationRegistration(
    send: { registration in try await api.registerDevice(registration) },  // your server, your request
    unregister: { token in try await api.unregisterDevice(token: token) }
)

// Once the session is known: at every launch, and after each sign-in or account switch
await registration.signIn(account: user.id)

// At launch and each time the app comes to the foreground
await registration.refresh()

// Before ending the session
await registration.signOut()

// When the moment is right to ask
try await registration.requestAuthorization()                 // shows the prompt
try await registration.requestAuthorization(provisional: true) // quiet, no prompt
```

`send` receives a `DeviceRegistration`:

| Property | Example | |
|---|---|---|
| `token` | `"a1b2…"` | Lowercase hex. `nil` if the device has never been given one |
| `apnsEnvironment` | `.production` | `.sandbox` under `DEBUG`, `.production` otherwise. Pass `environment:` to override |
| `timeZone` | `"Asia/Tokyo"` | IANA identifier |
| `locale` | `"ja-JP"` | BCP 47, in the language the app is displayed in |
| `appVersion` | `"2.4.0"` | `CFBundleShortVersionString` |
| `authorization` | `.authorized` | Also `.denied` and `.notDetermined` |

It is `Codable` and encodes as
`{"token","apnsEnv","tz","locale","appVersion","authorization"}`.

What `refresh()` does:

- If the person allows notifications, it asks the system for a token, and sends the registration
  when the token comes back through the app delegate
- If they do not, it sends the registration at once with the last token the device had, so the
  server can mark that token as unreachable
- A registration equal to the last one `send` returned from **for the same account** is skipped,
  across launches (`UserDefaultsRegistrationStore` by default). If `send` throws, the next refresh
  sends it again
- Requests never overlap; a change that arrives during one is sent after it

### Accounts

An APNs token belongs to the app's installation, not to the person signed in. When someone else
signs in on the same device the token stays the same, so the server only learns of it if told.

| When | Call | What reaches the server |
|---|---|---|
| The session is known (every launch, after sign-in, after an account switch) | `signIn(account:)` | The registration, again, when the account differs from the one the token was last registered for. The server should move the token to that account — the last account to register a token owns it |
| An anonymous account is linked to Apple or Google and keeps its id | `signIn(account:)` with the same id | Nothing |
| Signing out | `signOut()`, **before** ending the session | `unregister(token)`. If it throws, it is retried on the next refresh — or made unnecessary by the next sign-in |
| The server deleted the account and its devices | `forgetAccount()` | Nothing |

Until `signIn(account:)` is called, nothing is registered. `account` is kept on the device and
compared; it is never sent by the package — `send` runs with whatever authentication the app has
for the signed-in person.

### Opening a notification

The payload carries two keys beside `aps`:

```json
{"aps": {"alert": {"title": "…", "body": "…"}}, "send_id": "snd_123", "route": "items/42"}
```

```swift
let notifications = NotificationCenterDelegate(
    foregroundPresentation: [.banner, .list, .sound],
    reportOpened: { sendId in try await api.reportOpened(sendId) },
    onOpen: { open in router.pendingRoute = open.route }
)
UNUserNotificationCenter.current().delegate = notifications   // keep a reference: the center holds it weakly
```

`onOpen` runs first, on the main actor, then `reportOpened` with the `send_id`. A dismissal is
neither. A tap can launch the app before any view exists, so store the route where a view will
read it rather than navigating from `onOpen`. The key names can be changed with `PayloadKeys`.

### Wiring it into a SwiftUI app

```swift
import RemoteNotifications
import SwiftUI
import UserNotifications

@MainActor @Observable
final class Router {
    var pendingRoute: String?
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    let router = Router()
    let registration = NotificationRegistration(
        send: { try await API.shared.registerDevice($0) },
        unregister: { try await API.shared.unregisterDevice(token: $0) }
    )
    lazy var notifications = NotificationCenterDelegate(
        reportOpened: { try await API.shared.reportOpened($0) },
        onOpen: { [router] open in router.pendingRoute = open.route }
    )

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Before returning, or the tap that launched the app is lost.
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

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appDelegate.router)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { Task { await appDelegate.registration.refresh() } }
        }
    }
}
```

### Apps that use Firebase

Firebase swizzles the app delegate by default, and with it in place
`application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` is never called. Add this to
Info.plist:

```xml
<key>FirebaseAppDelegateProxyEnabled</key>
<false/>
```

### Testing

The system is reached only through `NotificationPermission`, `RemoteNotificationRegistering` and
`RegistrationStore`. Pass fakes of the three, and pass `context:` for a fixed time zone and
language, and the whole flow runs under `swift test` without a simulator.

## Documentation

**[API documentation](https://no-problem-dev.github.io/swift-remote-notifications/documentation/remotenotifications/)**

## Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 6.0+
- The Push Notifications capability on the app target

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-remote-notifications.git", .upToNextMinor(from: "0.2.0"))
]
```

Or in Xcode, `File > Add Package Dependencies...` with
`https://github.com/no-problem-dev/swift-remote-notifications`.

## License

[MIT](./LICENSE)
