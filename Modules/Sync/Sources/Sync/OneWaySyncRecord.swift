//
//  OneWaySyncRecord.swift
//  SyncCloud
//

import Foundation

/// RD67's memory of the last state both sides agreed on: one-way sync from iCloud Drive ▸ Documents
/// to Dropbox ▸ Documents.
///
/// Each side is diffed against this record, never against the other side, so it is the only
/// thing that can tell "deleted in iCloud" from "added in Dropbox". It is tied to this Mac and
/// these accounts and this disk (`binding`): a record carried anywhere else would read every
/// difference as a change to apply, so any mismatch means a new first run, which the user starts.
///
/// Paths are relative to each side's parent folder, `/`-separated, and start with the synced
/// folder's name ("Finance/2026/W-2.pdf"). Dates are whole seconds since 1970, because the design
/// compares dates to the second.
public struct OneWaySyncRecord: Codable, Equatable, Sendable {
    /// The layout this build writes. A record of any other version is never read as this one.
    public static let currentVersion = 1

    public var version: Int
    public var binding: OneWaySyncBinding
    public var iCloudParent: OneWaySyncParentRecord
    public var dropboxParent: OneWaySyncParentRecord
    /// The folders directly inside both parents that the user ticked.
    public var syncedFolders: [OneWaySyncFolderRecord]
    /// Folders below the synced folders, followed by their own IDs so a renamed or moved folder
    /// becomes one move in Dropbox rather than a move per file.
    public var subfolders: [OneWaySyncFolderRecord]
    public var files: [OneWaySyncFileRecord]
    /// Files SyncCloud moved to Dropbox ▸ SyncCloud Removed because iCloud deleted them. If the
    /// iCloud ID turns up again, the file is moved back rather than uploaded again.
    public var removed: [OneWaySyncRemovedFile]
    /// The next unused `key`, shared by folder and file records.
    public var nextKey: UInt64

    public init(
        version: Int = OneWaySyncRecord.currentVersion,
        binding: OneWaySyncBinding,
        iCloudParent: OneWaySyncParentRecord,
        dropboxParent: OneWaySyncParentRecord,
        syncedFolders: [OneWaySyncFolderRecord] = [],
        subfolders: [OneWaySyncFolderRecord] = [],
        files: [OneWaySyncFileRecord] = [],
        removed: [OneWaySyncRemovedFile] = [],
        nextKey: UInt64 = 1
    ) {
        self.version = version
        self.binding = binding
        self.iCloudParent = iCloudParent
        self.dropboxParent = dropboxParent
        self.syncedFolders = syncedFolders
        self.subfolders = subfolders
        self.files = files
        self.removed = removed
        self.nextKey = nextKey
    }
}

/// What a record belongs to. Any field differing from the running Mac's means a new first run.
public struct OneWaySyncBinding: Codable, Equatable, Sendable {
    public var hardwareID: String
    public var iCloudAccount: String
    /// The Dropbox account folder's path, which names the account (`~/Library/CloudStorage/Dropbox`).
    public var dropboxAccountFolder: String
    public var dataVolumeUUID: String

    public init(hardwareID: String, iCloudAccount: String, dropboxAccountFolder: String, dataVolumeUUID: String) {
        self.hardwareID = hardwareID
        self.iCloudAccount = iCloudAccount
        self.dropboxAccountFolder = dropboxAccountFolder
        self.dataVolumeUUID = dataVolumeUUID
    }

    /// Why a record bound to `self` can't be used on `current`, or nil when it can. An empty
    /// field on either side is a mismatch: a value that couldn't be read can't confirm anything.
    public func mismatch(with current: OneWaySyncBinding) -> OneWaySyncNewFirstRunReason? {
        func differs(_ a: String, _ b: String) -> Bool { a.isEmpty || b.isEmpty || a != b }
        if differs(hardwareID, current.hardwareID) { return .otherMac }
        if differs(iCloudAccount, current.iCloudAccount) { return .otherICloudAccount }
        if differs(dropboxAccountFolder, current.dropboxAccountFolder) { return .otherDropboxAccount }
        if differs(dataVolumeUUID, current.dataVolumeUUID) { return .otherDisk }
        return nil
    }
}

/// A parent folder as set up: its path, and the link it goes through, if any, with that link's
/// target. The parent's own link is followed once and remembered; if it changes, the sync stops.
public struct OneWaySyncParentRecord: Codable, Equatable, Sendable {
    public var path: String
    public var link: String?
    public var linkTarget: String?

    public init(path: String, link: String? = nil, linkTarget: String? = nil) {
        self.path = path
        self.link = link
        self.linkTarget = linkTarget
    }
}

/// A folder's own identity on one side: its inode and the provider's item ID.
public struct OneWaySyncFolderID: Codable, Hashable, Sendable {
    public var inode: UInt64?
    public var providerItemID: String?

    public init(inode: UInt64? = nil, providerItemID: String? = nil) {
        self.inode = inode
        self.providerItemID = providerItemID
    }

    /// The key a recorded folder is looked up by: the provider's item ID when there is one, which
    /// survives a rename made on another device, else the inode. Nil when neither is set, since
    /// an empty ID is never used.
    var lookupKey: String? {
        if let providerItemID, !providerItemID.isEmpty { return "p:" + providerItemID }
        if let inode, inode != 0 { return "i:\(inode)" }
        return nil
    }

    /// Every key a folder on disk can be found by.
    var allKeys: [String] {
        var keys: [String] = []
        if let providerItemID, !providerItemID.isEmpty { keys.append("p:" + providerItemID) }
        if let inode, inode != 0 { keys.append("i:\(inode)") }
        return keys
    }
}

public struct OneWaySyncFolderRecord: Codable, Equatable, Sendable {
    public var key: UInt64
    public var iCloudPath: String
    public var dropboxPath: String
    public var iCloudID: OneWaySyncFolderID?
    public var dropboxID: OneWaySyncFolderID?
    /// Read only for a synced folder: false until its first run is applied. A folder synced again
    /// after Stop Syncing starts over with a first run. No default: a folder recorded without
    /// saying would skip its first run.
    public var firstRunCompleted: Bool

    public init(
        key: UInt64, iCloudPath: String, dropboxPath: String,
        iCloudID: OneWaySyncFolderID? = nil, dropboxID: OneWaySyncFolderID? = nil,
        firstRunCompleted: Bool
    ) {
        self.key = key
        self.iCloudPath = iCloudPath
        self.dropboxPath = dropboxPath
        self.iCloudID = iCloudID
        self.dropboxID = dropboxID
        self.firstRunCompleted = firstRunCompleted
    }

    func path(on side: OneWaySyncSide) -> String { side == .iCloud ? iCloudPath : dropboxPath }
    func id(on side: OneWaySyncSide) -> OneWaySyncFolderID? { side == .iCloud ? iCloudID : dropboxID }
}

public struct OneWaySyncFileRecord: Codable, Equatable, Sendable {
    public var key: UInt64
    public var iCloudPath: String
    public var dropboxPath: String
    /// Document IDs. Never 0: an empty ID is never recorded.
    public var iCloudID: UInt64?
    public var dropboxID: UInt64?
    public var size: Int64
    /// Modification date in whole seconds since 1970.
    public var modified: Int64
    public var tags: [String]
    public var contentHash: String?
    /// When SyncCloud first saw the file gone from iCloud, in seconds. It is removed from Dropbox
    /// only once it has been gone 30 minutes and is still gone at a later full check.
    public var iCloudGoneSince: Int64?
    /// When SyncCloud last put iCloud's version back after the file was deleted, renamed or moved
    /// in Dropbox. A second such change within a day waits for the user.
    public var matchedICloudAt: Int64?

    public init(
        key: UInt64, iCloudPath: String, dropboxPath: String,
        iCloudID: UInt64?, dropboxID: UInt64?,
        size: Int64, modified: Int64, tags: [String] = [], contentHash: String? = nil,
        iCloudGoneSince: Int64? = nil, matchedICloudAt: Int64? = nil
    ) {
        self.key = key
        self.iCloudPath = iCloudPath
        self.dropboxPath = dropboxPath
        self.iCloudID = iCloudID
        self.dropboxID = dropboxID
        self.size = size
        self.modified = modified
        self.tags = tags
        self.contentHash = contentHash
        self.iCloudGoneSince = iCloudGoneSince
        self.matchedICloudAt = matchedICloudAt
    }

    func path(on side: OneWaySyncSide) -> String { side == .iCloud ? iCloudPath : dropboxPath }
    func id(on side: OneWaySyncSide) -> UInt64? { side == .iCloud ? iCloudID : dropboxID }
}

public struct OneWaySyncRemovedFile: Codable, Equatable, Sendable {
    /// The file as it was synced when SyncCloud removed it.
    public var file: OneWaySyncFileRecord
    /// Where it went, relative to the Dropbox parent's account folder (`SyncCloud Removed/…`).
    public var removedPath: String

    public init(file: OneWaySyncFileRecord, removedPath: String) {
        self.file = file
        self.removedPath = removedPath
    }
}

/// Why a stored record can't be used, so the sync stops with *Needs a new first run*. It never
/// runs one on its own.
public enum OneWaySyncNewFirstRunReason: Equatable, Sendable {
    case noRecord
    case unreadable
    case unsupportedVersion(Int)
    case otherMac
    case otherICloudAccount
    case otherDropboxAccount
    case otherDisk
    /// The record is fine but Dropbox holds no marker naming a Mac (`OneWaySyncMacMarker`):
    /// turned off on another Mac, or the marker was lost, so this Mac can't tell it still owns
    /// the sync.
    case noMarker
}

public enum OneWaySyncRecordLoad: Equatable, Sendable {
    case ready(OneWaySyncRecord)
    case needsNewFirstRun(OneWaySyncNewFirstRunReason)
}

public extension OneWaySyncRecord {

    /// Reads a stored record for the Mac and accounts described by `binding`. The version is read
    /// on its own first, so a record from a newer build is reported as such rather than as
    /// unreadable, and never half-decoded.
    static func load(_ data: Data?, on binding: OneWaySyncBinding) -> OneWaySyncRecordLoad {
        guard let data else { return .needsNewFirstRun(.noRecord) }
        struct Header: Decodable { var version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            return .needsNewFirstRun(.unreadable)
        }
        guard header.version == currentVersion else {
            return .needsNewFirstRun(.unsupportedVersion(header.version))
        }
        guard let record = try? JSONDecoder().decode(OneWaySyncRecord.self, from: data) else {
            return .needsNewFirstRun(.unreadable)
        }
        if let reason = record.binding.mismatch(with: binding) { return .needsNewFirstRun(reason) }
        return .ready(record)
    }

    /// The stored form. Keys are sorted so an unchanged record writes the same bytes.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
