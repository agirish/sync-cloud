import Foundation
import Testing
@testable import Sync

/// Activity ▸ Now's one-way sync rows: saved, kept until answered or until the cause clears,
/// grouped past three files a folder, and notified once, then reminded daily or weekly.
@Suite struct OneWaySyncNoticesTests {

    static let t0 = OneWayWorld.t0
    static let hour: TimeInterval = 60 * 60
    static let day = 24 * hour

    static func file(_ path: String, in folder: String = "Legal", at date: Date = t0) -> OneWaySyncNotice {
        OneWaySyncNotice(id: "edited:" + path, kind: .needsYou, scope: .file(folder: folder, path: path),
                         title: "\((path as NSString).lastPathComponent) was edited in Dropbox",
                         detail: "\(folder) · this file waits; the rest keeps syncing", buttons: [.chooseAVersion], raisedAt: date)
    }

    static let dropboxNotRunning = OneWaySyncNotice(
        id: "dropbox-not-running", kind: .needsYou, scope: .wholeSync,
        title: "Sync stopped: the Dropbox app isn’t running", buttons: [.openDropbox, .retry], raisedAt: t0)

    static let renamed = OneWaySyncNotice(
        id: "renamed:Health", kind: .needsYou, scope: .folder("Health"), title: "Health was renamed to Medical in iCloud",
        detail: "Health waits. Nothing copied or removed meanwhile.", buttons: [.renameDropboxsToo, .stopSyncing], raisedAt: t0)

    static func dropboxOnly(_ count: Int) -> OneWaySyncNotice {
        OneWaySyncNotice(id: "dropbox-only", kind: .information, scope: .wholeSync, title: "\(count) files are only in Dropbox",
                         detail: "Inside synced folders · left alone", buttons: [.showThem], raisedAt: t0)
    }

    static let removedIsLarge = OneWaySyncNotice(
        id: "removed-large", kind: .information, scope: .wholeSync, title: "SyncCloud Removed holds 18 GB",
        buttons: [.chooseItemsToEmpty], raisedAt: t0, notifiesOnce: true)

    // MARK: Rows

    @Test func theSameCauseRaisedAgainIsTheSameRow() {
        var board = OneWaySyncNoticeBoard()
        board.raise(Self.renamed)
        do { let due = board.deliveries(now: Self.t0); #expect(due.count == 1) }
        var again = Self.renamed
        again.title = "Health was renamed to Medical Records in iCloud"
        again.raisedAt += 600
        board.raise(again)
        #expect(board.rows.count == 1)
        #expect(board.rows[0].title == again.title)
        // When it first appeared, and that it was notified, both kept.
        #expect(board.rows[0].raisedAt == Self.renamed.raisedAt)
        do { let due = board.deliveries(now: Self.t0 + Self.hour); #expect(due.isEmpty) }
    }

    @Test func aNeedsYouRowStaysUntilAnsweredOrItsCauseClears() {
        var board = OneWaySyncNoticeBoard()
        board.raise(Self.renamed)
        do { let dismissed = board.dismiss(Self.renamed.id); #expect(!dismissed) }
        #expect(board.needsYou.map(\.id) == [Self.renamed.id])
        board.clear(Self.renamed.id)
        #expect(board.needsYou.isEmpty)
        // Back again: a new row, with its own notification.
        board.raise(Self.renamed)
        do { let due = board.deliveries(now: Self.t0); #expect(due.map(\.kind) == [.first]) }
    }

    @Test func aDismissedInformationRowComesBackOnlyWhenItSaysSomethingElse() {
        var board = OneWaySyncNoticeBoard()
        board.raise(Self.dropboxOnly(9))
        do { let dismissed = board.dismiss("dropbox-only"); #expect(dismissed) }
        #expect(board.information.isEmpty)
        board.raise(Self.dropboxOnly(9))
        #expect(board.information.isEmpty)
        board.raise(Self.dropboxOnly(10))
        #expect(board.information.map(\.title) == ["10 files are only in Dropbox"])
        // Once its cause clears, the next time it comes back whatever it says.
        do { let dismissed = board.dismiss("dropbox-only"); #expect(dismissed) }
        board.clear("dropbox-only")
        board.raise(Self.dropboxOnly(10))
        #expect(board.information.count == 1)
    }

    @Test func informationRowsSendNoNotificationButSyncCloudRemovedSendsOne() {
        var board = OneWaySyncNoticeBoard()
        board.raise(Self.dropboxOnly(9))
        board.raise(Self.removedIsLarge)
        let due = board.deliveries(now: Self.t0)
        #expect(due == [OneWaySyncNoticeDelivery(kind: .first, rowID: "removed-large", title: "SyncCloud Removed holds 18 GB", body: nil)])
        // Never a reminder.
        do { let due = board.deliveries(now: Self.t0 + 30 * Self.day); #expect(due.isEmpty) }
    }

    /// SyncCloud Removed's one notification is one, whatever its size says after a dismissal.
    @Test func theOneInformationNotificationIsNotSentAgainAfterADismissal() {
        var board = OneWaySyncNoticeBoard()
        board.raise(Self.removedIsLarge)
        do { let due = board.deliveries(now: Self.t0); #expect(due.count == 1) }
        do { let dismissed = board.dismiss("removed-large"); #expect(dismissed) }
        var larger = Self.removedIsLarge
        larger.title = "SyncCloud Removed holds 19 GB"
        board.raise(larger)
        #expect(board.information.map(\.title) == ["SyncCloud Removed holds 19 GB"])
        do { let due = board.deliveries(now: Self.t0 + 60); #expect(due.isEmpty) }
        // Once it clears and comes back, it is a new one.
        board.clear("removed-large")
        board.raise(larger)
        do { let due = board.deliveries(now: Self.t0 + 120); #expect(due.count == 1) }
    }

    @Test func moreThanThreeFileRowsInAFolderGroupIntoOne() {
        var board = OneWaySyncNoticeBoard()
        for (index, name) in ["a.pdf", "b.pdf", "c.pdf"].enumerated() {
            board.raise(Self.file("Legal/\(name)", at: Self.t0 + Double(index)))
        }
        board.raise(Self.file("Finance/x.pdf", in: "Finance", at: Self.t0 - 1))
        // Three is not more than three.
        #expect(board.needsYou.map(\.id) == ["edited:Legal/c.pdf", "edited:Legal/b.pdf", "edited:Legal/a.pdf", "edited:Finance/x.pdf"])

        board.raise(Self.file("Legal/d.pdf", at: Self.t0 + 10))
        let rows = board.needsYou
        #expect(rows.map(\.id) == ["group:Legal", "edited:Finance/x.pdf"])
        #expect(rows[0].title == "Legal: 4 files wait for you")
        #expect(rows[0].members.count == 4)
        #expect(rows[0].raisedAt == Int64((Self.t0 + 10).timeIntervalSince1970))
        // A notification for one of them opens the group.
        #expect(board.shownRow(for: "edited:Legal/a.pdf") == "group:Legal")
    }

    @Test func rowsThatStopTheWholeSyncComeFirst() {
        var board = OneWaySyncNoticeBoard()
        var newer = Self.renamed
        newer.raisedAt += 3600
        board.raise(newer)
        board.raise(Self.dropboxNotRunning)
        #expect(board.needsYou.map(\.id) == ["dropbox-not-running", "renamed:Health"])
    }

    // MARK: Notifications

    @Test func eachRowSendsOneNotificationThenAReminder() {
        var board = OneWaySyncNoticeBoard()
        board.raise(Self.dropboxNotRunning)
        board.raise(Self.renamed)
        let first = board.deliveries(now: Self.t0)
        #expect(first == [
            OneWaySyncNoticeDelivery(kind: .first, rowID: "dropbox-not-running", title: Self.dropboxNotRunning.title, body: nil),
            OneWaySyncNoticeDelivery(kind: .first, rowID: "renamed:Health", title: Self.renamed.title, body: Self.renamed.detail),
        ])
        do { let due = board.deliveries(now: Self.t0 + 1); #expect(due.isEmpty) }
        // While the whole sync is stopped, once a day…
        do { let due = board.deliveries(now: Self.t0 + Self.day - 1); #expect(due.isEmpty) }
        do { let due = board.deliveries(now: Self.t0 + Self.day); #expect(due.map(\.rowID) == ["dropbox-not-running"]) }
        do { let due = board.deliveries(now: Self.t0 + 2 * Self.day - 1); #expect(due.isEmpty) }
        // …and anything else that waits, once a week.
        do { let due = board.deliveries(now: Self.t0 + 7 * Self.day - 1); #expect(due.map(\.rowID) == ["dropbox-not-running"]) }
        let week = board.deliveries(now: Self.t0 + 7 * Self.day)
        #expect(week.map(\.rowID) == ["renamed:Health"])
        #expect(week.map(\.kind) == [.reminder])
    }

    @Test func aGroupIsNotifiedAsOneRow() {
        var board = OneWaySyncNoticeBoard()
        for name in ["a", "b", "c", "d", "e"] { board.raise(Self.file("Legal/\(name).pdf")) }
        let due = board.deliveries(now: Self.t0)
        #expect(due.map(\.rowID) == ["group:Legal"])
        #expect(due.first?.title == "Legal: 5 files wait for you")
        // A sixth file is one the user hasn't heard of: the group's notification, once.
        board.raise(Self.file("Legal/f.pdf"))
        do { let due = board.deliveries(now: Self.t0 + 60); #expect(due.map(\.rowID) == ["group:Legal"]) }
        do { let due = board.deliveries(now: Self.t0 + 120); #expect(due.isEmpty) }
    }

    @Test func aClockMovedBackwardsWaitsAFullIntervalFromNow() {
        var board = OneWaySyncNoticeBoard()
        board.raise(Self.dropboxNotRunning)
        _ = board.deliveries(now: Self.t0 + 10 * Self.day)
        // The clock goes back nine days: nothing is sent, and the day starts again from here.
        do { let due = board.deliveries(now: Self.t0 + Self.day); #expect(due.isEmpty) }
        do { let due = board.deliveries(now: Self.t0 + 2 * Self.day - 1); #expect(due.isEmpty) }
        do { let due = board.deliveries(now: Self.t0 + 2 * Self.day); #expect(due.map(\.kind) == [.reminder]) }
    }

    // MARK: Saved

    @Test func rowsSurviveAQuit() throws {
        let scratch = OneWayScratch()
        let url = scratch.store.noticesURL
        var board = OneWaySyncNoticeBoard()
        board.raise(Self.renamed)
        board.raise(Self.dropboxOnly(3))
        _ = board.deliveries(now: Self.t0)
        _ = board.dismiss("dropbox-only")
        let store = OneWaySyncNoticeStore(url: url)
        store.save(board)
        store.flush()

        let relaunched = OneWaySyncNoticeStore(url: url).load()
        #expect(relaunched == .ready(board))
        // Including that it was notified, and what was dismissed.
        var read = try #require(relaunched.value)
        do { let due = read.deliveries(now: Self.t0 + Self.hour); #expect(due.isEmpty) }
        read.raise(Self.dropboxOnly(3))
        #expect(read.information.isEmpty)
    }

    @Test func savesLandInOrder() throws {
        let scratch = OneWayScratch()
        let store = OneWaySyncNoticeStore(url: scratch.store.noticesURL)
        var board = OneWaySyncNoticeBoard()
        for index in 0..<20 {
            board.raise(Self.file("Legal/\(index).pdf"))
            store.save(board)
        }
        store.flush()
        #expect(store.load().value?.rows.count == 20)
    }

    /// A save to be notified from is on disk when `saveNow` returns; a board already written
    /// isn't written again.
    @Test func saveNowIsOnDiskAtOnceAndAnUnchangedBoardIsNotRewritten() throws {
        let scratch = OneWayScratch()
        let url = scratch.store.noticesURL
        let store = OneWaySyncNoticeStore(url: url)
        var board = OneWaySyncNoticeBoard()
        board.raise(Self.renamed)
        store.saveNow(board)
        #expect(OneWaySyncNoticeStore(url: url).load().value == board)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        store.saveNow(board)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        // A rewrite renames a new file over the old one: a new inode.
        #expect(before != nil && before == after)
    }

    /// An unreadable file is moved aside, never written over: a newer build's rows survive a
    /// launch of an older one.
    @Test func anUnreadableFileIsKeptAside() throws {
        let scratch = OneWayScratch()
        let url = scratch.store.noticesURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":2,"rows":[]}"#.utf8).write(to: url)
        let reported = Reported()
        let store = OneWaySyncNoticeStore(url: url, reportFailure: { reported.append($0) })
        #expect(store.load(now: Self.t0) == .unreadable)
        let aside = url.deletingLastPathComponent().appendingPathComponent("notices.unreadable-\(Int(Self.t0.timeIntervalSince1970)).json")
        #expect(try Data(contentsOf: aside) == Data(#"{"version":2,"rows":[]}"#.utf8))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(reported.messages.count == 1)
    }

    @Test func aFailedSaveIsReported() throws {
        let scratch = OneWayScratch()
        let blocker = scratch.url.appendingPathComponent("not a folder")
        try Data().write(to: blocker)
        let reported = Reported()
        let store = OneWaySyncNoticeStore(url: blocker.appendingPathComponent("notices.json"),
                                          reportFailure: { reported.append($0) })
        store.save(OneWaySyncNoticeBoard())
        store.flush()
        #expect(reported.messages.count == 1)
        #expect(reported.messages.first?.hasPrefix("One-way sync couldn’t save Activity’s rows") == true)
    }

    @Test func everyButtonHasItsTitle() {
        #expect(OneWaySyncNoticeButton.allCases.count == Set(OneWaySyncNoticeButton.allCases.map(\.title)).count)
        #expect(OneWaySyncNoticeButton.syncFromThisMacInstead.title == "Sync From This Mac Instead…")
    }
}

final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ message: String) { lock.withLock { stored.append(message) } }
    var messages: [String] { lock.withLock { stored } }
}
