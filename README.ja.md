# RemoteNotifications

リモート通知の端末側 —— 許可、APNsのデバイストークン、通知を押されたとき —— を扱う。サーバーはアプリが受け持つ。

![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017.0%2B%20%7C%20macOS%2014.0%2B-blue.svg)
![SPM](https://img.shields.io/badge/SPM-compatible-green.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

[English](./README.md) | 日本語

## 概要

このパッケージはURLを持たない。登録をどこへ送るか、開かれた通知をどこへ知らせるかは、アプリが関数で渡す。どのサーバーでも同じコードで使える。

- 許可の状態を読む・頼む（provisionalも選べる）
- 起動のたびにデバイストークンを取り、APNsの環境・タイムゾーン・言語・アプリの版・許可の状態と一緒に渡す
- 通知を許可していない端末も知らせる。サーバーが届く人数と届かない人数を数えられる
- 前回サーバーが受け付けた登録から何も変わっていなければ送らない
- 通知を押されたら、payloadの`route`をアプリに渡し、`send_id`を開いたとして知らせる
- アプリを開いているときの通知の出し方を引数で決められる
- Swift 6の厳密な並行性検査を通る。判断の部分は偽物を渡してMacの`swift test`で試せる

## 使い方

### 端末を登録する

```swift
import RemoteNotifications

let registration = NotificationRegistration { registration in
    try await api.registerDevice(registration)   // 送り先と送り方はアプリが決める
}

// 起動したとき、前面に戻るたびに
await registration.refresh()

// 許可を頼むとき
try await registration.requestAuthorization()                 // 確認のダイアログを出す
try await registration.requestAuthorization(provisional: true) // ダイアログを出さず、静かに届ける
```

`send`には`DeviceRegistration`が渡る。

| プロパティ | 例 | |
|---|---|---|
| `token` | `"a1b2…"` | 小文字の16進。一度も受け取っていなければ`nil` |
| `apnsEnvironment` | `.production` | `DEBUG`なら`.sandbox`、それ以外は`.production`。`environment:`で変えられる |
| `timeZone` | `"Asia/Tokyo"` | IANAの識別子 |
| `locale` | `"ja-JP"` | BCP 47。アプリを表示している言語 |
| `appVersion` | `"2.4.0"` | `CFBundleShortVersionString` |
| `authorization` | `.authorized` | `.denied`と`.notDetermined`も届く |

`Codable`で、JSONの鍵は`{"token","apnsEnv","tz","locale","appVersion","authorization"}`。

`refresh()`がすること：

- 許可されていれば、システムにトークンを頼む。トークンがアプリデリゲート経由で届いたら登録を送る
- 許可されていなければ、端末が最後に持っていたトークンを付けてすぐ送る。サーバーはそのトークンを届かない物として扱える
- `send`が最後に成功した登録と同じなら送らない。起動をまたいでも効く（既定は`UserDefaultsRegistrationStore`）。`send`が投げたら、次のrefreshで送り直す
- 送信は重ならない。送っている間に起きた変化は、終わってから送る

### 通知を押されたとき

payloadは`aps`の横に2つの鍵を持つ。

```json
{"aps": {"alert": {"title": "…", "body": "…"}}, "send_id": "snd_123", "route": "items/42"}
```

```swift
let notifications = NotificationCenterDelegate(
    foregroundPresentation: [.banner, .list, .sound],
    reportOpened: { sendId in try await api.reportOpened(sendId) },
    onOpen: { open in router.pendingRoute = open.route }
)
UNUserNotificationCenter.current().delegate = notifications   // centerは弱参照で持つので、参照を保持する
```

先に`onOpen`がメインアクターで呼ばれ、次に`send_id`で`reportOpened`が呼ばれる。通知を消しただけなら、どちらも呼ばれない。通知を押してアプリが起動したときは、まだ画面が無いことがある。`onOpen`の中で画面を動かさず、画面が表示されたときに読む場所へrouteを置く。鍵の名前は`PayloadKeys`で変えられる。

### SwiftUIのアプリにつなぐ

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
    let registration = NotificationRegistration { try await API.shared.registerDevice($0) }
    lazy var notifications = NotificationCenterDelegate(
        reportOpened: { try await API.shared.reportOpened($0) },
        onOpen: { [router] open in router.pendingRoute = open.route }
    )

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // returnする前に設定する。遅れると、アプリを起動した通知のタップが届かない
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

### Firebaseを使うアプリ

Firebaseは既定でアプリデリゲートを差し替える。そのままだと`application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`が呼ばれない。Info.plistに次を足す。

```xml
<key>FirebaseAppDelegateProxyEnabled</key>
<false/>
```

### テスト

システムに触るのは`NotificationPermission`・`RemoteNotificationRegistering`・`RegistrationStore`の3つだけ。この3つの偽物と、固定のタイムゾーンと言語を返す`context:`を渡せば、シミュレーター無しで`swift test`で流れ全体を試せる。

## ドキュメント

**[APIドキュメント](https://no-problem-dev.github.io/swift-remote-notifications/documentation/remotenotifications/)**

## 動作環境

- iOS 17.0+ / macOS 14.0+
- Swift 6.0+
- アプリのターゲットにPush Notificationsのcapability

## インストール

`Package.swift`に追加する。

```swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-remote-notifications.git", .upToNextMinor(from: "0.1.0"))
]
```

Xcodeでは`File > Add Package Dependencies...`で`https://github.com/no-problem-dev/swift-remote-notifications`を入力する。

## ライセンス

[MIT](./LICENSE)
