import Foundation
import UserNotifications
@testable import RemoteNotifications

final class FakePermission: NotificationPermission, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: NotificationAuthorization
    private var _requested: [UNAuthorizationOptions] = []
    private let grantsTo: NotificationAuthorization

    init(_ status: NotificationAuthorization, grantsTo: NotificationAuthorization = .authorized) {
        self._status = status
        self.grantsTo = grantsTo
    }

    var status: NotificationAuthorization {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }

    var requested: [UNAuthorizationOptions] { lock.withLock { _requested } }

    func authorization() async -> NotificationAuthorization { status }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        lock.withLock {
            _requested.append(options)
            _status = options.contains(.provisional) ? .provisional : grantsTo
            return _status.allowsDelivery
        }
    }
}

@MainActor
final class FakeApplication: RemoteNotificationRegistering {
    var registerCalls = 0
    func registerForRemoteNotifications() { registerCalls += 1 }
}

/// Records what was sent. When `gate` is set, each send waits until `release()` is called.
actor Sender {
    private(set) var sent: [DeviceRegistration] = []
    private var failNext = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var gated = false

    func gate() { gated = true }
    func failOnce() { failNext = true }

    func release() {
        gated = false
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }

    var waitingCount: Int { waiting.count }

    func send(_ registration: DeviceRegistration) async throws {
        if gated { await withCheckedContinuation { waiting.append($0) } }
        if failNext {
            failNext = false
            throw SendError()
        }
        sent.append(registration)
    }
}

struct SendError: Error {}

let tokyo = DeviceContext(timeZone: "Asia/Tokyo", locale: "ja-JP", appVersion: "1.0.0")

@MainActor
func makeRegistration(
    permission: FakePermission,
    application: FakeApplication = FakeApplication(),
    store: InMemoryRegistrationStore = InMemoryRegistrationStore(),
    sender: Sender,
    environment: APNsEnvironment = .production,
    context: @escaping @Sendable () -> DeviceContext = { tokyo },
    onFailure: @escaping @MainActor (RegistrationFailure) -> Void = { _ in }
) -> NotificationRegistration {
    NotificationRegistration(
        environment: environment,
        store: store,
        context: context,
        permission: permission,
        application: application,
        onFailure: onFailure,
        send: { try await sender.send($0) }
    )
}
