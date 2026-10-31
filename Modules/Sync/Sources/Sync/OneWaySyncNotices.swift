//
//  OneWaySyncNotices.swift
//  SyncCloud
//

import Darwin
import Events
import Foundation

/// A row in Activity ▸ Now for one-way sync (DC): under *Needs you*, something waiting for the
/// user, or under *For your information*.
///
/// Saved, so it survives a quit. A *Needs you* row stays until answered or until its cause clears,
/// and can't be dismissed; an information row is dismissed item by item and comes back if what
/// it says changes.
public struct OneWaySyncNotice: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case needsYou
        case information
    }

    /// What waits: the page's three groups. A file row names its synced folder, so more than
    /// three in one folder can group into one.
    public enum Scope: Codable, Hashable, Sendable {
        case wholeSync
        case folder(String)
        case file(folder: String, path: String)
    }

    /// The cause. Raising the same cause again updates this row rather than adding one, and sends
    /// no second notification.
    public var id: String
    public var kind: Kind
    public var scope: Scope
    public var title: String
    public var detail: String?
    public var buttons: [OneWaySyncNoticeButton]
    /// When the row first appeared, in seconds.
    public var raisedAt: Int64
    /// An information row that sends its one notification anyway: SyncCloud Removed passing 10%
    /// of this Mac's free space. Information rows send none otherwise, and never a reminder.
    public var notifiesOnce: Bool
    /// The last notification or reminder this row sent, in seconds; nil before the first.
    public var notifiedAt: Int64?

    public init(
        id: String, kind: Kind, scope: Scope, title: String, detail: String? = nil,
        buttons: [OneWaySyncNoticeButton] = [], raisedAt: Date, notifiesOnce: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.scope = scope
        self.title = title
        self.detail = detail
        self.buttons = buttons
        self.raisedAt = OneWaySyncHistoryStore.seconds(raisedAt)
        self.notifiesOnce = notifiesOnce
    }

    /// What a dismissal is matched against: a row saying something else is a new state.
    var says: String { title + "\n" + (detail ?? "") }
}

/// The buttons the design's rows carry, by their titles.
public enum OneWaySyncNoticeButton: String, Codable, CaseIterable, Sendable {
    case openDropbox = "Open Dropbox"
    case openICloudSettings = "Open iCloud Settings"
    case showThem = "Show Them"
    case grantAccess = "Grant Access…"
    case retry = "Retry"
    case chooseItemsToEmpty = "Choose Items to Empty…"
    case review = "Review…"
    case findFolder = "Find Folder…"
    case turnOff = "Turn Off One-Way Sync…"
    case reviewFirstRun = "Review First Run…"
    case syncFromThisMacInstead = "Sync From This Mac Instead…"
    case renameDropboxsToo = "Rename Dropbox’s Too"
    case moveToSyncCloudRemoved = "Move to SyncCloud Removed"
    case stopSyncing = "Stop Syncing"
    case matchICloud = "Match iCloud"
    case downloadFolderList = "Download Folder List"
    case chooseAVersion = "Choose a Version…"
    case stopSyncingThisFile = "Stop Syncing This File"
    case showBoth = "Show Both"
    case renameIClouds = "Rename iCloud’s…"
    case syncNow = "Sync Now"
    case createInDropboxAndSync = "Create in Dropbox & Sync"

    public var title: String { rawValue }
}

/// Now's rows as shown: more than three file rows in one folder fold into one.
public struct OneWaySyncNoticeRow: Equatable, Sendable, Identifiable {
    /// The notice's own id, or `group:<folder>` for a folded group. A notification names it, so
    /// its click picks this row out.
    public var id: String
    public var title: String
    public var detail: String?
    public var buttons: [OneWaySyncNoticeButton]
    /// The notices it shows: one, or the group's files.
    public var members: [OneWaySyncNotice]
    /// The newest member's.
    public var raisedAt: Int64

    public var stopsTheWholeSync: Bool { members.contains { $0.scope == .wholeSync } }
}

/// A notification due now: a row's first, or its reminder.
public struct OneWaySyncNoticeDelivery: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case first
        case reminder
    }

    public var kind: Kind
    /// The row a click opens Now on.
    public var rowID: String
    public var title: String
    public var body: String?

    public init(kind: Kind, rowID: String, title: String, body: String?) {
        self.kind = kind
        self.rowID = rowID
        self.title = title
        self.body = body
    }
}

/// Every saved row, and the information rows the user dismissed.
public struct OneWaySyncNoticeBoard: Codable, Equatable, Sendable, OneWaySyncEmpty {
    public static let currentVersion = 1

    /// While the whole sync is stopped, a row reminds once a day (DM)…
    public static let wholeSyncReminder: Int64 = 24 * 60 * 60
    /// …and anything else that waits, once a week.
    public static let otherReminder: Int64 = 7 * 24 * 60 * 60
    /// More than this many file rows in one folder fold into one.
    public static let fileRowsBeforeGrouping = 3

    /// The defaults key for *Notify me when something needs me*, set at setup. Its own opt-in,
    /// apart from General's background-completion notifications, and posting with SyncCloud in
    /// front too. Off until setup turns it on.
    public static let notifyKey = "oneWaySyncNotifications"

    public var version: Int
    public var rows: [OneWaySyncNotice]
    /// Dismissed information rows by id, with what each said when dismissed.
    public var dismissed: [String: String]
    /// When an information row that sends its one notification sent it, kept through a
    /// dismissal: SyncCloud Removed's size changing after one isn't a second.
    public var informed: [String: Int64]

    public init(version: Int = OneWaySyncNoticeBoard.currentVersion, rows: [OneWaySyncNotice] = [],
                dismissed: [String: String] = [:], informed: [String: Int64] = [:]) {
        self.version = version
        self.rows = rows
        self.dismissed = dismissed
        self.informed = informed
    }

    public static var empty: OneWaySyncNoticeBoard { OneWaySyncNoticeBoard() }

    // MARK: Changing

    /// Adds `notice`, or updates the row its cause already has: the words and buttons are the
    /// new ones, the time it appeared and its last notification are kept. An information row
    /// the user dismissed stays dismissed while it says the same.
    public mutating func raise(_ notice: OneWaySyncNotice) {
        if notice.kind == .information, let said = dismissed[notice.id] {
            if said == notice.says { return }
            dismissed[notice.id] = nil
        }
        guard let index = rows.firstIndex(where: { $0.id == notice.id }) else {
            var added = notice
            if added.kind == .information, let sent = informed[added.id] { added.notifiedAt = sent }
            rows.append(added)
            return
        }
        var updated = notice
        if rows[index].kind == notice.kind {
            updated.raisedAt = rows[index].raisedAt
            updated.notifiedAt = rows[index].notifiedAt
        }
        rows[index] = updated
    }

    /// The row was answered, or its cause cleared. If the cause comes back, it is a new row with
    /// its own notification; an information row the user had dismissed comes back too.
    public mutating func clear(_ id: String) {
        rows.removeAll { $0.id == id }
        dismissed[id] = nil
        informed[id] = nil
    }

    /// Clears every row `matches` picks: the rows of a folder no longer synced, or every row when
    /// another Mac takes the sync over.
    public mutating func clear(where matches: (OneWaySyncNotice) -> Bool) {
        for row in rows where matches(row) {
            dismissed[row.id] = nil
            informed[row.id] = nil
        }
        rows.removeAll(where: matches)
    }

    /// Dismisses an information row. A *Needs you* row can't be dismissed: false, and it stays.
    @discardableResult
    public mutating func dismiss(_ id: String) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].kind == .information else { return false }
        dismissed[id] = rows[index].says
        rows.remove(at: index)
        return true
    }

    // MARK: Reading

    /// *Needs you*, as shown: rows that stop the whole sync first, then newest first, with more
    /// than three file rows in one folder folded into one.
    public var needsYou: [OneWaySyncNoticeRow] {
        let waiting = rows.filter { $0.kind == .needsYou }
        var filesByFolder: [String: [OneWaySyncNotice]] = [:]
        for notice in waiting {
            if case .file(let folder, _) = notice.scope { filesByFolder[folder, default: []].append(notice) }
        }
        var shown: [OneWaySyncNoticeRow] = []
        var grouped: Set<String> = []
        for notice in waiting {
            if case .file(let folder, _) = notice.scope,
               let files = filesByFolder[folder], files.count > Self.fileRowsBeforeGrouping {
                guard grouped.insert(folder).inserted else { continue }
                shown.append(OneWaySyncNoticeRow(
                    id: "group:" + folder, title: "\(folder): \(files.count) files wait for you",
                    detail: "Everything else keeps syncing.", buttons: [.review],
                    members: files, raisedAt: files.map(\.raisedAt).max() ?? notice.raisedAt))
            } else {
                shown.append(OneWaySyncNoticeRow(
                    id: notice.id, title: notice.title, detail: notice.detail, buttons: notice.buttons,
                    members: [notice], raisedAt: notice.raisedAt))
            }
        }
        return shown.sorted {
            if $0.stopsTheWholeSync != $1.stopsTheWholeSync { return $0.stopsTheWholeSync }
            if $0.raisedAt != $1.raisedAt { return $0.raisedAt > $1.raisedAt }
            return $0.id < $1.id
        }
    }

    /// *For your information*, newest first.
    public var information: [OneWaySyncNotice] {
        rows.filter { $0.kind == .information }.sorted {
            $0.raisedAt != $1.raisedAt ? $0.raisedAt > $1.raisedAt : $0.id < $1.id
        }
    }

    /// The row `id` names now: a notification's row, or a notice folded into a group since.
    public func shownRow(for id: String) -> String? {
        if let row = needsYou.first(where: { $0.id == id || $0.members.contains { $0.id == id } }) { return row.id }
        return information.first { $0.id == id }?.id
    }

    // MARK: Notifications

    /// The notifications due at `now`, marked sent: each *Needs you* row's first, then a reminder
    /// once a day for a row that stops the whole sync and once a week for any other; an
    /// information row's one, when it sends one. A group is notified as one row, when a file in
    /// it has never been.
    ///
    /// A time saved later than `now` means the clock went back: it is reset to `now`, sending
    /// nothing, so the reminder waits a full interval from here rather than for the clock to
    /// catch up.
    public mutating func deliveries(now date: Date) -> [OneWaySyncNoticeDelivery] {
        let now = OneWaySyncHistoryStore.seconds(date)
        var due: [OneWaySyncNoticeDelivery] = []
        var sent: Set<String> = []
        var reset: Set<String> = []
        for row in needsYou {
            let ids = row.members.map(\.id)
            let times = row.members.map(\.notifiedAt)
            if times.contains(where: { $0 == nil }) {
                due.append(OneWaySyncNoticeDelivery(kind: .first, rowID: row.id, title: row.title, body: row.detail))
                sent.formUnion(ids)
                continue
            }
            let last = times.compactMap { $0 }.max()!
            if last > now {
                reset.formUnion(ids)
                continue
            }
            let interval = row.stopsTheWholeSync ? Self.wholeSyncReminder : Self.otherReminder
            if now - last >= interval {
                due.append(OneWaySyncNoticeDelivery(kind: .reminder, rowID: row.id, title: row.title, body: row.detail))
                sent.formUnion(ids)
            }
        }
        for row in information where row.notifiesOnce && row.notifiedAt == nil {
            due.append(OneWaySyncNoticeDelivery(kind: .first, rowID: row.id, title: row.title, body: row.detail))
            sent.insert(row.id)
            informed[row.id] = now
        }
        for index in rows.indices where sent.contains(rows[index].id) || reset.contains(rows[index].id) {
            rows[index].notifiedAt = now
        }
        return due
    }
}

/// `notices.json`. Saves go to one serial queue, in order, so the main actor never waits on a
/// flush to disk — except `saveNow`, for a board about to be notified from, which must be on
/// disk before the notification goes: a crash between the two then costs a notification rather
/// than repeating one. A board equal to the last one written isn't written again; a failed write
/// is retried by the next save.
public final class OneWaySyncNoticeStore: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "com.abhishekgirish.SyncCloud.one-way-sync-notices")
    private let reportFailure: @Sendable (String) -> Void
    /// Read and written only on `queue`.
    private var written: OneWaySyncNoticeBoard?

    public init(url: URL, reportFailure: @escaping @Sendable (String) -> Void = { message in
        Task { @MainActor in _ = Logger.shared.error(message) }
    }) {
        self.url = url
        self.reportFailure = reportFailure
    }

    /// The saved board. An unreadable file (a newer build's, or damaged) is moved aside to
    /// `notices.unreadable-<time>.json`, not written over, and reported; the board starts empty.
    public func load(now: Date = Date()) -> OneWaySyncLoad<OneWaySyncNoticeBoard> {
        let load: OneWaySyncLoad<OneWaySyncNoticeBoard> = .read(url, currentVersion: OneWaySyncNoticeBoard.currentVersion)
        switch load {
        case .ready(let board):
            queue.sync { written = board }
        case .unreadable:
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("notices.unreadable-\(OneWaySyncHistoryStore.seconds(now)).json")
            if rename(url.path, aside.path) == 0 {
                reportFailure("One-way sync couldn’t read Activity’s saved rows; kept them as \(aside.lastPathComponent)")
            } else {
                reportFailure("One-way sync couldn’t read Activity’s saved rows at \(url.path)")
            }
        }
        return load
    }

    public func save(_ board: OneWaySyncNoticeBoard) {
        queue.async { self.write(board) }
    }

    /// Saves and waits for the write.
    public func saveNow(_ board: OneWaySyncNoticeBoard) {
        queue.sync { write(board) }
    }

    /// Waits for every save asked for so far: at quit.
    public func flush() {
        queue.sync {}
    }

    private func write(_ board: OneWaySyncNoticeBoard) {
        guard board != written else { return }
        do {
            try OneWaySyncFiles.writeDurably(OneWaySyncStore.encode(board), to: url)
            written = board
        } catch {
            reportFailure("One-way sync couldn’t save Activity’s rows: \(error)")
        }
    }
}
