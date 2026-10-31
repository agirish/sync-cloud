//
//  OneWaySyncRecordKeeper.swift
//  SyncCloud
//

import Foundation

/// What one step of a plan came to, as the record needs it.
public enum OneWaySyncStepOutcome: Equatable, Sendable {
    /// Done. For a copy, a replace or a move back, Dropbox reported the upload, and `dropboxID` is
    /// the file's document ID read after it.
    case landed(dropboxID: UInt64?)
    /// Moved into SyncCloud Removed, at `removedPath` (relative to the Dropbox account folder).
    case removed(removedPath: String)
    /// Written, but Dropbox didn't report the upload: it doesn't count as synced, so the record
    /// keeps what it had and the next pass compares the file again.
    case unconfirmed
    /// Skipped or failed: nothing changed in Dropbox.
    case notDone

    public var happened: Bool {
        switch self {
        case .landed, .removed, .unconfirmed: return true
        case .notDone: return false
        }
    }

    var counts: Bool {
        switch self {
        case .landed, .removed: return true
        case .unconfirmed, .notDone: return false
        }
    }
}

/// **The record after a pass**: what both sides agree on once the plan's steps landed, or didn't.
///
/// Pure. The rule is the record's own: it holds the last state both sides agreed on. So
///
/// - a file whose steps all landed, and that nothing holds, takes iCloud's path and Dropbox's
///   location, and, where its contents were written, iCloud's size, date, tags and hash;
/// - a file with a step that didn't land, or that waits, keeps what it had, apart from where
///   Dropbox's copy now is when SyncCloud moved it itself (a folder move above it, or its own
///   move): that was SyncCloud's doing, and would otherwise read as a move made in Dropbox;
/// - every file found on a side by ID or by name takes the ID it has there now (a save that gave
///   it a new one), and every file gone from iCloud keeps when it was first seen gone;
/// - the folders below the synced ones are recorded again from what both sides now hold, so a
///   later rename of one is one move in Dropbox.
public enum OneWaySyncRecordKeeper {

    /// `outcomes` is one per `plan.steps`. `dropboxFolderID` reads a Dropbox folder's identity at a
    /// path relative to the Dropbox parent now, after the steps; nil when there is none.
    public static func update(
        _ record: OneWaySyncRecord, pass: OneWaySyncPass, plan: OneWaySyncPlan, outcomes: [OneWaySyncStepOutcome],
        dropboxFolderID: (String) -> OneWaySyncFolderID?, now: Date
    ) -> OneWaySyncRecord {
        precondition(outcomes.count == plan.steps.count, "one outcome per step")
        var keeper = Keeper(record: record, pass: pass, plan: plan, now: now)
        for (index, step) in plan.steps.enumerated() { keeper.note(step, outcomes[index]) }
        keeper.settleFiles()
        keeper.addNewFiles()
        keeper.settleFolders(dropboxFolderID: dropboxFolderID)
        return keeper.record
    }
}

private struct Keeper {
    var record: OneWaySyncRecord
    let pass: OneWaySyncPass
    let plan: OneWaySyncPlan
    let now: Int64
    let iKey = OneWaySyncSide.iCloud.nameKey
    let dKey = OneWaySyncSide.dropbox.nameKey

    /// What happened to one file's steps.
    struct Fate {
        var allCounted = true
        var anyStep = false
        var wrote = false
        var adopted = false
        var tagged = false
        var undid = false
        var forgotten = false
        var removedTo: String?
        var dropboxID: UInt64?
        /// Where its Dropbox copy is after the steps; nil when it has none.
        var location: String?
        /// Its recorded Dropbox path, carried only by SyncCloud's own moves: what a file that
        /// doesn't agree keeps, so a move made in Dropbox still reads as one next pass.
        var recordedPath: String?
        /// A folder move above it that didn't go through: its files don't agree either.
        var folderMoveFailed = false
        /// Its contents' hash where the step knew it: an adopted pair's.
        var hash: String?
        /// A move back from SyncCloud Removed that landed: the removed file it was.
        var movedBack: OneWaySyncRemovedFile?
    }

    var fates: [UInt64: Fate] = [:]
    /// Files no record holds yet, by iCloud name key.
    var newFates: [String: Fate] = [:]
    /// Where each Dropbox item now is: its listing path's name key → its location now.
    var locations: [String: String] = [:]

    init(record: OneWaySyncRecord, pass: OneWaySyncPass, plan: OneWaySyncPlan, now: Date) {
        self.record = record
        self.pass = pass
        self.plan = plan
        self.now = Int64(now.timeIntervalSince1970.rounded(.down))
        for file in record.files {
            var fate = Fate()
            if case .found(let item, _) = plan.matches.dropbox.files[file.key] ?? .gone { fate.location = item.path }
            fate.recordedPath = file.dropboxPath
            fates[file.key] = fate
        }
    }

    // MARK: Steps

    mutating func note(_ step: OneWaySyncStep, _ outcome: OneWaySyncStepOutcome) {
        let dKey = self.dKey
        let removed = record.removed
        switch step.action {
        case .moveFolderInDropbox(let from, let to):
            guard outcome.happened else {
                let fromKey = dKey(from)
                for key in fates.keys {
                    if let location = fates[key]!.location, dKey(location).hasPrefix(fromKey + "/") { fates[key]!.folderMoveFailed = true }
                }
                return
            }
            rebase(from: from, to: to)
        case .moveInDropbox(let from, let to):
            change(step, iCloudPath: to, outcome) { fate in
                guard outcome.happened else { return }
                if let location = fate.location, dKey(location) == dKey(from) { fate.location = to }
                else if fate.location == nil { fate.location = to }
                fate.recordedPath = to
            }
        case .moveToRemoved(_, _):
            change(step, iCloudPath: nil, outcome) { fate in
                if case .removed(let path) = outcome { fate.removedTo = path }
            }
        case .replace(let dropboxPath, let iCloudPath, _, _):
            change(step, iCloudPath: iCloudPath, outcome) { fate in
                if outcome.happened { fate.location = fate.location ?? dropboxPath }
                if case .landed(let id) = outcome {
                    fate.wrote = true
                    fate.dropboxID = id ?? fate.dropboxID
                }
            }
        case .copy(let iCloudPath, let dropboxPath, _):
            change(step, iCloudPath: iCloudPath, outcome) { fate in
                if outcome.happened { fate.location = dropboxPath }
                if case .landed(let id) = outcome {
                    fate.wrote = true
                    fate.dropboxID = id
                }
            }
        case .moveBackFromRemoved(let removedPath, let to):
            change(step, iCloudPath: to, outcome) { fate in
                guard outcome.happened else { return }
                fate.location = to
                fate.movedBack = removed.first { $0.removedPath == removedPath }
                if case .landed(let id) = outcome { fate.dropboxID = id }
            }
        case .adopt(let iCloudPath, let dropboxPath):
            change(step, iCloudPath: iCloudPath, outcome) { fate in
                guard outcome.counts else { return }
                fate.adopted = true
                // Where the agreed file is: a Dropbox-only twin adopted in place of the old copy.
                fate.location = dropboxPath
            }
        case .setTags:
            change(step, iCloudPath: nil, outcome) { fate in if outcome.counts { fate.tagged = true } }
        case .forget:
            change(step, iCloudPath: nil, outcome) { fate in if outcome.counts { fate.forgotten = true } }
        }
    }

    /// Applies `body` to the fate of the file `step` is for: its record's, or for a file no record
    /// holds yet, the one at `iCloudPath`.
    mutating func change(_ step: OneWaySyncStep, iCloudPath: String?, _ outcome: OneWaySyncStepOutcome, _ body: (inout Fate) -> Void) {
        func mark(_ fate: inout Fate) {
            fate.anyStep = true
            if !outcome.counts { fate.allCounted = false }
            if outcome.happened, step.undoesDropboxChange { fate.undid = true }
            body(&fate)
        }
        if let key = step.record, fates[key] != nil {
            mark(&fates[key]!)
        } else if let iCloudPath {
            mark(&newFates[iKey(iCloudPath), default: Fate()])
        }
    }

    /// A folder moved in Dropbox carries every file below it.
    mutating func rebase(from: String, to: String) {
        let fromKey = dKey(from)
        func moved(_ path: String) -> String? {
            let key = dKey(path)
            if key == fromKey { return to }
            guard key.hasPrefix(fromKey + "/") else { return nil }
            return to + "/" + OneWaySyncPath.components(path).dropFirst(OneWaySyncPath.depth(from)).joined(separator: "/")
        }
        for key in fates.keys {
            if let location = fates[key]!.location, let now = moved(location) { fates[key]!.location = now }
            if let recorded = fates[key]!.recordedPath, let now = moved(recorded) { fates[key]!.recordedPath = now }
        }
        for key in newFates.keys {
            if let location = newFates[key]!.location, let now = moved(location) { newFates[key]!.location = now }
        }
    }

    // MARK: Files

    /// Synced folders (Dropbox name key) held as a whole this pass, or not fully listed.
    var heldTops: Set<String> {
        var tops = Set(plan.notFullyListed.map(dKey))
        for wait in plan.waits {
            if case .folder(let name) = wait.subject { tops.insert(dKey(name)) }
        }
        for folder in record.syncedFolders {
            let held = tops.contains(dKey(folder.iCloudPath)) || tops.contains(dKey(folder.dropboxPath))
            if held {
                tops.insert(dKey(folder.iCloudPath))
                tops.insert(dKey(folder.dropboxPath))
                if let item = plan.matches.iCloud.folders[folder.key]?.item { tops.insert(dKey(item.path)) }
                if let item = plan.matches.dropbox.folders[folder.key]?.item { tops.insert(dKey(item.path)) }
            }
        }
        return tops
    }

    /// Recorded paths that wait for the user or for a later pass.
    var waitingPaths: (iCloud: Set<String>, dropbox: Set<String>) {
        var iCloud = Set<String>(), dropbox = Set<String>()
        for wait in plan.waits {
            guard case .file(let i, let d) = wait.subject else { continue }
            if let i { iCloud.insert(iKey(i)) }
            if let d { dropbox.insert(dKey(d)) }
        }
        return (iCloud, dropbox)
    }

    mutating func settleFiles() {
        let held = heldTops
        let waiting = waitingPaths
        var kept: [OneWaySyncFileRecord] = []
        for var file in record.files {
            let fate = fates[file.key] ?? Fate()
            file.iCloudGoneSince = plan.goneSince[file.key]
            if fate.forgotten { continue }
            // Renamed onto a Dropbox-only twin with the same contents: the old copy went to
            // SyncCloud Removed and the twin is this file now.
            if fate.removedTo != nil, fate.adopted, fate.allCounted, case .found(let i, _) = plan.matches.iCloud.files[file.key] ?? .gone,
               let location = fate.location {
                file.iCloudPath = i.path
                file.dropboxPath = location
                file.size = i.size
                file.modified = i.second
                file.tags = i.tags
                let twin = pass.dropbox.items.first { dKey($0.path) == dKey(location) }
                file.contentHash = i.contentHash ?? twin?.contentHash
                file.dropboxID = twin.flatMap { plan.matches.dropbox.recordableID(of: $0) }
                if let id = plan.matches.iCloud.recordableID(of: i) { file.iCloudID = id }
                kept.append(file)
                continue
            }
            if let removedPath = fate.removedTo {
                record.removed.append(OneWaySyncRemovedFile(file: file, removedPath: removedPath))
                continue
            }
            let iMatch = plan.matches.iCloud.files[file.key] ?? .gone
            let dMatch = plan.matches.dropbox.files[file.key] ?? .gone
            // The IDs the files have now, wherever the match found them.
            if case .found(let item, _) = iMatch, let id = plan.matches.iCloud.recordableID(of: item) { file.iCloudID = id }
            if case .found(let item, _) = dMatch, let id = plan.matches.dropbox.recordableID(of: item) { file.dropboxID = id }
            let isHeld = held.contains(dKey(OneWaySyncPath.top(file.iCloudPath))) || held.contains(dKey(OneWaySyncPath.top(file.dropboxPath)))
                || iMatch.item.map { held.contains(dKey(OneWaySyncPath.top($0.path))) } == true
            let waits = waiting.iCloud.contains(iKey(file.iCloudPath)) || waiting.dropbox.contains(dKey(file.dropboxPath))
            let agreed = !isHeld && !waits && fate.allCounted && fate.location != nil && !fate.folderMoveFailed
            // Agreed, Dropbox's copy is where it is; otherwise where SyncCloud's own moves left it.
            file.dropboxPath = (agreed ? fate.location : fate.recordedPath) ?? file.dropboxPath
            if agreed, case .found(let i, _) = iMatch {
                file.iCloudPath = i.path
                if fate.wrote || fate.adopted {
                    file.size = i.size
                    file.modified = i.second
                    file.tags = i.tags
                    file.contentHash = i.contentHash ?? (fate.adopted ? dMatch.item?.contentHash : nil)
                } else if fate.tagged {
                    file.tags = i.tags
                }
                if let id = fate.dropboxID { file.dropboxID = id }
                if fate.undid { file.matchedICloudAt = now }
            }
            kept.append(file)
        }
        record.files = kept
    }

    /// Files no record held, recorded once every step for them landed: a copy, a first run's
    /// replace or rename, an adopted pair. A move back from SyncCloud Removed is recorded as soon
    /// as the move itself landed, with the contents it was removed with if its replace didn't.
    mutating func addNewFiles() {
        var iCloudByKey: [String: OneWaySyncItem] = [:]
        for item in pass.iCloud.items where item.kind == .file { iCloudByKey[iKey(item.path)] = item }
        var dropboxByKey: [String: OneWaySyncItem] = [:]
        for item in pass.dropbox.items where item.kind == .file { dropboxByKey[dKey(item.path)] = item }
        var pairDropbox: [String: OneWaySyncItem] = [:]
        for pair in plan.matches.pairs { pairDropbox[iKey(pair.iCloud.path)] = pair.dropbox }

        for (key, fate) in newFates.sorted(by: { $0.key < $1.key }) {
            guard let i = iCloudByKey[key], let location = fate.location else { continue }
            let d = pairDropbox[key] ?? dropboxByKey[dKey(location)]
            if let back = fate.movedBack {
                record.removed.removeAll { $0.removedPath == back.removedPath }
                var file = back.file
                file.iCloudPath = i.path
                file.dropboxPath = location
                file.iCloudID = plan.matches.iCloud.recordableID(of: i) ?? file.iCloudID
                file.dropboxID = fate.dropboxID ?? file.dropboxID
                file.iCloudGoneSince = nil
                if fate.allCounted && (fate.wrote || !contentsDiffer(i, file)) {
                    file.size = i.size
                    file.modified = i.second
                    file.tags = i.tags
                    file.contentHash = i.contentHash ?? file.contentHash
                }
                record.files.append(file)
                continue
            }
            guard fate.allCounted, fate.wrote || fate.adopted else { continue }
            let file = OneWaySyncFileRecord(
                key: record.nextKey, iCloudPath: i.path, dropboxPath: location,
                iCloudID: plan.matches.iCloud.recordableID(of: i),
                dropboxID: fate.dropboxID ?? d.flatMap { plan.matches.dropbox.recordableID(of: $0) },
                size: i.size, modified: i.second, tags: i.tags,
                contentHash: i.contentHash ?? (fate.adopted ? d?.contentHash : nil))
            record.nextKey += 1
            record.files.append(file)
        }
    }

    func contentsDiffer(_ item: OneWaySyncItem, _ file: OneWaySyncFileRecord) -> Bool {
        if item.size != file.size || item.second != file.modified { return true }
        if let hash = item.contentHash, let recorded = file.contentHash { return hash != recorded }
        return false
    }

    // MARK: Folders

    /// The synced folders take the IDs they have now and finish their first run; the folders below
    /// them are recorded from what both sides hold now. A held folder keeps everything it had.
    mutating func settleFolders(dropboxFolderID: (String) -> OneWaySyncFolderID?) {
        let held = heldTops
        // A first run is done once nothing it decided by first-run rules is still open: no pair
        // waiting on contents or on you, and every step for a new file landed.
        var unfinished = Set<String>()
        for wait in plan.waits {
            switch wait.reason {
            case .contentsNotRead, .dropboxNewerOnFirstRun, .sameDateOnFirstRun, .futureDateOnFirstRun:
                if case .file(let i, let d) = wait.subject { unfinished.insert(dKey(OneWaySyncPath.top(i ?? d ?? ""))) }
            default: break
            }
        }
        for (key, fate) in newFates where !fate.allCounted { unfinished.insert(dKey(OneWaySyncPath.top(key))) }
        var syncedNames = Set<String>()
        for index in record.syncedFolders.indices {
            let folder = record.syncedFolders[index]
            guard !held.contains(dKey(folder.iCloudPath)), !held.contains(dKey(folder.dropboxPath)) else { continue }
            syncedNames.insert(iKey(folder.iCloudPath))
            if case .found(let item, _) = plan.matches.iCloud.folders[folder.key] ?? .gone, item.folderID?.lookupKey != nil {
                record.syncedFolders[index].iCloudID = item.folderID
            }
            if case .found(let item, _) = plan.matches.dropbox.folders[folder.key] ?? .gone, item.folderID?.lookupKey != nil {
                record.syncedFolders[index].dropboxID = item.folderID
            }
            if !unfinished.contains(dKey(folder.iCloudPath)) { record.syncedFolders[index].firstRunCompleted = true }
        }

        var recordedKeyByPath: [String: UInt64] = [:]
        for folder in record.subfolders {
            if case .found(let item, _) = plan.matches.iCloud.folders[folder.key] ?? .gone { recordedKeyByPath[iKey(item.path)] = folder.key }
        }
        var subfolders = record.subfolders.filter { folder in
            held.contains(dKey(OneWaySyncPath.top(folder.iCloudPath))) || held.contains(dKey(OneWaySyncPath.top(folder.dropboxPath)))
        }
        let folders = pass.iCloud.items
            .filter { $0.kind == .folder && !$0.isExcluded && OneWaySyncPath.depth($0.path) >= 2
                && syncedNames.contains(iKey(OneWaySyncPath.top($0.path))) }
            .sorted { $0.path < $1.path }
        for item in folders {
            guard let dropboxID = dropboxFolderID(item.path), dropboxID.lookupKey != nil, item.folderID?.lookupKey != nil else { continue }
            let key: UInt64
            if let known = recordedKeyByPath[iKey(item.path)] {
                key = known
            } else {
                key = record.nextKey
                record.nextKey += 1
            }
            subfolders.append(OneWaySyncFolderRecord(
                key: key, iCloudPath: item.path, dropboxPath: item.path, iCloudID: item.folderID, dropboxID: dropboxID,
                firstRunCompleted: true))
        }
        record.subfolders = subfolders
    }
}
