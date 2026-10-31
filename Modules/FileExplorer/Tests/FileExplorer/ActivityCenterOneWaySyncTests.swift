import Foundation
import Testing
import Sync
@testable import FileExplorer

/// **Activity ▸ Now's one-way sync rows** (RD67, DC) on Activity's owner: read back after a quit,
/// notified once, reminded when due, and a click picking out the row. A fresh center and a
/// scratch file per test — the app's are `.shared` and Application Support.
@MainActor
@Suite struct ActivityCenterOneWaySyncTests {

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static let day: TimeInterval = 24 * 60 * 60

    final class Scratch {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityOneWay-\(UUID().uuidString)")
        var notices: URL { url.appendingPathComponent("notices.json") }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    static func notice(_ id: String, _ kind: OneWaySyncNotice.Kind = .needsYou,
                       scope: OneWaySyncNotice.Scope = .folder("Legal")) -> OneWaySyncNotice {
        OneWaySyncNotice(id: id, kind: kind, scope: scope, title: "Row \(id)", detail: "Everything else keeps syncing.",
                         buttons: [.review], raisedAt: t0)
    }

    private func center(_ scratch: Scratch, now: Date = t0) -> (ActivityCenter, Posted) {
        let center = ActivityCenter()
        let posted = Posted()
        center.postOneWaySyncNotice = { posted.list.append($0) }
        center.attachOneWaySync(OneWaySyncNoticeStore(url: scratch.notices), now: now)
        return (center, posted)
    }

    final class Posted { var list: [OneWaySyncNoticeDelivery] = [] }

    @Test func rowsSurviveAQuitAndAreNotNotifiedTwice() {
        let scratch = Scratch()
        let (first, posted) = center(scratch)
        first.raiseOneWaySync([Self.notice("legal-limit"), Self.notice("skipped", .information)], now: Self.t0)
        #expect(posted.list.map(\.rowID) == ["legal-limit"])
        // The same cause again: the same row, and no second notification.
        first.raiseOneWaySync([Self.notice("legal-limit")], now: Self.t0 + 60)
        #expect(posted.list.count == 1)
        first.oneWaySyncFlushForTests()

        // The next launch.
        let (relaunched, posted2) = center(scratch, now: Self.t0 + 3600)
        #expect(relaunched.oneWaySync.needsYou.map(\.id) == ["legal-limit"])
        #expect(relaunched.oneWaySync.information.map(\.id) == ["skipped"])
        #expect(posted2.list.isEmpty)
    }

    @Test func aReminderComesDueWhileClosedOrOnTheHour() {
        let scratch = Scratch()
        let (first, _) = center(scratch)
        first.raiseOneWaySync([Self.notice("legal-limit")], now: Self.t0)
        first.oneWaySyncFlushForTests()

        // Opened eight days later: the week's reminder, at launch.
        let (relaunched, posted) = center(scratch, now: Self.t0 + 8 * Self.day)
        #expect(posted.list.map(\.kind) == [.reminder])
        relaunched.remindOneWaySync(now: Self.t0 + 8 * Self.day + 3600)
        #expect(posted.list.count == 1)
        relaunched.remindOneWaySync(now: Self.t0 + 15 * Self.day)
        #expect(posted.list.map(\.kind) == [.reminder, .reminder])
    }

    @Test func answeringClearsTheRowAndDismissingOnlyTakesInformation() {
        let scratch = Scratch()
        let (center, _) = center(scratch)
        center.raiseOneWaySync([Self.notice("legal-limit"), Self.notice("skipped", .information)], now: Self.t0)
        center.dismissOneWaySync("legal-limit")
        center.dismissOneWaySync("skipped")
        #expect(center.oneWaySync.needsYou.map(\.id) == ["legal-limit"])
        #expect(center.oneWaySync.information.isEmpty)
        center.clearOneWaySync(["legal-limit"], now: Self.t0)
        #expect(center.oneWaySync.needsYou.isEmpty)
        center.oneWaySyncFlushForTests()
        #expect(OneWaySyncNoticeStore(url: scratch.notices).load().value?.rows.isEmpty == true)
    }

    @Test func aClickOpensNowOnTheRowEvenOnceItGrouped() {
        let scratch = Scratch()
        let (center, _) = center(scratch)
        let files = (1...4).map {
            Self.notice("edited:\($0)", scope: .file(folder: "Legal", path: "Legal/\($0).pdf"))
        }
        center.raiseOneWaySync(files, now: Self.t0)
        center.tab = .history
        let requests = center.windowRequests
        center.openWindow(highlightingNotice: "edited:2")
        #expect(center.highlightedNotice == "group:Legal")
        #expect(center.tab == .now)
        #expect(center.windowRequests == requests + 1)
    }
}

extension ActivityCenter {
    /// Waits for the rows' saves to land.
    func oneWaySyncFlushForTests() {
        oneWaySyncStore?.flush()
    }
}
