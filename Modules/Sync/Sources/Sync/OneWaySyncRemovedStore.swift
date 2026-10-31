//
//  OneWaySyncRemovedStore.swift
//  SyncCloud
//

import Darwin
import Foundation

/// An item in Dropbox ▸ SyncCloud Removed: a file one-way sync took out of a synced folder, or a
/// version of one it replaced.
public struct OneWaySyncRemovedItem: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A version SyncCloud wrote, replaced by a newer one from iCloud. Only these count: one a
        /// day per file is kept (DG), and at most seven per file (DJ).
        case replacedSyncCloudVersion
        /// A version made in Dropbox, replaced by iCloud's. Always kept, never counted.
        case replacedDropboxVersion
        case deletedInICloud
        case movedOutInICloud
        /// Made redundant when a Dropbox-only file with the same contents was adopted.
        case duplicateOfAdoptedFile
        /// Nothing on the item says where it came from; its place in the folder still does.
        case unrecorded
    }

    /// Where the item came from, kept on the item itself so it survives Turn Off and a move.
    public struct Origin: Codable, Equatable, Sendable {
        /// Relative to the Dropbox account folder ("Documents/Finance/W-2.pdf").
        public var dropboxPath: String
        /// The iCloud parent at the time, and the file's path relative to it.
        public var iCloudParent: String?
        public var iCloudPath: String?
        /// The Dropbox file's document ID when this was taken from it. Replace keeps that ID on the
        /// live file, so it ties every version of one file together however it was renamed.
        public var fileID: UInt64?
        /// Seconds since 1970.
        public var removedAt: Int64
        public var kind: Kind

        public init(dropboxPath: String, iCloudParent: String? = nil, iCloudPath: String? = nil,
                    fileID: UInt64? = nil, removedAt: Int64, kind: Kind) {
            self.dropboxPath = dropboxPath
            self.iCloudParent = iCloudParent
            self.iCloudPath = iCloudPath
            self.fileID = fileID
            self.removedAt = removedAt
            self.kind = kind
        }
    }

    /// Relative to the Dropbox account folder ("SyncCloud Removed/2026-10-30/Documents/Finance/W-2.pdf").
    public var path: String
    public var origin: Origin
    /// Bytes, everything inside a package included.
    public var size: Int64

    /// Whether it is the same file as `other` came from: by document ID when both have one, else
    /// by Dropbox path, ignoring case as Dropbox does.
    func isSameFile(as fileID: UInt64?, dropboxPath: String) -> Bool {
        if let mine = origin.fileID, let fileID { return mine == fileID }
        return OneWaySyncSide.dropbox.nameKey(origin.dropboxPath) == OneWaySyncSide.dropbox.nameKey(dropboxPath)
    }
}

/// **Dropbox ▸ SyncCloud Removed**: everything one-way sync takes out of Dropbox, filed by date
/// under its Dropbox path, `SyncCloud Removed/<date>/<path in Dropbox>`.
///
/// - It is inside Dropbox, so a move into it is a rename: nothing downloads or uploads again, and
///   the item keeps its Dropbox ID.
/// - Items never overwrite each other: a taken name gets " 2", " 3"…, and every move in is
///   `RENAME_EXCL`.
/// - Each item says where it came from in an attribute of its own, which Turn Off leaves alone.
/// - It is emptied only when the user chooses (DB), apart from DJ: an eighth version SyncCloud
///   wrote of one file sends the oldest to Dropbox's own deleted files. Nothing goes to the Mac's
///   Trash.
public struct OneWaySyncRemovedStore: Sendable {
    public static let folderName = "SyncCloud Removed"
    /// DJ: replaced versions SyncCloud wrote, kept per file.
    public static let versionsKeptPerFile = 7
    /// Holds each item's `Origin`, as JSON.
    public static let originAttribute = "com.abhishekgirish.SyncCloud.removedFrom"

    public let accountFolder: URL
    /// Files the date folders, and decides what "a day" is for DG.
    public var calendar: Calendar

    /// `accountFolder` is taken canonical (its symlinks resolved): every move refuses a symlink
    /// on its path, so `~/Dropbox` would refuse them all.
    public init(accountFolder: URL, calendar: Calendar = .current) {
        self.accountFolder = URL(fileURLWithPath: OneWaySyncDisk.canonicalPath(accountFolder), isDirectory: true)
        self.calendar = calendar
    }

    public var root: URL { accountFolder.appendingPathComponent(Self.folderName, isDirectory: true) }

    /// The date folder's name for `date`, in the store's calendar ("2026-10-30").
    public func dayName(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Reading

    /// Every item, oldest first. An item is anything carrying an origin; else a file, or a
    /// package, below a date folder. Folders in between are only where items are filed.
    public func items() -> [OneWaySyncRemovedItem] {
        var found: [OneWaySyncRemovedItem] = []
        func walk(_ folder: URL, _ relative: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
            for name in names.sorted() {
                let url = folder.appendingPathComponent(name)
                let path = relative + "/" + name
                guard let kind = OneWaySyncDisk.kind(at: url.path), kind != .symlink else { continue }
                if let origin = Self.origin(at: url.path) {
                    found.append(item(at: url, path: path, origin: origin))
                } else if kind == .file || isPackage(url) {
                    guard !CloudAppStatusModel.isNeverUploaded(name: name) else { continue }
                    found.append(item(at: url, path: path, origin: unrecordedOrigin(path)))
                } else {
                    walk(url, path)
                }
            }
        }
        walk(root, Self.folderName)
        return found.sorted { ($0.origin.removedAt, $0.path) < ($1.origin.removedAt, $1.path) }
    }

    func item(at url: URL, path: String, origin: OneWaySyncRemovedItem.Origin) -> OneWaySyncRemovedItem {
        OneWaySyncRemovedItem(path: path, origin: origin, size: (try? OneWaySyncDisk.state(at: url.path).size) ?? 0)
    }

    func isPackage(_ url: URL) -> Bool {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    /// What an item's place in the store says: the date folder and the Dropbox path below it.
    func unrecordedOrigin(_ path: String) -> OneWaySyncRemovedItem.Origin {
        let parts = OneWaySyncPath.components(path).dropFirst()
        var removedAt: Int64 = 0
        if let day = parts.first {
            let numbers = day.split(separator: "-").compactMap { Int($0) }
            if numbers.count == 3, let date = calendar.date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2])) {
                removedAt = Int64(date.timeIntervalSince1970)
            }
        }
        return .init(dropboxPath: parts.dropFirst().joined(separator: "/"), removedAt: removedAt, kind: .unrecorded)
    }

    static func origin(at path: String) -> OneWaySyncRemovedItem.Origin? {
        OneWaySyncDisk.attribute(originAttribute, at: path).flatMap { try? JSONDecoder().decode(OneWaySyncRemovedItem.Origin.self, from: $0) }
    }

    // MARK: DG and DJ

    /// DG: whether Dropbox's previous version of a file is kept when iCloud's replaces it. A version
    /// made in Dropbox always is; one SyncCloud wrote, only if none of that file's was kept today.
    public func keepsPreviousVersion(fileID: UInt64?, dropboxPath: String, previousIsDropboxEdit: Bool,
                                     at now: Date, in items: [OneWaySyncRemovedItem]) -> Bool {
        if previousIsDropboxEdit { return true }
        return !items.contains {
            $0.origin.kind == .replacedSyncCloudVersion && $0.isSameFile(as: fileID, dropboxPath: dropboxPath)
                && calendar.isDate(Date(timeIntervalSince1970: TimeInterval($0.origin.removedAt)), inSameDayAs: now)
        }
    }

    /// DJ: the versions SyncCloud wrote of this file beyond the newest seven, oldest first. The
    /// one at `keeping` (the version just kept) is never among them, even when a clock set back
    /// dates it before the rest.
    public func versionsPastTheLimit(fileID: UInt64?, dropboxPath: String, keeping: String? = nil,
                                     in items: [OneWaySyncRemovedItem]) -> [OneWaySyncRemovedItem] {
        let versions = items.filter { $0.origin.kind == .replacedSyncCloudVersion && $0.isSameFile(as: fileID, dropboxPath: dropboxPath) }
            .sorted { ($0.origin.removedAt, $0.path) < ($1.origin.removedAt, $1.path) }
        let others = versions.filter { $0.path != keeping }
        let room = Self.versionsKeptPerFile - (others.count < versions.count ? 1 : 0)
        return Array(others.dropLast(room))
    }

    // MARK: Writing

    /// Moves `url`, already inside Dropbox, into the store, and records where it came from.
    /// A rename: nothing downloads, and the item keeps its Dropbox ID.
    func moveIn(_ url: URL, origin: OneWaySyncRemovedItem.Origin) throws -> OneWaySyncRemovedItem {
        guard OneWaySyncDisk.device(of: url.path) == OneWaySyncDisk.device(of: accountFolder.path) else {
            throw OneWaySyncWriteError.stagingUnusable(url.path)
        }
        let path = try place(url, origin: origin)
        let placed = try OneWaySyncDisk.url(path, in: accountFolder)
        // After the move: written before, a move that then failed would leave the live file
        // carrying a removal record. Without it, the store still reads the item by its place.
        try? OneWaySyncDisk.setAttribute(Self.originAttribute, try JSONEncoder().encode(origin), at: placed.path)
        ChangedFileLedger.shared.note(placed.path)
        return item(at: placed, path: path, origin: origin)
    }

    /// Moves a staged item (a clone of a Dropbox version) into the store, its origin written
    /// before it arrives, so nothing half-made ever shows in Dropbox.
    func moveInStaged(_ staged: URL, origin: OneWaySyncRemovedItem.Origin) throws -> OneWaySyncRemovedItem {
        try OneWaySyncDisk.setAttribute(Self.originAttribute, try JSONEncoder().encode(origin), at: staged.path)
        let path = try place(staged, origin: origin)
        let placed = try OneWaySyncDisk.url(path, in: accountFolder)
        ChangedFileLedger.shared.note(placed.path)
        return item(at: placed, path: path, origin: origin)
    }

    /// Moves `url` to the first free name at its place in the store and returns that place.
    private func place(_ url: URL, origin: OneWaySyncRemovedItem.Origin) throws -> String {
        let day = dayName(Date(timeIntervalSince1970: TimeInterval(origin.removedAt)))
        let parent = OneWaySyncPath.parent(origin.dropboxPath)
        let folderPath = OneWaySyncPath.join(Self.folderName + "/" + day, parent)
        let folder = try OneWaySyncDisk.makeFolders(folderPath, in: accountFolder)
        let name = OneWaySyncPath.name(origin.dropboxPath)
        for attempt in 1...10_000 {
            let candidate = Self.numbered(name, attempt)
            do {
                try OneWaySyncDisk.moveExclusively(url, to: folder.appendingPathComponent(candidate))
                return folderPath + "/" + candidate
            } catch OneWaySyncWriteError.nameTaken {
                continue
            }
        }
        throw OneWaySyncWriteError.nameTaken(folder.appendingPathComponent(name).path)
    }

    /// The longest name APFS takes, in UTF-16 code units (measured: 255 `é` or `書` go, a 256th
    /// doesn't; an emoji counts two), in the form it is sent: a `URL` sends names decomposed, so
    /// a precomposed `é` counts two. Not POSIX's `NAME_MAX`, which counts bytes.
    static let longestName = 255

    /// A name's length as the file system counts it, sent through a `URL`.
    static func sentLength(_ name: String) -> Int {
        URL(fileURLWithPath: "/").appendingPathComponent(name).lastPathComponent.utf16.count
    }

    /// "W-2.pdf", "W-2 2.pdf", "W-2 3.pdf"…, as Finder numbers a copy. A name already near the
    /// limit gives up the end of its stem, a whole character at a time, to make room.
    static func numbered(_ name: String, _ attempt: Int) -> String {
        guard attempt > 1 else { return name }
        var ext = (name as NSString).pathExtension
        var stem = (name as NSString).deletingPathExtension
        if ext.isEmpty || stem.isEmpty {
            stem = name
            ext = ""
        }
        let tail = " \(attempt)" + (ext.isEmpty ? "" : "." + ext)
        while !stem.isEmpty, sentLength(stem + tail) > Self.longestName { stem.removeLast() }
        return stem + tail
    }

    // MARK: Choose Items to Empty

    public enum EmptyOrder: Sendable {
        case oldestFirst
        case largestFirst
    }

    /// The items as *Choose Items to Empty…* lists them.
    public func itemsToEmpty(_ order: EmptyOrder) -> [OneWaySyncRemovedItem] {
        let all = items()
        switch order {
        case .oldestFirst: return all
        case .largestFirst: return all.sorted { ($1.size, $0.origin.removedAt, $0.path) < ($0.size, $1.origin.removedAt, $1.path) }
        }
    }

    /// The items removed before `date`.
    public func items(removedBefore date: Date) -> [OneWaySyncRemovedItem] {
        items().filter { $0.origin.removedAt < Int64(date.timeIntervalSince1970) }
    }

    public struct Emptied: Equatable, Sendable {
        public var emptied: [OneWaySyncRemovedItem] = []
        public var failed: [OneWaySyncRemovedItem] = []
        public var bytes: Int64 { emptied.reduce(0) { $0 + $1.size } }
    }

    /// Deletes the chosen items from Dropbox, which keeps them in its own deleted files; then
    /// any folder they leave empty. Never the Mac's Trash. An item is deleted only while what is
    /// at its place is still it: the same origin, or for one with none, still none and the same
    /// size. Anything else there now is left alone and the item reported as failed.
    public func empty(_ chosen: [OneWaySyncRemovedItem]) -> Emptied {
        var result = Emptied()
        for item in chosen {
            guard item.path.hasPrefix(Self.folderName + "/"),
                  let url = try? OneWaySyncDisk.url(item.path, in: accountFolder),
                  let kind = OneWaySyncDisk.kind(at: url.path), kind != .symlink,
                  isStill(item, at: url) else {
                result.failed.append(item)
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                result.emptied.append(item)
                pruneEmptyFolders(above: item.path)
            } catch {
                result.failed.append(item)
            }
        }
        return result
    }

    func isStill(_ item: OneWaySyncRemovedItem, at url: URL) -> Bool {
        let origin = Self.origin(at: url.path)
        if item.origin.kind == .unrecorded {
            return origin == nil && (try? OneWaySyncDisk.state(at: url.path).size) == item.size
        }
        return origin == item.origin
    }

    /// Removes the folders above `path` that hold nothing now (Finder's `.DS_Store` aside), up to
    /// the store itself, which stays. `rmdir`, never a recursive delete: an item that arrives
    /// meanwhile keeps its folder.
    func pruneEmptyFolders(above path: String) {
        var parent = OneWaySyncPath.parent(path)
        while parent != Self.folderName, parent.hasPrefix(Self.folderName + "/"),
              let url = try? OneWaySyncDisk.url(parent, in: accountFolder),
              OneWaySyncDisk.kind(at: url.path) == .folder,
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path),
              names.allSatisfy({ $0 == ".DS_Store" }) {
            unlink(url.appendingPathComponent(".DS_Store").path)
            guard rmdir(url.path) == 0 else { return }
            parent = OneWaySyncPath.parent(parent)
        }
    }

    // MARK: Restore to iCloud

    /// Copies an item back into iCloud at the path it came from, keeping both when that name is
    /// taken ("W-2 2.pdf"). The read and the write are coordinated, and the copy carries neither
    /// Dropbox's attributes nor the item's origin. The item stays in the store: putting it back
    /// in Dropbox is the sync's own step (`moveBackFromRemoved`). Returns where it went.
    public func restoreToICloud(_ item: OneWaySyncRemovedItem, iCloudParent: URL, staging: URL,
                                deadline: TimeInterval) throws -> URL {
        guard let iCloudPath = item.origin.iCloudPath else { throw OneWaySyncWriteError.missing(item.path) }
        let iCloudParent = URL(fileURLWithPath: OneWaySyncDisk.canonicalPath(iCloudParent), isDirectory: true)
        let staging = URL(fileURLWithPath: OneWaySyncDisk.canonicalPath(staging), isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let source = try OneWaySyncDisk.url(item.path, in: accountFolder)
        _ = try OneWaySyncDisk.url(iCloudPath, in: iCloudParent)
        let staged = staging.appendingPathComponent(UUID().uuidString)
        defer { OneWaySyncDisk.removeStaged(staged) }
        try OneWaySyncDisk.coordinatedRead(source, deadline: deadline) { read in
            let before = try OneWaySyncDisk.state(at: read.path)
            try OneWaySyncDisk.copy(read, to: staged)
            guard try OneWaySyncDisk.state(at: read.path) == before else { throw OneWaySyncWriteError.changedDuringCopy(read.path) }
        }
        OneWaySyncDisk.forEachItem(staged.path) { removexattr($0, Self.originAttribute, XATTR_NOFOLLOW) }

        let folder = try OneWaySyncDisk.coordinatedWrite(try OneWaySyncDisk.url(iCloudPath, in: iCloudParent).deletingLastPathComponent(),
                                                         deadline: deadline) { _ in
            try OneWaySyncDisk.makeFolders(OneWaySyncPath.parent(iCloudPath), in: iCloudParent)
        }
        let name = OneWaySyncPath.name(iCloudPath)
        for attempt in 1...10_000 {
            let destination = folder.appendingPathComponent(Self.numbered(name, attempt))
            do {
                try OneWaySyncDisk.coordinatedWrite(destination, deadline: deadline) { write in
                    try OneWaySyncDisk.moveExclusively(staged, to: write)
                }
                return destination
            } catch OneWaySyncWriteError.nameTaken {
                continue
            }
        }
        throw OneWaySyncWriteError.nameTaken(folder.appendingPathComponent(name).path)
    }
}
