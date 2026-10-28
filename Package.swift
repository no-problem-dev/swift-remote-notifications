// swift-tools-version: 6.0
import PackageDescription

/// The device side of remote notifications: permission, the device token, and taps.
///
/// **It knows no server.** Where a registration is sent and where an opened notification is
/// reported are closures the app passes in, so the same package serves any backend.
let package = Package(
    name: "swift-remote-notifications",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        // Depends on Foundation and UserNotifications only. UIKit and AppKit are reached behind
        // `#if canImport`, so the decision logic builds and tests on macOS with `swift test`.
        .library(name: "RemoteNotifications", targets: ["RemoteNotifications"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0")
    ],
    targets: [
        .target(name: "RemoteNotifications"),
        .testTarget(name: "RemoteNotificationsTests", dependencies: ["RemoteNotifications"])
    ]
)
