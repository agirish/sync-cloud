import Foundation
@testable import Sync

/// A RAM-only filesystem for unit tests: it implements `FileManaging` with volume constraints,
/// read/write state and injectable failures, without touching the real disk.
///
/// One recursive lock guards it, from both sides. Every method takes it, so the mock is safe to
/// drive from the parallel worker pools in `syncAll` and bulk verify, and every collection a test
/// and an operation both touch (``virtualDisk``, the recording lists, the arming sets) takes it at
/// the property, so a test's own access waits out whole operations too. Recursive because
/// `moveItem`/`trashItem` call `copyItem`/`removeItem` while holding it, and every method re-enters
/// it through those properties.
///
/// Flags, injected errors and hooks are plain properties, so the rule for them is order: arm them
/// before starting the operation and read them after it drains (a callback may disarm its own
/// hook). A racing `Bool` or `Int` read is merely stale, but a hook or error is a reference and can
/// crash like a collection.
///
/// **A callback that runs under the lock must never block**: `onFileExists`, `onAttributesOfItem`,
/// and `beforeCopyItem` when that copy is nested inside `moveItem`, `trashItem`, `replaceItem` or a
/// folder's own copy. It may touch the disk (the lock is recursive), but while it blocks every
/// other thread's access waits too, a test's `waitUntil` poll on the main actor included. Park in
/// ``beforeFileExists`` instead, which runs before `fileExists` takes the lock.
public final class MockFileManager: FileManaging, @unchecked Sendable {

    public struct FileStub {
        var isDirectory: Bool
        let attributes: [FileAttributeKey: Any]?
        var contents: [String]? // Child names if directory
    }

    private let lock = NSRecursiveLock()
    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Takes the lock for a locked property's `_modify`, returning the thread that took it.
    /// `_modify`, not `set`: a write mutates the collection in place under the lock, where a setter
    /// would copy the collection per assignment and its read-modify-write wouldn't be atomic.
    private func lockForMutation() -> pthread_t {
        lock.lock()
        return pthread_self()
    }

    /// Releases ``lockForMutation()``'s lock on the thread that took it, or stops the process. An
    /// access held `inout` across an `await` can end on another thread, and an `NSRecursiveLock`
    /// unlocked by a non-owner stays locked, so every later call into the mock would hang silently.
    private func unlockAfterMutation(_ owner: pthread_t) {
        precondition(pthread_equal(owner, pthread_self()) != 0,
                     "a MockFileManager property was held inout across an `await` and released on another thread")
        lock.unlock()
    }

    /// The RAM disk. A test reads it while the operation it started is still writing it (a
    /// `waitUntil` polls it), so it locks at the property.
    ///
    /// An unlocked read can land inside a write: during an in-place insert or remove, Swift parks a
    /// placeholder in the variable (`0x8000000000000000` on arm64), and a lookup that loads it
    /// treats it as a bridged `NSDictionary` and crashes (SIGSEGV at `0x10`, or SIGABRT on a
    /// selector sent to that address). A read that survives can still see half of a compound
    /// operation, such as a `moveItem` that has copied but not removed. See "An unlocked read of
    /// the mock's disk lands inside the write the test is waiting for" in `docs/flaky-tests.md`.
    ///
    /// **Never pass this, or any locked property here, `inout` across an `await`**: the access
    /// holds the lock for its whole length (see ``unlockAfterMutation(_:)``).
    public var virtualDisk: [String: FileStub] {
        get { sync { _virtualDisk } }
        _modify { let owner = lockForMutation(); defer { unlockAfterMutation(owner) }; yield &_virtualDisk }
    }
    private var _virtualDisk: [String: FileStub] = [:]

    /// Paths whose stub is a dangling symlink: the directory entry is there, its target is not.
    ///
    /// This is the state that separates the two existence probes: `fileExists(atPath:)` follows the
    /// link and answers `false`, while `attributesOfItem(atPath:)` describes the link and succeeds.
    /// Code that asks only the first can't see the entry at all (see `deleteItems(at:)`).
    ///
    /// Keep the stub in ``virtualDisk`` as well: the entry really is there, so trashing it works and
    /// removes it, as on a real volume.
    public var danglingSymlinks: Set<String> {
        get { sync { _danglingSymlinks } }
        _modify { let owner = lockForMutation(); defer { unlockAfterMutation(owner) }; yield &_danglingSymlinks }
    }
    private var _danglingSymlinks: Set<String> = []

    public init() {}

    /// Invoked (under the lock) after each `fileExists` check, both overloads, with the queried
    /// path. Lets a test plant a file right after an existence check to simulate a TOCTOU race (a
    /// cloud placeholder hydrating between the backup stat and the final move, say). The returned
    /// existence reflects the state before the callback, as a real stat would.
    public var onFileExists: ((String) -> Void)?

    /// Invoked (under the lock) after each successful `attributesOfItem`, with the queried path:
    /// the walk-progress seam. A test interleaving an edit with an identity walk needs to know the
    /// walk has read a file's pre-edit state, and the stat is that read, which neither
    /// `onFileExists` nor `onEnumerate` sees. Must not block (see the type's doc); setting a flag in
    /// a `LockedBox` is the usual use.
    public var onAttributesOfItem: ((String) -> Void)?

    /// Invoked once per `enumerator(at:…)` call, with the directory being listed. A listing is the
    /// unit of cost of a tree walk, so a test asserting a walk's budget counts these; counting
    /// entries or `fileExists` calls would measure the fixture's shape instead.
    public var onEnumerate: ((URL) -> Void)?

    /// Directories that exist but can't be listed (permission denied, I/O error, a vanished
    /// volume), so a test of the unreadable case isn't vacuous.
    ///
    /// Modelled on what the real `FileManager` does, which is counterintuitive: `enumerator(at:)`
    /// returns a non-nil enumerator that yields nothing and reports the failure through
    /// `errorHandler`. A mock that returned nil would make every `guard let enumerator … else` look
    /// tested while that branch stays dead in production.
    public var unlistableDirectories: Set<String> {
        get { sync { _unlistableDirectories } }
        _modify { let owner = lockForMutation(); defer { unlockAfterMutation(owner) }; yield &_unlistableDirectories }
    }
    private var _unlistableDirectories: Set<String> = []

    /// Invoked before the lock is taken, on the calling thread, for each `fileExists` check: the
    /// unlocked sibling of ``onFileExists``.
    ///
    /// It can park a call, which `onFileExists` can't: blocking there holds the recursive lock a
    /// concurrent identity walk's `attributesOfItem` needs, a deadlock. Blocking here holds nothing,
    /// so the walk runs on and the parked thread is a worker, not the main one. It may touch the
    /// disk and may block.
    public var beforeFileExists: ((String) -> Void)?

    /// Sets or removes one entry, the same as assigning into ``virtualDisk``, which takes the lock
    /// itself, so either is safe while a walk, a copy worker or a queued operation is live.
    public func setStub(_ stub: FileStub?, at path: String) {
        virtualDisk[path] = stub
    }

    public func fileExists(atPath path: String) -> Bool {
        beforeFileExists?(path)
        return sync {
            // A dangling link is followed to a missing target: `false`, as on a real volume, even
            // though the entry exists and `attributesOfItem` below describes it.
            let exists = virtualDisk.keys.contains(path) && !danglingSymlinks.contains(path)
            onFileExists?(path)
            return exists
        }
    }

    public func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        beforeFileExists?(path)
        return sync {
            let stub = virtualDisk[path]
            isDirectory?.pointee = ObjCBool(stub?.isDirectory ?? false)
            let exists = stub != nil
            onFileExists?(path)
            return exists
        }
    }

    public func attributesOfItem(atPath path: String) throws -> [FileAttributeKey : Any] {
        try sync {
            guard let stub = virtualDisk[path] else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
            }
            var attrs = stub.attributes ?? [:]
            attrs[.type] = danglingSymlinks.contains(path) ? FileAttributeType.typeSymbolicLink
                : (stub.isDirectory ? FileAttributeType.typeDirectory : FileAttributeType.typeRegular)
            // A real regular file always reports a size, so a stub built without attributes gets
            // one; otherwise anything reading its size would see "unknown", which the real
            // filesystem never produces. Synthesized like `.type` above, only if the fixture
            // didn't state one.
            if !stub.isDirectory, attrs[.size] == nil {
                attrs[.size] = NSNumber(value: 0)
            }
            onAttributesOfItem?(path)
            return attrs
        }
    }

    /// Runs before ``setAttributes(_:ofItemAtPath:)``, and so before every `setModificationDate`,
    /// while the mock holds no lock, so it may block. It parks Match Dates (which writes a date and
    /// copies nothing) the way ``beforeCopyItem`` parks a copy.
    public var beforeSetAttributes: ((String) -> Void)?

    public func setAttributes(_ attributes: [FileAttributeKey : Any], ofItemAtPath path: String) throws {
        beforeSetAttributes?(path)
        return try sync {
            guard let stub = virtualDisk[path] else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
            }
            var merged = stub.attributes ?? [:]
            for (k, v) in attributes { merged[k] = v }
            virtualDisk[path] = FileStub(isDirectory: stub.isDirectory, attributes: merged, contents: stub.contents)
        }
    }

    public func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws {
        try sync {
            let path = url.path
            if let existing = virtualDisk[path] {
                if createIntermediates && existing.isDirectory {
                    return // Native FileManager doesn't throw if the dir already exists and createIntermediates is true
                }
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
            }

            // Intermediate directories aren't modelled; only the requested one is created.
            virtualDisk[path] = FileStub(isDirectory: true, attributes: attributes, contents: [])
        }
    }

    public var calledCopyItem: Bool = false
    /// One-shot copy failure (like `shouldFailMove`): the next copyItem throws, then the flag resets
    /// so a retry succeeds, for pinning retry flows.
    public var shouldFailCopy: Bool = false

    /// Invoked with the source path before each `copyItem` takes the lock, so a test may block in
    /// it: that holds a bulk run mid-flight by its own I/O, rather than by a foreign operation
    /// parked on the queue ahead of it (which moves `fileOperationsEpoch` and so can't coexist with
    /// a live copy offer).
    ///
    /// Only a direct `copyItem` runs it without the lock. One nested inside `moveItem`,
    /// `trashItem`, `replaceItem` or a folder's own copy runs with the lock held, and blocking there
    /// blocks every other access to the mock (see the type's doc).
    public var beforeCopyItem: ((String) -> Void)?

    public func copyItem(at srcURL: URL, to dstURL: URL) throws {
        beforeCopyItem?(srcURL.path)
        try sync {
            calledCopyItem = true
            if shouldFailCopy {
                shouldFailCopy = false
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: "Simulated copy failure"])
            }
            let src = srcURL.path
            let dst = dstURL.path

            guard let sourceData = virtualDisk[src] else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
            }

            if virtualDisk[dst] != nil {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
            }

            virtualDisk[dst] = sourceData

            // Deep copy of the contents
            if sourceData.isDirectory, let children = sourceData.contents {
                for child in children {
                    try? copyItem(at: srcURL.appendingPathComponent(child), to: dstURL.appendingPathComponent(child))
                }
            }
        }
    }

    public var shouldFailMove: Bool = false
    public var shouldFailMoveOnTempRename: Bool = false
    /// Counted variant of `shouldFailMoveOnTempRename`, for flows where several consecutive `.tmp_`
    /// moves must fail (the replace swap-in and the restoring move-back).
    public var tempRenameFailuresRemaining: Int = 0

    public func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try sync {
            if shouldFailMove {
                shouldFailMove = false
                // Emulate a cross-device link failure (EXDEV)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV), userInfo: nil)
            }

            if failMoveToPathsOnce.contains(dstURL.path) {
                failMoveToPathsOnce.remove(dstURL.path)
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileWriteNoPermissionError, userInfo: nil)
            }

            if (shouldFailMoveOnTempRename || tempRenameFailuresRemaining > 0) && srcURL.path.contains(".tmp_") {
                shouldFailMoveOnTempRename = false
                if tempRenameFailuresRemaining > 0 { tempRenameFailuresRemaining -= 1 }
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: nil)
            }

            // A move is a copy plus a delete here
            try copyItem(at: srcURL, to: dstURL)
            try removeItem(at: srcURL)
            // Models the refusal `trashAfterReregistering` exists for: an item becomes trashable
            // only once it has been moved into the path being trashed. Without this the retry
            // would pass on `trashErrorOnce` alone, whether or not the move happened.
            movedInto.insert(dstURL.path)
        }
    }

    /// Destination paths whose next `moveItem` throws a permission error (then clears). The only
    /// way to reach `trashAfterReregistering`'s strand branch, where the park must succeed and the
    /// move back must fail; `shouldFailMove` clears on its first throw, so it always takes the park.
    public var failMoveToPathsOnce: Set<String> {
        get { sync { _failMoveToPathsOnce } }
        _modify { let owner = lockForMutation(); defer { unlockAfterMutation(owner) }; yield &_failMoveToPathsOnce }
    }
    private var _failMoveToPathsOnce: Set<String> = []

    /// When set, every `trashItem` throws this error, unlike `trashErrorOnce`, which clears on the
    /// first throw. The "nothing can trash this" case, where all three attempts are denied, as
    /// distinct from `trashRefusedUntilMovedIn`, which re-registering fixes. A once-only error
    /// can't express it: the retries would succeed because the injected failure ran out.
    public var trashErrorAlways: Error? = nil

    /// When set, `trashItem` refuses with a permission error for any path not moved into place
    /// since. This is the refusal seen on real files: both Trash APIs deny a long-registered item,
    /// and moving it re-registers it. Removing the production retry must fail the re-registration
    /// test, which `trashErrorOnce` alone couldn't ensure (it clears and lets any second attempt
    /// through).
    public var trashRefusedUntilMovedIn: Bool = false
    /// Paths that have been the destination of a `moveItem` on this mock.
    public var movedInto: Set<String> {
        get { sync { _movedInto } }
        _modify { let owner = lockForMutation(); defer { unlockAfterMutation(owner) }; yield &_movedInto }
    }
    private var _movedInto: Set<String> = []

    public var shouldFailTrash: Bool = false
    /// When set, `trashItem` moves the item to the Trash but reports no resulting location: the
    /// platform's nil `resultingItemURL`, which `deleteItems` must not read as a permanent delete.
    public var trashReportsNoLocation: Bool = false
    /// When set, the next `trashItem` throws this error (then clears), so a test can pin how
    /// `deleteItems` classifies a particular failure, such as a transient EBUSY versus an
    /// unsupported volume. Checked before `shouldFailTrash`.
    public var trashErrorOnce: Error? = nil
    public var trashedPaths: [String] {
        get { sync { _trashedPaths } }
        _modify { let owner = lockForMutation(); defer { unlockAfterMutation(owner) }; yield &_trashedPaths }
    }
    private var _trashedPaths: [String] = []
    public var enumeratorDelay: TimeInterval = 0
    public var failRemovePathsOnce: Set<String> {
        get { sync { _failRemovePathsOnce } }
        _modify { let owner = lockForMutation(); defer { unlockAfterMutation(owner) }; yield &_failRemovePathsOnce }
    }
    private var _failRemovePathsOnce: Set<String> = []

    /// Deterministic enumerator gate: when set, the first enumerator call signals `entered` and
    /// parks until `release` is signalled. Use it, not `enumeratorDelay`, for "load observably in
    /// flight" tests: a fixed delay loses its race under a loaded parallel run.
    ///
    /// The park is bounded and `ParkGate` records a timed-out release: check
    /// `try #require(!gate.releasedByTimeout)` after the load completes, or a walk that resumed on
    /// its own reads exactly like one the test held.
    public var enumeratorGate: ParkGate?
    private let gateLock = NSLock()
    private var gateFired = false

    public func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        try sync {
            if let err = trashErrorOnce {
                trashErrorOnce = nil
                throw err
            }
            if let err = trashErrorAlways {
                throw err
            }
            if trashRefusedUntilMovedIn, !movedInto.contains(url.path) {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileWriteNoPermissionError, userInfo: nil)
            }
            if shouldFailTrash {
                // A network drive without a Trash
                throw NSError(domain: POSIXError.errorDomain, code: Int(POSIXError.ENOTSUP.rawValue))
            }

            let path = url.path
            guard virtualDisk[path] != nil else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
            }

            // Emulate moving to ~/.Trash
            let trashedTarget = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(url.lastPathComponent)

            // A direct copy+remove, so injected move-failure flags apply only to the operation
            // under test, not to trash bookkeeping.
            try copyItem(at: url, to: trashedTarget)
            try removeItem(at: url)
            trashedPaths.append(trashedTarget.path)

            if !trashReportsNoLocation { outResultingURL?.pointee = trashedTarget as NSURL }
        }
    }

    /// Every path `removeItem` was called with, whether or not it succeeded. The mock disk is
    /// case-sensitive, so a removal that would hit a case variant on a real (case-insensitive)
    /// volume shows up here even though the mock throws no-such-file.
    public var attemptedRemovePaths: [String] {
        get { sync { _attemptedRemovePaths } }
        _modify { let owner = lockForMutation(); defer { unlockAfterMutation(owner) }; yield &_attemptedRemovePaths }
    }
    private var _attemptedRemovePaths: [String] = []

    public func removeItem(at URL: URL) throws {
        try sync {
            let path = URL.path
            attemptedRemovePaths.append(path)
            if failRemovePathsOnce.contains(path) {
                failRemovePathsOnce.remove(path)
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
            }
            guard let sourceData = virtualDisk[path] else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
            }

            virtualDisk.removeValue(forKey: path)

            // Deep remove
            if sourceData.isDirectory, let children = sourceData.contents {
                for child in children {
                    try? removeItem(at: URL.appendingPathComponent(child))
                }
            }
        }
    }

    public var calledReplaceItem: Bool = false

    /// Models `FileManager.replaceItemAt` atomically: the prior destination becomes the sibling
    /// backup, then the staged item takes its place. Both steps go through `moveItem`, so the
    /// injected failure flags still apply; the staged URL is a `.tmp_`, so
    /// `shouldFailMoveOnTempRename` fires on the swap-in for the rollback tests. On failure the
    /// original destination is restored, as the real primitive guarantees.
    public func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? {
        try sync {
            calledReplaceItem = true
            let backupURL = destinationURL.deletingLastPathComponent().appendingPathComponent(backupItemName)
            let hadDestination = virtualDisk[destinationURL.path] != nil
            if hadDestination {
                do {
                    try moveItem(at: destinationURL, to: backupURL)
                } catch {
                    // Backing up the destination failed and nothing was swapped, so the
                    // destination is left untouched (the real primitive's atomicity). Clean any
                    // partial backup so no stray artifact survives a failed replace.
                    try? removeItem(at: backupURL)
                    throw error
                }
            }
            do {
                try moveItem(at: stagedURL, to: destinationURL)
            } catch {
                if hadDestination {
                    try? moveItem(at: backupURL, to: destinationURL)
                }
                throw error
            }
            return hadDestination ? backupURL : nil
        }
    }

    public func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
        onEnumerate?(url)
        if let gate = enumeratorGate {
            gateLock.lock(); let first = !gateFired; if first { gateFired = true }; gateLock.unlock()
            if first { gate.park() }
        }
        if enumeratorDelay > 0 {
            Thread.sleep(forTimeInterval: enumeratorDelay)
        }

        // An unlistable root: report it and yield nothing, as the real enumerator does. The
        // enumerator stays non-nil; that is the point of modelling this.
        if unlistableDirectories.contains(url.path) {
            _ = handler?(url, NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))
            return MockEnumerator(urls: [])
        }

        // Snapshot the matching children under the lock, then hand off to the enumerator.
        let allChildren: [URL] = sync {
            var children: [URL] = []
            let root = url.path
            var blockedDescendants: [URL] = []
            var blockedEntries = Set<String>()
            // Read once per listing, not per key: each read of a locked property is a lock
            // round-trip, and this loop runs over every key of the virtual disk.
            let unlistableDirectories = self.unlistableDirectories

            for (key, _) in virtualDisk {
                if key.hasPrefix(root) && key != root {
                    let rel = String(key.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if rel.isEmpty { continue }

                    if mask.contains(.skipsSubdirectoryDescendants), rel.contains("/") {
                        continue
                    }

                    let itemURL = URL(fileURLWithPath: key)
                    if mask.contains(.skipsHiddenFiles) && itemURL.lastPathComponent.hasPrefix(".") {
                        continue
                    }

                    // An unlistable descendant is still yielded as an entry (it exists, it just
                    // can't be descended into) while everything below it is withheld, as the real
                    // enumerator does for a locked subdirectory, reporting it through the handler.
                    //
                    // Sorted by (length, path), not `first(where:)`: a Set's order depends on the
                    // per-launch hash seed, so with nested unlistable directories (/a and /a/b) the
                    // one reported would vary between runs. Shortest is outermost, the one the
                    // real enumerator meets first.
                    //
                    // Skipped when nothing is armed: the filter-and-sort allocates per entry, and
                    // this loop runs over every key on every enumeration.
                    let ancestors = unlistableDirectories.isEmpty ? [] : unlistableDirectories
                        .filter { key.hasPrefix($0 + "/") }
                        .sorted { ($0.count, $0) < ($1.count, $1) }
                    if let blocked = ancestors.first {
                        blockedDescendants.append(URL(fileURLWithPath: blocked))
                        // The blocked directory is itself a real entry, yielded whether or not the
                        // disk holds a stub for it. Otherwise a fixture that created only
                        // `/root/a/b` would withhold `/root/a` too, and a partial answer would read
                        // as a wholly unreadable root.
                        blockedEntries.insert(blocked)
                        continue
                    }
                    if unlistableDirectories.contains(key), !mask.contains(.skipsSubdirectoryDescendants) {
                        blockedDescendants.append(itemURL)
                    }
                    children.append(itemURL)
                }
            }
            for path in blockedEntries where !children.contains(where: { $0.path == path }) {
                children.append(URL(fileURLWithPath: path))
            }
            children.sort { $0.path < $1.path }

            var reported = Set<String>()
            for blocked in blockedDescendants where reported.insert(blocked.path).inserted {
                _ = handler?(blocked, NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))
            }
            return children
        }

        // `.producesRelativePathURLs` is modelled because a caller reads the answer through
        // `relativePath`. `FileManaging.listing(of:)` re-spells every entry as "the URL I was asked
        // about" + `relativePath` (how a folder reached through a symlink keeps the caller's
        // spelling at every depth), so an absolute `relativePath` would make it build
        // `/p//p/Health` and lose everything.
        //
        // `path` is unchanged either way, which is what existing assertions read, so this only
        // matters to a caller that asks for it (`listing(of:)`).
        guard mask.contains(.producesRelativePathURLs) else { return MockEnumerator(urls: allChildren) }
        let base = URL(fileURLWithPath: url.path, isDirectory: true)
        return MockEnumerator(urls: allChildren.map { child in
            let relative = String(child.path.dropFirst(url.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return URL(fileURLWithPath: relative, relativeTo: base)
        })
    }
}

public class MockEnumerator: FileManager.DirectoryEnumerator {
    private var urls: [URL]
    private var index = 0

    init(urls: [URL]) {
        self.urls = urls
    }

    public override func nextObject() -> Any? {
        if index < urls.count {
            let item = urls[index]
            index += 1
            return item
        }
        return nil
    }
}
