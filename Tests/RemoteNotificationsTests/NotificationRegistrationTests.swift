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
        let store = InMemoryRegistrationStore(account: "user-a")
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
        #expect(store.registered == RegisteredDevice(account: "user-a", registration: await sender.sent[0]))
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
        let store = InMemoryRegistrationStore(account: "user-a")
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
        let store = InMemoryRegistrationStore(account: "user-a")
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
        let value = RegisteredDevice(
            account: "user-a",
            registration: DeviceRegistration(token: tokenHex, apnsEnvironment: .sandbox, timeZone: "UTC",
                                              locale: "en", appVersion: "2", authorization: .denied)
        )

        let store = UserDefaultsRegistrationStore(defaults: defaults)
        store.token = tokenHex
        store.account = "user-a"
        store.registered = value
        store.tokenToUnregister = "ab"

        let reopened = UserDefaultsRegistrationStore(defaults: defaults)
        #expect(reopened.token == tokenHex)
        #expect(reopened.account == "user-a")
        #expect(reopened.registered == value)
        #expect(reopened.tokenToUnregister == "ab")
    }
}

/// トークンはアプリの入れ物に1つで、誰がサインインしているかでは変わらない。サーバーに「誰の端末か」を
/// 伝え直せるのは、端末の側がアカウントの変化を知っているときだけ。
@Suite("端末とアカウント")
@MainActor
struct AccountBindingTests {

    @Test("誰もサインインしていなければ何も送らない。サインインしたら送る")
    func nothingBeforeSignIn() async {
        let sender = Sender()
        let store = InMemoryRegistrationStore()
        let registration = makeRegistration(permission: FakePermission(.authorized), store: store, sender: sender)
        await registration.refresh()
        await registration.receive(deviceToken: tokenBytes)
        #expect(await sender.requests.isEmpty)

        await registration.signIn(account: "user-a")
        #expect(await sender.requests == [.send(tokenHex)])
        #expect(registration.account == "user-a")
    }

    /// ストックレーダーで 2026-08-02 に起きた：入れ直しで作られた匿名の id にトークンが登録され、
    /// 元のアカウントにサインインし直しても「登録済み」と判断して送らなかった。サーバーは元の id に古いトークンを持ち続けた
    @Test("トークンが同じでも、アカウントが変わったら送り直す。新しいトークンを待たない")
    func accountSwitchResendsSameToken() async {
        let sender = Sender()
        let store = InMemoryRegistrationStore(account: "anon-1")
        let registration = makeRegistration(permission: FakePermission(.authorized), store: store, sender: sender)
        await registration.refresh()
        await registration.receive(deviceToken: tokenBytes)

        await registration.signIn(account: "account-b")
        #expect(await sender.requests == [.send(tokenHex), .send(tokenHex)])
        #expect(store.registered?.account == "account-b")
    }

    @Test("同じアカウントでのサインイン（匿名から Apple・Google にリンクして id が変わらない）は送らない")
    func sameAccountSendsNothing() async {
        let sender = Sender()
        let registration = makeRegistration(permission: FakePermission(.authorized), sender: sender)
        await registration.receive(deviceToken: tokenBytes)
        await registration.signIn(account: "user-a")
        await registration.signIn(account: "user-a")
        #expect(await sender.requests == [.send(tokenHex)])
    }

    @Test("サインアウトでトークンを外す。次にサインインするまで登録しない")
    func signOutUnregisters() async {
        let sender = Sender()
        let store = InMemoryRegistrationStore(account: "user-a")
        let registration = makeRegistration(permission: FakePermission(.authorized), store: store, sender: sender)
        await registration.receive(deviceToken: tokenBytes)

        await registration.signOut()
        await registration.refresh()
        await registration.receive(deviceToken: tokenBytes)

        #expect(await sender.requests == [.send(tokenHex), .unregister(tokenHex)])
        #expect(store.account == nil)
        #expect(store.registered == nil)
        #expect(store.tokenToUnregister == nil)

        await registration.signIn(account: "user-b")
        #expect(await sender.requests.last == .send(tokenHex))
    }

    @Test("許可していない端末でも、前に持っていたトークンを外す")
    func signOutUnregistersDeniedDevice() async {
        let sender = Sender()
        let permission = FakePermission(.authorized)
        let registration = makeRegistration(permission: permission, sender: sender)
        await registration.receive(deviceToken: tokenBytes)
        permission.status = .denied
        await registration.refresh()

        await registration.signOut()
        #expect(await sender.unregistered == [tokenHex])
    }

    @Test("サインアウトが届かなければ覚えておき、次の refresh で外し直す")
    func failedSignOutIsRetried() async {
        let sender = Sender()
        await sender.failUnregisterOnce()
        var failures: [RegistrationFailure] = []
        let store = InMemoryRegistrationStore(account: "user-a")
        let registration = makeRegistration(permission: FakePermission(.authorized), store: store, sender: sender,
                                            onFailure: { failures.append($0) })
        await registration.receive(deviceToken: tokenBytes)

        await registration.signOut()
        #expect(store.tokenToUnregister == tokenHex)
        if case .unregister = failures.first {} else { Issue.record("unregister の失敗として届いていない") }

        await registration.refresh()
        #expect(await sender.unregistered == [tokenHex])
        #expect(store.tokenToUnregister == nil)
    }

    @Test("外し直す前に次の人がサインインしたら、外してから次の人で登録する")
    func leftoverIsUnregisteredBeforeTheNextAccount() async {
        let sender = Sender()
        await sender.failUnregisterOnce()
        let store = InMemoryRegistrationStore(account: "user-a")
        let registration = makeRegistration(permission: FakePermission(.authorized), store: store, sender: sender)
        await registration.receive(deviceToken: tokenBytes)
        await registration.signOut()

        await registration.signIn(account: "user-b")
        #expect(await sender.requests == [.send(tokenHex), .unregister(tokenHex), .send(tokenHex)])
        #expect(store.registered?.account == "user-b")
    }

    @Test("外すのがまた届かなくても、次の人の登録が届けば持ち主は移ったので、外すのはやめる")
    func registrationSupersedesLeftover() async {
        let sender = Sender()
        let store = InMemoryRegistrationStore(account: "user-a")
        let registration = makeRegistration(permission: FakePermission(.authorized), store: store, sender: sender)
        await registration.receive(deviceToken: tokenBytes)
        await sender.failUnregisterOnce()
        await registration.signOut()
        await sender.failUnregisterOnce()

        await registration.signIn(account: "user-b")
        #expect(await sender.requests == [.send(tokenHex), .send(tokenHex)])
        #expect(store.tokenToUnregister == nil)

        await registration.refresh()
        #expect(await sender.unregistered.isEmpty)
    }

    @Test("アカウントの削除のあとは何も送らずに忘れる。次のサインインで送る")
    func forgetAccountSendsNothing() async {
        let sender = Sender()
        let store = InMemoryRegistrationStore(account: "user-a")
        let registration = makeRegistration(permission: FakePermission(.authorized), store: store, sender: sender)
        await registration.receive(deviceToken: tokenBytes)

        registration.forgetAccount()
        await registration.refresh()
        #expect(await sender.requests == [.send(tokenHex)])
        #expect(store.registered == nil)

        await registration.signIn(account: "user-a2")
        #expect(await sender.requests == [.send(tokenHex), .send(tokenHex)])
    }

    @Test("送っている間にサインアウトしたら、送れた登録を覚えずに外す")
    func signOutDuringSend() async {
        let sender = Sender()
        await sender.gate()
        let store = InMemoryRegistrationStore(account: "user-a")
        let registration = makeRegistration(permission: FakePermission(.authorized), store: store, sender: sender)

        let first = Task { await registration.receive(deviceToken: tokenBytes) }
        while await sender.waitingCount == 0 { await Task.yield() }
        await registration.signOut()
        await sender.release()
        await first.value

        #expect(await sender.requests == [.send(tokenHex), .unregister(tokenHex)])
        #expect(store.registered == nil)

        // 同じ人がサインインし直したら、登録し直す
        await registration.signIn(account: "user-a")
        #expect(await sender.requests.last == .send(tokenHex))
    }
}
