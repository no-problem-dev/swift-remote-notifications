import Foundation
import Testing
import UserNotifications
@testable import RemoteNotifications

@Suite("値と読み取り")
struct ValueTests {

    @Test("トークンは小文字の16進で、0 埋めされる")
    func tokenHex() {
        #expect(Data([0x00, 0x0a, 0xff, 0x7f]).lowercaseHex == "000aff7f")
        #expect(Data().lowercaseHex == "")
    }

    @Test("登録は短い鍵の JSON になり、読み戻せる")
    func registrationJSON() throws {
        let value = DeviceRegistration(token: "ab", apnsEnvironment: .sandbox, timeZone: "Asia/Tokyo",
                                       locale: "ja-JP", appVersion: "1.2.3", authorization: .notDetermined)
        let data = try JSONEncoder().encode(value)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json == ["token": "ab", "apnsEnv": "sandbox", "tz": "Asia/Tokyo", "locale": "ja-JP",
                         "appVersion": "1.2.3", "authorization": "not_determined"])
        #expect(try JSONDecoder().decode(DeviceRegistration.self, from: data) == value)
    }

    @Test("システムの許可状態を読み替える")
    func authorizationMapping() {
        #expect(NotificationAuthorization(.notDetermined) == .notDetermined)
        #expect(NotificationAuthorization(.denied) == .denied)
        #expect(NotificationAuthorization(.authorized) == .authorized)
        #expect(NotificationAuthorization(.provisional) == .provisional)
        #expect(NotificationAuthorization.allCases.filter(\.allowsDelivery) == [.authorized, .provisional, .ephemeral])
    }

    @Test("テストは DEBUG でビルドされるので、既定の環境は sandbox")
    func currentEnvironmentInDebug() {
        #expect(APNsEnvironment.current == .sandbox)
    }

    @Test("payload から send_id と route を読む")
    func readsPayload() {
        let open = NotificationOpen(
            userInfo: ["aps": ["alert": "hi"], "send_id": "snd_1", "route": "items/42"],
            actionIdentifier: UNNotificationDefaultActionIdentifier
        )
        #expect(open == NotificationOpen(sendId: "snd_1", route: "items/42",
                                         actionIdentifier: UNNotificationDefaultActionIdentifier))
    }

    @Test("数の send_id は10進の文字列、空や別の型は無いものとして読む")
    func payloadEdges() {
        let number = NotificationOpen(userInfo: ["send_id": 123], actionIdentifier: "a")
        #expect(number.sendId == "123")
        #expect(number.route == nil)

        let odd = NotificationOpen(userInfo: ["send_id": "", "route": ["x"]], actionIdentifier: "a")
        #expect(odd.sendId == nil)
        #expect(odd.route == nil)
    }

    @Test("鍵は差し替えられる")
    func customKeys() {
        let open = NotificationOpen(userInfo: ["id": "s", "deeplink": "r"], actionIdentifier: "a",
                                    keys: PayloadKeys(sendId: "id", route: "deeplink"))
        #expect(open.sendId == "s")
        #expect(open.route == "r")
    }
}
