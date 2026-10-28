/// Which APNs gateway a device token belongs to.
///
/// A token issued to a development-signed build only works against the sandbox gateway, and one
/// issued to a TestFlight or App Store build only against production. Sending to the wrong one
/// fails with `BadDeviceToken`, so the server has to be told which it is.
public enum APNsEnvironment: String, Sendable, Codable, CaseIterable {
    /// `api.sandbox.push.apple.com` — builds signed for development.
    case sandbox
    /// `api.push.apple.com` — TestFlight and the App Store.
    case production

    /// `sandbox` when this package is compiled with `DEBUG`, `production` otherwise.
    ///
    /// Xcode builds a package with the configuration of the app that includes it, so a Debug run
    /// from Xcode reports `sandbox` and an archive reports `production`. A build whose signing
    /// does not follow its configuration — a Release build run from Xcode with a development
    /// profile, say — should pass the environment explicitly.
    public static var current: APNsEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}
