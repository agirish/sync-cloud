//
//  OneWaySyncChangeCount.swift
//  SyncCloud
//

import Darwin
import Events
import Foundation
import UniformTypeIdentifiers

/// What the change count measures against: both parents, the synced folders on each side, and
/// what the record says is there — the last state both sides agreed on.
public struct OneWaySyncChangeScope: Sendable {
    struct Recorded: Equatable, Sendable {
        var size: Int64
        /// Whole seconds since 1970.
        var modified: Int64
    }

    /// Canonical paths, as the watcher's roots are spelled.
    public let iCloudParent: String
    public let dropboxParent: String
    /// The synced folders, each side's own name.
    public let iCloudFolders: [String]
    public let dropboxFolders: [String]
    var files: [OneWaySyncSide: [String: Recorded]] = [.iCloud: [:], .dropbox: [:]]
    var folders: [OneWaySyncSide: Set<String>] = [.iCloud: [], .dropbox: []]
    var excluded: [OneWaySyncSide: Set<String>] = [.iCloud: [], .dropbox: []]

    /// Keyed by each side's `nameKey`. A refused file counts as recorded as it was refused, on
    /// both sides: it stays skipped until it changes in iCloud (ES). A file you stopped syncing
    /// never counts.
    public init(record: OneWaySyncRecord, exclusions: OneWaySyncExclusions, iCloudParent: String, dropboxParent: String) {
        self.iCloudParent = iCloudParent
        self.dropboxParent = dropboxParent
        iCloudFolders = record.syncedFolders.map(\.iCloudPath)
        dropboxFolders = record.syncedFolders.map(\.dropboxPath)
        let i = OneWaySyncSide.iCloud.nameKey, d = OneWaySyncSide.dropbox.nameKey
        for folder in record.syncedFolders + record.subfolders {
            folders[.iCloud]?.insert(i(folder.iCloudPath))
            folders[.dropbox]?.insert(d(folder.dropboxPath))
        }
        for file in record.files {
            files[.iCloud]?[i(file.iCloudPath)] = Recorded(size: file.size, modified: file.modified)
            files[.dropbox]?[d(file.dropboxPath)] = Recorded(size: file.size, modified: file.dropboxModified ?? file.modified)
        }
        for file in record.refused {
            files[.iCloud]?[i(file.iCloudPath)] = Recorded(size: file.size, modified: file.modified)
            files[.dropbox]?[d(file.dropboxPath)] = Recorded(size: file.copySize, modified: file.copyModified)
        }
        for file in exclusions.files {
            excluded[.iCloud]?.insert(i(file.iCloudPath))
            excluded[.dropbox]?.insert(d(file.dropboxPath))
        }
    }

    /// The roots to watch: every synced folder on both sides.
    public var roots: [String] {
        iCloudFolders.map { iCloudParent + "/" + $0 } + dropboxFolders.map { dropboxParent + "/" + $0 }
    }

    func parent(_ side: OneWaySyncSide) -> String { side == .iCloud ? iCloudParent : dropboxParent }

    /// Whether an item's tagged path (`i:` or `d:`, then the path from its parent) can count: in a
    /// synced folder, and not a file you stopped syncing.
    func canCount(_ tagged: String) -> Bool {
        let (side, path) = Self.untag(tagged)
        let names = side == .iCloud ? iCloudFolders : dropboxFolders
        return names.contains { OneWaySyncDisk.isWithin(path, $0) } && excluded[side]?.contains(side.nameKey(path)) != true
    }

    static func tag(_ side: OneWaySyncSide, _ path: String) -> String { (side == .iCloud ? "i:" : "d:") + path }
    static func untag(_ tagged: String) -> (OneWaySyncSide, String) {
        (tagged.hasPrefix("i:") ? .iCloud : .dropbox, String(tagged.dropFirst(2)))
    }

    /// The side and the path relative to its parent of a path under one of the roots, or nil.
    func place(_ path: String) -> (OneWaySyncSide, String)? {
        for (side, names) in [(OneWaySyncSide.iCloud, iCloudFolders), (.dropbox, dropboxFolders)] {
            let parent = self.parent(side)
            for name in names where OneWaySyncDisk.isWithin(path, parent + "/" + name) {
                return (side, String(path.dropFirst(parent.count + 1)))
            }
        }
        return nil
    }
}

/// **Decision FV: how many items changed in the synced folders since the last completed Sync
/// Now** — the number the pill shows beside *Sync Now*. It suggests a sync; it never runs one.
///
/// The folder watcher says where something happened; the record decides whether it is a change.
/// An item counts while, read from disk, it differs from what the record holds: a file of another
/// size or date, a file or folder the record doesn't have, or a recorded one that is gone. So
/// iCloud downloading or offloading a file, Dropbox marking an upload, and the sync's own copies
/// (recorded once the pass ends) never count; a replay after a relaunch, which loses FSEvents'
/// mark on this process's writes, is judged the same way; and an item put back as it was (a file
/// back from the Trash, a rename undone, a temporary file gone again) stops counting.
///
/// - Each item counts once however often it changes: events are joined by path, inode and
///   document ID, so a rename (old path, new path) or an app's safe save is one item. A file and a
///   folder are each an item.
/// - Not counted at all: attribute-only changes (FU: an opened stamp, quarantine, tags), names the
///   sync never lists, symlinks, live libraries, files you stopped syncing; a change inside a
///   package counts as the package. This process's own changes count — they are your edits in
///   SyncCloud's panes. On a side the sync or Reverse is writing to (``holdOwnWrites(on:until:)``)
///   they are held, and judged against the record once the hold ends: what the pass recorded
///   doesn't count, what no pass recorded (one that stopped early, or never ran) does.
/// - When FSEvents can't say what changed (its history lost, events dropped, a synced folder
///   itself moved), or past ``limit`` items, the count is unknown: *Changes may be waiting*.
/// - Not seen: an edit that keeps a file's size and date, which Sync Now still catches by its
///   change time (ET); the change time also moves when iCloud downloads or offloads a file.
///
/// Saved when it changes, so a relaunch starts from the count it left and the watcher's replay
/// adds what happened while SyncCloud was closed. Thread-safe: the watcher's queue notes batches;
/// the main actor reads and resets.
public final class OneWaySyncChangeCount: @unchecked Sendable {
    /// Past this many items the count reads as unknown rather than a number, so its file stays small.
    public static let limit = 2_000

    struct Item: Codable, Equatable {
        /// `i:`/`d:` (the side), then `p:` and the path's name key, `n:` an inode or `o:` a document ID.
        var keys: [String]
        /// `i:` or `d:`, then the path from the side's parent: what is read again.
        var paths: [String]
        /// The newest event id that touched it.
        var newest: UInt64
    }

    struct Saved: Codable, Equatable {
        static let currentVersion = 1
        var version = Saved.currentVersion
        var items: [Item] = []
        /// The newest event id of a rescan, or of an item past ``limit``, since the last completed pass.
        var unknownSince: UInt64?
        /// The event id the last completed pass started at: nothing at or before it counts.
        var after: UInt64 = 0

        /// What a relaunch needs: everything but each item's newest id, which only orders an item
        /// against a pass this process runs.
        var shape: [[String]] { items.map { $0.keys + ["|"] + $0.paths } }
    }

    public struct Tally: Equatable, Sendable {
        public var count: Int
        public var isUnknown: Bool
        public init(count: Int = 0, isUnknown: Bool = false) {
            self.count = count
            self.isUnknown = isUnknown
        }
    }

    private let lock = NSLock()
    private let fileURL: URL?
    private var saved: Saved
    private var owner: [String: Int] = [:]
    private var scope: OneWaySyncChangeScope?
    private var holdOwnUntil: [OneWaySyncSide: Date] = [:]
    /// This process's changes on a held side, judged once its hold ends.
    private var held: [OneWaySyncSide: [Item]] = [:]

    /// Reads the count saved at `fileURL`; nil keeps it in memory only (a test).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        let data = fileURL.flatMap { try? Data(contentsOf: $0) }
        if let data, let read = try? JSONDecoder().decode(Saved.self, from: data), read.version == Saved.currentVersion {
            saved = read
        } else {
            saved = Saved()
            // A count that was there and couldn't be read can't vouch for anything.
            if data != nil { saved.unknownSince = 0 }
        }
        reindex()
    }

    public var tally: Tally {
        lock.lock(); defer { lock.unlock() }
        return Tally(count: saved.items.count, isUnknown: saved.unknownSince != nil)
    }

    /// The record and exclusions as they stand now; every later batch is judged against them. An
    /// item in a folder no longer synced (Choose Folders), or a file you stopped syncing, stops
    /// counting.
    public func use(_ scope: OneWaySyncChangeScope?) {
        lock.lock(); defer { lock.unlock() }
        self.scope = scope
        guard let scope else { return }
        let before = saved
        saved.items.removeAll { !$0.paths.contains(where: scope.canCount) }
        settle(since: before)
    }

    /// This process's changes on `side` are the sync's (a pass writing Dropbox, Reverse writing
    /// iCloud) until `date`, not yours.
    public func holdOwnWrites(on side: OneWaySyncSide, until date: Date) {
        lock.lock(); defer { lock.unlock() }
        holdOwnUntil[side] = date
    }

    /// Judges what a hold that has ended held back. Whether the tally changed. The controller
    /// calls it once a hold's grace is over; a batch or a pass does too.
    @discardableResult
    public func settleHolds(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let before = saved
        releaseHolds(now: now)
        return settle(since: before)
    }

    private func releaseHolds(now: Date) {
        guard let scope else { return }
        var judge = Judge(scope: scope)
        for (side, items) in held where now >= (holdOwnUntil[side] ?? .distantPast) {
            held[side] = nil
            for item in items where item.paths.contains(where: { scope.canCount($0) && judge.differs(tagged: $0) == true }) { add(item) }
        }
    }

    // MARK: Batches

    /// Notes what the watcher delivered. Whether the tally changed.
    @discardableResult
    public func note(_ batch: FolderWatchBatch, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let scope else { return false }
        let before = saved
        releaseHolds(now: now)
        for rescan in batch.rescans where rescan.id > saved.after {
            // At or under a synced folder, or above one (a moved parent).
            guard scope.place(rescan.path) != nil || scope.roots.contains(where: { OneWaySyncDisk.isWithin($0, rescan.path) }) else { continue }
            saved.unknownSince = max(saved.unknownSince ?? 0, rescan.id)
        }
        var judge = Judge(scope: scope)
        var foldersGone: [String] = []
        for event in batch.events where event.id > saved.after {
            guard !event.change.isOnlyExtendedAttributes, let (side, raw) = scope.place(event.path) else { continue }
            guard let (path, isPackage) = judge.item(raw, side: side) else { continue }
            let tagged = OneWaySyncChangeScope.tag(side, path)
            guard scope.canCount(tagged) else { continue }
            if event.change.contains(.isDirectory) && !event.change.isDisjoint(with: [.removed, .renamed]) { foldersGone.append(tagged) }
            let pathKey = (side == .iCloud ? "i:p:" : "d:p:") + side.nameKey(path)
            let tag = side == .iCloud ? "i:" : "d:"
            var keys = [pathKey]
            if !isPackage || path == raw {
                if let inode = event.fileID, inode != 0 { keys.append(tag + "n:\(inode)") }
                if let document = event.documentID, document != 0 { keys.append(tag + "o:\(document)") }
            }
            let item = Item(keys: keys, paths: [tagged], newest: event.id)
            if event.isOwn, let until = holdOwnUntil[side], now < until {
                held[side, default: []].append(item)
                continue
            }
            switch judge.differs(side, path, isPackage: isPackage) {
            case false?:
                // Back as recorded: the item it belongs to goes once none of its paths differ.
                if let index = owner[pathKey], !saved.items[index].paths.contains(where: { judge.differs(tagged: $0) != false }) {
                    saved.items.remove(at: index)
                    reindex()
                }
            case true?:
                // An item the record doesn't have, and that only had its attributes or owner
                // touched, was there before: nothing here makes it new.
                if !judge.isRecorded(side, path) && event.change.isDisjoint(with: [.created, .removed, .renamed, .modified]) { continue }
                add(item)
            case nil:
                // Offloaded: nothing here can tell, so it neither counts nor stops counting.
                continue
            }
        }
        // A folder moved or deleted takes its contents with it, and they have no events of their own.
        for folder in foldersGone {
            let inside = saved.items.indices.filter { index in
                saved.items[index].paths.allSatisfy { $0 != folder && OneWaySyncDisk.isWithin($0, folder) }
                    && !saved.items[index].paths.contains(where: { judge.differs(tagged: $0) != false })
            }
            guard !inside.isEmpty else { continue }
            for index in inside.reversed() { saved.items.remove(at: index) }
            reindex()
        }
        return settle(since: before)
    }

    /// Saves what changed since `before` and says whether the tally did.
    @discardableResult
    private func settle(since before: Saved) -> Bool {
        if saved.shape != before.shape || saved.unknownSince != before.unknownSince || saved.after != before.after { persist() }
        return Tally(count: before.items.count, isUnknown: before.unknownSince != nil)
            != Tally(count: saved.items.count, isUnknown: saved.unknownSince != nil)
    }

    private func add(_ item: Item) {
        let joined = Set(item.keys.compactMap { owner[$0] }).sorted()
        guard let first = joined.first else {
            guard saved.items.count < Self.limit else {
                saved.unknownSince = max(saved.unknownSince ?? 0, item.newest)
                return
            }
            saved.items.append(item)
            for key in item.keys { owner[key] = saved.items.count - 1 }
            return
        }
        var merged = saved.items[first]
        for index in joined.dropFirst() {
            merged.keys += saved.items[index].keys
            merged.paths += saved.items[index].paths
            merged.newest = max(merged.newest, saved.items[index].newest)
        }
        merged.keys = Array(Set(merged.keys + item.keys)).sorted()
        merged.paths = Array(Set(merged.paths + item.paths)).sorted()
        merged.newest = max(merged.newest, item.newest)
        saved.items[first] = merged
        if joined.count > 1 {
            for index in joined.dropFirst().reversed() { saved.items.remove(at: index) }
            reindex()
        } else {
            for key in merged.keys { owner[key] = first }
        }
    }

    private func reindex() {
        owner = [:]
        for (index, item) in saved.items.enumerated() { for key in item.keys { owner[key] = index } }
    }

    // MARK: A pass

    /// A Sync Now completed, having started at event id `startedAt` (read before its checks),
    /// judged against the record it saved (``use(_:)`` first). What changed before it started is
    /// synced, waits in Now's rows, or is nothing to sync (a Dropbox-only file): the count starts
    /// again, except for what the pass left for a later one (`leftForLater`, paths from the
    /// parents, see ``OneWaySyncRunResult/leftForLater(record:)``) that still differs. What changed
    /// while it ran still counts if it differs from the new record. A pass you stopped reset
    /// nothing it didn't sync: every item is read again.
    public func passCompleted(startedAt: UInt64, stopped: Bool, leftForLater: [String] = []) {
        lock.lock(); defer { lock.unlock() }
        guard let scope else { return }
        let before = saved
        releaseHolds(now: Date())
        let later = leftForLater.map(OneWaySyncSide.dropbox.nameKey)
        func isLeft(_ tagged: String) -> Bool {
            let path = OneWaySyncSide.dropbox.nameKey(OneWaySyncChangeScope.untag(tagged).1)
            return later.contains { OneWaySyncDisk.isWithin(path, $0) }
        }
        if !stopped {
            saved.after = max(saved.after, startedAt)
            saved.items.removeAll { $0.newest <= startedAt && !$0.paths.contains(where: isLeft) }
            if let unknown = saved.unknownSince, unknown <= startedAt { saved.unknownSince = nil }
        }
        var judge = Judge(scope: scope)
        // Kept while one of its paths differs, or can't be read without a download.
        saved.items.removeAll { item in
            !item.paths.contains { scope.canCount($0) && judge.differs(tagged: $0) != false }
        }
        reindex()
        settle(since: before)
    }

    /// Forgets everything: the sync was turned off or set up again.
    public func reset(after id: UInt64) {
        lock.lock(); defer { lock.unlock() }
        saved = Saved(after: id)
        held = [:]
        reindex()
        persist()
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: fileURL, options: .atomic)
        } catch {
            Logger.shared.warning("One-way sync: the change count couldn’t be saved: \(error.localizedDescription)")
        }
    }

    // MARK: Judging one item

    /// One batch's reads of the disk, each at most once: a package's walk, which many events
    /// inside it would otherwise repeat, and every item's answer.
    struct Judge {
        let scope: OneWaySyncChangeScope
        /// Keyed by the tagged path: the same folder names are on both sides.
        private var packages: [String: Bool] = [:]
        private var answers: [String: Bool?] = [:]

        init(scope: OneWaySyncChangeScope) { self.scope = scope }

        /// The item an event's path stands for: the path itself, or the outermost package holding
        /// it. Nil for what the sync never syncs.
        mutating func item(_ path: String, side: OneWaySyncSide) -> (path: String, isPackage: Bool)? {
            let parent = scope.parent(side)
            let names = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            for (index, name) in names.enumerated() {
                if OneWaySyncLister.isNeverListed(name) || OneWaySyncLister.refusedByDropbox.contains(name) { return nil }
                if OneWaySyncLister.liveLibraryExtensions.contains((name as NSString).pathExtension.lowercased()) { return nil }
                // The synced folder itself is never a package.
                guard index > 0 else { continue }
                let prefix = names[...index].joined(separator: "/")
                let tagged = OneWaySyncChangeScope.tag(side, prefix)
                let isPackage: Bool
                if let known = packages[tagged] { isPackage = known } else {
                    isPackage = OneWaySyncChangeCount.isPackage(name, at: parent + "/" + prefix)
                    packages[tagged] = isPackage
                }
                if isPackage { return (prefix, true) }
            }
            return (names.joined(separator: "/"), false)
        }

        func isRecorded(_ side: OneWaySyncSide, _ path: String) -> Bool {
            let key = side.nameKey(path)
            return scope.files[side]?[key] != nil || scope.folders[side]?.contains(key) == true
        }

        mutating func differs(tagged: String) -> Bool? {
            let (side, path) = OneWaySyncChangeScope.untag(tagged)
            let isPackage = item(path, side: side)?.isPackage ?? false
            return differs(side, path, isPackage: isPackage)
        }

        /// Whether the item at `path` on `side`, read now, isn't what the record holds; nil when
        /// that can't be read without downloading it.
        mutating func differs(_ side: OneWaySyncSide, _ path: String, isPackage: Bool) -> Bool? {
            let tagged = OneWaySyncChangeScope.tag(side, path)
            if let known = answers[tagged] { return known }
            let answer = read(side, path, isPackage: isPackage)
            answers[tagged] = answer
            return answer
        }

        private func read(_ side: OneWaySyncSide, _ path: String, isPackage: Bool) -> Bool? {
            let key = side.nameKey(path)
            let recorded = scope.files[side]?[key]
            let full = scope.parent(side) + "/" + path
            var info = stat()
            guard lstat(full, &info) == 0 else {
                // Gone, or unreadable: a change only where the record had something.
                return isRecorded(side, path)
            }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                guard let recorded else { return true }
                return Int64(info.st_size) != recorded.size || Int64(info.st_mtimespec.tv_sec) != recorded.modified
            case S_IFDIR where isPackage:
                guard let recorded else { return true }
                // Offloaded: reading inside would download it, as the lister never does.
                if MaterializationStatus.isDataless(flags: info.st_flags) { return nil }
                guard let state = try? OneWaySyncDisk.state(at: full) else { return true }
                return state.size != recorded.size || state.modifiedSecond != recorded.modified
            case S_IFDIR:
                return scope.folders[side]?.contains(key) != true
            case S_IFLNK:
                // Never synced; a recorded item replaced by one is gone.
                return isRecorded(side, path)
            default:
                return false
            }
        }
    }

    /// A package by its extension's type, else by what the disk says (one read, only for a name
    /// with an extension): a package that is gone is still known by its type.
    static func isPackage(_ name: String, at path: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return false }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .package) { return true }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
}

extension OneWaySyncRunResult {
    /// What this pass left for a later one, as paths from the parents: steps that didn't go through
    /// (stopped, still changing in Dropbox, Dropbox full), deletions still inside their 30 minutes
    /// (`record` is the one the pass saved), and folders not fully listed. A change there still
    /// counts after the pass (FV).
    public func leftForLater(record: OneWaySyncRecord) -> [String] {
        var paths = look.plan.steps.indices.filter { !outcomes[$0].counts }.flatMap { OneWaySyncRun.dropboxPaths(of: look.plan.steps[$0].action) }
        for file in record.files where file.iCloudGoneSince != nil { paths += [file.iCloudPath, file.dropboxPath] }
        paths += look.plan.notFullyListed
        return Array(Set(paths)).sorted()
    }
}
