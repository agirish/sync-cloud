//
//  OneWaySyncRun.swift
//  SyncCloud
//

import Darwin
import Events
import Foundation

/// One look at both sides: the listings, the plan made from them, and what the lister skipped.
/// What *Sync Now* applies, and what the first run's preview and the review sheets show.
public struct OneWaySyncLook: Sendable {
    public var pass: OneWaySyncPass
    public var plan: OneWaySyncPlan
    public var iCloud: OneWaySyncSideListing
    public var dropbox: OneWaySyncSideListing
    /// Offloaded iCloud files whose contents a decision still needs: compared only once downloaded.
    public var contentsLeftUnread: [String]
    /// Dropbox files in the synced folders that aren't on this Mac. Dropbox keeps every file here
    /// (measured), so one that isn't stops the whole sync as unsupported.
    public var dropboxNotHere: [String] {
        let synced = Set(pass.record.syncedFolders.map { OneWaySyncSide.dropbox.nameKey($0.dropboxPath) })
        return pass.dropbox.items.filter {
            $0.kind == .file && !$0.isDownloaded && !$0.isExcluded && synced.contains(OneWaySyncSide.dropbox.nameKey(OneWaySyncPath.top($0.path)))
        }.map(\.path)
    }

    /// The numbers the first run's preview shows.
    public var summary: OneWaySyncSummary { OneWaySyncSummary(self) }

    /// What Now lists as skipped: what the lister left out, and files whose copy Dropbox refused
    /// and that are unchanged in iCloud since, by their iCloud path.
    public var skipped: [OneWaySyncSkippedItem] {
        iCloud.skipped + plan.waits.compactMap { wait in
            guard wait.reason == .refusedByDropbox, case .file(let iCloudPath?, _) = wait.subject else { return nil }
            return OneWaySyncSkippedItem(path: iCloudPath, reason: OneWaySyncSkippedItem.dropboxWontTakeIt)
        }
    }

    /// iCloud files that wait because their contents, or their Dropbox counterpart's, couldn't
    /// be read to compare (a read failed, or a download didn't finish), by their iCloud path.
    public var unread: [String] {
        Array(Set(plan.waits.compactMap { wait -> String? in
            guard wait.reason == .contentsNotRead, case .file(let i, let d) = wait.subject else { return nil }
            return i ?? d
        })).sorted()
    }

    /// The iCloud item at `path`, as listed.
    public func iCloudItem(_ path: String) -> OneWaySyncItem? {
        let key = OneWaySyncSide.iCloud.nameKey(path)
        return pass.iCloud.items.first { OneWaySyncSide.iCloud.nameKey($0.path) == key }
    }

    /// The Dropbox item at `path`, as listed.
    public func dropboxItem(_ path: String) -> OneWaySyncItem? {
        let key = OneWaySyncSide.dropbox.nameKey(path)
        return pass.dropbox.items.first { OneWaySyncSide.dropbox.nameKey($0.path) == key }
    }
}

public struct OneWaySyncSummary: Equatable, Sendable {
    public var copies = 0
    public var copyBytes: Int64 = 0
    /// iCloud newer: replaced, Dropbox's version kept in SyncCloud Removed.
    public var replaces = 0
    public var replaceBytes: Int64 = 0
    /// Renamed or moved in Dropbox to match: nothing uploaded.
    public var moves = 0
    public var removals = 0
    /// Already the same: recorded, nothing written.
    public var same = 0
    public var waitsForYou = 0
    public var dropboxOnly = 0
    /// Bytes to download from iCloud: offloaded files to copy, replace or compare.
    public var downloadBytes: Int64 = 0
    /// What Dropbox holds of the synced folders once the run is done: everything iCloud holds there.
    public var syncedBytes: Int64 = 0

    public var changes: Int { copies + replaces + moves + removals }

    public init() {}

    init(_ look: OneWaySyncLook) {
        var iCloud: [String: OneWaySyncItem] = [:]
        for item in look.pass.iCloud.items where item.kind == .file { iCloud[OneWaySyncSide.iCloud.nameKey(item.path)] = item }
        for step in look.plan.steps {
            switch step.action {
            case .copy(let from, _, let download):
                copies += 1
                let size = iCloud[OneWaySyncSide.iCloud.nameKey(from)]?.size ?? 0
                copyBytes += size
                if download { downloadBytes += size }
            case .replace(_, let with, let download, _):
                replaces += 1
                let size = iCloud[OneWaySyncSide.iCloud.nameKey(with)]?.size ?? 0
                replaceBytes += size
                if download { downloadBytes += size }
            case .moveInDropbox(_, let to):
                if !OneWaySyncPath.name(to).hasPrefix(OneWaySyncPlanner.temporaryNamePrefix) { moves += 1 }
            case .moveFolderInDropbox:
                moves += 1
            case .moveToRemoved:
                removals += 1
            case .adopt:
                same += 1
            case .moveBackFromRemoved, .setTags, .forget:
                break
            }
        }
        for path in look.contentsLeftUnread { downloadBytes += iCloud[OneWaySyncSide.iCloud.nameKey(path)]?.size ?? 0 }
        waitsForYou = look.plan.waits.filter(\.reason.needsYou).count
        dropboxOnly = look.plan.dropboxOnly.count
        let synced = Set(look.pass.record.syncedFolders.map { OneWaySyncSide.iCloud.nameKey($0.iCloudPath) })
        syncedBytes = look.pass.iCloud.items
            .filter { $0.kind == .file && !$0.isExcluded && synced.contains(OneWaySyncSide.iCloud.nameKey(OneWaySyncPath.top($0.path))) }
            .reduce(0) { $0 + $1.size }
    }
}

/// What one *Sync Now* did.
public struct OneWaySyncRunResult: Sendable {
    public var look: OneWaySyncLook
    public var record: OneWaySyncRecord
    public var outcomes: [OneWaySyncStepOutcome]
    /// Steps that didn't go through, with why: Dropbox's copy changed since the check, a read
    /// timed out. Each is compared again at the next pass.
    public var notDone: [(path: String, why: String)]
    /// Files Dropbox won't take, from its upload reading, by their iCloud path.
    public var refused: [OneWaySyncSkippedItem]
    /// Written, but Dropbox didn't report the upload in time.
    public var unconfirmed: [String]
    /// Dropbox reported the account full for a file this pass wrote: the sync stops.
    public var dropboxFull = false

    public var synced: Int { outcomes.filter(\.counts).count }
}

extension OneWaySyncRunResult {
    /// What the log keeps of a pass besides its count, one line each: what went to SyncCloud
    /// Removed, what was replaced or moved back, what didn't go through and why, what Dropbox
    /// refused or hasn't reported, and what waits, by kind. Paths, never contents; at most 20 a line.
    public var logDetails: [String] {
        func listed(_ paths: [String]) -> String {
            paths.prefix(20).joined(separator: "; ") + (paths.count > 20 ? "; and \(paths.count - 20) more" : "")
        }
        var removed: [String] = [], replaced: [String] = [], movedBack: [String] = [], refusedWhy: [String] = []
        for (index, step) in look.plan.steps.enumerated() {
            switch (step.action, outcomes[index]) {
            case (.moveToRemoved(let path, _), .removed(let to)): removed.append("\(path) → \(to)")
            case (.replace(let path, _, _, _), let outcome) where outcome.happened: replaced.append(path)
            case (.moveBackFromRemoved(let from, let to), let outcome) where outcome.happened: movedBack.append("\(from) → \(to)")
            default: break
            }
            if case .refused(let why, _) = outcomes[index] {
                refusedWhy.append("\(OneWaySyncRun.dropboxPaths(of: step.action).first ?? "?") (\(why))")
            }
        }
        var lines: [String] = []
        if !removed.isEmpty { lines.append("moved to SyncCloud Removed: " + listed(removed)) }
        if !replaced.isEmpty { lines.append("replaced with iCloud’s version, the old one kept: " + listed(replaced)) }
        if !movedBack.isEmpty { lines.append("moved back from SyncCloud Removed: " + listed(movedBack)) }
        if !notDone.isEmpty { lines.append("didn’t go through: " + listed(notDone.map { "\($0.path) (\($0.why))" })) }
        if !refusedWhy.isEmpty { lines.append("Dropbox won’t take: " + listed(refusedWhy)) }
        if !unconfirmed.isEmpty { lines.append("not yet reported uploaded: " + listed(unconfirmed)) }
        var kinds: [String: Int] = [:]
        for wait in look.plan.waits { kinds[OneWaySyncRun.words(wait.reason), default: 0] += 1 }
        if !kinds.isEmpty { lines.append("waits: " + kinds.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")) }
        if !look.unread.isEmpty { lines.append("couldn’t be read to compare: " + listed(look.unread)) }
        return lines
    }
}

/// One one-way sync pass: look, then apply. Lists both sides, plans, reads the contents the plan
/// asks for and plans again; then applies the plan through `OneWaySyncWriter`, ticking History off
/// step by step, waits for Dropbox to report the uploads, and saves the record both sides now agree
/// on.
///
/// Blocking: every call reads or writes the disk. The caller runs it off the main thread; the
/// apply hops onto its own queue for the writes, so the cooperative pool never waits on a disk.
public enum OneWaySyncRun {

    /// How long a manual *Sync Now* waits for Dropbox to report its uploads. A file not reported
    /// by then isn't counted as synced, but is recorded as SyncCloud's own copy, and its upload
    /// read again before the next pass looks (``recheckPending(_:dropboxParent:now:confirm:)``).
    public static let uploadDeadline: Duration = .seconds(180)

    // MARK: Look

    /// Both sides listed against `record` and planned. `download` lets the contents of offloaded
    /// iCloud files be read (each downloaded, hashed and offloaded again); without it they are
    /// left unread and listed in `contentsLeftUnread`.
    public static func look(
        record: OneWaySyncRecord, state: OneWaySyncSavedState, exclusions: OneWaySyncExclusions,
        places: OneWaySyncPlaces, download: Bool, now: Date, outside: OneWaySyncOutsideFiles = OneWaySyncOutsideFiles(),
        isShared: @escaping @Sendable (URL) -> Bool = OneWaySyncLister.reportsShared,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> OneWaySyncLook {
        var iCloudLister = OneWaySyncLister(side: .iCloud, parent: places.iCloudParent)
        var dropboxLister = OneWaySyncLister(side: .dropbox, parent: places.dropboxParent)
        iCloudLister.isShared = isShared
        dropboxLister.isShared = isShared
        iCloudLister.isCancelled = isCancelled
        dropboxLister.isCancelled = isCancelled
        let iCloudSynced = Set(record.syncedFolders.map(\.iCloudPath))
        let dropboxSynced = Set(record.syncedFolders.map(\.dropboxPath))
        // Every other iCloud folder is read too, so a file moved out of the sync is told from one
        // deleted; Dropbox's others are none of the sync's business.
        let iCloudTop = (try? FileManager.default.contentsOfDirectory(atPath: iCloudLister.parent.path)) ?? []
        var iCloud = iCloudLister.list(syncedFolders: iCloudSynced, alsoInside: Set(iCloudTop).subtracting(iCloudSynced))
        var dropbox = dropboxLister.list(syncedFolders: dropboxSynced)
        exclude(exclusions, from: &iCloud.listing, side: .iCloud)
        exclude(exclusions, from: &dropbox.listing, side: .dropbox)
        exclude(setAside(iCloud.skipped, record: record), from: &dropbox.listing, side: .dropbox)

        // An item emptied from SyncCloud Removed since it went there (Choose Items to Empty…, or by
        // hand) can't be moved back: a file of its ID back in iCloud syncs as a new one.
        var record = record
        record.removed.removeAll { removed in
            (try? OneWaySyncDisk.url(removed.removedPath, in: places.dropboxAccountFolder)).map { OneWaySyncDisk.kind(at: $0.path) == nil } ?? true
        }
        let confirmed = Set(state.confirmed)
        var pass = OneWaySyncPass(
            record: record, iCloud: iCloud.listing, dropbox: dropbox.listing, settings: state.settings,
            window: state.window, confirmed: confirmed, outside: outside.byID, now: now)
        var hashes = Hashes(places: places, download: download, isCancelled: isCancelled)
        hashes.read(firstRunCandidates(pass), into: &pass)
        var plan = OneWaySyncPlanner.plan(pass)
        for _ in 0..<4 {
            let both = changedOnBothSides(plan, record: record)
            let wanted = (iCloud: plan.iCloudContentsToRead + both.iCloud, dropbox: plan.dropboxContentsToRead + both.dropbox)
            guard hashes.read(wanted, into: &pass) else { break }
            plan = OneWaySyncPlanner.plan(pass)
        }
        return OneWaySyncLook(pass: pass, plan: plan, iCloud: iCloud, dropbox: dropbox, contentsLeftUnread: hashes.leftUnread.sorted())
    }

    /// Takes the files the user stopped syncing out of a listing, by path or by ID: neither side
    /// sees them, so nothing is copied, replaced or removed for them.
    static func exclude(_ exclusions: OneWaySyncExclusions, from listing: inout OneWaySyncListing, side: OneWaySyncSide) {
        guard !exclusions.files.isEmpty else { return }
        let paths = Set(exclusions.files.map { side.nameKey(side == .iCloud ? $0.iCloudPath : $0.dropboxPath) })
        let ids = Set(exclusions.files.compactMap { side == .iCloud ? $0.iCloudID : $0.dropboxID })
        listing.items.removeAll { item in
            item.kind == .file && (paths.contains(side.nameKey(item.path)) || item.documentID.map(ids.contains) == true)
        }
    }

    /// iCloud packages the lister skipped as holding a symlink, set aside as files you stopped
    /// syncing are: Dropbox's item of the same name, and the copy a record holds of one synced
    /// before, aren't seen either. So none is replaced (the copy would be refused) and none is
    /// removed as gone from iCloud; a record of one is dropped, its Dropbox copy left as it is.
    static func setAside(_ skipped: [OneWaySyncSkippedItem], record: OneWaySyncRecord) -> OneWaySyncExclusions {
        let iKey = OneWaySyncSide.iCloud.nameKey
        var files: [OneWaySyncExclusion] = []
        for item in skipped where item.reason == OneWaySyncSkippedItem.holdsSymlink {
            files.append(OneWaySyncExclusion(iCloudPath: item.path, dropboxPath: item.path, stoppedAt: 0))
            for file in record.files where iKey(file.iCloudPath) == iKey(item.path) {
                files.append(OneWaySyncExclusion(iCloudPath: file.iCloudPath, dropboxPath: file.dropboxPath, dropboxID: file.dropboxID,
                                                 stoppedAt: 0))
            }
        }
        return OneWaySyncExclusions(files: files)
    }

    /// On a first run, files only content can pair: one of a size and type on each side, with
    /// different names. Read before planning, since the planner can only pair what it can compare.
    static func firstRunCandidates(_ pass: OneWaySyncPass) -> (iCloud: [String], dropbox: [String]) {
        let firstRun = Set(pass.record.syncedFolders.filter { !$0.firstRunCompleted }.flatMap {
            [OneWaySyncSide.dropbox.nameKey($0.iCloudPath), OneWaySyncSide.dropbox.nameKey($0.dropboxPath)]
        })
        guard !firstRun.isEmpty else { return ([], []) }
        // In one folder, as the matcher pairs them.
        struct Shape: Hashable { var folder: String; var size: Int64; var type: String }
        func candidates(_ items: [OneWaySyncItem]) -> [Shape: [OneWaySyncItem]] {
            var shapes: [Shape: [OneWaySyncItem]] = [:]
            for item in items where item.kind == .file && !item.isExcluded && item.size > OneWaySyncMatcher.contentsPairingMinimumSize
                && firstRun.contains(OneWaySyncSide.dropbox.nameKey(OneWaySyncPath.top(item.path))) {
                let shape = Shape(folder: OneWaySyncSide.dropbox.nameKey(OneWaySyncPath.parent(item.path)), size: item.size,
                                  type: (item.path as NSString).pathExtension.lowercased())
                shapes[shape, default: []].append(item)
            }
            return shapes
        }
        let iCloud = candidates(pass.iCloud.items), dropbox = candidates(pass.dropbox.items)
        var wanted: (iCloud: [String], dropbox: [String]) = ([], [])
        for (shape, iItems) in iCloud where iItems.count == 1 {
            guard let dItems = dropbox[shape], dItems.count == 1 else { continue }
            let key = OneWaySyncSide.dropbox.nameKey
            guard key(iItems[0].path) != key(dItems[0].path) else { continue }
            wanted.iCloud.append(iItems[0].path)
            wanted.dropbox.append(dItems[0].path)
        }
        return wanted
    }

    /// Recorded files changed on both sides to the same size: most often one SyncCloud wrote
    /// itself whose upload wasn't confirmed in time. Read, so identical contents record it rather
    /// than wait as edited on both sides.
    static func changedOnBothSides(_ plan: OneWaySyncPlan, record: OneWaySyncRecord) -> (iCloud: [String], dropbox: [String]) {
        var wanted: (iCloud: [String], dropbox: [String]) = ([], [])
        for file in record.files {
            guard case .found(let i, _) = plan.matches.iCloud.files[file.key] ?? .gone,
                  case .found(let d, _) = plan.matches.dropbox.files[file.key] ?? .gone,
                  i.size == d.size, i.size != file.size || i.second != file.modified,
                  d.size != file.size || d.second != file.modified(on: .dropbox),
                  i.contentHash == nil || d.contentHash == nil else { continue }
            if i.contentHash == nil { wanted.iCloud.append(i.path) }
            if d.contentHash == nil { wanted.dropbox.append(d.path) }
        }
        return wanted
    }

    /// The contents read so far this look, so none is read twice.
    struct Hashes {
        let places: OneWaySyncPlaces
        let download: Bool
        let isCancelled: @Sendable () -> Bool
        var tried: Set<String> = []
        var leftUnread: Set<String> = []

        /// Reads the wanted contents into `pass`; whether anything new was read.
        @discardableResult
        mutating func read(_ wanted: (iCloud: [String], dropbox: [String]), into pass: inout OneWaySyncPass) -> Bool {
            var changed = false
            for (side, paths) in [(OneWaySyncSide.iCloud, wanted.iCloud), (.dropbox, wanted.dropbox)] {
                let base = side == .iCloud ? places.iCloudParent : places.dropboxParent
                for path in paths {
                    let tag = (side == .iCloud ? "i:" : "d:") + side.nameKey(path)
                    guard !isCancelled(), tried.insert(tag).inserted else { continue }
                    var items = side == .iCloud ? pass.iCloud.items : pass.dropbox.items
                    guard let index = items.firstIndex(where: { side.nameKey($0.path) == side.nameKey(path) }),
                          items[index].contentHash == nil else { continue }
                    if side == .iCloud, !items[index].isDownloaded, !download {
                        leftUnread.insert(items[index].path)
                        continue
                    }
                    guard let url = try? OneWaySyncDisk.url(items[index].path, in: base),
                          let hash = OneWaySyncContents.hash(at: url.path, download: side == .iCloud && download,
                                                             isCancelled: isCancelled) else { continue }
                    leftUnread.remove(items[index].path)
                    items[index].contentHash = hash
                    if side == .iCloud { pass.iCloud.items = items } else { pass.dropbox.items = items }
                    changed = true
                }
            }
            return changed
        }
    }

    // MARK: Apply

    /// Applies `look.plan` and saves what came of it: History before anything is written, the
    /// removal window before any removal, the record and the state once the uploads are read, and
    /// the marker's last sync. `holdingBack` are Dropbox paths (relative to the Dropbox parent)
    /// still changing on their own, which this pass doesn't touch.
    public static func apply(
        _ look: OneWaySyncLook, state: OneWaySyncSavedState, firstRun: UUID, store: OneWaySyncStore,
        writer: OneWaySyncWriter, marker: OneWaySyncMarkerFile?, hardwareID: String, macName: String,
        holdingBack: Set<String> = [],
        isCancelled: @escaping @Sendable () -> Bool = { false },
        confirmUploads: @escaping @Sendable ([String]) async -> [String: OneWaySyncUploadOutcome] = {
            await OneWaySyncUploads.confirm($0, deadline: OneWaySyncRun.uploadDeadline)
        },
        now: @escaping @Sendable () -> Date = Date.init,
        progress: @escaping @Sendable (_ done: Int, _ of: Int) -> Void = { _, _ in }
    ) async throws -> OneWaySyncRunResult {
        let plan = look.plan
        var state = state
        // What the user changes while the pass runs (Pause, the settings, answers) is saved by
        // others, from the moment the pass started: each save here reads the state again and
        // changes only the pass's own fields.
        func savingState(_ change: (inout OneWaySyncSavedState) -> Void) throws {
            var current = store.loadState().value ?? state
            change(&current)
            try store.saveState(current)
        }
        // Before any removal: a crash after one would otherwise let it drop out of the 24 hours.
        try savingState { $0.window = plan.window }

        let history = store.history
        for unfinished in history.unfinished(firstRun: firstRun) { try? history.finish(unfinished.id, now: now()) }
        let entry = try history.begin(steps: plan.steps, held: plan.waits, firstRun: firstRun, now: now())

        nonisolated(unsafe) let writer = writer
        let applied = await onWriteQueue {
            writeSteps(look, writer: writer, history: history, entry: entry?.id, holdingBack: holdingBack, isCancelled: isCancelled,
                       now: now, progress: progress)
        }
        var outcomes = applied.outcomes
        // Files moved one by one out of a folder iCloud no longer has (its rename couldn't be one
        // move): the folder they left goes, once nothing at all is left in it.
        let emptied = await onWriteQueue {
            removeFoldersLeftEmpty(plan, outcomes: applied.outcomes, iCloud: look.pass.iCloud, dropboxParent: writer.places.dropboxParent)
        }
        if !emptied.isEmpty { Logger.shared.info("One-way sync: removed folders left empty in Dropbox: " + emptied.joined(separator: "; ")) }
        var refused: [OneWaySyncSkippedItem] = []
        var unconfirmed: [String] = []
        var dropboxFull = false
        var notDone = applied.notDone

        let dropboxParent = writer.places.dropboxParent
        func recordAfter(_ outcomes: [OneWaySyncStepOutcome]) -> OneWaySyncRecord {
            OneWaySyncRecordKeeper.update(
                look.pass.record, pass: look.pass, plan: plan, outcomes: outcomes,
                dropboxFolderID: { relative in
                    guard let url = try? OneWaySyncDisk.url(relative, in: dropboxParent) else { return nil }
                    var info = stat()
                    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
                    return OneWaySyncFolderID(inode: UInt64(info.st_ino))
                },
                now: now())
        }

        // Nothing counts as synced until Dropbox reports the upload.
        let written = applied.written
        if !written.isEmpty {
            // What the steps did is saved before the wait for uploads: a quit or a crash during it
            // would otherwise leave SyncCloud's own moves and writes to read as Dropbox's next time.
            try store.saveRecord(recordAfter(outcomes), firstRun: firstRun)
            let reports = await confirmUploads(written.map(\.absolute))
            for upload in written {
                switch reports[upload.absolute] ?? .notConfirmed {
                case .uploaded(let id):
                    outcomes[upload.step] = .landed(dropboxID: id)
                    if let entry { try? history.tick(entry.id, step: upload.step, status: .confirmed, now: now()) }
                case .refused(let why):
                    // Never counted as synced, however alike the copies: listed until iCloud's file changes.
                    let copy = (try? OneWaySyncDisk.state(at: upload.absolute)).map {
                        OneWaySyncExpectedState(size: $0.size, modified: $0.modifiedSecond, documentID: nil)
                    }
                    outcomes[upload.step] = .refused(why: why, copy: copy)
                    refused.append(OneWaySyncSkippedItem(path: iCloudPath(of: plan.steps[upload.step].action) ?? upload.relative,
                                                         reason: OneWaySyncSkippedItem.dropboxWontTakeIt))
                    if let entry { try? history.tick(entry.id, step: upload.step, status: .skipped(why), now: now()) }
                case .gone:
                    outcomes[upload.step] = .notDone
                    notDone.append((upload.relative, "it was moved or deleted in Dropbox before it uploaded"))
                case .notConfirmed:
                    outcomes[upload.step] = .unconfirmed
                    unconfirmed.append(upload.relative)
                case .dropboxFull:
                    outcomes[upload.step] = .unconfirmed
                    unconfirmed.append(upload.relative)
                    dropboxFull = true
                }
            }
        }

        var record = recordAfter(outcomes)
        record.pendingUploads = pendingUploads(after: written, outcomes: outcomes, plan: plan, record: record, now: now())
        try store.saveRecord(record, firstRun: firstRun)
        // Each landed step ticked again with the file as now recorded: what *Reverse in iCloud*
        // checks both sides against.
        if let entry {
            var byKey: [UInt64: OneWaySyncFileRecord] = [:]
            for file in record.files { byKey[file.key] = file }
            var removedByPath: [String: OneWaySyncFileRecord] = [:]
            for removed in record.removed { removedByPath[removed.removedPath] = removed.file }
            var byICloudPath: [String: OneWaySyncFileRecord] = [:]
            for file in record.files { byICloudPath[OneWaySyncSide.iCloud.nameKey(file.iCloudPath)] = file }
            for (index, step) in plan.steps.enumerated() where outcomes[index].counts {
                var recorded = step.record.flatMap { byKey[$0] }
                if case .removed(let path) = outcomes[index] { recorded = removedByPath[path] }
                if recorded == nil, case .moveInDropbox(_, let to) = step.action { recorded = byICloudPath[OneWaySyncSide.iCloud.nameKey(to)] }
                // A file copied in: Reverse moves it back where it came from.
                if recorded == nil, case .copy(let from, _, _) = step.action { recorded = byICloudPath[OneWaySyncSide.iCloud.nameKey(from)] }
                guard let recorded else { continue }
                let keptAt: String?
                if case .removed(let path) = outcomes[index] { keptAt = path } else { keptAt = nil }
                try? history.tick(entry.id, step: index, status: .confirmed, now: now(), keptAt: keptAt, recorded: recorded)
            }
        }

        // Where iCloud's other files are now: the next pass tells a file moved in by it.
        // A file moved in whose copy didn't land keeps where it came from, for the pass that copies it.
        var outside = OneWaySyncOutsideFiles(listing: look.pass.iCloud)
        for (index, step) in plan.steps.enumerated() where !outcomes[index].counts {
            guard let origin = step.movedInFrom, case .copy(let from, _, _) = step.action,
                  let id = look.iCloudItem(from).flatMap({ plan.matches.iCloud.recordableID(of: $0) }) else { continue }
            outside.carry(id: id, path: origin)
        }
        if outside.byID != look.pass.outside {
            do { try store.saveOutside(outside) } catch {
                Logger.shared.warning("One-way sync: where iCloud’s other files are couldn’t be saved: \(error.localizedDescription)")
            }
        }

        let done = Set(plan.steps.indices.filter { outcomes[$0].counts }.compactMap { plan.steps[$0].record })
        let finished = now()
        state.lastSyncAt = OneWaySyncHistoryStore.seconds(finished)
        let lastSyncAt = state.lastSyncAt
        try savingState {
            $0.confirmed.removeAll(where: done.contains)
            $0.lastSyncAt = lastSyncAt
        }
        if let entry { try? history.finish(entry.id, now: finished) }
        history.prune(now: finished, firstRun: firstRun)
        // Only over this Mac's own marker: another Mac that took the sync over while this pass ran
        // keeps it, and this Mac stops at its next start check.
        if let marker, case .thisMac(let existing) = marker.check(hardwareID: hardwareID) {
            do {
                try marker.write(OneWaySyncMacMarker(hardwareID: hardwareID, macName: macName, claimedAt: existing.claimedAt,
                                                     lastSyncAt: state.lastSyncAt))
            } catch {
                Logger.shared.warning("One-way sync: its marker in Dropbox couldn’t be written: \(error.localizedDescription)")
            }
        }
        return OneWaySyncRunResult(look: look, record: record, outcomes: outcomes, notDone: notDone, refused: refused,
                                   unconfirmed: unconfirmed, dropboxFull: dropboxFull)
    }

    /// The record's uploads still to hear about: those carried from before (whose files are still
    /// recorded), and this pass's writes Dropbox hadn't reported, each with its copy as written.
    static func pendingUploads(after written: [Written], outcomes: [OneWaySyncStepOutcome], plan: OneWaySyncPlan,
                               record: OneWaySyncRecord, now: Date) -> [OneWaySyncPendingUpload] {
        let dKey = OneWaySyncSide.dropbox.nameKey
        var byDropbox: [String: OneWaySyncFileRecord] = [:]
        for file in record.files { byDropbox[dKey(file.dropboxPath)] = file }
        var fresh: [OneWaySyncPendingUpload] = []
        for upload in written where outcomes[upload.step] == .unconfirmed {
            guard let file = byDropbox[dKey(upload.relative)], let state = try? OneWaySyncDisk.state(at: upload.absolute) else { continue }
            let step = plan.steps[upload.step]
            var wasNew = false
            if case .copy = step.action, step.record == nil { wasNew = true }
            fresh.append(OneWaySyncPendingUpload(record: file.key, dropboxPath: file.dropboxPath, wasNew: wasNew, size: state.size,
                                                 modified: state.modifiedSecond, writtenAt: OneWaySyncHistoryStore.seconds(now)))
        }
        let freshKeys = Set(fresh.map(\.record)), keys = Set(record.files.map(\.key))
        return record.pendingUploads.filter { !freshKeys.contains($0.record) && keys.contains($0.record) } + fresh
    }

    /// What reading the pending uploads again found.
    public struct PendingCheck: Sendable {
        public var record: OneWaySyncRecord
        /// Copies Dropbox now says it won't take, by their iCloud path: listed as skipped.
        public var refused: [String] = []
        /// Uploaded since, or no longer SyncCloud's copy: nothing more to hear.
        public var settled = 0
        /// Dropbox still reports the account full for one: the sync stops before writing more.
        public var stillFull = false
    }

    /// The uploads a pass didn't hear about, read again before the next one looks. A copy refused
    /// since leaves the record's synced files for its refusals, as one refused at once does; one
    /// uploaded, gone, or changed since leaves the list; one Dropbox still reports full stops the
    /// pass. One not answering yet stays, for a day.
    public static func recheckPending(
        _ record: OneWaySyncRecord, dropboxParent: URL, now: Date,
        confirm: @Sendable ([String]) async -> [String: OneWaySyncUploadOutcome] = {
            await OneWaySyncUploads.confirm($0, interval: .seconds(1), deadline: .seconds(5))
        }
    ) async -> PendingCheck {
        var check = PendingCheck(record: record)
        guard !record.pendingUploads.isEmpty else { return check }
        let seconds = OneWaySyncHistoryStore.seconds(now)
        var asking: [(OneWaySyncPendingUpload, String)] = []
        var kept: [OneWaySyncPendingUpload] = []
        for pending in record.pendingUploads {
            guard let url = try? OneWaySyncDisk.url(pending.dropboxPath, in: dropboxParent),
                  let state = try? OneWaySyncDisk.state(at: url.path),
                  state.size == pending.size, state.modifiedSecond == pending.modified else {
                check.settled += 1
                continue
            }
            asking.append((pending, url.path))
        }
        let outcomes = await confirm(asking.map(\.1))
        for (pending, path) in asking {
            switch outcomes[path] ?? .notConfirmed {
            case .uploaded(let id):
                check.settled += 1
                if let id, let index = check.record.files.firstIndex(where: { $0.key == pending.record }), check.record.files[index].dropboxID == nil {
                    check.record.files[index].dropboxID = id
                }
            case .gone:
                check.settled += 1
            case .refused(let why):
                guard let index = check.record.files.firstIndex(where: { $0.key == pending.record }) else { continue }
                let file = check.record.files[index]
                check.record.refused.removeAll { OneWaySyncSide.iCloud.nameKey($0.iCloudPath) == OneWaySyncSide.iCloud.nameKey(file.iCloudPath) }
                check.record.refused.append(OneWaySyncRefusedFile(
                    iCloudPath: file.iCloudPath, iCloudID: file.iCloudID, size: file.size, modified: file.modified, changed: file.changed,
                    dropboxPath: pending.dropboxPath, copySize: pending.size, copyModified: pending.modified,
                    record: pending.wasNew ? nil : file.key, why: why, refusedAt: seconds))
                // A copy of a file Dropbox never had isn't synced at all; an edit's keeps its record.
                if pending.wasNew { check.record.files.remove(at: index) }
                check.refused.append(file.iCloudPath)
            case .dropboxFull:
                check.stillFull = true
                kept.append(pending)
            case .notConfirmed:
                if seconds - pending.writtenAt < 86_400 { kept.append(pending) } else { check.settled += 1 }
            }
        }
        check.record.pendingUploads = kept
        return check
    }

    struct Written: Sendable {
        var step: Int
        var relative: String
        var absolute: String
    }

    struct Applied: Sendable {
        var outcomes: [OneWaySyncStepOutcome]
        var written: [Written]
        var notDone: [(path: String, why: String)]
    }

    /// Each step in order, on the write queue. A swap's temporary name is undone when a later
    /// step of its cycle fails, so nothing is left under it in Dropbox.
    static func writeSteps(
        _ look: OneWaySyncLook, writer: OneWaySyncWriter, history: OneWaySyncHistoryStore, entry: UUID?,
        holdingBack: Set<String>, isCancelled: @Sendable () -> Bool = { false }, now: @Sendable () -> Date,
        progress: (Int, Int) -> Void
    ) -> Applied {
        let plan = look.plan
        let dKey = OneWaySyncSide.dropbox.nameKey
        let held = Set(holdingBack.map(dKey))
        var outcomes = Array(repeating: OneWaySyncStepOutcome.notDone, count: plan.steps.count)
        var written: [Written] = []
        var notDone: [(String, String)] = []
        var records: [UInt64: OneWaySyncFileRecord] = [:]
        for file in look.pass.record.files { records[file.key] = file }
        var pairs: [String: OneWaySyncItem] = [:]
        for pair in plan.matches.pairs { pairs[OneWaySyncSide.iCloud.nameKey(pair.iCloud.path)] = pair.dropbox }
        /// Parked name → where the file was before it, and the step that parked it.
        var parked: [String: (original: String, step: Int)] = [:]
        /// What a replace left in Dropbox, by record (or new file's iCloud path): the move after it
        /// re-checks against that, not against the listing's older version.
        var rewritten: [String: OneWaySyncExpectedState] = [:]
        /// What a move back from SyncCloud Removed put in Dropbox, by its Dropbox name key: the
        /// replace that follows it re-checks against that.
        var movedBack: [String: OneWaySyncExpectedState] = [:]
        func writtenKey(_ step: OneWaySyncStep, iCloudPath: String) -> String {
            step.record.map { "r:\($0)" } ?? "i:" + OneWaySyncSide.iCloud.nameKey(iCloudPath)
        }

        func follow(from: String, to: String) {
            for w in written.indices where dKey(written[w].relative) == dKey(from) {
                written[w].relative = to
                written[w].absolute = (try? OneWaySyncDisk.url(to, in: writer.places.dropboxParent).path) ?? to
            }
        }

        var tickFailed = false
        func tick(_ index: Int, _ status: OneWaySyncHistoryStep.Status, keptAt: String? = nil, emptied: [String]? = nil) {
            guard let entry else { return }
            do { try history.tick(entry, step: index, status: status, now: now(), keptAt: keptAt, emptied: emptied) } catch {
                // Once a pass: the steps still apply; History shows them as not ticked off.
                if !tickFailed { Logger.shared.warning("One-way sync: History couldn’t be written: \(error.localizedDescription)") }
                tickFailed = true
            }
        }

        for (index, step) in plan.steps.enumerated() {
            progress(index, plan.steps.count)
            let touched = dropboxPaths(of: step.action)
            // Paused or stopped: the steps left wait for the next pass, a swap's park excepted,
            // which is undone below.
            if isCancelled() {
                notDone.append((touched.first ?? "", "the sync was stopped"))
                tick(index, .skipped("the sync was stopped"))
                continue
            }
            // A path inside the step's holds it too: saving a package changes the files in it.
            if touched.contains(where: { path in held.contains { OneWaySyncDisk.isWithin($0, dKey(path)) } }) {
                notDone.append((touched.first ?? "", "it is still changing in Dropbox"))
                tick(index, .skipped("still changing in Dropbox"))
                continue
            }
            // What the diff saw of the Dropbox file, by the step's record: later steps run after
            // earlier moves, so the step's own path may not be where the listing saw it.
            var expected: OneWaySyncExpectedState?
            if let key = step.record, let item = plan.matches.dropbox.files[key]?.item {
                expected = OneWaySyncExpectedState(item)
            } else {
                switch step.action {
                case .replace(let path, let with, _, _):
                    // A file never synced: the Dropbox file paired with it, or SyncCloud's refused copy.
                    let key = OneWaySyncSide.iCloud.nameKey(with)
                    expected = (pairs[key] ?? plan.refusedCopies[dKey(path)]).map(OneWaySyncExpectedState.init) ?? movedBack[dKey(path)]
                case .moveInDropbox(_, let to): expected = pairs[OneWaySyncSide.iCloud.nameKey(to)].map(OneWaySyncExpectedState.init)
                // SyncCloud's refused copy, its iCloud file gone.
                case .moveToRemoved(let path, _): expected = plan.refusedCopies[dKey(path)].map(OneWaySyncExpectedState.init)
                default: break
                }
            }
            if case .moveFolderInDropbox = step.action { expected = nil }
            if case .moveInDropbox(_, let to) = step.action, let after = rewritten[writtenKey(step, iCloudPath: to)] { expected = after }
            // A replace writes only over what was checked: one whose file the plan expected and
            // didn't find there (a move back before it that didn't land) leaves the name alone.
            if case .replace = step.action, expected == nil {
                notDone.append((touched.first ?? "", "what it would replace wasn’t the file the sync checked"))
                tick(index, .skipped("not the file the sync checked"))
                continue
            }
            var keptAt: String?
            if case .moveToRemoved(let path, _) = step.action {
                keptAt = writer.removalPlace(dropboxPath: path)
                tick(index, .started, keptAt: keptAt)
            }
            do {
                let result = try writer.apply(step, expected: expected, file: step.record.flatMap { records[$0] })
                switch result {
                case .wrote(let path, let kept, let emptied):
                    outcomes[index] = .unconfirmed
                    let absolute = (try? OneWaySyncDisk.url(path, in: writer.places.dropboxParent).path) ?? path
                    if case .replace(_, let with, _, _) = step.action, let state = try? OneWaySyncDisk.state(at: absolute) {
                        rewritten[writtenKey(step, iCloudPath: with)] = OneWaySyncExpectedState(
                            size: state.size, modified: state.modifiedSecond, documentID: OneWaySyncDisk.documentID(at: absolute))
                    }
                    written.append(Written(step: index, relative: path, absolute: absolute))
                    tick(index, .applied, keptAt: kept?.path, emptied: emptied.isEmpty ? nil : emptied.map(\.path))
                    if !emptied.isEmpty {
                        Logger.shared.info("One-way sync: past seven kept versions of \(path), sent the oldest to Dropbox’s deleted files: "
                                           + emptied.map(\.path).joined(separator: "; "))
                    }
                case .removed(let item):
                    outcomes[index] = .removed(removedPath: item.path)
                    tick(index, .confirmed, keptAt: item.path)
                case .moved(let to):
                    if case .moveBackFromRemoved = step.action {
                        outcomes[index] = .unconfirmed
                        let absolute = (try? OneWaySyncDisk.url(to, in: writer.places.dropboxParent).path) ?? to
                        if let state = try? OneWaySyncDisk.state(at: absolute) {
                            movedBack[dKey(to)] = OneWaySyncExpectedState(
                                size: state.size, modified: state.modifiedSecond, documentID: OneWaySyncDisk.documentID(at: absolute))
                        }
                        written.append(Written(step: index, relative: to, absolute: absolute))
                        tick(index, .applied)
                    } else {
                        outcomes[index] = .landed(dropboxID: nil)
                        tick(index, .confirmed)
                    }
                    if case .moveInDropbox(let from, let to) = step.action {
                        if OneWaySyncPath.name(to).hasPrefix(OneWaySyncPlanner.temporaryNamePrefix) { parked[to] = (from, index) }
                        parked[from] = nil
                        // A file written earlier in the pass and moved since (an edit and a rename
                        // together): its upload is read where it is now.
                        follow(from: from, to: to)
                    }
                case .taggedFile, .nothingToWrite:
                    outcomes[index] = .landed(dropboxID: nil)
                    tick(index, .confirmed)
                }
            } catch {
                let why = describe(error)
                notDone.append((touched.first ?? "", why))
                if case OneWaySyncWriteError.changedSinceDiff = error { tick(index, .skipped(why)) } else { tick(index, .failed(why)) }
            }
        }
        // A cycle cut short: the parked file goes back where it was, or where it was going.
        // The record is told: the park undone didn't happen; a park finished to its target did.
        for (temporary, park) in parked.sorted(by: { $0.key < $1.key }) {
            if (try? writer.move(from: temporary, to: park.original)) != nil {
                outcomes[park.step] = .notDone
                follow(from: temporary, to: park.original)
                continue
            }
            let finishing = plan.steps.indices.first { index in
                if case .moveInDropbox(let from, _) = plan.steps[index].action { return from == temporary }
                return false
            }
            if let finishing, case .moveInDropbox(_, let target) = plan.steps[finishing].action,
               (try? writer.move(from: temporary, to: target)) != nil {
                outcomes[finishing] = .landed(dropboxID: nil)
                follow(from: temporary, to: target)
                continue
            }
            notDone.append((temporary, "it couldn’t be put back after a swap of names stopped"))
        }
        progress(plan.steps.count, plan.steps.count)
        return Applied(outcomes: outcomes, written: written, notDone: notDone)
    }

    /// Puts back files a swap of names parked and never finished (the app quit mid-swap): under
    /// the name each had, where that is free, or else where the swap was taking it, as the
    /// unfinished History entry `steps` say. What can't go either way stays parked. Paths are
    /// relative to the Dropbox parent.
    public static func putBackParked(_ parked: [String], steps: [OneWaySyncStep], writer: OneWaySyncWriter)
        -> (putBack: [String], left: [String]) {
        var putBack: [String] = [], left: [String] = []
        let dKey = OneWaySyncSide.dropbox.nameKey
        for path in parked {
            guard let original = OneWaySyncPlanner.parkedOriginal(OneWaySyncPath.name(path)) else { continue }
            var targets = [OneWaySyncPath.join(OneWaySyncPath.parent(path), original)]
            for step in steps {
                if case .moveInDropbox(let from, let to) = step.action, dKey(from) == dKey(path) { targets.append(to) }
            }
            if let target = targets.first(where: { (try? writer.move(from: path, to: $0)) != nil }) {
                putBack.append(target)
            } else {
                left.append(path)
            }
        }
        return (putBack, left)
    }

    /// Removes, in Dropbox, each folder a move this pass took the last file out of, when iCloud
    /// has no folder there any more and it holds nothing but Finder's `.DS_Store`; then its parent,
    /// the same way, up to (never including) the synced folder. A folder holding anything stays.
    static func removeFoldersLeftEmpty(_ plan: OneWaySyncPlan, outcomes: [OneWaySyncStepOutcome], iCloud: OneWaySyncListing,
                                       dropboxParent: URL) -> [String] {
        // A Dropbox path is compared as Dropbox compares names: a synced folder "Family" in iCloud
        // may be "family" in Dropbox.
        let key = OneWaySyncSide.dropbox.nameKey
        let iCloudFolders = Set(iCloud.items.filter { $0.kind == .folder }.map { key($0.path) })
        var left = Set<String>()
        for (index, step) in plan.steps.enumerated() where outcomes[index].happened {
            guard case .moveInDropbox(let from, let to) = step.action,
                  OneWaySyncSide.dropbox.nameKey(OneWaySyncPath.parent(from)) != OneWaySyncSide.dropbox.nameKey(OneWaySyncPath.parent(to))
            else { continue }
            left.insert(OneWaySyncPath.parent(from))
        }
        var removed: [String] = []
        for start in left.sorted(by: { OneWaySyncPath.depth($0) > OneWaySyncPath.depth($1) }) {
            var folder = start
            while OneWaySyncPath.depth(folder) > 1, !iCloudFolders.contains(key(folder)),
                  let url = try? OneWaySyncDisk.url(folder, in: dropboxParent), OneWaySyncDisk.kind(at: url.path) == .folder,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: url.path), names.allSatisfy({ $0 == ".DS_Store" }) {
                unlink(url.appendingPathComponent(".DS_Store").path)
                guard rmdir(url.path) == 0 else { break }
                removed.append(folder)
                folder = OneWaySyncPath.parent(folder)
            }
        }
        return removed
    }

    /// The iCloud file a copy or replace writes from.
    static func iCloudPath(of action: OneWaySyncAction) -> String? {
        switch action {
        case .copy(let from, _, _): return from
        case .replace(_, let with, _, _): return with
        default: return nil
        }
    }

    /// The Dropbox paths a step reads or writes.
    public static func dropboxPaths(of action: OneWaySyncAction) -> [String] {
        switch action {
        case .moveFolderInDropbox(let from, let to), .moveInDropbox(let from, let to): return [from, to]
        case .moveToRemoved(let path, _), .replace(let path, _, _, _), .setTags(let path, _): return [path]
        case .copy(_, let to, _), .moveBackFromRemoved(_, let to): return [to]
        case .adopt, .forget: return []
        }
    }

    /// A wait's reason in the log's words.
    public static func words(_ reason: OneWaySyncWaitReason) -> String {
        switch reason {
        case .editedInDropbox: return "edited in Dropbox"
        case .editedOnBothSides: return "edited on both sides"
        case .deletedInICloudEditedInDropbox: return "deleted in iCloud, edited in Dropbox"
        case .deletedOrMovedInDropbox: return "deleted, renamed or moved in Dropbox"
        case .changedInDropboxAgainToday: return "changed in Dropbox again today"
        case .changedOnBothSides: return "changed on both sides"
        case .conflictedCopy: return "conflicted copies"
        case .nameTakenByDropboxOnlyFile, .nameTaken: return "name taken in Dropbox"
        case .dropboxNewerOnFirstRun: return "newer in Dropbox on a first run"
        case .sameDateOnFirstRun, .futureDateOnFirstRun: return "unclear which is newer on a first run"
        case .overRemovalLimit: return "over a folder’s removal limit"
        case .overRemovalLimitAcrossFolders: return "over the removal limit across folders"
        case .syncedFolderRenamedInICloud: return "synced folder renamed in iCloud"
        case .syncedFolderMovedOrDeletedInICloud: return "synced folder moved or deleted in iCloud"
        case .syncedFolderShared: return "synced folder shared now"
        case .syncedFolderChangedInDropbox: return "synced folder changed in Dropbox"
        case .waitingForRemovalOf: return "waiting for a removal"
        case .contentsNotRead: return "contents not read yet"
        case .refusedByDropbox: return "refused by Dropbox"
        }
    }

    /// A write error in the words a row or the log uses.
    public static func describe(_ error: Error) -> String {
        guard let error = error as? OneWaySyncWriteError else { return error.localizedDescription }
        switch error {
        case .symlink(let path): return "\(name(path)) is a symlink"
        case .missing(let path): return "\(name(path)) isn’t there any more"
        case .changedSinceDiff(let path): return "Dropbox’s copy of \(name(path)) changed since the check"
        case .changedDuringCopy(let path): return "\(name(path)) changed while it was being copied"
        case .coordinationTimedOut(let path): return "\(name(path)) was busy, or didn’t download in time"
        case .nameTaken(let path): return "the name \(name(path)) is taken"
        case .kindChanged(let path): return "\(name(path)) changed between a file and a package"
        case .stagingUnusable: return "SyncCloud’s staging folder isn’t usable"
        case .badPath(let path): return "\(path) isn’t a path SyncCloud writes"
        case .failed(let path, let code): return "\(name(path)): \(String(cString: strerror(code)))"
        }
    }

    static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    public static let writeQueue = DispatchQueue(label: "com.abhishekgirish.SyncCloud.one-way-sync.writes", qos: .userInitiated)

    /// Runs `work` on the queue every write of the sync goes through, one at a time.
    public static func onWriteQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            writeQueue.async { continuation.resume(returning: work()) }
        }
    }
}
