import Foundation
@testable import Sync

/// Two parents in sync, for RD67 planner tests: every recorded file is on both sides exactly as
/// recorded, and a test changes one side or the other before planning.
///
/// A recorded file numbered n (1-based, in `files` order) has iCloud ID n, Dropbox ID n + 10,000,
/// 2,000 bytes, date `t0` and hash "h<n>"; its record key is n. Folders carry an inode and a
/// provider item ID in iCloud and an inode alone in Dropbox, so both ways of finding a folder run.
struct OneWayWorld {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static let binding = OneWaySyncBinding(
        hardwareID: "HW-1", iCloudAccount: "icloud-account", dropboxAccountFolder: "/Users/me/Library/CloudStorage/Dropbox",
        dataVolumeUUID: "VOL-1")

    var record: OneWaySyncRecord
    var iCloud: [OneWaySyncItem] = []
    var dropbox: [OneWaySyncItem] = []
    var iCloudIncomplete: Set<String> = []
    var dropboxIncomplete: Set<String> = []

    init(folders: [String] = ["Finance"], subfolders: [String] = [], files: [String] = [], firstRun: Bool = false) {
        record = OneWaySyncRecord(
            binding: Self.binding,
            iCloudParent: OneWaySyncParentRecord(path: "/Users/me/Documents"),
            dropboxParent: OneWaySyncParentRecord(path: "/Users/me/Library/CloudStorage/Dropbox/Documents"))
        var key: UInt64 = 1000
        for path in folders + subfolders {
            key += 1
            let iCloudID = OneWaySyncFolderID(inode: key, providerItemID: "icloud-\(key)")
            let dropboxID = OneWaySyncFolderID(inode: key + 50_000)
            let folder = OneWaySyncFolderRecord(
                key: key, iCloudPath: path, dropboxPath: path, iCloudID: iCloudID, dropboxID: dropboxID,
                firstRunCompleted: !firstRun)
            if folders.contains(path) { record.syncedFolders.append(folder) } else { record.subfolders.append(folder) }
            iCloud.append(OneWaySyncItem(path: path, kind: .folder, folderID: iCloudID))
            dropbox.append(OneWaySyncItem(path: path, kind: .folder, folderID: dropboxID))
        }
        for (index, path) in files.enumerated() {
            let id = UInt64(index + 1)
            record.files.append(OneWaySyncFileRecord(
                key: id, iCloudPath: path, dropboxPath: path, iCloudID: id, dropboxID: id + 10_000,
                size: 2000, modified: Int64(Self.t0.timeIntervalSince1970), contentHash: "h\(id)"))
            iCloud.append(Self.file(path, id: id, hash: "h\(id)"))
            dropbox.append(Self.file(path, id: id + 10_000, hash: "h\(id)"))
        }
        record.nextKey = key + 1
    }

    static func file(
        _ path: String, id: UInt64?, size: Int64 = 2000, modified: Date = t0, hash: String?,
        tags: [String] = [], downloaded: Bool = true, excluded: Bool = false
    ) -> OneWaySyncItem {
        OneWaySyncItem(
            path: path, kind: .file, documentID: id, size: size, modified: modified, tags: tags,
            contentHash: hash, isDownloaded: downloaded, isExcluded: excluded)
    }

    static func folder(_ path: String, inode: UInt64, excluded: Bool = false) -> OneWaySyncItem {
        OneWaySyncItem(path: path, kind: .folder, folderID: OneWaySyncFolderID(inode: inode), isExcluded: excluded)
    }

    private static func items(_ side: OneWaySyncSide) -> WritableKeyPath<OneWayWorld, [OneWaySyncItem]> {
        side == .iCloud ? \.iCloud : \.dropbox
    }

    func key(_ path: String) -> UInt64 { record.files.first { $0.iCloudPath == path }!.key }

    func item(_ side: OneWaySyncSide, _ path: String) -> OneWaySyncItem? { self[keyPath: Self.items(side)].first { $0.path == path } }

    /// Renames or moves the item at `from` and everything below it.
    mutating func rename(_ side: OneWaySyncSide, _ from: String, to: String) {
        let found = self[keyPath: Self.items(side)].contains { $0.path == from }
        precondition(found, "no \(from) in \(side)")
        for index in self[keyPath: Self.items(side)].indices {
            let path = self[keyPath: Self.items(side)][index].path
            if path == from {
                self[keyPath: Self.items(side)][index].path = to
            } else if path.hasPrefix(from + "/") {
                self[keyPath: Self.items(side)][index].path = to + path.dropFirst(from.count)
            }
        }
    }

    mutating func update(_ side: OneWaySyncSide, _ path: String, _ change: (inout OneWaySyncItem) -> Void) {
        let index = self[keyPath: Self.items(side)].firstIndex { $0.path == path }
        precondition(index != nil, "no \(path) in \(side)")
        change(&self[keyPath: Self.items(side)][index!])
    }

    /// New contents: 3,000 bytes, a minute later, hash "edited" unless given.
    mutating func edit(_ side: OneWaySyncSide, _ path: String, size: Int64 = 3000, hash: String = "edited") {
        update(side, path) {
            $0.size = size
            $0.contentHash = hash
            $0.modified = Self.t0.addingTimeInterval(60)
        }
    }

    /// Deletes the item at `path` and everything below it.
    mutating func delete(_ side: OneWaySyncSide, _ path: String) {
        let before = self[keyPath: Self.items(side)].count
        self[keyPath: Self.items(side)].removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
        precondition(self[keyPath: Self.items(side)].count < before, "no \(path) in \(side)")
    }

    mutating func add(_ side: OneWaySyncSide, _ item: OneWaySyncItem) {
        self[keyPath: Self.items(side)].append(item)
    }

    mutating func setGoneSince(_ path: String, _ date: Date?) {
        let index = record.files.firstIndex { $0.iCloudPath == path }!
        record.files[index].iCloudGoneSince = date.map { Int64($0.timeIntervalSince1970) }
    }

    func pass(
        settings: OneWaySyncSettings = OneWaySyncSettings(), now: Date = t0.addingTimeInterval(3600),
        window: OneWaySyncRemovalWindow = OneWaySyncRemovalWindow(), confirmed: Set<UInt64> = []
    ) -> OneWaySyncPass {
        OneWaySyncPass(
            record: record,
            iCloud: OneWaySyncListing(items: iCloud, incompleteFolders: iCloudIncomplete),
            dropbox: OneWaySyncListing(items: dropbox, incompleteFolders: dropboxIncomplete),
            settings: settings, window: window, confirmed: confirmed, now: now)
    }

    func plan(
        settings: OneWaySyncSettings = OneWaySyncSettings(), now: Date = t0.addingTimeInterval(3600),
        window: OneWaySyncRemovalWindow = OneWaySyncRemovalWindow(), confirmed: Set<UInt64> = []
    ) -> OneWaySyncPlan {
        OneWaySyncPlanner.plan(pass(settings: settings, now: now, window: window, confirmed: confirmed))
    }
}

extension OneWaySyncPlan {
    var waitReasons: [OneWaySyncWaitReason] { waits.map(\.reason) }
}
