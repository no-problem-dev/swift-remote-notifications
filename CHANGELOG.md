# Changelog

All notable changes to this project are recorded in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-10-28

### Added
- `NotificationRegistration.signIn(account:)`, which says who is signed in and refreshes the
  registration for them. A different account than the one the token was last registered for
  sends the same token again, so the server moves it; the same account sends nothing.
- `NotificationRegistration.signOut()`, which asks the server through the new `unregister`
  closure to drop this device's token, and retries on the next refresh if that fails.
- `NotificationRegistration.forgetAccount()`, for after the server has deleted the account: it
  forgets what was sent without a request.
- `NotificationRegistration.account`, the account signed in now.
- `RegisteredDevice`: what the server holds — the account and the registration it accepted.
- `RegistrationFailure.unregister`.

### Changed
- **Breaking:** `NotificationRegistration.init` takes `unregister:` after `send:`.
- **Breaking:** nothing is registered until `signIn(account:)` has been called. A registration is
  compared with the last accepted one together with its account, so switching accounts on a
  device whose token has not changed is no longer skipped — the server kept the token on the
  previous account.
- **Breaking:** `RegistrationStore` keeps `account`, `registered` and `tokenToUnregister` in place
  of `lastSent`. `UserDefaultsRegistrationStore` uses new keys, so each device sends its
  registration once after updating.
- With notifications allowed, `refresh()` sends the token the device already has instead of
  waiting for the system to hand it over again.

## [0.1.0] - 2026-10-29

### Added
- `NotificationRegistration`, which keeps the app's server told about this device. `refresh()`
  reads the permission and, when notifications are allowed, asks for an APNs token; the token is
  forwarded from the app delegate with `didRegisterForRemoteNotifications(deviceToken:)`. Each
  change is handed to the app's `send` closure as a `DeviceRegistration` — the token in lowercase
  hex, the `APNsEnvironment`, the time zone, the language, the app version and the
  `NotificationAuthorization`. Devices that do not allow notifications are reported too, with the
  last token they had. A registration equal to the last one `send` accepted is not sent again,
  across launches, and sends never overlap.
- `requestAuthorization(options:provisional:)`, which asks for the permission and refreshes the
  registration with the answer.
- `APNsEnvironment.current`: `sandbox` under `DEBUG`, `production` otherwise, overridable through
  `NotificationRegistration(environment:)`.
- `NotificationCenterDelegate`, a `UNUserNotificationCenterDelegate` that shows notifications in the
  foreground with configurable options, hands each opened notification to the app as a
  `NotificationOpen` (`sendId`, `route`, `actionIdentifier`), and reports the `send_id` through the
  app's `reportOpened` closure. Dismissals are ignored.
- `NotificationPermission`, `RemoteNotificationRegistering` and `RegistrationStore`, the three
  points where the system is reached, with `SystemNotificationPermission`,
  `UserDefaultsRegistrationStore` and `InMemoryRegistrationStore`.
