//
//  OneWaySyncRemovalLimit.swift
//  SyncCloud
//

import Foundation

/// The removals and replacements SyncCloud made in Dropbox over the last 24 hours, for the removal
/// limit. Saved, so the window survives a quit.
///
/// Each change is timed by when SyncCloud saw it, not when it was applied, so a burst iCloud
/// delivers late still lands in one window. A clock moved backwards starts a fresh window, since
/// no saved time can then be trusted to be in the past.
public struct OneWaySyncRemovalWindow: Codable, Equatable, Sendable {

    public struct Change: Codable, Equatable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case deletedOrMovedOut
            case replaced
        }

        /// The file record's key: each file counts once, however often it changes.
        public var file: UInt64
        /// The synced folder's record key.
        public var folder: UInt64
        public var kind: Kind
        /// Seconds since 1970.
        public var seenAt: Int64

        public init(file: UInt64, folder: UInt64, kind: Kind, seenAt: Int64) {
            self.file = file
            self.folder = folder
            self.kind = kind
            self.seenAt = seenAt
        }
    }

    public static let span: Int64 = 24 * 60 * 60
    /// In one folder, more than this many files deleted, moved out or replaced.
    public static let folderCount = 25
    /// In one folder, more than this percentage of its files deleted or moved out…
    public static let folderPercent = 10
    /// …when that is also more than this many.
    public static let folderPercentFloor = 5
    /// Across all folders, more than this many.
    public static let acrossFolders = 50

    public var changes: [Change]

    public init(changes: [Change] = []) {
        self.changes = changes
    }

    /// The window as it stands at `now`: changes seen 24 hours ago or earlier dropped, and
    /// everything dropped if any saved time is later than `now`.
    public func current(at now: Int64) -> OneWaySyncRemovalWindow {
        if changes.contains(where: { $0.seenAt > now }) { return OneWaySyncRemovalWindow() }
        return OneWaySyncRemovalWindow(changes: changes.filter { now - $0.seenAt < Self.span })
    }

    public struct Verdict: Equatable, Sendable {
        /// Synced folders (record keys) over their own limit: every such change in them waits.
        public var overFolders: Set<UInt64>
        /// Distinct files counted across all folders.
        public var acrossCount: Int
        /// Over 50 across folders: the whole sync stops until reviewed.
        public var overAcrossFolders: Bool { acrossCount > OneWaySyncRemovalWindow.acrossFolders }
    }

    /// Whether `candidates`, the changes a pass would make, take any folder or the whole sync over
    /// the limit, counted together with the changes already in the window.
    ///
    /// `folderFileCounts` is each synced folder's recorded file count, for the percentage rule.
    /// Candidates always count, however long ago they were seen: they are about to be applied.
    public func verdict(
        adding candidates: [Change], folderFileCounts: [UInt64: Int], now: Int64
    ) -> Verdict {
        var all = Set<UInt64>()
        var perFolder: [UInt64: Set<UInt64>] = [:]
        var removedPerFolder: [UInt64: Set<UInt64>] = [:]
        for change in current(at: now).changes + candidates {
            all.insert(change.file)
            perFolder[change.folder, default: []].insert(change.file)
            if change.kind == .deletedOrMovedOut { removedPerFolder[change.folder, default: []].insert(change.file) }
        }
        var over = Set<UInt64>()
        for (folder, files) in perFolder {
            let removed = removedPerFolder[folder]?.count ?? 0
            let total = folderFileCounts[folder] ?? 0
            if files.count > Self.folderCount
                || (removed > Self.folderPercentFloor && removed * 100 > total * Self.folderPercent) {
                over.insert(folder)
            }
        }
        return Verdict(overFolders: over, acrossCount: all.count)
    }

    /// The window to save once `applied` have gone through.
    public func adding(_ applied: [Change], now: Int64) -> OneWaySyncRemovalWindow {
        var window = current(at: now)
        window.changes.append(contentsOf: applied)
        return window
    }
}
