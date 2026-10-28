import Foundation
import Testing
@testable import RemoteNotifications

private let tokenBytes = Data([0x00, 0x0f, 0xa0, 0xff, 0x12])
private let tokenHex = "000fa0ff12"

@Suite("端末の登録")
@MainActor
struct NotificationRegistrationTests {

    @Test("許可されていればトークンを取りに行き、届いたトークンで登録を送る")
    func authorizedRegistersAndSendsToken() async throws {
        let app = FakeApplication()
        let sender = Sender()
        let store = InMemoryRegistrationStore()
        let registration = makeRegistration(permission: FakePermission(.authorized), application: app, store: store, sender: sender)

        #expect(await registration.refresh() == .authorized)
        #expect(app.registerCalls == 1)
        #expect(await sender.sent.isEmpty)

        await registration.receive(deviceToken: tokenBytes)

        #expect(await sender.sent == [
            DeviceRegistration(token: tokenHex, apnsEnvironment: .production, timeZone: "Asia/Tokyo",
                               locale: "ja-JP", appVersion: "1.0.0", authorization: .authorized)
        ])
        #expect(store.token == tokenHex)
        #expect(store.lastSent?.token == tokenHex)
    }

    @Test("provisional でもトークンを取りに行く")
    func provisionalRegisters() async {
        let app = FakeApplication()
        let registration = makeRegistration(permission: FakePermission(.provisional), application: app, sender: Sender())
        await registration.refresh()
        #expect(app.registerCalls == 1)
    }

    @Test("未決定はトークンを取りに行かず、トークン無しで状態だけ送る")
    func notDeterminedReportsWithoutToken() async {
        let app = FakeApplication()
        let sender = Sender()
        let registration = makeRegistration(permission: FakePermission(.notDetermined), application: app, sender: sender)

        await registration.refresh()

        #expect(app.registerCalls == 0)
        let sent = await sender.sent
        #expect(sent.count == 1)
        #expect(sent.first?.token == nil)
        #expect(sent.first?.authorization == .notDetermined)
    }

    @Test("拒否に変わったら、前のトークンを付けて denied を送る")
    func deniedReportsLastToken() async {
        let permission = FakePermission(.authorized)
        let sender = Sender()
        let registration = makeRegistration(permission: permission, sender: sender)
        await registration.refresh()
        await registration.receive(deviceToken: tokenBytes)

        permission.status = .denied
        await registration.refresh()

        let sent = await sender.sent
        #expect(sent.map(\.authorization) == [.authorized, .denied])
        #expect(sent.last?.token == tokenHex)
    }

    @Test("前回受け付けられた登録と同じなら送らない（起動をまたいでも）")
    func skipsDuplicateAcrossLaunches() async {
        let store = InMemoryRegistrationStore()
        let sender = Sender()

        let first = makeRegistration(permission: FakePermission(.authorized), store: store, sender: sender)
        await first.refresh()
        await first.receive(deviceToken: tokenBytes)
        await first.receive(deviceToken: tokenBytes)

        let nextLaunch = makeRegistration(permission: FakePermission(.authorized), store: store, sender: sender)
        await nextLaunch.refresh()
        await nextLaunch.receive(deviceToken: tokenBytes)

        #expect(await sender.sent.count == 1)
    }

    @Test("トークン・言語・版のどれかが変われば送り直す")
    func resendsOnChange() async {
        let store = InMemoryRegistrationStore()
        let sender = Sender()
        await makeRegistration(permission: FakePermission(.authorized), store: store, sender: sender)
            .receive(deviceToken: tokenBytes)
        await makeRegistration(permission: FakePermission(.authorized), store: store, sender: sender)
            .receive(deviceToken: Data([0x01]))
        await makeRegistration(permission: FakePermission(.authorized), store: store, sender: sender,
                               context: { DeviceContext(timeZone: "Asia/Tokyo", locale: "en-US", appVersion: "1.0.0") })
            .receive(deviceToken: Data([0x01]))
        await makeRegistration(permission: FakePermission(.authorized), store: store, sender: sender,
                               context: { DeviceContext(timeZone: "Asia/Tokyo", locale: "en-US", appVersion: "1.1.0") })
            .receive(deviceToken: Data([0x01]))

        #expect(await sender.sent.map(\.token) == [tokenHex, "01", "01", "01"])
        #expect(await sender.sent.map(\.locale) == ["ja-JP", "ja-JP", "en-US", "en-US"])
        #expect(await sender.sent.map(\.appVersion) == ["1.0.0", "1.0.0", "1.0.0", "1.1.0"])
    }

    @Test("送れなかった登録は受け付け済みにせず、次の refresh で送り直す")
    func failedSendIsRetriedNextTime() async {
        let sender = Sender()
        await sender.failOnce()
        var failures: [RegistrationFailure] = []
        let registration = makeRegistration(permission: FakePermission(.denied), sender: sender,
                                            onFailure: { failures.append($0) })

        await registration.refresh()
        #expect(await sender.sent.isEmpty)
        #expect(failures.count == 1)
        if case .send = failures.first {} else { Issue.record("send の失敗として届いていない") }

        await registration.refresh()
        #expect(await sender.sent.count == 1)
    }

    @Test("送っている間に届いた変化は重ねずに後で送り、同じ物は1回だけ")
    func sendsDoNotOverlap() async throws {
        let sender = Sender()
        await sender.gate()
        let registration = makeRegistration(permission: FakePermission(.authorized), sender: sender)

        let first = Task { await registration.receive(deviceToken: tokenBytes) }
        while await sender.waitingCount == 0 { await Task.yield() }

        // While the first is in flight: the same token twice, then a new one.
        await registration.receive(deviceToken: tokenBytes)
        await registration.receive(deviceToken: Data([0x02]))
        #expect(await sender.waitingCount == 1)

        await sender.release()
        await first.value

        #expect(await sender.sent.map(\.token) == [tokenHex, "02"])
    }

    @Test("許可を頼むと、答えで登録し直す。provisional は選べる")
    func requestAuthorizationRefreshes() async throws {
        let permission = FakePermission(.notDetermined)
        let app = FakeApplication()
        let registration = makeRegistration(permission: permission, application: app, sender: Sender())

        #expect(try await registration.requestAuthorization(provisional: true) == .provisional)
        #expect(permission.requested == [[.alert, .badge, .sound, .provisional]])
        #expect(app.registerCalls == 1)
    }

    @Test("APNs が失敗したら apns の失敗として知らせる")
    func apnsFailureIsReported() {
        var failures: [RegistrationFailure] = []
        let registration = makeRegistration(permission: FakePermission(.authorized), sender: Sender(),
                                            onFailure: { failures.append($0) })
        registration.didFailToRegisterForRemoteNotifications(error: SendError())
        if case .apns = failures.first {} else { Issue.record("apns の失敗として届いていない") }
    }

    @Test("sandbox を渡せば sandbox で送る")
    func environmentIsOverridable() async {
        let sender = Sender()
        await makeRegistration(permission: FakePermission(.authorized), sender: sender, environment: .sandbox)
            .receive(deviceToken: tokenBytes)
        #expect(await sender.sent.first?.apnsEnvironment == .sandbox)
    }

    @Test("UserDefaults の保存は起動をまたいで同じ値を返す")
    func userDefaultsStoreRoundTrips() throws {
        let suite = "RemoteNotificationsTests.\(#function)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let value = DeviceRegistration(token: tokenHex, apnsEnvironment: .sandbox, timeZone: "UTC",
                                       locale: "en", appVersion: "2", authorization: .denied)

        let store = UserDefaultsRegistrationStore(defaults: defaults)
        store.token = tokenHex
        store.lastSent = value

        let reopened = UserDefaultsRegistrationStore(defaults: defaults)
        #expect(reopened.token == tokenHex)
        #expect(reopened.lastSent == value)
    }
}
