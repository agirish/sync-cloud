//
//  OneWaySyncAnswers.swift
//  SyncCloud
//

import Darwin
import Foundation

/// The two versions *Choose a Version…* shows, from a look.
public struct OneWaySyncVersions: Equatable, Sendable {
    public var iCloud: OneWaySyncItem?
    public var dropbox: OneWaySyncItem?
    /// The file's record, when the sync has one.
    public var record: UInt64?
    /// Where iCloud's file is, or would go back to.
    public var iCloudPath: String
    public var dropboxPath: String
    /// The Dropbox file is a conflicted copy Dropbox made of the synced file, not the synced
    /// file itself: told by the wait, never by the name, which a synced file can share.
    public var isConflictedCopy = false
    /// Both copies still hold the contents the record has for them, each with its own date: the
    /// same file, whatever the dates say (a pair adopted with two dates).
    public var sameAsRecorded = false

    /// *Copy Dropbox’s into iCloud* is offered only when iCloud's file is downloaded here, or gone.
    public var canCopyDropboxsIntoICloud: Bool { dropbox != nil && (iCloud?.isDownloaded ?? true) }
}

/// One removal or replacement waiting on the removal limit, as *Review…* lists it.
public struct OneWaySyncPendingRemoval: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case deleted
        case movedOut(to: String)
        case replaced
    }

    public var record: UInt64
    public var iCloudPath: String
    public var dropboxPath: String
    public var kind: Kind
    public var id: UInt64 { record }

    public init(record: UInt64, iCloudPath: String, dropboxPath: String, kind: Kind) {
        self.record = record
        self.iCloudPath = iCloudPath
        self.dropboxPath = dropboxPath
        self.kind = kind
    }
}

/// One change of a History entry that *Reverse in iCloud…* can undo in iCloud.
public struct OneWaySyncReversal: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// Renamed or moved: iCloud's item goes back to `to`.
        case moveBack(from: String, to: String, isFolder: Bool)
        /// Deleted or moved out in iCloud: the removed copy comes back to iCloud.
        case restore(removedPath: String, to: String)
        /// Edited in iCloud: the version this sync replaced goes back into iCloud.
        case previousVersion(keptAt: String, at: String)
        /// Moved in from a folder that isn't synced (EU): iCloud's file goes back to `to`, in that
        /// folder, which must still be there; nothing is made for it. The next sync then moves
        /// Dropbox's copy to SyncCloud Removed, as for any move out.
        case moveBackOut(from: String, to: String)
    }

    public var step: Int
    public var kind: Kind
    /// Why it can't be reversed now, shown in place of the tick; nil when it can.
    public var unavailable: String?
    public var id: Int { step }

    public init(step: Int, kind: Kind, unavailable: String? = nil) {
        self.step = step
        self.kind = kind
        self.unavailable = unavailable
    }

    /// The row's two halves: the item, and what reversing does.
    public var item: String {
        switch kind {
        case .moveBack(let from, _, _), .moveBackOut(let from, _): return from
        case .restore(_, let to): return to
        case .previousVersion(_, let at): return at
        }
    }

    public var summary: String {
        switch kind {
        case .moveBack(let from, let to, _):
            return OneWaySyncPath.parent(from) == OneWaySyncPath.parent(to)
                ? "rename back to \(OneWaySyncPath.name(to))" : "move back to \(OneWaySyncPath.parent(to).isEmpty ? "the top" : OneWaySyncPath.parent(to) + "/")"
        case .restore: return "bring back from SyncCloud Removed"
        case .previousVersion: return "return to the version this sync replaced"
        case .moveBackOut(let from, let to):
            let folder = OneWaySyncPath.parent(to).isEmpty ? "the top" : OneWaySyncPath.parent(to) + "/"
            // Renamed since it came in: it goes back under its old name too.
            return OneWaySyncPath.name(from) == OneWaySyncPath.name(to) ? "move back to \(folder)"
                : "move back to \(folder) as \(OneWaySyncPath.name(to))"
        }
    }
}

/// **The answers to Now's rows.** Each does one thing on disk and leaves the rest to the next
/// pass, which finds both sides agreeing and records them; none of them edits the record behind
/// the planner's back except where a folder's own record changes (renamed, stopped, removed).
///
/// Blocking, like the writer: the caller runs them off the main thread.
public enum OneWaySyncAnswers {

    // MARK: Finding the file a row is about

    /// The record a wait's subject names.
    public static func record(for subject: OneWaySyncWait.Subject, in record: OneWaySyncRecord) -> OneWaySyncFileRecord? {
        guard case .file(let iCloudPath, let dropboxPath) = subject else { return nil }
        return record.files.first { file in
            (iCloudPath.map { file.iCloudPath == $0 } ?? false)
                || (dropboxPath.map { OneWaySyncSide.dropbox.nameKey(file.dropboxPath) == OneWaySyncSide.dropbox.nameKey($0) } ?? false)
        }
    }

    /// The versions a file wait is about, as both sides hold them in `look`.
    public static func versions(for subject: OneWaySyncWait.Subject, in look: OneWaySyncLook) -> OneWaySyncVersions? {
        guard case .file(let iCloudPath, let dropboxPath) = subject else { return nil }
        let plan = look.plan
        if let file = record(for: subject, in: look.pass.record) {
            let i = plan.matches.iCloud.files[file.key].flatMap { match -> OneWaySyncItem? in
                if case .found(let item, _) = match { return item }
                return nil
            }
            var d = plan.matches.dropbox.files[file.key]?.item
            // A conflicted copy: the Dropbox file asked about is the copy, not the synced file.
            let copy = plan.waits.contains { wait in
                guard case .conflictedCopy = wait.reason, case .file(_, let waiting?) = wait.subject, let dropboxPath else { return false }
                return OneWaySyncSide.dropbox.nameKey(waiting) == OneWaySyncSide.dropbox.nameKey(dropboxPath)
            }
            if copy, let dropboxPath { d = look.dropboxItem(dropboxPath) }
            let same = !copy && i.map { !file.differs(from: $0, on: .iCloud) } == true && d.map { !file.differs(from: $0, on: .dropbox) } == true
            return OneWaySyncVersions(iCloud: i, dropbox: d, record: file.key, iCloudPath: i?.path ?? file.iCloudPath,
                                      dropboxPath: d?.path ?? file.dropboxPath, isConflictedCopy: copy, sameAsRecorded: same)
        }
        let i = iCloudPath.flatMap(look.iCloudItem)
        let d = dropboxPath.flatMap(look.dropboxItem)
        return OneWaySyncVersions(iCloud: i, dropbox: d, record: nil, iCloudPath: i?.path ?? iCloudPath ?? dropboxPath ?? "",
                                  dropboxPath: d?.path ?? dropboxPath ?? iCloudPath ?? "")
    }

    // MARK: Choose a Version

    /// *Use iCloud’s*: Dropbox's version goes to SyncCloud Removed, always kept, and iCloud's takes
    /// its place; with iCloud's deleted, Dropbox's is moved there alone. A conflicted copy is
    /// moved there too.
    public static func useICloudsVersion(_ versions: OneWaySyncVersions, writer: OneWaySyncWriter) throws {
        guard let d = versions.dropbox else { return }
        let expected = OneWaySyncExpectedState(d)
        if let i = versions.iCloud, !versions.isConflictedCopy {
            _ = try writer.replace(dropboxPath: d.path, with: i.path, needsDownload: !i.isDownloaded,
                                   previousIsDropboxEdit: true, expected: expected, recordedID: d.documentID)
        } else {
            _ = try writer.moveToRemoved(dropboxPath: d.path, cause: .deletedInICloud, iCloudPath: versions.iCloud?.path,
                                         expected: expected, recordedID: d.documentID)
        }
    }

    /// *Copy Dropbox’s into iCloud*: iCloud's current version is kept in SyncCloud Removed, then
    /// Dropbox's is written in its place, both coordinated. The next pass finds the two the same.
    public static func copyDropboxsIntoICloud(_ versions: OneWaySyncVersions, writer: OneWaySyncWriter) throws {
        guard let d = versions.dropbox, versions.canCopyDropboxsIntoICloud else { return }
        let source = try OneWaySyncDisk.url(d.path, in: writer.places.dropboxParent)
        let target = try OneWaySyncDisk.url(versions.iCloudPath, in: writer.places.iCloudParent)
        try writer.writeIntoICloud(from: source, at: target, iCloudPath: versions.iCloudPath, expected: OneWaySyncExpectedState(d))
    }

    // MARK: Match iCloud

    /// *Match iCloud* for a file changed in Dropbox: Dropbox's copy goes back to iCloud's name,
    /// and takes iCloud's contents when they differ (Dropbox's version kept); a copy deleted in
    /// Dropbox is copied again.
    public static func matchICloud(_ versions: OneWaySyncVersions, writer: OneWaySyncWriter) throws {
        guard let i = versions.iCloud else { return }
        guard var d = versions.dropbox, !versions.isConflictedCopy else {
            try writer.copy(from: i.path, to: i.path, needsDownload: !i.isDownloaded)
            return
        }
        if OneWaySyncPath.needsMove(from: d.path, to: i.path) {
            try writer.move(from: d.path, to: i.path, expected: OneWaySyncExpectedState(d))
            d.path = i.path
        }
        // Identical by the record, though dated apart: the name alone goes back, nothing uploads.
        let same = versions.sameAsRecorded || (d.size == i.size && d.second == i.second)
        if !same {
            _ = try writer.replace(dropboxPath: d.path, with: i.path, needsDownload: !i.isDownloaded,
                                   previousIsDropboxEdit: true, expected: OneWaySyncExpectedState(d), recordedID: d.documentID)
        }
    }

    /// *Match iCloud* for a synced folder renamed, moved or deleted in Dropbox: put back under its
    /// recorded name, or, if it is gone, made again with every synced file copied in. Returns the
    /// files that couldn't be copied, with why; the next pass compares them again.
    @discardableResult
    public static func matchICloudFolder(_ name: String, look: OneWaySyncLook, writer: OneWaySyncWriter) throws -> [String] {
        let key = OneWaySyncSide.dropbox.nameKey
        guard let folder = look.pass.record.syncedFolders.first(where: { key($0.iCloudPath) == key(name) || key($0.dropboxPath) == key(name) }) else { return [] }
        if let item = look.plan.matches.dropbox.folders[folder.key]?.item, key(item.path) != key(folder.dropboxPath) {
            try writer.move(from: item.path, to: folder.dropboxPath)
            return []
        }
        try OneWaySyncDisk.makeFolders(folder.dropboxPath, in: writer.places.dropboxParent)
        var failed: [String] = []
        for file in look.pass.record.files where key(OneWaySyncPath.top(file.dropboxPath)) == key(folder.dropboxPath) {
            guard case .found(let i, _) = look.plan.matches.iCloud.files[file.key] ?? .gone else { continue }
            do { try writer.copy(from: i.path, to: i.path, needsDownload: !i.isDownloaded) } catch {
                failed.append("\(i.path) (\(OneWaySyncRun.describe(error)))")
            }
        }
        return failed
    }

    // MARK: Stop syncing

    /// *Stop Syncing This File*: it becomes an exclusion, followed by its IDs, and its record goes.
    /// Dropbox's copy stays as it is.
    public static func stopSyncingFile(_ versions: OneWaySyncVersions, record: OneWaySyncRecord, exclusions: OneWaySyncExclusions,
                                       now: Date) -> (OneWaySyncRecord, OneWaySyncExclusions) {
        var record = record, exclusions = exclusions
        let file = versions.record.flatMap { key in record.files.first { $0.key == key } }
        exclusions.files.append(OneWaySyncExclusion(
            iCloudPath: versions.iCloud?.path ?? file?.iCloudPath ?? versions.iCloudPath,
            dropboxPath: versions.dropbox?.path ?? file?.dropboxPath ?? versions.dropboxPath,
            iCloudID: versions.iCloud?.documentID ?? file?.iCloudID, dropboxID: versions.dropbox?.documentID ?? file?.dropboxID,
            stoppedAt: OneWaySyncHistoryStore.seconds(now)))
        if let key = versions.record { record.files.removeAll { $0.key == key } }
        return (record, exclusions)
    }

    /// *Sync Again…*: the exclusion goes. The next pass compares the two files as on a first run
    /// would: the same contents are recorded, others wait.
    public static func syncAgain(_ exclusion: OneWaySyncExclusion, exclusions: OneWaySyncExclusions) -> OneWaySyncExclusions {
        var exclusions = exclusions
        exclusions.files.removeAll { $0 == exclusion }
        return exclusions
    }

    // MARK: Synced folders

    /// *Rename Dropbox’s Too*: Dropbox's folder takes iCloud's new name, and the record follows.
    public static func renameDropboxFolderToo(_ name: String, look: OneWaySyncLook, writer: OneWaySyncWriter) throws -> OneWaySyncRecord {
        let key = OneWaySyncSide.dropbox.nameKey
        var record = look.pass.record
        guard let index = record.syncedFolders.firstIndex(where: { key($0.iCloudPath) == key(name) }),
              case .found(let renamed, _) = look.plan.matches.iCloud.folders[record.syncedFolders[index].key] ?? .gone,
              OneWaySyncPath.depth(renamed.path) == 1 else { return record }
        let old = record.syncedFolders[index]
        try writer.move(from: old.dropboxPath, to: renamed.path)
        func moved(_ path: String, from top: String) -> String {
            key(OneWaySyncPath.top(path)) == key(top)
                ? ([renamed.path] + OneWaySyncPath.components(path).dropFirst()).joined(separator: "/") : path
        }
        record.syncedFolders[index].iCloudPath = renamed.path
        record.syncedFolders[index].dropboxPath = renamed.path
        record.syncedFolders[index].iCloudID = renamed.folderID ?? old.iCloudID
        for i in record.files.indices {
            record.files[i].iCloudPath = moved(record.files[i].iCloudPath, from: old.iCloudPath)
            record.files[i].dropboxPath = moved(record.files[i].dropboxPath, from: old.dropboxPath)
        }
        for i in record.subfolders.indices {
            record.subfolders[i].iCloudPath = moved(record.subfolders[i].iCloudPath, from: old.iCloudPath)
            record.subfolders[i].dropboxPath = moved(record.subfolders[i].dropboxPath, from: old.dropboxPath)
        }
        return record
    }

    /// *Move to SyncCloud Removed* for a synced folder moved or deleted in iCloud: every synced
    /// file in Dropbox's copy goes there, and the folder's record with them. The folder itself
    /// stays while it holds files only in Dropbox; emptied, it goes.
    public static func moveFolderToRemoved(_ name: String, look: OneWaySyncLook, writer: OneWaySyncWriter) -> (OneWaySyncRecord, failed: [String]) {
        let key = OneWaySyncSide.dropbox.nameKey
        var record = look.pass.record
        guard let folder = record.syncedFolders.first(where: { key($0.iCloudPath) == key(name) }) else { return (record, []) }
        var failed: [String] = []
        for file in record.files where key(OneWaySyncPath.top(file.dropboxPath)) == key(folder.dropboxPath) {
            guard let d = look.plan.matches.dropbox.files[file.key]?.item else { continue }
            do {
                let item = try writer.moveToRemoved(dropboxPath: d.path, cause: .deletedInICloud, iCloudPath: file.iCloudPath,
                                                    expected: OneWaySyncExpectedState(d), recordedID: file.dropboxID)
                record.removed.append(OneWaySyncRemovedFile(file: file, removedPath: item.path))
            } catch {
                failed.append(d.path)
            }
        }
        // What did move is in SyncCloud Removed now, not synced.
        let moved = Set(record.removed.map(\.file.key))
        record.files.removeAll { moved.contains($0.key) }
        if failed.isEmpty {
            record = OneWaySyncSetup.removing(name, from: record)
            if let url = try? OneWaySyncDisk.url(folder.dropboxPath, in: writer.places.dropboxParent) { removeEmptyFolders(url) }
        }
        return (record, failed)
    }

    /// Removes `url` and the folders inside it that hold nothing but empty folders and Finder's
    /// `.DS_Store`. Never a file: `rmdir` refuses a folder with anything in it.
    static func removeEmptyFolders(_ url: URL) {
        guard OneWaySyncDisk.kind(at: url.path) == .folder,
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return }
        for name in names where OneWaySyncDisk.kind(at: url.appendingPathComponent(name).path) == .folder {
            removeEmptyFolders(url.appendingPathComponent(name))
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        guard left.allSatisfy({ $0 == ".DS_Store" }) else { return }
        unlink(url.appendingPathComponent(".DS_Store").path)
        rmdir(url.path)
    }

    /// *Create in Dropbox & Sync*: the folder is made in the Dropbox parent when it is missing.
    public static func createInDropbox(_ name: String, places: OneWaySyncPlaces) throws {
        let dropboxParent = URL(fileURLWithPath: OneWaySyncDisk.canonicalPath(places.dropboxParent), isDirectory: true)
        try OneWaySyncDisk.makeFolders(name, in: dropboxParent)
    }

    // MARK: After a takeover

    /// Moves the Dropbox-only files at `paths` to SyncCloud Removed, as deleted in iCloud, each
    /// checked against the look first. Returns the ones that didn't go, with why.
    public static func removeDropboxOnly(_ paths: [String], look: OneWaySyncLook, writer: OneWaySyncWriter) -> [String] {
        let only = Set(look.plan.dropboxOnly.map(OneWaySyncSide.dropbox.nameKey))
        var failed: [String] = []
        for path in paths {
            guard only.contains(OneWaySyncSide.dropbox.nameKey(path)), let item = look.dropboxItem(path) else {
                failed.append("\(path) (it isn’t only in Dropbox now)")
                continue
            }
            do {
                _ = try writer.moveToRemoved(dropboxPath: path, cause: .deletedInICloud, iCloudPath: nil,
                                             expected: OneWaySyncExpectedState(item), recordedID: item.documentID)
            } catch {
                failed.append("\(path) (\(OneWaySyncRun.describe(error)))")
            }
        }
        return failed
    }

    // MARK: The removal limit

    /// What waits on the removal limit, in `folder` or across all folders.
    public static func pendingRemovals(in look: OneWaySyncLook, folder: String?) -> [OneWaySyncPendingRemoval] {
        let key = OneWaySyncSide.dropbox.nameKey
        var pending: [OneWaySyncPendingRemoval] = []
        for wait in look.plan.waits where wait.reason == .overRemovalLimit || wait.reason == .overRemovalLimitAcrossFolders {
            guard let file = record(for: wait.subject, in: look.pass.record) else { continue }
            if let folder, key(OneWaySyncPath.top(file.iCloudPath)) != key(folder) { continue }
            let kind: OneWaySyncPendingRemoval.Kind
            switch look.plan.matches.iCloud.files[file.key] ?? .gone {
            case .found: kind = .replaced
            case .movedOut(let item): kind = .movedOut(to: item.path)
            case .gone: kind = .deleted
            }
            pending.append(OneWaySyncPendingRemoval(record: file.key, iCloudPath: file.iCloudPath, dropboxPath: file.dropboxPath, kind: kind))
        }
        return pending.sorted { $0.iCloudPath < $1.iCloudPath }
    }

    /// *Keep in Dropbox* for removals and replacements left unticked: a removal's file stays in
    /// Dropbox as a Dropbox-only file, its record dropped; a replacement's keeps Dropbox's version
    /// and becomes a file you stopped syncing.
    public static func keepInDropbox(_ chosen: [OneWaySyncPendingRemoval], look: OneWaySyncLook, record: OneWaySyncRecord,
                                     exclusions: OneWaySyncExclusions, now: Date) -> (OneWaySyncRecord, OneWaySyncExclusions) {
        var record = record, exclusions = exclusions
        for item in chosen {
            guard let file = record.files.first(where: { $0.key == item.record }) else { continue }
            if item.kind == .replaced {
                exclusions.files.append(OneWaySyncExclusion(
                    iCloudPath: look.plan.matches.iCloud.files[file.key]?.item?.path ?? file.iCloudPath,
                    dropboxPath: look.plan.matches.dropbox.files[file.key]?.item?.path ?? file.dropboxPath,
                    iCloudID: file.iCloudID, dropboxID: file.dropboxID, stoppedAt: OneWaySyncHistoryStore.seconds(now)))
            }
            record.files.removeAll { $0.key == item.record }
        }
        return (record, exclusions)
    }

    // MARK: Reverse in iCloud

    /// What of `entry` can be reversed now: each change whose items are unchanged on both sides
    /// since, and whose iCloud copy is downloaded and current. An edit needs SyncCloud Removed to
    /// still hold the version it replaced; a removal, the removed copy. Swaps through a temporary
    /// name aren't offered. A file moved in from a folder that isn't synced is listed once its copy
    /// was confirmed, and marked unavailable with the reason when it can't go back.
    public static func reversals(of entry: OneWaySyncHistoryEntry, look: OneWaySyncLook, removed: [OneWaySyncRemovedItem]) -> [OneWaySyncReversal] {
        let held = Set(removed.map(\.path))
        func unchanged(_ recorded: OneWaySyncFileRecord?) -> Bool {
            guard let recorded else { return false }
            return whyChanged(recorded, look: look) == nil
        }
        var reversals: [OneWaySyncReversal] = []
        // Only what iCloud did: a move that undid a Dropbox rename, or a first run's rename of a
        // Dropbox file found by its contents, was never iCloud's to reverse.
        for (index, step) in entry.steps.enumerated() where step.status == .confirmed && !step.step.undoesDropboxChange {
            switch step.step.action {
            case .moveInDropbox(let from, let to):
                guard step.step.record != nil, ![from, to].contains(where: { OneWaySyncPath.name($0).hasPrefix(OneWaySyncPlanner.temporaryNamePrefix) }),
                      let recorded = step.recorded, unchanged(recorded), look.iCloudItem(from) == nil else { continue }
                reversals.append(OneWaySyncReversal(step: index, kind: .moveBack(from: recorded.iCloudPath, to: from, isFolder: false)))
            case .moveFolderInDropbox(let from, let to):
                guard let item = look.iCloudItem(to), item.kind == .folder, look.iCloudItem(from) == nil else { continue }
                reversals.append(OneWaySyncReversal(step: index, kind: .moveBack(from: to, to: from, isFolder: true)))
            case .moveToRemoved(_, let cause):
                guard case .deletedInICloud = cause, let keptAt = step.keptAt, held.contains(keptAt),
                      let recorded = step.recorded, look.iCloudItem(recorded.iCloudPath) == nil else { continue }
                reversals.append(OneWaySyncReversal(step: index, kind: .restore(removedPath: keptAt, to: recorded.iCloudPath)))
            case .replace(_, _, _, let previousIsDropboxEdit):
                guard !previousIsDropboxEdit, let keptAt = step.keptAt, held.contains(keptAt),
                      let recorded = step.recorded, unchanged(recorded) else { continue }
                reversals.append(OneWaySyncReversal(step: index, kind: .previousVersion(keptAt: keptAt, at: recorded.iCloudPath)))
            case .copy(let from, _, _):
                guard let origin = step.step.movedInFrom else { continue }
                let current = step.recorded?.iCloudPath ?? from
                reversals.append(OneWaySyncReversal(
                    step: index, kind: .moveBackOut(from: current, to: origin),
                    unavailable: whyNotMovedBack(step.recorded, to: origin, look: look)))
            default:
                continue
            }
        }
        return reversals
    }

    /// Why a file moved in can't go back to `origin` now, or nil when it can: it must be unchanged
    /// on both sides since the sync, and the folder it came from still there with the name free.
    static func whyNotMovedBack(_ recorded: OneWaySyncFileRecord?, to origin: String, look: OneWaySyncLook) -> String? {
        guard let recorded else { return "it didn’t finish syncing" }
        if let why = whyChanged(recorded, look: look) { return why }
        let folder = OneWaySyncPath.parent(origin)
        if !folder.isEmpty, look.iCloudItem(folder)?.kind != .folder { return "\(folder) isn’t in iCloud any more" }
        // Taken in any letter case: the disk on this Mac doesn't tell case apart.
        let taken = OneWaySyncSide.dropbox.nameKey(origin)
        if look.pass.iCloud.items.contains(where: { OneWaySyncSide.dropbox.nameKey($0.path) == taken }) {
            return "\(OneWaySyncPath.name(origin)) is taken in \(folder.isEmpty ? "iCloud" : folder)"
        }
        return nil
    }

    /// What changed about a file since it was recorded, in words, or nil when nothing did on either
    /// side and iCloud's copy is downloaded here.
    static func whyChanged(_ recorded: OneWaySyncFileRecord, look: OneWaySyncLook) -> String? {
        guard let i = look.iCloudItem(recorded.iCloudPath) else { return "it was moved or deleted in iCloud since" }
        guard let d = look.dropboxItem(recorded.dropboxPath) else { return "Dropbox’s copy was moved or deleted since" }
        guard i.size == recorded.size, i.second == recorded.modified, recorded.iCloudID == nil || i.documentID == recorded.iCloudID else {
            return "it changed in iCloud since"
        }
        guard d.size == recorded.size, d.second == recorded.modified(on: .dropbox) else { return "Dropbox’s copy changed since" }
        guard i.isDownloaded else { return "it isn’t downloaded in iCloud" }
        return nil
    }

    /// Reverses the chosen changes in iCloud, each coordinated; the sync then carries them to
    /// Dropbox as usual. Returns the ones that couldn't be.
    public static func reverse(_ chosen: [OneWaySyncReversal], writer: OneWaySyncWriter) -> [(OneWaySyncReversal, String)] {
        var failed: [(OneWaySyncReversal, String)] = []
        let iCloudParent = writer.places.iCloudParent
        for reversal in chosen {
            do {
                switch reversal.kind {
                case .moveBack(let from, let to, _):
                    let source = try OneWaySyncDisk.url(from, in: iCloudParent)
                    let target = try OneWaySyncDisk.url(to, in: iCloudParent)
                    try OneWaySyncDisk.coordinatedWrite(source, deadline: writer.coordinationDeadline) { _ in
                        try OneWaySyncDisk.makeFolders(OneWaySyncPath.parent(to), in: iCloudParent)
                        try OneWaySyncDisk.moveExclusively(source, to: target)
                    }
                case .restore(let removedPath, _):
                    guard let item = writer.removed.items().first(where: { $0.path == removedPath }) else {
                        throw OneWaySyncWriteError.missing(removedPath)
                    }
                    _ = try writer.removed.restoreToICloud(item, iCloudParent: iCloudParent, staging: writer.places.staging,
                                                           deadline: writer.coordinationDeadline)
                case .previousVersion(let keptAt, let at):
                    let source = try OneWaySyncDisk.url(keptAt, in: writer.places.dropboxAccountFolder)
                    let target = try OneWaySyncDisk.url(at, in: iCloudParent)
                    try writer.writeIntoICloud(from: source, at: target, iCloudPath: at, expected: nil)
                case .moveBackOut(let from, let to):
                    guard reversal.unavailable == nil else { throw OneWaySyncWriteError.badPath(to) }
                    let source = try OneWaySyncDisk.url(from, in: iCloudParent)
                    let target = try OneWaySyncDisk.url(to, in: iCloudParent)
                    // Into the folder as it is: one gone since isn't made again.
                    guard OneWaySyncDisk.kind(at: target.deletingLastPathComponent().path) == .folder else {
                        throw OneWaySyncWriteError.missing(target.deletingLastPathComponent().path)
                    }
                    try OneWaySyncDisk.coordinatedWrite(source, deadline: writer.coordinationDeadline) { _ in
                        try OneWaySyncDisk.moveExclusively(source, to: target)
                    }
                }
            } catch {
                failed.append((reversal, OneWaySyncRun.describe(error)))
            }
        }
        return failed
    }

    // MARK: Rename iCloud's

    /// *Rename iCloud’s…*: iCloud's file takes a name of the user's choosing, in its own folder.
    public static func renameICloudFile(_ path: String, to name: String, places: OneWaySyncPlaces, deadline: TimeInterval = 30) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw OneWaySyncWriteError.badPath(name) }
        let parent = URL(fileURLWithPath: OneWaySyncDisk.canonicalPath(places.iCloudParent), isDirectory: true)
        let source = try OneWaySyncDisk.url(path, in: parent)
        let target = try OneWaySyncDisk.url(OneWaySyncPath.join(OneWaySyncPath.parent(path), name), in: parent)
        try OneWaySyncDisk.coordinatedWrite(source, deadline: deadline) { _ in
            try OneWaySyncDisk.moveExclusively(source, to: target)
        }
    }
}

extension OneWaySyncWriter {
    /// Writes `source` (a Dropbox file, or a version in SyncCloud Removed) into iCloud at
    /// `target`, iCloud's current version kept first in SyncCloud Removed. Read and written
    /// coordinated; nothing of Dropbox's attributes comes along. A file already at `target` is
    /// renamed over, so iCloud keeps its item.
    func writeIntoICloud(from source: URL, at target: URL, iCloudPath: String, expected: OneWaySyncExpectedState?) throws {
        let staged = places.staging.appendingPathComponent(UUID().uuidString)
        defer { OneWaySyncDisk.removeStaged(staged) }
        try OneWaySyncDisk.coordinatedRead(source, deadline: coordinationDeadline) { read in
            let before = try OneWaySyncDisk.state(at: read.path)
            if let expected, !expected.matches(before, documentID: OneWaySyncDisk.documentID(at: read.path)) {
                throw OneWaySyncWriteError.changedSinceDiff(read.path)
            }
            try OneWaySyncDisk.copy(read, to: staged)
            guard try OneWaySyncDisk.state(at: read.path) == before else { throw OneWaySyncWriteError.changedDuringCopy(read.path) }
        }
        OneWaySyncDisk.forEachItem(staged.path) { removexattr($0, OneWaySyncRemovedStore.originAttribute, XATTR_NOFOLLOW) }

        var kept: OneWaySyncFileState?
        if OneWaySyncDisk.kind(at: target.path) != nil {
            // iCloud's current version, kept outside DG's and DJ's limits.
            let clone = places.staging.appendingPathComponent(UUID().uuidString)
            defer { OneWaySyncDisk.removeStaged(clone) }
            try OneWaySyncDisk.coordinatedRead(target, deadline: coordinationDeadline) { read in
                let before = try OneWaySyncDisk.state(at: read.path)
                try OneWaySyncDisk.copy(read, to: clone)
                guard try OneWaySyncDisk.state(at: read.path) == before else { throw OneWaySyncWriteError.changedDuringCopy(read.path) }
                kept = before
            }
            let accountPath = "iCloud/" + iCloudPath
            _ = try removed.moveInStaged(clone, origin: OneWaySyncRemovedItem.Origin(
                dropboxPath: accountPath, iCloudParent: places.iCloudParent.path, iCloudPath: iCloudPath,
                removedAt: Int64(now().timeIntervalSince1970), kind: .replacedICloudVersion))
        }
        try OneWaySyncDisk.coordinatedWrite(target, deadline: coordinationDeadline) { write in
            try OneWaySyncDisk.makeFolders(OneWaySyncPath.parent(iCloudPath), in: places.iCloudParent)
            if OneWaySyncDisk.kind(at: write.path) != nil {
                // An edit since the version was kept would be lost: it waits instead.
                if let kept, try OneWaySyncDisk.state(at: write.path) != kept { throw OneWaySyncWriteError.changedSinceDiff(write.path) }
                try OneWaySyncDisk.moveOver(staged, onto: write)
            } else {
                try OneWaySyncDisk.moveExclusively(staged, to: write)
            }
        }
    }
}
