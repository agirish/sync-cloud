//
//  OneWaySyncWriter.swift
//  SyncCloud
//

import Foundation

/// Where one-way sync reads and writes on this Mac.
public struct OneWaySyncPlaces: Sendable {
    /// The parents as set up, with the parent's own link already followed (iCloud ▸ Documents is
    /// `~/Documents` when Desktop & Documents is on).
    public var iCloudParent: URL
    public var dropboxParent: URL
    /// Dropbox's account folder, which holds SyncCloud Removed.
    public var dropboxAccountFolder: URL
    /// SyncCloud's own staging folder: outside both sides, on Dropbox's volume.
    public var staging: URL

    public init(iCloudParent: URL, dropboxParent: URL, dropboxAccountFolder: URL, staging: URL) {
        self.iCloudParent = iCloudParent
        self.dropboxParent = dropboxParent
        self.dropboxAccountFolder = dropboxAccountFolder
        self.staging = staging
    }

    /// `~/Library/Application Support/SyncCloud/One-Way Sync/Staging`.
    public static func defaultStaging(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SyncCloud/One-Way Sync/Staging", isDirectory: true)
    }
}

/// What applying one step did.
public enum OneWaySyncApplied: Equatable, Sendable {
    /// A file put in Dropbox, by a copy or a replace. `kept` is Dropbox's previous version, in
    /// SyncCloud Removed; `emptied` are versions DJ sent to Dropbox's deleted files to make room,
    /// which History logs.
    case wrote(dropboxPath: String, kept: OneWaySyncRemovedItem?, emptied: [OneWaySyncRemovedItem])
    case removed(OneWaySyncRemovedItem)
    case moved(to: String)
    case taggedFile(dropboxPath: String)
    /// Adopt and forget write nothing; the caller updates the record.
    case nothingToWrite
}

/// **Carries out a one-way sync plan's actions on disk**, one step at a time: RD67's file-writing
/// layer. The plan comes from `OneWaySyncPlanner`; the record and History are the caller's.
///
/// - **Copies stage outside Dropbox.** iCloud's file is read inside a coordinated read with a
///   deadline, its size, date and change time checked unchanged across the copy, into
///   `places.staging`, then moved into Dropbox under a name nothing holds. No `.tmp_` or
///   `.rollback_` file is ever made inside Dropbox.
/// - **Replace keeps the Dropbox item.** Dropbox's previous version is cloned (not moved) into
///   SyncCloud Removed (DG, DJ), then the staged file is renamed over the old one: measured on this
///   Mac, that keeps Dropbox's document ID, its item ID and the server's file ID. Nothing goes to
///   the Mac's Trash.
/// - **Dropbox's copy is re-checked just before** each write over it, move of it or removal of it,
///   against what the diff saw (`OneWaySyncExpectedState`); a change waits.
/// - **Nothing follows a symlink**, and no copy carries Dropbox's attributes.
///
/// Not thread-safe: one pass applies its steps in order from one task, off the main thread — every
/// call blocks on the disk and on file coordination.
public final class OneWaySyncWriter {
    public let places: OneWaySyncPlaces
    public let removed: OneWaySyncRemovedStore
    /// How long a coordinated read or write waits to be granted.
    public var coordinationDeadline: TimeInterval = 30
    /// The same, for an iCloud file that has to download first.
    public var downloadDeadline: TimeInterval = 10 * 60
    public var now: () -> Date = Date.init
    /// Offloads an iCloud file again after it was downloaded only to be copied.
    public var evict: (URL) -> Void = { try? FileManager.default.evictUbiquitousItem(at: $0) }

    /// Runs between a copy and the check that its source didn't change: a test's way in.
    var afterCopy: (URL) -> Void = { _ in }
    /// Runs in a replace just before the last check of Dropbox's file: a test's way in.
    var beforeLastCheck: (URL) -> Void = { _ in }

    /// Checks the staging folder can do its job: outside both sides, and on Dropbox's volume, so a
    /// staged file moves in without being copied again. Creates it when missing.
    ///
    /// Each place is taken canonical (its symlinks resolved once, here): every move refuses a
    /// symlink anywhere on its path, so a parent reached through one (`~/Dropbox`) would refuse all.
    public init(places: OneWaySyncPlaces, calendar: Calendar = .current) throws {
        let staging = places.staging.path
        func canonical(_ url: URL) -> URL { URL(fileURLWithPath: OneWaySyncDisk.canonicalPath(url), isDirectory: true) }
        self.places = OneWaySyncPlaces(
            iCloudParent: canonical(places.iCloudParent), dropboxParent: canonical(places.dropboxParent),
            dropboxAccountFolder: canonical(places.dropboxAccountFolder), staging: canonical(places.staging))
        self.removed = OneWaySyncRemovedStore(accountFolder: self.places.dropboxAccountFolder, calendar: calendar)
        let places = self.places
        let canonical = OneWaySyncDisk.canonicalPath(places.staging)
        for side in [places.iCloudParent, places.dropboxAccountFolder, places.dropboxParent] {
            let path = OneWaySyncDisk.canonicalPath(side)
            if OneWaySyncDisk.isWithin(canonical, path) || OneWaySyncDisk.isWithin(path, canonical) {
                throw OneWaySyncWriteError.stagingUnusable(staging)
            }
        }
        try FileManager.default.createDirectory(at: places.staging, withIntermediateDirectories: true)
        guard OneWaySyncDisk.kind(at: staging) == .folder,
              let device = OneWaySyncDisk.device(of: staging),
              device == OneWaySyncDisk.device(of: places.dropboxAccountFolder.path) else {
            throw OneWaySyncWriteError.stagingUnusable(staging)
        }
    }

    /// Deletes whatever a stopped pass left in staging. At the start of a pass, and at Turn Off.
    public func removeTemporaryFiles() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: places.staging.path)) ?? [] {
            OneWaySyncDisk.removeStaged(places.staging.appendingPathComponent(name))
        }
    }

    // MARK: One step

    /// Applies one step of a plan. `expected` is what the diff saw of the Dropbox file the step
    /// writes over, moves or removes; `file` is its record, which says where it came from in iCloud.
    public func apply(_ step: OneWaySyncStep, expected: OneWaySyncExpectedState?, file: OneWaySyncFileRecord?) throws -> OneWaySyncApplied {
        switch step.action {
        case .copy(let from, let to, let needsDownload):
            try copy(from: from, to: to, needsDownload: needsDownload)
            return .wrote(dropboxPath: to, kept: nil, emptied: [])
        case .replace(let dropboxPath, let iCloudPath, let needsDownload, let previousIsDropboxEdit):
            let result = try replace(dropboxPath: dropboxPath, with: iCloudPath, needsDownload: needsDownload,
                                     previousIsDropboxEdit: previousIsDropboxEdit, expected: expected, recordedID: file?.dropboxID)
            return .wrote(dropboxPath: dropboxPath, kept: result.kept, emptied: result.emptied)
        case .moveToRemoved(let dropboxPath, let cause):
            return .removed(try moveToRemoved(dropboxPath: dropboxPath, cause: cause, iCloudPath: file?.iCloudPath,
                                              expected: expected, recordedID: file?.dropboxID))
        case .moveInDropbox(let from, let to), .moveFolderInDropbox(let from, let to):
            try move(from: from, to: to, expected: expected)
            return .moved(to: to)
        case .moveBackFromRemoved(let removedPath, let to):
            try moveBack(removedPath: removedPath, to: to)
            return .moved(to: to)
        case .setTags(let dropboxPath, let tags):
            try setTags(dropboxPath: dropboxPath, tags: tags, expected: expected)
            return .taggedFile(dropboxPath: dropboxPath)
        case .adopt, .forget:
            return .nothingToWrite
        }
    }

    // MARK: Copy

    /// Copies iCloud's file to a Dropbox name nothing holds. An offloaded iCloud file is
    /// downloaded for the copy, then offloaded again.
    public func copy(from iCloudPath: String, to dropboxPath: String, needsDownload: Bool) throws {
        let target = try OneWaySyncDisk.url(dropboxPath, in: places.dropboxParent)
        if OneWaySyncDisk.kind(at: target.path) != nil { throw OneWaySyncWriteError.nameTaken(target.path) }
        let staged = try stage(iCloudPath, needsDownload: needsDownload)
        defer { OneWaySyncDisk.removeStaged(staged) }
        try OneWaySyncDisk.makeFolders(OneWaySyncPath.parent(dropboxPath), in: places.dropboxParent)
        try OneWaySyncDisk.moveExclusively(staged, to: target)
        ChangedFileLedger.shared.note(target.path)
    }

    /// iCloud's file, copied into staging inside a coordinated read, with its size, date and
    /// change time unchanged across the copy.
    func stage(_ iCloudPath: String, needsDownload: Bool) throws -> URL {
        let source = try OneWaySyncDisk.url(iCloudPath, in: places.iCloudParent)
        if OneWaySyncDisk.kind(at: source.path) == .symlink { throw OneWaySyncWriteError.symlink(source.path) }
        // The ID alone: a staged name never runs past the 255-unit limit a long name is near.
        let staged = places.staging.appendingPathComponent(UUID().uuidString)
        do {
            try OneWaySyncDisk.coordinatedRead(source, deadline: needsDownload ? downloadDeadline : coordinationDeadline) { read in
                let before = try OneWaySyncDisk.state(at: read.path)
                try OneWaySyncDisk.copy(read, to: staged)
                afterCopy(read)
                guard try OneWaySyncDisk.state(at: read.path) == before else { throw OneWaySyncWriteError.changedDuringCopy(read.path) }
            }
        } catch {
            OneWaySyncDisk.removeStaged(staged)
            throw error
        }
        if needsDownload { evict(source) }
        return staged
    }

    // MARK: Replace

    public struct Replaced: Equatable, Sendable {
        public var kept: OneWaySyncRemovedItem?
        public var emptied: [OneWaySyncRemovedItem]
    }

    /// Writes iCloud's file over Dropbox's, keeping the Dropbox item (its ID, links and history).
    /// Dropbox's previous version is cloned into SyncCloud Removed first when DG keeps it, and
    /// DJ then empties that file's oldest version past seven.
    ///
    /// A replace that stops after the clone takes the clone back out, so retrying never piles up
    /// copies: Dropbox's file was not touched. A file over a package or the other way round, and a
    /// Finder-locked Dropbox file, can't be renamed over, so they stop before anything is cloned.
    public func replace(dropboxPath: String, with iCloudPath: String, needsDownload: Bool, previousIsDropboxEdit: Bool,
                        expected: OneWaySyncExpectedState?, recordedID: UInt64? = nil) throws -> Replaced {
        let target = try OneWaySyncDisk.url(dropboxPath, in: places.dropboxParent)
        let seen = try check(target, against: expected)
        // A lock on the file, or on the folder it is in, refuses the rename at the end.
        for path in [target.path, target.deletingLastPathComponent().path] where OneWaySyncDisk.isLocked(path) {
            throw OneWaySyncWriteError.failed(path, errno: EPERM)
        }
        let staged = try stage(iCloudPath, needsDownload: needsDownload)
        defer { OneWaySyncDisk.removeStaged(staged) }
        if (OneWaySyncDisk.kind(at: staged.path) == .folder) != seen.isFolder { throw OneWaySyncWriteError.kindChanged(target.path) }

        let fileID = OneWaySyncDisk.documentID(at: target.path) ?? recordedID
        let accountPath = try self.accountPath(of: target)
        var result = Replaced(kept: nil, emptied: [])
        // A version made in Dropbox is always kept and never counted: no need to read the store.
        let items = previousIsDropboxEdit ? [] : removed.items()
        if removed.keepsPreviousVersion(fileID: fileID, dropboxPath: accountPath, previousIsDropboxEdit: previousIsDropboxEdit,
                                        at: now(), in: items) {
            let origin = OneWaySyncRemovedItem.Origin(
                dropboxPath: accountPath, iCloudParent: places.iCloudParent.path, iCloudPath: iCloudPath, fileID: fileID,
                removedAt: Int64(now().timeIntervalSince1970),
                kind: previousIsDropboxEdit ? .replacedDropboxVersion : .replacedSyncCloudVersion)
            result.kept = try keepVersion(of: target, unchanged: seen, origin: origin)
        }

        do {
            beforeLastCheck(target)
            // The clone took time: Dropbox may have written since.
            guard try OneWaySyncDisk.state(at: target.path) == seen else { throw OneWaySyncWriteError.changedSinceDiff(target.path) }
            try OneWaySyncDisk.moveOver(staged, onto: target)
        } catch {
            if let kept = result.kept { _ = removed.empty([kept]) }
            throw error
        }
        // DJ only once the new version is in: a replace that stopped short empties nothing.
        if let kept = result.kept, kept.origin.kind == .replacedSyncCloudVersion {
            let past = removed.versionsPastTheLimit(fileID: fileID, dropboxPath: accountPath, keeping: kept.path, in: items + [kept])
            result.emptied = removed.empty(past).emptied
        }
        ChangedFileLedger.shared.note(target.path)
        return result
    }

    /// Clones Dropbox's current version into staging inside a coordinated read, then moves the
    /// clone into the store with its origin already on it.
    func keepVersion(of target: URL, unchanged seen: OneWaySyncFileState, origin: OneWaySyncRemovedItem.Origin) throws -> OneWaySyncRemovedItem {
        let clone = places.staging.appendingPathComponent(UUID().uuidString)
        defer { OneWaySyncDisk.removeStaged(clone) }
        try OneWaySyncDisk.coordinatedRead(target, deadline: coordinationDeadline) { read in
            try OneWaySyncDisk.copy(read, to: clone)
            afterCopy(read)
            guard try OneWaySyncDisk.state(at: read.path) == seen else { throw OneWaySyncWriteError.changedSinceDiff(read.path) }
        }
        return try removed.moveInStaged(clone, origin: origin)
    }

    // MARK: Removal

    /// Moves Dropbox's file into SyncCloud Removed: a rename inside Dropbox, nothing downloaded.
    public func moveToRemoved(dropboxPath: String, cause: OneWaySyncRemovalCause, iCloudPath: String?,
                              expected: OneWaySyncExpectedState?, recordedID: UInt64? = nil) throws -> OneWaySyncRemovedItem {
        let target = try OneWaySyncDisk.url(dropboxPath, in: places.dropboxParent)
        _ = try check(target, against: expected)
        let kind: OneWaySyncRemovedItem.Kind
        switch cause {
        case .deletedInICloud: kind = .deletedInICloud
        case .movedOutInICloud: kind = .movedOutInICloud
        case .duplicateOfAdoptedFile: kind = .duplicateOfAdoptedFile
        }
        let origin = OneWaySyncRemovedItem.Origin(
            dropboxPath: try accountPath(of: target), iCloudParent: places.iCloudParent.path, iCloudPath: iCloudPath,
            fileID: OneWaySyncDisk.documentID(at: target.path) ?? recordedID,
            removedAt: Int64(now().timeIntervalSince1970), kind: kind)
        return try removed.moveIn(target, origin: origin)
    }

    /// Moves an item SyncCloud Removed holds back into Dropbox, under a name nothing holds. Its
    /// origin goes: it is a synced file again.
    public func moveBack(removedPath: String, to dropboxPath: String) throws {
        guard removedPath.hasPrefix(OneWaySyncRemovedStore.folderName + "/") else { throw OneWaySyncWriteError.badPath(removedPath) }
        let source = try OneWaySyncDisk.url(removedPath, in: places.dropboxAccountFolder)
        if OneWaySyncDisk.kind(at: source.path) == .symlink { throw OneWaySyncWriteError.symlink(source.path) }
        let target = try OneWaySyncDisk.url(dropboxPath, in: places.dropboxParent)
        try OneWaySyncDisk.makeFolders(OneWaySyncPath.parent(dropboxPath), in: places.dropboxParent)
        try OneWaySyncDisk.moveExclusively(source, to: target)
        removexattr(target.path, OneWaySyncRemovedStore.originAttribute, XATTR_NOFOLLOW)
        removed.pruneEmptyFolders(above: removedPath)
        ChangedFileLedger.shared.note(target.path)
    }

    // MARK: Moves and tags

    /// Renames or moves a file or folder inside Dropbox, under a name nothing holds. A cycle
    /// (a↔b) arrives from the plan already split through a temporary name in the same folder.
    public func move(from: String, to: String, expected: OneWaySyncExpectedState? = nil) throws {
        let source = try OneWaySyncDisk.url(from, in: places.dropboxParent)
        let target = try OneWaySyncDisk.url(to, in: places.dropboxParent)
        if OneWaySyncDisk.kind(at: source.path) == .symlink { throw OneWaySyncWriteError.symlink(source.path) }
        if let expected { _ = try check(source, against: expected) }
        try OneWaySyncDisk.makeFolders(OneWaySyncPath.parent(to), in: places.dropboxParent)
        try OneWaySyncDisk.moveExclusively(source, to: target)
        ChangedFileLedger.shared.note(target.path)
    }

    /// Sets a Dropbox file's Finder tags to iCloud's.
    public func setTags(dropboxPath: String, tags: [String], expected: OneWaySyncExpectedState? = nil) throws {
        let target = try OneWaySyncDisk.url(dropboxPath, in: places.dropboxParent)
        _ = try check(target, against: expected)
        var url = target
        var values = URLResourceValues()
        values.tagNames = tags
        try url.setResourceValues(values)
        ChangedFileLedger.shared.note(target.path)
    }

    /// Where `moveToRemoved` would put the Dropbox file at `dropboxPath` now, relative to the
    /// account folder: what History is ticked with before the move.
    public func removalPlace(dropboxPath: String) -> String? {
        guard let target = try? OneWaySyncDisk.url(dropboxPath, in: places.dropboxParent),
              let accountPath = try? accountPath(of: target) else { return nil }
        return removed.nextPlace(forDropboxPath: accountPath, at: now())
    }

    // MARK: Helpers

    /// Dropbox's file, re-checked against what the diff saw. Returns its state now.
    func check(_ url: URL, against expected: OneWaySyncExpectedState?) throws -> OneWaySyncFileState {
        let state = try OneWaySyncDisk.state(at: url.path)
        if let expected, !expected.matches(state, documentID: OneWaySyncDisk.documentID(at: url.path)) {
            throw OneWaySyncWriteError.changedSinceDiff(url.path)
        }
        return state
    }

    /// `url`'s path relative to the Dropbox account folder, the way SyncCloud Removed files it.
    func accountPath(of url: URL) throws -> String {
        let base = OneWaySyncDisk.canonicalPath(places.dropboxAccountFolder)
        let path = OneWaySyncDisk.canonicalPath(url)
        guard path != base, OneWaySyncDisk.isWithin(path, base) else { throw OneWaySyncWriteError.badPath(url.path) }
        return String(path.dropFirst(base.count + 1))
    }

}

// MARK: - Upload confirmation

/// How a file SyncCloud put in Dropbox stands once its upload is read.
public enum OneWaySyncUploadOutcome: Equatable, Sendable {
    /// Dropbox reports it uploaded. `documentID` is read again now, for the record.
    case uploaded(documentID: UInt64?)
    /// Dropbox won't take it (an upload error naming the file, or its ignore mark): listed,
    /// blocking nothing.
    case refused(String)
    /// Gone from where it was put: whatever moved it, the next pass sees.
    case gone
    /// Not reported uploaded by the deadline, or the wait was cancelled. Not synced.
    case notConfirmed
}

public enum OneWaySyncUploads {
    /// What one read of a file's upload says.
    public enum Reading: Equatable, Sendable {
        case upload(CloudAppStatusModel.UploadReading)
        case gone
        case ignoredByDropbox
    }

    /// Reads `path`'s upload: gone, carrying Dropbox's ignore mark (`com.dropbox.ignored`, which
    /// Dropbox never uploads), or what RD68's reading says.
    public static func reading(at path: String) -> Reading {
        guard OneWaySyncDisk.kind(at: path) != nil else { return .gone }
        if OneWaySyncDisk.attribute("com.dropbox.ignored", at: path) != nil { return .ignoredByDropbox }
        return .upload(CloudAppStatusModel.reading(at: path))
    }

    /// **Nothing counts as synced until Dropbox reports the upload** — measured: not uploaded,
    /// uploading, then uploaded, 7–18 s after a file is put in place. Reads each file every
    /// `interval` until it is uploaded, refused or gone, or `deadline` passes, then reads its
    /// document ID again: an ID is only worth recording once Dropbox has the file. `settled` hears
    /// each file as soon as its outcome is known.
    ///
    /// The reads block on File Provider, which has hung before, so they run off the cooperative
    /// pool, on one serial queue, and a round that hasn't answered when the deadline passes is
    /// left to finish alone: a wedged File Provider holds one thread, however many passes ask.
    public static func confirm(
        _ paths: [String], interval: Duration = .seconds(2), deadline: Duration = .seconds(CloudAppStatusModel.uploadDeadline),
        reading: @escaping @Sendable (String) -> Reading = OneWaySyncUploads.reading(at:),
        documentID: @escaping @Sendable (String) -> UInt64? = OneWaySyncDisk.documentID(at:),
        settled: @Sendable (String, OneWaySyncUploadOutcome) -> Void = { _, _ in }
    ) async -> [String: OneWaySyncUploadOutcome] {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)
        var outcomes: [String: OneWaySyncUploadOutcome] = [:]
        var waiting = paths
        while !waiting.isEmpty, !Task.isCancelled {
            let round = waiting
            guard let read = await offPool(until: end, {
                round.map { path -> (String, OneWaySyncUploadOutcome?) in
                    switch reading(path) {
                    case .upload(.uploaded): return (path, .uploaded(documentID: documentID(path)))
                    case .upload(.refused(let reason)): return (path, .refused(reason))
                    case .ignoredByDropbox: return (path, .refused("Dropbox ignores it"))
                    case .gone: return (path, .gone)
                    case .upload(.pending), .upload(.unknown): return (path, nil)
                    }
                }
            }) else { break }
            waiting = []
            for (path, outcome) in read {
                if let outcome {
                    outcomes[path] = outcome
                    settled(path, outcome)
                } else {
                    waiting.append(path)
                }
            }
            guard !waiting.isEmpty, clock.now < end else { break }
            do { try await Task.sleep(for: min(interval, clock.now.duration(to: end))) } catch { break }
        }
        for path in waiting where outcomes[path] == nil {
            outcomes[path] = .notConfirmed
            settled(path, .notConfirmed)
        }
        return outcomes
    }

    static let readQueue = DispatchQueue(label: "com.abhishekgirish.SyncCloud.one-way-sync.upload-reads", qos: .userInitiated)

    /// Runs `work` on `readQueue` and returns its answer, or nil once `end` passes or the task is
    /// cancelled first; a late answer is dropped.
    static func offPool<T: Sendable>(until end: ContinuousClock.Instant, _ work: @escaping @Sendable () -> T) async -> T? {
        let once = ResumeOnce<T?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.lock.lock()
                once.continuation = continuation
                once.lock.unlock()
                // A cancel that came before the continuation was stored resumed nothing.
                if Task.isCancelled { once.resume(nil) }
                readQueue.async { once.resume(work()) }
                let wait = ContinuousClock.now.duration(to: end)
                let nanoseconds = max(0, wait.components.seconds * 1_000_000_000 + wait.components.attoseconds / 1_000_000_000)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) { once.resume(nil) }
            }
        } onCancel: {
            once.resume(nil)
        }
    }
}

/// A continuation resumed by whichever of several callers comes first; the rest do nothing.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<T, Never>?

    func resume(_ value: T) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}
