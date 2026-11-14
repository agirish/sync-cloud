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
    /// Written, but Dropbox didn't report the upload by the deadline: not counted in the pass's
    /// synced count, and History shows the step "Not yet uploaded"; but the record takes what
    /// SyncCloud wrote, so the next pass reads the copy as SyncCloud's own and not as an edit made
    /// in Dropbox. The record keeps it as a pending upload, read again before the next pass looks
    /// (`OneWaySyncRun.recheckPending`), which hears a refusal reported later.
    case unconfirmed
    /// Written, and Dropbox won't take it: never synced, and listed as skipped until iCloud's
    /// file changes (`OneWaySyncRecord.refused`). `why` is Dropbox's words; `copy` is the refused
    /// copy's size and date as read after the write, nil when it couldn't be read.
    case refused(why: String, copy: OneWaySyncExpectedState? = nil)
    /// Skipped or failed: nothing changed in Dropbox.
    case notDone

    public var happened: Bool {
        switch self {
        case .landed, .removed, .unconfirmed, .refused: return true
        case .notDone: return false
        }
    }

    var counts: Bool {
        switch self {
        case .landed, .removed: return true
        case .unconfirmed, .refused, .notDone: return false
        }
    }

    /// Whether the record takes the step as done: everything that counts, and a write Dropbox
    /// hasn't reported yet, which is SyncCloud's own copy whatever Dropbox later says of it.
    var agrees: Bool {
        switch self {
        case .landed, .removed, .unconfirmed: return true
        case .refused, .notDone: return false
        }
    }
}

/// The record after a pass: what both sides agree on once the plan's steps landed, or didn't.
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
///   later rename of one is one move in Dropbox;
/// - a file whose copy Dropbox refused is listed in `refused`, never recorded as synced, and stays
///   there until a retry lands; each agreed file keeps iCloud's change time.
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
        keeper.settleRefusals()
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
        /// A move back from SyncCloud Removed that landed: the removed file it was.
        var movedBack: OneWaySyncRemovedFile?
        /// Its copy or replace written and refused by Dropbox, with Dropbox's words and the copy.
        var refused: (why: String, copy: OneWaySyncExpectedState?)?
        /// A copy or replace of it was written, whatever Dropbox then said.
        var wroteAny = false
    }

    var fates: [UInt64: Fate] = [:]
    /// Files no record holds yet, by iCloud name key.
    var newFates: [String: Fate] = [:]
    /// Files whose copy Dropbox refused this pass.
    var newRefusals: [OneWaySyncRefusedFile] = []
    /// Refused copies moved to SyncCloud Removed this pass, by Dropbox path (name key).
    var removedRefusedCopies = Set<String>()

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
        case .moveToRemoved(let dropboxPath, let cause):
            if cause == .refusedCopy, case .removed = outcome { removedRefusedCopies.insert(dKey(dropboxPath)) }
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
                if case .unconfirmed = outcome { fate.wrote = true }
                if case .refused(let why, let copy) = outcome { fate.refused = (why, copy) }
                if outcome.happened { fate.wroteAny = true }
            }
        case .copy(let iCloudPath, let dropboxPath, _):
            change(step, iCloudPath: iCloudPath, outcome) { fate in
                if outcome.happened { fate.location = dropboxPath }
                if case .landed(let id) = outcome {
                    fate.wrote = true
                    fate.dropboxID = id
                }
                if case .unconfirmed = outcome { fate.wrote = true }
                if case .refused(let why, let copy) = outcome { fate.refused = (why, copy) }
                if outcome.happened { fate.wroteAny = true }
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
            if !outcome.agrees { fate.allCounted = false }
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
            // A conflicted copy waits; the synced file it was made from goes on syncing.
            if case .conflictedCopy = wait.reason {
                if let d { dropbox.insert(dKey(d)) }
                continue
            }
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
                let twin = pass.dropbox.items.first { dKey($0.path) == dKey(location) }
                file.take(i, dropboxSecond: twin?.second, hash: twin?.contentHash)
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
            if let refused = fate.refused, case .found(let i, _) = iMatch {
                newRefusals.append(refusal(of: i, at: fate.location ?? file.dropboxPath, record: file.key, refused))
            }
            // The IDs the files have now, wherever the match found them.
            if case .found(let item, _) = iMatch, let id = plan.matches.iCloud.recordableID(of: item) { file.iCloudID = id }
            if case .found(let item, _) = dMatch, let id = plan.matches.dropbox.recordableID(of: item) { file.dropboxID = id }
            let isHeld = held.contains(dKey(OneWaySyncPath.top(file.iCloudPath))) || held.contains(dKey(OneWaySyncPath.top(file.dropboxPath)))
                || iMatch.item.map { held.contains(dKey(OneWaySyncPath.top($0.path))) } == true
                || dMatch.item.map { held.contains(dKey(OneWaySyncPath.top($0.path))) } == true
            let waits = waiting.iCloud.contains(iKey(file.iCloudPath)) || waiting.dropbox.contains(dKey(file.dropboxPath))
            let agreed = !isHeld && !waits && fate.allCounted && fate.location != nil && !fate.folderMoveFailed
            // Agreed, Dropbox's copy is where it is; otherwise where SyncCloud's own moves left it.
            file.dropboxPath = (agreed ? fate.location : fate.recordedPath) ?? file.dropboxPath
            if agreed, case .found(let i, _) = iMatch {
                file.iCloudPath = i.path
                if fate.wrote {
                    file.take(i, dropboxSecond: nil, hash: nil)
                } else if fate.adopted {
                    // Identical, whatever the two dates: each side keeps its own.
                    file.take(i, dropboxSecond: dMatch.item?.second, hash: dMatch.item?.contentHash)
                } else {
                    if fate.tagged { file.tags = i.tags }
                    // A change time moved with nothing else is taken once the contents read as
                    // unchanged; until then the old one stays, so the next pass reads them again.
                    // One recorded while offloaded, or before change times were kept, is taken as is.
                    if !i.isDownloaded {
                        file.changed = nil
                    } else if file.changed == nil {
                        file.changed = i.changed
                    } else if plan.settledChangeTimes.contains(file.key) {
                        file.changed = i.changed
                        file.contentHash = i.contentHash ?? file.contentHash
                    }
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
                if fate.allCounted && (fate.wrote || !file.differs(from: i, on: .iCloud)) {
                    file.take(i, dropboxSecond: fate.wrote ? nil : file.modified(on: .dropbox), hash: file.contentHash)
                }
                record.files.append(file)
                continue
            }
            if let refused = fate.refused {
                newRefusals.append(refusal(of: i, at: location, record: nil, refused))
                continue
            }
            guard fate.allCounted, fate.wrote || fate.adopted else { continue }
            let file = OneWaySyncFileRecord(
                key: record.nextKey, iCloudPath: i.path, dropboxPath: location,
                iCloudID: plan.matches.iCloud.recordableID(of: i),
                dropboxID: fate.dropboxID ?? d.flatMap { plan.matches.dropbox.recordableID(of: $0) },
                size: i.size, modified: i.second, dropboxModified: fate.adopted && d?.second != i.second ? d?.second : nil,
                changed: Self.changeTime(i), tags: i.tags, contentHash: i.contentHash ?? (fate.adopted ? d?.contentHash : nil))
            record.nextKey += 1
            record.files.append(file)
        }
    }

    /// The change time a record keeps for iCloud's file: none while it is offloaded.
    static func changeTime(_ item: OneWaySyncItem) -> Int64? { item.isDownloaded ? item.changed : nil }

    func refusal(of i: OneWaySyncItem, at dropboxPath: String, record key: UInt64?,
                 _ refused: (why: String, copy: OneWaySyncExpectedState?)) -> OneWaySyncRefusedFile {
        OneWaySyncRefusedFile(
            iCloudPath: i.path, iCloudID: plan.matches.iCloud.recordableID(of: i), size: i.size, modified: i.second,
            changed: Self.changeTime(i), dropboxPath: dropboxPath, copySize: refused.copy?.size, copyModified: refused.copy?.modified,
            record: key, why: refused.why, refusedAt: now)
    }

    // MARK: Refused files

    /// What still stands, what was tried again and didn't land, and what Dropbox refused this pass;
    /// a refusal this pass replaces the one before it for the same file.
    mutating func settleRefusals() {
        var refused = plan.refused
        for retry in plan.retrying where !landed(retry) { refused.append(retry.refused) }
        for (path, refusal) in plan.removingRefusals where !removedRefusedCopies.contains(path) { refused.append(refusal) }
        let freshPaths = Set(newRefusals.map { iKey($0.iCloudPath) })
        let freshRecords = Set(newRefusals.compactMap(\.record))
        refused.removeAll { freshPaths.contains(iKey($0.iCloudPath)) || $0.record.map(freshRecords.contains) == true }
        record.refused = (refused + newRefusals).sorted { ($0.iCloudPath, $0.refusedAt) < ($1.iCloudPath, $1.refusedAt) }
    }

    /// Whether a retry is settled: something was written over the refused copy (Dropbox then took
    /// it, refused it again, or hasn't said: the copy is no longer the one refused, and an
    /// unreported upload is compared again like any other), an edit's file was removed, or a new
    /// file was recorded. A retry that wrote nothing keeps the refusal.
    func landed(_ retry: OneWaySyncRetry) -> Bool {
        if let key = retry.refused.record {
            guard let fate = fates[key] else { return true }
            return fate.wroteAny || (fate.anyStep && fate.allCounted)
        }
        guard let fate = newFates[iKey(retry.iCloudPath)] else { return false }
        return fate.wroteAny || (fate.allCounted && (fate.wrote || fate.adopted))
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
