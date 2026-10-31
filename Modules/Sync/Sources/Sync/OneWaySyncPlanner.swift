//
//  OneWaySyncPlanner.swift
//  SyncCloud
//

import Foundation

/// The two DA settings: what SyncCloud does when a synced Dropbox file is changed directly.
public struct OneWaySyncSettings: Codable, Equatable, Sendable {
    public enum WhenDeletedRenamedOrMoved: String, Codable, Sendable {
        case matchICloud
        case askMe
    }

    public enum WhenEdited: String, Codable, Sendable {
        case askMe
        case useICloud
    }

    public var whenDeletedRenamedOrMoved: WhenDeletedRenamedOrMoved
    public var whenEdited: WhenEdited

    public init(whenDeletedRenamedOrMoved: WhenDeletedRenamedOrMoved = .matchICloud, whenEdited: WhenEdited = .askMe) {
        self.whenDeletedRenamedOrMoved = whenDeletedRenamedOrMoved
        self.whenEdited = whenEdited
    }
}

public enum OneWaySyncRemovalCause: Codable, Equatable, Sendable {
    case deletedInICloud
    /// Moved in iCloud to a folder that isn't synced, or into a shared one.
    case movedOutInICloud(to: String)
    /// Renamed in iCloud onto a Dropbox-only file with identical contents, which was adopted; this
    /// is the old Dropbox copy it makes redundant.
    case duplicateOfAdoptedFile(String)
}

/// One step of a plan, in the order it is applied. Paths are relative to the parents; each is the
/// item's path at the moment the step runs, after the steps before it.
///
/// Steps, waits and their reasons are saved in History entries (`OneWaySyncHistoryStore`) in
/// their synthesized Codable form, so renaming a case or an argument label changes what an older
/// entry reads as: bump `OneWaySyncHistoryEntry.currentVersion` with it.
public enum OneWaySyncAction: Codable, Equatable, Sendable {
    /// A folder below a synced folder renamed or moved in iCloud: one move, nothing uploaded.
    case moveFolderInDropbox(from: String, to: String)
    case moveToRemoved(dropboxPath: String, cause: OneWaySyncRemovalCause)
    /// Writes iCloud's file over Dropbox's, keeping the Dropbox item. Dropbox's previous version
    /// goes to SyncCloud Removed; `previousIsDropboxEdit` means Dropbox made that version, so it
    /// is always kept and never counts toward the seven SyncCloud keeps per file.
    case replace(dropboxPath: String, with: String, needsDownload: Bool, previousIsDropboxEdit: Bool)
    case moveInDropbox(from: String, to: String)
    case moveBackFromRemoved(removedPath: String, to: String)
    case copy(from: String, to: String, needsDownload: Bool)
    /// Nothing written: the two files are recorded as synced.
    case adopt(iCloudPath: String, dropboxPath: String)
    case setTags(dropboxPath: String, tags: [String])
    /// Gone from both sides: the record is dropped.
    case forget(dropboxPath: String)
}

public enum OneWaySyncWaitReason: Codable, Equatable, Sendable {
    case editedInDropbox
    case editedOnBothSides
    case deletedInICloudEditedInDropbox
    /// The *Deleted, renamed or moved* setting is Ask Me.
    case deletedOrMovedInDropbox
    /// Deleted, renamed or moved in Dropbox again within a day of SyncCloud undoing it.
    case changedInDropboxAgainToday
    case changedOnBothSides
    case conflictedCopy(of: String)
    case nameTakenByDropboxOnlyFile(String)
    case nameTaken(String)
    case dropboxNewerOnFirstRun
    case sameDateOnFirstRun
    case futureDateOnFirstRun
    case overRemovalLimit
    case overRemovalLimitAcrossFolders
    case syncedFolderRenamedInICloud(to: String)
    case syncedFolderMovedOrDeletedInICloud
    case syncedFolderChangedInDropbox
    /// Its Dropbox name is held by a file whose removal hasn't gone through yet.
    case waitingForRemovalOf(String)
    /// Same size on both sides, contents not read yet. The plan lists the files to read
    /// (`iCloudContentsToRead`, `dropboxContentsToRead`), and the next pass decides.
    case contentsNotRead

    /// Whether this waits for the user (a row under *Needs you*), rather than for something
    /// SyncCloud will see on its own at a later pass.
    public var needsYou: Bool {
        switch self {
        case .waitingForRemovalOf, .contentsNotRead: return false
        default: return true
        }
    }
}

public struct OneWaySyncWait: Codable, Equatable, Sendable {
    public enum Subject: Codable, Equatable, Sendable {
        case file(iCloudPath: String?, dropboxPath: String?)
        /// A synced folder, by its recorded name.
        case folder(String)
    }

    public var subject: Subject
    public var reason: OneWaySyncWaitReason

    public init(subject: Subject, reason: OneWaySyncWaitReason) {
        self.subject = subject
        self.reason = reason
    }
}

/// An action with what the caller needs to update the record once it is applied.
public struct OneWaySyncStep: Codable, Equatable, Sendable {
    public var action: OneWaySyncAction
    /// The file record the step changes; nil for a file no record holds yet, and for folder moves.
    public var record: UInt64?
    /// Puts iCloud's version back after the file was deleted, renamed or moved in Dropbox. Once it
    /// is applied, the record's `matchedICloudAt` is set, so a second such change within a day waits.
    public var undoesDropboxChange: Bool

    public init(action: OneWaySyncAction, record: UInt64? = nil, undoesDropboxChange: Bool = false) {
        self.action = action
        self.record = record
        self.undoesDropboxChange = undoesDropboxChange
    }
}

public enum OneWaySyncStop: Equatable, Sendable {
    case overRemovalLimitAcrossFolders(count: Int)
}

/// Everything one pass decides from.
public struct OneWaySyncPass: Sendable {
    public var record: OneWaySyncRecord
    public var iCloud: OneWaySyncListing
    public var dropbox: OneWaySyncListing
    public var settings: OneWaySyncSettings
    public var window: OneWaySyncRemovalWindow
    /// Files (record keys) whose removal or replacement the user confirmed: they go ahead and
    /// don't count toward the removal limit.
    public var confirmed: Set<UInt64>
    public var now: Date

    public init(
        record: OneWaySyncRecord, iCloud: OneWaySyncListing, dropbox: OneWaySyncListing,
        settings: OneWaySyncSettings = OneWaySyncSettings(), window: OneWaySyncRemovalWindow = OneWaySyncRemovalWindow(),
        confirmed: Set<UInt64> = [], now: Date
    ) {
        self.record = record
        self.iCloud = iCloud
        self.dropbox = dropbox
        self.settings = settings
        self.window = window
        self.confirmed = confirmed
        self.now = now
    }
}

public struct OneWaySyncPlan: Sendable {
    /// Set when the whole sync stops. `steps` is then empty, so nothing can be applied; `waits`
    /// lists what stopped it.
    public var stop: OneWaySyncStop?
    public var steps: [OneWaySyncStep]
    public var waits: [OneWaySyncWait]
    /// Files inside synced folders only in Dropbox: left alone, listed.
    public var dropboxOnly: [String]
    /// Every folder directly in the iCloud parent that isn't synced. Telling a new one from one
    /// left unticked at setup is the caller's: the record doesn't keep the folders declined.
    public var unsyncedICloudFolders: [String]
    /// Files whose contents must be read (hashed) before the next pass can decide them.
    public var iCloudContentsToRead: [String]
    public var dropboxContentsToRead: [String]
    /// Synced folders not fully listed on one side or the other; nothing in them was decided.
    public var notFullyListed: [String]
    /// Every file record gone from iCloud and when it was first seen gone, to save in the record
    /// whatever is applied.
    public var goneSince: [UInt64: Int64]
    /// The removal window to save once the actions are applied.
    public var window: OneWaySyncRemovalWindow
    public var matches: OneWaySyncMatches

    public var actions: [OneWaySyncAction] { steps.map(\.action) }
}

/// RD67's diff: each side against the record, per the state table, into a plan of actions.
///
/// Pure. It reads no file and writes none; the caller applies the plan and updates the record.
public enum OneWaySyncPlanner {
    /// A file is removed from Dropbox only after it has been gone from iCloud this long, and is
    /// still gone at a later full check.
    public static let deletionDelay: Int64 = 30 * 60
    /// A second Dropbox-side delete, rename or move within this long of SyncCloud undoing one waits.
    public static let againWithin: Int64 = 24 * 60 * 60
    /// SyncCloud's temporary names in Dropbox start with this; the lister skips them.
    public static let temporaryNamePrefix = ".SyncCloud-"

    public static func plan(_ pass: OneWaySyncPass) -> OneWaySyncPlan {
        var builder = PlanBuilder(pass: pass)
        return builder.build()
    }
}

// MARK: - The builder

private struct Op {
    enum Kind {
        case removal(OneWaySyncRemovalCause)
        case replace(iCloudPath: String, needsDownload: Bool, previousIsDropboxEdit: Bool)
        case move
        case copy(iCloudPath: String, needsDownload: Bool)
        case moveBack(removedPath: String)
        case adopt(iCloudPath: String)
        case setTags([String])
        case forget
    }

    enum Status: Equatable {
        case active
        case waiting
        /// Depended on an op that waits; that op's wait row covers it.
        case dropped
    }

    var kind: Kind
    /// The Dropbox item the op acts on, where it is when the op runs (moves: the source).
    var dropboxPath: String?
    /// Where a move, copy or move-back puts its item.
    var target: String?
    var subject: OneWaySyncWait.Subject
    /// The iCloud file whose contents a move is carrying, to compare with a file in its way.
    var iCloudItem: OneWaySyncItem?
    var counted: OneWaySyncRemovalWindow.Change?
    /// An op that must go through for this one to: a move-back before the replace that follows it.
    var dependsOn: Int?
    /// A move whose target becomes this op's `dropboxPath` when it goes through.
    var follows: Int?
    /// Sorts after replaces and moves: a replace of a file moved back from SyncCloud Removed.
    var late = false
    var status: Status = .active
    var record: UInt64?
    var undoesDropboxChange = false
}

private struct PlanBuilder {
    let pass: OneWaySyncPass
    let record: OneWaySyncRecord
    let matches: OneWaySyncMatches
    let now: Int64
    let iKey = OneWaySyncSide.iCloud.nameKey
    let dKey = OneWaySyncSide.dropbox.nameKey

    var ops: [Op] = []
    var waits: [OneWaySyncWait] = []
    var folderMoves: [(from: String, to: String)] = []
    /// Folder moves as (Dropbox name key before the move, path after), in order.
    var rebases: [(fromKey: String, to: String)] = []
    var goneSince: [UInt64: Int64] = [:]
    /// Dropbox-only files adopted while settling names, by Dropbox name key.
    var adoptedDropboxOnly = Set<String>()
    var iCloudContentsToRead: [String] = []
    var dropboxContentsToRead: [String] = []

    /// Synced folder names, by name key per side, whose contents wait as a whole.
    var heldICloud = Set<String>()
    var heldDropbox = Set<String>()
    /// Synced folder names (Dropbox key, which also covers iCloud's) not fully listed.
    var incomplete = Set<String>()
    /// Synced folders on their first run, by Dropbox key.
    var firstRun = Set<String>()
    /// Synced folder record keys by Dropbox name key.
    var syncedFolderKey: [String: UInt64] = [:]

    init(pass: OneWaySyncPass) {
        self.pass = pass
        self.record = pass.record
        self.matches = OneWaySyncMatcher.match(record: pass.record, iCloud: pass.iCloud, dropbox: pass.dropbox)
        self.now = Int64(pass.now.timeIntervalSince1970.rounded(.down))
    }

    mutating func build() -> OneWaySyncPlan {
        for folder in record.syncedFolders {
            syncedFolderKey[dKey(folder.dropboxPath)] = folder.key
            syncedFolderKey[dKey(folder.iCloudPath)] = folder.key
            if !folder.firstRunCompleted {
                firstRun.insert(dKey(folder.iCloudPath))
                firstRun.insert(dKey(folder.dropboxPath))
            }
        }
        incomplete = Set((pass.iCloud.incompleteFolders.union(pass.dropbox.incompleteFolders)).map { dKey($0) })

        planSyncedFolders()
        planSubfolderMoves()
        for file in record.files.sorted(by: { ($0.iCloudPath, $0.key) < ($1.iCloudPath, $1.key) }) {
            planRecordedFile(file)
        }
        planReappeared()
        planPairs()
        planNewFiles()
        let dropboxOnly = planDropboxOnly()

        let stop = applyRemovalLimit()
        resolveNames()
        // Counted once names are settled: a replace dropped there never runs.
        let counted = stop != nil ? [] : ops.filter { $0.status == .active }.compactMap(\.counted)

        return OneWaySyncPlan(
            stop: stop,
            steps: stop != nil ? [] : emit(),
            waits: waits,
            dropboxOnly: dropboxOnly.filter { !adoptedDropboxOnly.contains(dKey($0)) },
            unsyncedICloudFolders: unsyncedICloudFolders(),
            iCloudContentsToRead: iCloudContentsToRead,
            dropboxContentsToRead: dropboxContentsToRead,
            notFullyListed: (pass.iCloud.incompleteFolders.union(pass.dropbox.incompleteFolders)).sorted(),
            goneSince: goneSince,
            window: pass.window.adding(counted, now: now),
            matches: matches
        )
    }

    // MARK: Holding

    func isHeld(iCloudPath path: String) -> Bool {
        let top = OneWaySyncPath.top(path)
        return heldICloud.contains(iKey(top)) || incomplete.contains(dKey(top))
    }

    func isHeld(dropboxPath path: String) -> Bool {
        let top = OneWaySyncPath.top(path)
        return heldDropbox.contains(dKey(top)) || incomplete.contains(dKey(top))
    }

    func isFirstRun(_ path: String) -> Bool { firstRun.contains(dKey(OneWaySyncPath.top(path))) }

    // MARK: Synced folders

    /// A synced folder renamed, moved or deleted on either side waits as a whole; nothing in it is
    /// copied or removed meanwhile.
    mutating func planSyncedFolders() {
        for folder in record.syncedFolders.sorted(by: { $0.iCloudPath < $1.iCloudPath }) {
            var reason: OneWaySyncWaitReason?
            switch matches.iCloud.folders[folder.key] ?? .gone {
            case .found(let item, _) where item.path != folder.iCloudPath:
                reason = .syncedFolderRenamedInICloud(to: item.path)
                heldICloud.insert(iKey(item.path))
            case .found:
                break
            case .movedOut, .gone:
                reason = .syncedFolderMovedOrDeletedInICloud
            }
            if reason == nil {
                switch matches.dropbox.folders[folder.key] ?? .gone {
                case .found(let item, _) where dKey(item.path) == dKey(folder.dropboxPath):
                    break
                case .found(let item, _):
                    reason = .syncedFolderChangedInDropbox
                    heldDropbox.insert(dKey(item.path))
                case .movedOut, .gone:
                    reason = .syncedFolderChangedInDropbox
                }
            }
            guard let reason else { continue }
            heldICloud.insert(iKey(folder.iCloudPath))
            heldDropbox.insert(dKey(folder.dropboxPath))
            waits.append(OneWaySyncWait(subject: .folder(folder.iCloudPath), reason: reason))
        }
    }

    // MARK: Folders below the synced folders

    func rebased(_ path: String) -> String {
        var path = path
        for (fromKey, to) in rebases {
            let key = dKey(path)
            if key == fromKey {
                path = to
            } else if key.hasPrefix(fromKey + "/") {
                let rest = OneWaySyncPath.components(path).dropFirst(OneWaySyncPath.depth(fromKey))
                path = to + "/" + rest.joined(separator: "/")
            }
        }
        return path
    }

    /// A folder renamed or moved in iCloud, whose Dropbox copy is where it was recorded, moves in
    /// Dropbox as one: its files follow without a move each. If anything holds the new name, or
    /// Dropbox's folder was moved by hand, its files are handled one by one instead.
    mutating func planSubfolderMoves() {
        var occupied = Set(pass.dropbox.items.map { dKey($0.path) })
        // By where each folder is going, shallowest first: a folder moved into another that is
        // itself renamed follows that rename, and each target is checked against every move
        // that could bring something to it.
        func destination(_ folder: OneWaySyncFolderRecord) -> String {
            matches.iCloud.folders[folder.key]?.item?.path ?? folder.iCloudPath
        }
        let folders = record.subfolders.sorted {
            (OneWaySyncPath.depth(destination($0)), destination($0)) < (OneWaySyncPath.depth(destination($1)), destination($1))
        }
        for folder in folders {
            guard case .found(let i, _) = matches.iCloud.folders[folder.key] ?? .gone,
                  case .found(let d, _) = matches.dropbox.folders[folder.key] ?? .gone,
                  !isHeld(iCloudPath: folder.iCloudPath), !isHeld(iCloudPath: i.path),
                  !isHeld(dropboxPath: folder.dropboxPath),
                  dKey(d.path) == dKey(folder.dropboxPath),
                  i.path != folder.iCloudPath else { continue }
            let current = rebased(d.path)
            guard OneWaySyncPath.needsMove(from: current, to: i.path) else { continue }
            let target = dKey(i.path)
            guard target == dKey(current) || !occupied.contains(target) else { continue }
            folderMoves.append((current, i.path))
            let fromKey = dKey(current)
            rebases.append((fromKey, i.path))
            occupied = Set(occupied.map { key in
                if key == fromKey { return target }
                if key.hasPrefix(fromKey + "/") { return target + key.dropFirst(fromKey.count) }
                return key
            })
        }
    }

    // MARK: Recorded files: the state table

    func contentsDiffer(_ item: OneWaySyncItem, _ file: OneWaySyncFileRecord) -> Bool {
        if item.size != file.size || item.second != file.modified { return true }
        if let hash = item.contentHash, let recorded = file.contentHash { return hash != recorded }
        return false
    }

    /// Identical contents, known rather than assumed: equal sizes and equal hashes.
    func identical(_ a: OneWaySyncItem, _ b: OneWaySyncItem) -> Bool {
        a.size == b.size && a.contentHash != nil && a.contentHash == b.contentHash
    }

    func change(_ file: OneWaySyncFileRecord, _ kind: OneWaySyncRemovalWindow.Change.Kind, seenAt: Int64) -> OneWaySyncRemovalWindow.Change? {
        guard !pass.confirmed.contains(file.key), !isFirstRun(file.dropboxPath),
              let folder = syncedFolderKey[dKey(OneWaySyncPath.top(file.dropboxPath))] else { return nil }
        return OneWaySyncRemovalWindow.Change(file: file.key, folder: folder, kind: kind, seenAt: seenAt)
    }

    mutating func planRecordedFile(_ file: OneWaySyncFileRecord) {
        let iMatch = matches.iCloud.files[file.key] ?? .gone
        let dMatch = matches.dropbox.files[file.key] ?? .gone
        let subject = OneWaySyncWait.Subject.file(iCloudPath: file.iCloudPath, dropboxPath: file.dropboxPath)
        let firstOp = ops.count
        defer { for index in firstOp..<ops.count { ops[index].record = file.key } }

        let held = isHeld(iCloudPath: file.iCloudPath) || isHeld(dropboxPath: file.dropboxPath)
            || iMatch.item.map { isHeld(iCloudPath: $0.path) } == true
            || dMatch.item.map { isHeld(dropboxPath: $0.path) } == true
        if case .gone = iMatch {
            // The deletion clock starts at the first complete check that finds the file gone. A
            // pass that decides nothing about it keeps the clock as it was; a start in the future
            // means the clock went backwards, so it starts again.
            if held || !incomplete.isEmpty {
                goneSince[file.key] = file.iCloudGoneSince
            } else {
                goneSince[file.key] = file.iCloudGoneSince.flatMap { $0 <= now ? $0 : nil } ?? now
            }
        }
        if held { return }
        // Nothing is called gone on either side while any folder isn't fully listed: the file may
        // be in the part that wasn't read.
        if !incomplete.isEmpty {
            if case .gone = iMatch { return }
            if case .gone = dMatch { return }
        }

        var iItem: OneWaySyncItem?
        var iMovedOut = false
        switch iMatch {
        case .found(let item, _): iItem = item
        case .movedOut: iMovedOut = true
        case .gone: break
        }
        var dItem: OneWaySyncItem?
        switch dMatch {
        case .found(let item, _): dItem = item
        case .movedOut, .gone: break
        }

        var iEdited = iItem.map { contentsDiffer($0, file) } ?? false
        // Moved by itself, not just carried along by a folder renamed above it.
        let iMoved = iItem.map { $0.path != matches.iCloud.followingFolders(file.iCloudPath) } ?? false
        var dEdited = dItem.map { contentsDiffer($0, file) } ?? false
        let dMoved = dItem.map { dKey($0.path) != dKey(file.dropboxPath) } ?? false
        let dGone = dItem == nil
        let again = file.matchedICloudAt.map { $0 <= now && now - $0 < OneWaySyncPlanner.againWithin } ?? false

        // Both sides made the same edit: nothing to copy, only the record to update.
        var sameEdit = false
        if let i = iItem, let d = dItem, iEdited, dEdited, identical(i, d) {
            iEdited = false
            dEdited = false
            sameEdit = true
        }

        // Edited in Dropbox, whatever iCloud did: the *Edited* setting.
        if let d = dItem, dEdited {
            switch pass.settings.whenEdited {
            case .askMe:
                let reason: OneWaySyncWaitReason = iItem == nil ? .deletedInICloudEditedInDropbox
                    : (iEdited ? .editedOnBothSides : .editedInDropbox)
                waits.append(OneWaySyncWait(subject: subject, reason: reason))
            case .useICloud:
                let current = rebased(d.path)
                if dMoved && again {
                    // Moved in Dropbox again within a day of SyncCloud moving it back.
                    waits.append(OneWaySyncWait(subject: subject, reason: .changedInDropboxAgainToday))
                } else if let i = iItem {
                    ops.append(Op(
                        kind: .replace(iCloudPath: i.path, needsDownload: !i.isDownloaded, previousIsDropboxEdit: true),
                        dropboxPath: current, subject: subject, counted: change(file, .replaced, seenAt: now)))
                    if followsICloud(file, from: current, to: i.path) {
                        ops.append(Op(kind: .move, dropboxPath: current, target: i.path, subject: subject, iCloudItem: i,
                                      undoesDropboxChange: dMoved))
                    }
                } else if iMovedOut, let moved = iMatch.item {
                    addRemoval(file, at: current, cause: .movedOutInICloud(to: moved.path), seenAt: now, subject: subject)
                } else {
                    planDeletion(file, at: current, subject: subject)
                }
            }
            return
        }

        // Deleted, renamed or moved in Dropbox.
        if dGone || dMoved {
            let iUnchanged = iItem != nil && !iMoved && !iEdited
            let matchICloud = pass.settings.whenDeletedRenamedOrMoved == .matchICloud
            if iUnchanged, let i = iItem {
                if !matchICloud {
                    waits.append(OneWaySyncWait(subject: subject, reason: .deletedOrMovedInDropbox))
                } else if again {
                    waits.append(OneWaySyncWait(subject: subject, reason: .changedInDropboxAgainToday))
                } else if let d = dItem {
                    ops.append(Op(kind: .move, dropboxPath: rebased(d.path), target: i.path, subject: subject, iCloudItem: i,
                                  undoesDropboxChange: true))
                } else {
                    ops.append(Op(kind: .copy(iCloudPath: i.path, needsDownload: !i.isDownloaded), target: i.path, subject: subject,
                                  undoesDropboxChange: true))
                }
                return
            }
            // Changed on both sides.
            if iItem == nil && dGone {
                ops.append(Op(kind: .forget, dropboxPath: file.dropboxPath, subject: subject))
                return
            }
            if let i = iItem, let d = dItem, !iEdited, dKey(i.path) == dKey(d.path) {
                // Renamed or moved the same way on both sides: only letter case can be left.
                planPresent(file, i: i, d: d, iEdited: false, adopt: true, subject: subject)
                return
            }
            // The one exception the design names: edited in iCloud, deleted in Dropbox, Match iCloud.
            // Renamed or moved in iCloud, or moved out of the synced folders in Dropbox, waits.
            if let i = iItem, iEdited, !iMoved, case .gone = dMatch, matchICloud {
                if again {
                    waits.append(OneWaySyncWait(subject: subject, reason: .changedInDropboxAgainToday))
                } else {
                    ops.append(Op(kind: .copy(iCloudPath: i.path, needsDownload: !i.isDownloaded), target: i.path, subject: subject,
                                  undoesDropboxChange: true))
                }
                return
            }
            waits.append(OneWaySyncWait(subject: subject, reason: .changedOnBothSides))
            return
        }

        // Dropbox as recorded (or only its tags changed).
        guard let d = dItem else { return }
        if let i = iItem {
            planPresent(file, i: i, d: d, iEdited: iEdited, adopt: sameEdit, subject: subject)
        } else if iMovedOut, let moved = iMatch.item {
            addRemoval(file, at: rebased(d.path), cause: .movedOutInICloud(to: moved.path), seenAt: now, subject: subject)
        } else {
            planDeletion(file, at: rebased(d.path), subject: subject)
        }
    }

    /// Whether a recorded file's Dropbox copy moves to follow iCloud's name. Letter case alone
    /// moves it only when iCloud's own name changed: a change of case made in Dropbox is no change.
    func followsICloud(_ file: OneWaySyncFileRecord, from current: String, to desired: String) -> Bool {
        dKey(current) != dKey(desired) || (desired != file.iCloudPath && OneWaySyncPath.needsMove(from: current, to: desired))
    }

    /// iCloud's file is here: follow its name, its contents and its tags. `adopt` records the
    /// pair as it now stands when both sides already made the change, so nothing else would.
    mutating func planPresent(
        _ file: OneWaySyncFileRecord, i: OneWaySyncItem, d: OneWaySyncItem, iEdited: Bool, adopt: Bool,
        subject: OneWaySyncWait.Subject
    ) {
        let current = rebased(d.path)
        if iEdited {
            ops.append(Op(
                kind: .replace(iCloudPath: i.path, needsDownload: !i.isDownloaded, previousIsDropboxEdit: false),
                dropboxPath: current, subject: subject, counted: change(file, .replaced, seenAt: now)))
        }
        var move: Int?
        if followsICloud(file, from: current, to: i.path) {
            ops.append(Op(kind: .move, dropboxPath: current, target: i.path, subject: subject, iCloudItem: i))
            move = ops.count - 1
        }
        // Only a change of tags in iCloud is copied; a difference only Dropbox shows is left, so a
        // tag Dropbox won't keep can't be rewritten every pass.
        if !iEdited && Set(i.tags) != Set(file.tags) {
            ops.append(Op(kind: .setTags(i.tags), dropboxPath: current, subject: subject, follows: move))
        }
        if adopt {
            ops.append(Op(kind: .adopt(iCloudPath: i.path), dropboxPath: current, subject: subject, follows: move))
        }
    }

    /// Gone from iCloud: removed from Dropbox once it has been gone 30 minutes and is still gone
    /// at a later full check. Never while any folder isn't fully listed.
    mutating func planDeletion(_ file: OneWaySyncFileRecord, at dropboxPath: String, subject: OneWaySyncWait.Subject) {
        // The clock in the record was started by an earlier check, so this check is at least the
        // second to find the file gone.
        guard incomplete.isEmpty, let since = file.iCloudGoneSince, since <= now,
              now - since >= OneWaySyncPlanner.deletionDelay else { return }
        addRemoval(file, at: dropboxPath, cause: .deletedInICloud, seenAt: since, subject: subject)
    }

    mutating func addRemoval(_ file: OneWaySyncFileRecord, at dropboxPath: String, cause: OneWaySyncRemovalCause, seenAt: Int64, subject: OneWaySyncWait.Subject) {
        ops.append(Op(kind: .removal(cause), dropboxPath: dropboxPath, subject: subject,
                      counted: change(file, .deletedOrMovedOut, seenAt: seenAt)))
    }

    // MARK: Unrecorded files

    /// A removed file's ID back in iCloud: moved back from SyncCloud Removed, not uploaded again.
    mutating func planReappeared() {
        for back in matches.reappeared where !isHeld(iCloudPath: back.item.path) {
            let subject = OneWaySyncWait.Subject.file(iCloudPath: back.item.path, dropboxPath: nil)
            ops.append(Op(kind: .moveBack(removedPath: back.removed.removedPath), target: back.item.path, subject: subject))
            if contentsDiffer(back.item, back.removed.file) {
                ops.append(Op(
                    kind: .replace(iCloudPath: back.item.path, needsDownload: !back.item.isDownloaded, previousIsDropboxEdit: false),
                    dropboxPath: back.item.path, subject: subject, dependsOn: ops.count - 1, late: true))
            }
        }
    }

    mutating func planPairs() {
        for pair in matches.pairs {
            let i = pair.iCloud, d = pair.dropbox
            guard !isHeld(iCloudPath: i.path), !isHeld(dropboxPath: d.path) else { continue }
            let subject = OneWaySyncWait.Subject.file(iCloudPath: i.path, dropboxPath: d.path)
            let current = rebased(d.path)

            switch pair.basis {
            case .contents:
                // First run: Dropbox's identical file is renamed to match.
                ops.append(Op(kind: .move, dropboxPath: current, target: i.path, subject: subject, iCloudItem: i))
                ops.append(Op(kind: .adopt(iCloudPath: i.path), dropboxPath: current, subject: subject,
                              dependsOn: ops.count - 1, follows: ops.count - 1))
            case .name:
                if identical(i, d) {
                    var move: Int?
                    if OneWaySyncPath.needsMove(from: current, to: i.path) {
                        ops.append(Op(kind: .move, dropboxPath: current, target: i.path, subject: subject, iCloudItem: i))
                        move = ops.count - 1
                    }
                    ops.append(Op(kind: .adopt(iCloudPath: i.path), dropboxPath: current, subject: subject, follows: move))
                } else if i.size == d.size && (i.contentHash == nil || d.contentHash == nil) {
                    // Same size: only the contents can tell, and they haven't been read.
                    waitForContents(i, d, subject: subject)
                } else if !isFirstRun(i.path) || !isFirstRun(d.path) {
                    // The Dropbox-only file is never overwritten.
                    waits.append(OneWaySyncWait(subject: subject, reason: .nameTakenByDropboxOnlyFile(d.path)))
                } else {
                    planFirstRunDifference(i: i, d: d, at: current, subject: subject)
                }
            }
        }
    }

    /// Waits for the contents of the two files to be read, and asks for them.
    mutating func waitForContents(_ i: OneWaySyncItem, _ d: OneWaySyncItem, subject: OneWaySyncWait.Subject) {
        waits.append(OneWaySyncWait(subject: subject, reason: .contentsNotRead))
        if i.contentHash == nil { iCloudContentsToRead.append(i.path) }
        if d.contentHash == nil { dropboxContentsToRead.append(d.path) }
    }

    /// CZ: on a first run, different contents at one name go by which is newer. The same date to
    /// the second, or a date in the future, is unclear and waits.
    mutating func planFirstRunDifference(i: OneWaySyncItem, d: OneWaySyncItem, at current: String, subject: OneWaySyncWait.Subject) {
        if i.second > now || d.second > now {
            waits.append(OneWaySyncWait(subject: subject, reason: .futureDateOnFirstRun))
        } else if i.second > d.second {
            ops.append(Op(
                kind: .replace(iCloudPath: i.path, needsDownload: !i.isDownloaded, previousIsDropboxEdit: true),
                dropboxPath: current, subject: subject))
            if OneWaySyncPath.needsMove(from: current, to: i.path) {
                ops.append(Op(kind: .move, dropboxPath: current, target: i.path, subject: subject, iCloudItem: i))
            }
        } else if d.second > i.second {
            waits.append(OneWaySyncWait(subject: subject, reason: .dropboxNewerOnFirstRun))
        } else {
            waits.append(OneWaySyncWait(subject: subject, reason: .sameDateOnFirstRun))
        }
    }

    mutating func planNewFiles() {
        for item in matches.iCloud.unclaimed where !isHeld(iCloudPath: item.path) {
            ops.append(Op(
                kind: .copy(iCloudPath: item.path, needsDownload: !item.isDownloaded), target: item.path,
                subject: .file(iCloudPath: item.path, dropboxPath: nil)))
        }
    }

    /// Dropbox files no record holds: a conflicted copy Dropbox made of a synced file waits as an
    /// edit; anything else is left alone and listed.
    mutating func planDropboxOnly() -> [String] {
        var recorded: [String: OneWaySyncFileRecord] = [:]
        for file in record.files {
            recorded[dKey(file.dropboxPath)] = file
            if let item = matches.dropbox.files[file.key]?.item { recorded[dKey(item.path)] = file }
        }
        var listed: [String] = []
        for item in matches.dropbox.unclaimed where !isHeld(dropboxPath: item.path) {
            if let original = Self.conflictedCopyOriginal(item.path), let file = recorded[dKey(original)] {
                waits.append(OneWaySyncWait(
                    subject: .file(iCloudPath: file.iCloudPath, dropboxPath: item.path),
                    reason: .conflictedCopy(of: file.dropboxPath)))
            } else {
                listed.append(item.path)
            }
        }
        return listed
    }

    /// The path a Dropbox conflicted copy was made from: "Report (Ann's conflicted copy
    /// 2026-10-30).pdf" → "Report.pdf", in the same folder.
    static func conflictedCopyOriginal(_ path: String) -> String? {
        let name = OneWaySyncPath.name(path) as NSString
        let ext = name.pathExtension
        let stem = name.deletingPathExtension
        guard stem.hasSuffix(")"), let open = stem.range(of: " (", options: .backwards) else { return nil }
        let inside = stem[open.upperBound..<stem.index(before: stem.endIndex)]
        guard inside.range(of: "conflicted copy", options: .caseInsensitive) != nil else { return nil }
        let base = String(stem[..<open.lowerBound])
        let original = ext.isEmpty ? base : base + "." + ext
        return OneWaySyncPath.join(OneWaySyncPath.parent(path), original)
    }

    func unsyncedICloudFolders() -> [String] {
        var synced = Set(record.syncedFolders.map { iKey($0.iCloudPath) })
        for folder in record.syncedFolders {
            if let item = matches.iCloud.folders[folder.key]?.item { synced.insert(iKey(item.path)) }
        }
        return pass.iCloud.items
            .filter { $0.kind == .folder && !$0.isExcluded && OneWaySyncPath.depth($0.path) == 1 && !synced.contains(iKey($0.path)) }
            .map(\.path)
            .sorted()
    }

    // MARK: The removal limit

    /// Over the limit in one folder, every removal and replacement from this pass in it waits and
    /// additions continue. Over 50 across folders, the whole sync stops until reviewed.
    mutating func applyRemovalLimit() -> OneWaySyncStop? {
        let candidates = ops.indices.filter { ops[$0].status == .active && ops[$0].counted != nil }
        guard !candidates.isEmpty else { return nil }
        var fileCounts: [UInt64: Int] = [:]
        for file in record.files {
            if let folder = syncedFolderKey[dKey(OneWaySyncPath.top(file.dropboxPath))] { fileCounts[folder, default: 0] += 1 }
        }
        let verdict = pass.window.verdict(adding: candidates.compactMap { ops[$0].counted }, folderFileCounts: fileCounts, now: now)
        for index in candidates {
            if verdict.overAcrossFolders {
                wait(index, .overRemovalLimitAcrossFolders)
            } else if verdict.overFolders.contains(ops[index].counted!.folder) {
                wait(index, .overRemovalLimit)
            }
        }
        return verdict.overAcrossFolders ? .overRemovalLimitAcrossFolders(count: verdict.acrossCount) : nil
    }

    mutating func wait(_ index: Int, _ reason: OneWaySyncWaitReason) {
        ops[index].status = .waiting
        waits.append(OneWaySyncWait(subject: ops[index].subject, reason: reason))
        for other in ops.indices where ops[other].dependsOn == index && ops[other].status == .active {
            ops[other].status = .dropped
        }
    }

    // MARK: Names in Dropbox

    /// Every move, copy and move-back needs its Dropbox name free by the time it runs: free now,
    /// or freed by a removal or another move in this plan. A name held by something that stays
    /// makes it wait; settling one wait can block another, so this repeats until nothing changes.
    mutating func resolveNames() {
        var occupant: [String: String] = [:]
        var fileKeys = Set<String>()
        for item in pass.dropbox.items {
            let path = rebased(item.path)
            occupant[dKey(path)] = path
            if item.kind == .file { fileKeys.insert(dKey(path)) }
        }

        var pendingRemoval = Set<String>()
        for file in record.files {
            guard let d = matches.dropbox.files[file.key]?.item, case .found = matches.dropbox.files[file.key] else { continue }
            switch matches.iCloud.files[file.key] ?? .gone {
            case .gone, .movedOut: pendingRemoval.insert(dKey(rebased(d.path)))
            case .found: break
            }
        }
        var dropboxOnly: [String: OneWaySyncItem] = [:]
        for item in matches.dropbox.unclaimed { dropboxOnly[dKey(rebased(item.path))] = item }

        let placers = ops.indices.filter { ops[$0].target != nil }.sorted { ops[$0].target! < ops[$1].target! }
        var claimedTarget: [String: Int] = [:]
        for index in placers where ops[index].status == .active {
            let target = dKey(ops[index].target!)
            if let first = claimedTarget[target] {
                wait(index, .nameTaken(ops[first].target!))
            } else {
                claimedTarget[target] = index
            }
        }

        var changed = true
        while changed {
            changed = false
            var leaving = Set<String>()
            for op in ops where op.status == .active {
                switch op.kind {
                case .removal, .move: leaving.insert(dKey(op.dropboxPath!))
                default: break
                }
            }
            for index in placers where ops[index].status == .active {
                let target = dKey(ops[index].target!)
                // A file where one of the target's folders should be blocks it too, unless it leaves.
                if let blocking = Self.ancestors(of: target).first(where: { fileKeys.contains($0) && !leaving.contains($0) }) {
                    changed = true
                    wait(index, pendingRemoval.contains(blocking) ? .waitingForRemovalOf(occupant[blocking]!) : .nameTaken(occupant[blocking]!))
                    continue
                }
                if let source = ops[index].dropboxPath, dKey(source) == target { continue }
                guard let holder = occupant[target], !leaving.contains(target) else { continue }
                changed = true
                if pendingRemoval.contains(target) {
                    wait(index, .waitingForRemovalOf(holder))
                } else if let other = dropboxOnly[target], case .move = ops[index].kind,
                          let i = ops[index].iCloudItem, identical(i, other) {
                    // Renamed onto a Dropbox-only file with the same contents: that file is
                    // adopted, and the old Dropbox copy is redundant, along with any replace of it.
                    let source = ops[index].dropboxPath!
                    ops[index].status = .dropped
                    for sibling in ops.indices where ops[sibling].record != nil && ops[sibling].record == ops[index].record {
                        if case .replace = ops[sibling].kind { ops[sibling].status = .dropped }
                    }
                    ops.append(Op(kind: .removal(.duplicateOfAdoptedFile(holder)), dropboxPath: source, subject: ops[index].subject,
                                  record: ops[index].record))
                    ops.append(Op(kind: .adopt(iCloudPath: i.path), dropboxPath: holder, subject: ops[index].subject,
                                  record: ops[index].record))
                    dropboxOnly.removeValue(forKey: target)
                    adoptedDropboxOnly.insert(dKey(other.path))
                    for dependent in ops.indices where ops[dependent].follows == index {
                        ops[dependent].follows = nil
                        ops[dependent].dropboxPath = holder
                    }
                } else if let other = dropboxOnly[target], case .move = ops[index].kind, let i = ops[index].iCloudItem,
                          i.size == other.size, i.contentHash == nil || other.contentHash == nil {
                    wait(index, .contentsNotRead)
                    if i.contentHash == nil { iCloudContentsToRead.append(i.path) }
                    if other.contentHash == nil { dropboxContentsToRead.append(other.path) }
                } else if dropboxOnly[target] != nil {
                    wait(index, .nameTakenByDropboxOnlyFile(holder))
                } else {
                    wait(index, .nameTaken(holder))
                }
            }
        }
    }

    // MARK: Order

    mutating func emit() -> [OneWaySyncStep] {
        var steps: [OneWaySyncStep] = folderMoves.map { OneWaySyncStep(action: .moveFolderInDropbox(from: $0.from, to: $0.to)) }
        let active = ops.indices.filter { ops[$0].status == .active }

        func path(_ index: Int) -> String {
            if let move = ops[index].follows, ops[move].status == .active { return ops[move].target! }
            return ops[index].dropboxPath!
        }

        for index in active {
            if case .removal(let cause) = ops[index].kind {
                steps.append(step(index, .moveToRemoved(dropboxPath: ops[index].dropboxPath!, cause: cause)))
            }
        }
        for index in active where !ops[index].late {
            if case .replace(let iPath, let download, let dropboxEdit) = ops[index].kind {
                steps.append(step(index, .replace(dropboxPath: ops[index].dropboxPath!, with: iPath, needsDownload: download, previousIsDropboxEdit: dropboxEdit)))
            }
        }
        steps += orderedMoves(active.filter { if case .move = ops[$0].kind { return true } else { return false } })
        for index in active {
            if case .moveBack(let removed) = ops[index].kind {
                steps.append(step(index, .moveBackFromRemoved(removedPath: removed, to: ops[index].target!)))
            }
        }
        for index in active where ops[index].late {
            if case .replace(let iPath, let download, let dropboxEdit) = ops[index].kind {
                steps.append(step(index, .replace(dropboxPath: ops[index].dropboxPath!, with: iPath, needsDownload: download, previousIsDropboxEdit: dropboxEdit)))
            }
        }
        for index in active {
            if case .copy(let iPath, let download) = ops[index].kind {
                steps.append(step(index, .copy(from: iPath, to: ops[index].target!, needsDownload: download)))
            }
        }
        for index in active {
            if case .adopt(let iPath) = ops[index].kind { steps.append(step(index, .adopt(iCloudPath: iPath, dropboxPath: path(index)))) }
        }
        for index in active {
            if case .setTags(let tags) = ops[index].kind { steps.append(step(index, .setTags(dropboxPath: path(index), tags: tags))) }
        }
        for index in active {
            if case .forget = ops[index].kind { steps.append(step(index, .forget(dropboxPath: ops[index].dropboxPath!))) }
        }
        return steps
    }

    func step(_ index: Int, _ action: OneWaySyncAction) -> OneWaySyncStep {
        OneWaySyncStep(action: action, record: ops[index].record, undoesDropboxChange: ops[index].undoesDropboxChange)
    }

    /// The name keys of the folders above `key`, nearest first.
    static func ancestors(of key: String) -> [String] {
        var parts = OneWaySyncPath.components(key)
        var result: [String] = []
        while parts.count > 1 {
            parts.removeLast()
            result.append(parts.joined(separator: "/"))
        }
        return result
    }

    /// Moves in an order where each target is free when its move runs: a move into another's old
    /// name, or below it, goes after it. A cycle (a↔b) goes through a temporary name in the same
    /// Dropbox folder.
    func orderedMoves(_ moves: [Int]) -> [OneWaySyncStep] {
        var bySource: [String: Int] = [:]
        for index in moves { bySource[dKey(ops[index].dropboxPath!)] = index }
        /// The moves that must vacate this move's target, or a folder above it, first.
        func blockers(_ index: Int) -> [Int] {
            let target = dKey(ops[index].target!)
            let source = dKey(ops[index].dropboxPath!)
            return ([target] + Self.ancestors(of: target)).compactMap { key in
                guard key != source, let other = bySource[key], other != index else { return nil }
                return other
            }
        }

        var steps: [OneWaySyncStep] = []
        var done = Set<Int>()
        var temporaries = 0

        /// `cycle[0]` waits on `cycle[1]`, …, and the last waits on `cycle[0]`. Parking the first
        /// frees the last, which frees the one before it, and so on back to the first.
        func emitCycle(_ cycle: [Int]) {
            temporaries += 1
            let start = cycle[0]
            let source = ops[start].dropboxPath!
            let parked = OneWaySyncPath.join(
                OneWaySyncPath.parent(source),
                "\(OneWaySyncPlanner.temporaryNamePrefix)swap-\(temporaries)-\(OneWaySyncPath.name(source))")
            steps.append(step(start, .moveInDropbox(from: source, to: parked)))
            done.insert(start)
            for index in cycle.dropFirst().reversed() where !done.contains(index) {
                steps.append(step(index, .moveInDropbox(from: ops[index].dropboxPath!, to: ops[index].target!)))
                done.insert(index)
            }
            steps.append(step(start, .moveInDropbox(from: parked, to: ops[start].target!)))
        }

        func visit(_ index: Int, _ path: [Int]) {
            guard !done.contains(index) else { return }
            if let first = path.firstIndex(of: index) {
                emitCycle(Array(path[first...]))
                return
            }
            for other in blockers(index) {
                visit(other, path + [index])
                if done.contains(index) { return }
            }
            steps.append(step(index, .moveInDropbox(from: ops[index].dropboxPath!, to: ops[index].target!)))
            done.insert(index)
        }

        for index in moves { visit(index, []) }
        return steps
    }
}
