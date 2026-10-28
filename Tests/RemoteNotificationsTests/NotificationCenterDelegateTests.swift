import Foundation
import Testing
import UserNotifications
@testable import RemoteNotifications

actor OpenLog {
    var reported: [String] = []
    func report(_ id: String) { reported.append(id) }
}

@Suite("通知を押されたとき")
@MainActor
struct NotificationCenterDelegateTests {

    @Test("アプリに route を渡してから、send_id を開いたとして知らせる")
    func deliversThenReports() async {
        let log = OpenLog()
        var opened: [NotificationOpen] = []
        let delegate = NotificationCenterDelegate(
            reportOpened: { await log.report($0) },
            onOpen: { opened.append($0) }
        )

        await delegate.receive(NotificationOpen(sendId: "snd_1", route: "items/42",
                                                actionIdentifier: UNNotificationDefaultActionIdentifier))

        #expect(opened.map(\.route) == ["items/42"])
        #expect(await log.reported == ["snd_1"])
    }

    @Test("send_id が無ければ route だけ渡し、何も知らせない")
    func noSendIdNoReport() async {
        let log = OpenLog()
        var opened: [NotificationOpen] = []
        let delegate = NotificationCenterDelegate(reportOpened: { await log.report($0) },
                                                  onOpen: { opened.append($0) })

        await delegate.receive(NotificationOpen(sendId: nil, route: "home", actionIdentifier: "a"))

        #expect(opened.count == 1)
        #expect(await log.reported.isEmpty)
    }

    @Test("消しただけ（dismiss）は開いたことにしない")
    func dismissIsIgnored() async {
        let log = OpenLog()
        var opened: [NotificationOpen] = []
        let delegate = NotificationCenterDelegate(reportOpened: { await log.report($0) },
                                                  onOpen: { opened.append($0) })

        await delegate.receive(NotificationOpen(sendId: "snd_1", route: "x",
                                                actionIdentifier: UNNotificationDismissActionIdentifier))

        #expect(opened.isEmpty)
        #expect(await log.reported.isEmpty)
    }

    @Test("知らせるのに失敗したら onFailure に届く")
    func reportFailureIsSurfaced() async {
        var failures = 0
        let delegate = NotificationCenterDelegate(reportOpened: { _ in throw SendError() },
                                                  onFailure: { _ in failures += 1 },
                                                  onOpen: { _ in })
        await delegate.receive(NotificationOpen(sendId: "snd_1", route: nil, actionIdentifier: "a"))
        #expect(failures == 1)
    }
}
