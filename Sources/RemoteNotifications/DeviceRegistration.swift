import Foundation

/// What a server needs to know to reach this device: the token, where it is valid, and the
/// person's time zone, language, app version and permission.
///
/// Encoded as JSON it reads:
///
/// ```json
/// {"token":"a1b2…","apnsEnv":"production","tz":"Asia/Tokyo","locale":"ja-JP",
///  "appVersion":"2.4.0","authorization":"authorized"}
/// ```
public struct DeviceRegistration: Sendable, Equatable, Codable {

    /// The APNs device token as lowercase hex, or `nil` when the device has never been given one.
    ///
    /// A device that is `denied` keeps the last token it was given, so the server can mark that
    /// token as unreachable rather than forget it.
    public var token: String?

    /// The gateway ``token`` is valid on.
    public var apnsEnvironment: APNsEnvironment

    /// An IANA time zone identifier, such as `Asia/Tokyo`.
    public var timeZone: String

    /// A BCP 47 language tag, such as `ja-JP`, in the language the app is displayed in.
    public var locale: String

    /// `CFBundleShortVersionString`.
    public var appVersion: String

    /// Whether the person allows notifications.
    public var authorization: NotificationAuthorization

    public init(
        token: String?,
        apnsEnvironment: APNsEnvironment,
        timeZone: String,
        locale: String,
        appVersion: String,
        authorization: NotificationAuthorization
    ) {
        self.token = token
        self.apnsEnvironment = apnsEnvironment
        self.timeZone = timeZone
        self.locale = locale
        self.appVersion = appVersion
        self.authorization = authorization
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case apnsEnvironment = "apnsEnv"
        case timeZone = "tz"
        case locale
        case appVersion
        case authorization
    }
}

/// The parts of a ``DeviceRegistration`` that describe the device rather than its token.
public struct DeviceContext: Sendable, Equatable {

    /// An IANA time zone identifier.
    public var timeZone: String
    /// A BCP 47 language tag.
    public var locale: String
    /// `CFBundleShortVersionString`.
    public var appVersion: String

    public init(timeZone: String, locale: String, appVersion: String) {
        self.timeZone = timeZone
        self.locale = locale
        self.appVersion = appVersion
    }

    /// The device's current time zone and locale, and the main bundle's version.
    ///
    /// `Locale.current` follows the language the person chose for this app in Settings, so the
    /// tag is the language the app is shown in, not merely the system's first language.
    public static var current: DeviceContext {
        DeviceContext(
            timeZone: TimeZone.current.identifier,
            locale: Locale.current.identifier(.bcp47),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        )
    }
}

extension Data {
    /// The bytes as lowercase hex, the form APNs device tokens are written in.
    var lowercaseHex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
