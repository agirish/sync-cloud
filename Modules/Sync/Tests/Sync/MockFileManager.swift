import Foundation
@testable import Sync

/// A RAM-only filesystem simulator built for Unit Tests.
/// It intercepts `FileManaging` protocol endpoints to emulate standard volume constraints,
/// read/write states, and failure behaviors without interacting with the physical local disk.
///
/// **One recursive lock guards it, from both sides.** Every method takes it, so the mock is safe
/// to drive from the parallel worker pools in `syncAll` / bulk verify (up to 4 concurrent
/// operations), and every COLLECTION a test and an operation both touch — ``virtualDisk``, the
/// recording lists, the arming sets — takes it at the property, so a test's own read or write
/// waits out whole operations too. It is recursive because `moveItem`/`trashItem` call
/// `copyItem`/`removeItem` while holding it, and because every method re-enters it through those
/// properties.
///
/// Flags, injected errors and hooks stay plain properties, so the rule for them is order: arm them
/// before starting the operation and read them after it drains (a callback may disarm its own
/// hook). A racing read of a `Bool` or `Int` is merely stale, but a hook or an error is a
/// reference, and racing one could crash like a collection.
///
/// **A callback that runs under the lock must never block**: `onFileExists`, `onAttributesOfItem`,
/// and `beforeCopyItem` whenever that copy is nested inside `moveItem`, `trashItem`, `replaceItem`
/// or a folder's own copy. It may touch the disk — the lock is recursive — but while it blocks,
/// every other thread's access waits with it, a test's `waitUntil` poll on the main actor
/// included. Park in ``beforeFileExists`` instead, which runs before `fileExists` takes the lock.
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
    ///
    /// `_modify`, not `set`: a write mutates the collection in place, under the lock. A setter
    /// would copy the whole collection per subscript assignment, and its read-modify-write would
    /// not be atomic against an operation's own writes.
    private func lockForMutation() -> pthread_t {
        lock.lock()
        return pthread_self()
    }

    /// Releases ``lockForMutation()``'s lock on the thread that took it, or stops the process.
    /// An access held `inout` across an `await` can end on another thread, and an `NSRecursiveLock`
    /// unlocked by a thread that does not own it stays locked (measured, 2026-10-03): every later
    /// call into this mock would hang with nothing to say why.
    private func unlockAfterMutation(_ owner: pthread_t) {
        precondition(pthread_equal(owner, pthread_self()) != 0,
                     "a MockFileManager property was held inout across an `await` and released on another thread")
        lock.unlock()
    }

    /// The dictionary-backed RAM virtual disk. A test reads it while the operation it started is
    /// still writing it — a `waitUntil` polls it — which is why it locks at the property.
    ///
    /// Unlocked, that read can land inside a write. For the length of an in-place insert or remove,
    /// Swift parks a placeholder in the variable that holds the dictionary (`0x8000000000000000`
    /// on arm64), and a lookup that loads it takes it for a bridged `NSDictionary`: SIGSEGV at
    /// `0x10`, or SIGABRT on a selector sent to instance `0x8000000000000000`. A read that survives
    /// can still see half of a compound operation, such as a `moveItem` that has copied but not yet
    /// removed. See "An unlocked read of the mock's disk lands inside the write the test is waiting
    /// for" in `docs/flaky-tests.md`.
    ///
    /// **Never pass this, or any locked property here, `inout` across an `await`**: the access
    /// holds the lock for its whole length — see ``unlockAfterMutation(_:)``.
    public var virtualDisk: [String: FileStub] {
        get { sync { _virtualDisk } }
        _modify { let owner = lockForMutation(); defer { unlockAfterMutation(owner) }; yield &_virtualDisk }
    }
    private var _virtualDisk: [String: FileStub] = [:]

    /// Paths whose stub is a **dangling symlink**: the directory entry is there, its target is not.
    ///
    /// The one filesystem state that separates the two existence probes, and the reason this
    /// exists rather than a general symlink model: `fileExists(atPath:)` FOLLOWS the link and so
    /// answers `false`, while `attributesOfItem(atPath:)` reports on the link itself and succeeds.
    /// Production code that asks only the first cannot see the entry at all — see
    /// `deleteItems(at:)`, which skipped such an item silently.
    ///
    /// Keep the stub in ``virtualDisk`` as well: the entry really is there, so trashing it works
    /// and removes it, exactly as on a real volume.
    public var danglingSymlinks: Set<String> {
        get { sync { _danglingSymlinks } }
        _modify { let owner = lockForMutation(); defer { unlockAfterMutation(owner) }; yield &_danglingSymlinks }
    }
    private var _danglingSymlinks: Set<String> = []

    public init() {}

    /// Invoked (under the lock) after each `fileExists` check (both the plain and the
    /// `isDirectory:` overloads), with the queried path. Lets tests plant a file right after an
    /// existence check to simulate TOCTOU races (e.g. a cloud placeholder hydrating between the
    /// backup stat and the final move, or between the collision stat and the operation running).
    /// The returned existence reflects state *before* the callback runs, matching a real stat.
    public var onFileExists: ((String) -> Void)?

    /// Invoked (under the lock) after each successful `attributesOfItem` lookup, with the queried
    /// path — the walk-progress seam. A test that interleaves an EDIT with an identity walk needs
    /// to know the walk has already READ a file's pre-edit state; the stat IS that read, which
    /// neither `onFileExists` nor `onEnumerate` can witness. The callback runs under the lock, so
    /// it must not block (see the type's doc); setting a flag in a `LockedBox` is the usual use.
    public var onAttributesOfItem: ((String) -> Void)?

    /// Invoked once per `enumerator(at:…)` call, with the directory being listed. A listing is the
    /// unit of cost for a tree walk, so this is what a test asserting a walk's *budget* counts —
    /// counting entries or `fileExists` calls instead would measure the fixture's shape rather than
    /// how far the walk went.
    public var onEnumerate: ((URL) -> Void)?

    /// Paths of directories that exist but cannot be LISTED — permission denied, I/O error, a
    /// volume that went away. Without this the mock models a disk on which every directory is
    /// readable, so a test for the unreadable case could only pass vacuously.
    ///
    /// The modelled behaviour is what the real `FileManager` was measured doing, which is the
    /// opposite of the intuitive one: `enumerator(at:)` hands back a **non-nil enumerator that
    /// yields zero entries** and reports the failure through the `errorHandler` — it does not
    /// return nil. A mock that returned nil here would make every `guard let enumerator … else`
    /// look tested while that branch stays dead in production.
    public var unlistableDirectories: Set<String> {
        get { sync { _unlistableDirectories } }
        _modify { let owner = lockForMutation(); defer { unlockAfterMutation(owner) }; yield &_unlistableDirectories }
    }
    private var _unlistableDirectories: Set<String> = []

    /// Invoked BEFORE the lock is taken, on the calling thread, for each `fileExists` check —
    /// the unlocked sibling of ``onFileExists``.
    ///
    /// It exists for the one thing `onFileExists` cannot do: PARK a call. A test that needs a
    /// batch to wait at a known point until a concurrent identity walk has reached some file has
    /// to block somewhere, and blocking inside `onFileExists` holds the recursive lock the walk's
    /// own `attributesOfItem` needs — a deadlock, not a race. Blocking here holds nothing, so the
    /// walk runs on and the parked thread is a worker rather than the main one.
    ///
    /// Like `onFileExists` it may touch the disk; unlike it, it runs while the mock holds no lock,
    /// so it may also block.
    public var beforeFileExists: ((String) -> Void)?

    /// Sets or removes one entry — the same as assigning into ``virtualDisk``, which takes the
    /// lock itself, so either is safe while a walk, a copy worker or a queued operation is live.
    public func setStub(_ stub: FileStub?, at path: String) {
        virtualDisk[path] = stub
    }

    public func fileExists(atPath path: String) -> Bool {
        beforeFileExists?(path)
        return sync {
            // A dangling link is followed to a target that is not there — `false`, as on a real
            // volume, even though the entry exists and `attributesOfItem` below will describe it.
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
            // A real regular file always reports a size; a stub built without an attributes
            // dictionary reported none, so anything reading size off this double saw "unknown"
            // for an ordinary file — a state the real filesystem does not produce. Synthesized for
            // the same reason `.type` above is, and only when the fixture did not state one.
            if !stub.isDirectory, attrs[.size] == nil {
                attrs[.size] = NSNumber(value: 0)
            }
            onAttributesOfItem?(path)
            return attrs
        }
    }

    public func setAttributes(_ attributes: [FileAttributeKey : Any], ofItemAtPath path: String) throws {
        try sync {
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

            // In a true mock, we'd traverse and split intermediate structures,
            // but for generic target testing, we stub it barebones.
            virtualDisk[path] = FileStub(isDirectory: true, attributes: attributes, contents: [])
        }
    }

    public var calledCopyItem: Bool = false
    /// One-shot copy failure (mirrors `shouldFailMove`): the next copyItem throws, then the
    /// flag resets so a retry succeeds — for pinning retry flows.
    public var shouldFailCopy: Bool = false

    /// Invoked with the source path immediately BEFORE each `copyItem`, before that call takes the
    /// lock, so a test may block in it: that is what lets a bulk run be held genuinely mid-flight,
    /// by its own I/O, instead of by a foreign operation parked on the queue ahead of it (which
    /// moves `fileOperationsEpoch` and so cannot coexist with a live copy offer).
    ///
    /// Only a DIRECT `copyItem` runs it without the lock. One nested inside `moveItem`,
    /// `trashItem`, `replaceItem` or a folder's own copy is called with the lock already held, and
    /// blocking there blocks every other access to this mock (see the type's doc).
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

            // Deep copy simulated contents
            if sourceData.isDirectory, let children = sourceData.contents {
                for child in children {
                    try? copyItem(at: srcURL.appendingPathComponent(child), to: dstURL.appendingPathComponent(child))
                }
            }
        }
    }

    public var shouldFailMove: Bool = false
    public var shouldFailMoveOnTempRename: Bool = false
    /// Counted variant of `shouldFailMoveOnTempRename`, for pinning flows where SEVERAL
    /// consecutive `.tmp_` moves must fail (the replace swap-in AND the restoring move-back).
    public var tempRenameFailuresRemaining: Int = 0

    public func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try sync {
            if shouldFailMove {
                shouldFailMove = false
                // Emulate Cross-Device Link failure (EXDEV)
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

            // Simple mock of move (copy + delete)
            try copyItem(at: srcURL, to: dstURL)
            try removeItem(at: srcURL)
            // Models the real refusal `trashAfterReregistering` exists for: an item becomes
            // trashable only once it has been moved INTO the path being trashed. Without this the
            // retry would pass on `trashErrorOnce` alone — i.e. whether or not the move happened.
            movedInto.insert(dstURL.path)
        }
    }

    /// Destination paths whose next `moveItem` throws a permission error (then clears). This is
    /// the ONLY way to reach `trashAfterReregistering`'s strand branch: the park must succeed and
    /// the move BACK must fail, and `shouldFailMove` cannot express that — it clears on its first
    /// throw, so it always takes the park instead.
    public var failMoveToPathsOnce: Set<String> {
        get { sync { _failMoveToPathsOnce } }
        _modify { let owner = lockForMutation(); defer { unlockAfterMutation(owner) }; yield &_failMoveToPathsOnce }
    }
    private var _failMoveToPathsOnce: Set<String> = []

    /// When set, EVERY `trashItem` throws this error — unlike `trashErrorOnce`, which clears on
    /// the first throw. This is the "nothing can trash this" case, where all three attempts are
    /// denied, as distinct from `trashRefusedUntilMovedIn`, which is the measured case that
    /// re-registering the item fixes. A once-only error cannot express it: the retries would
    /// succeed simply because the injected failure ran out.
    public var trashErrorAlways: Error? = nil

    /// When set, `trashItem` refuses with a permission error for any path that has not been
    /// moved into place since. This is the shape of the refusal measured on the real files
    /// (2026-08-30): both Trash APIs deny a long-registered item, and moving it re-registers it.
    /// It is what keeps the re-registration test honest — remove the production retry and it
    /// fails, because `trashErrorOnce` alone would clear on the first throw and let ANY second
    /// attempt through.
    public var trashRefusedUntilMovedIn: Bool = false
    /// Paths that have been the DESTINATION of a `moveItem` on this mock.
    public var movedInto: Set<String> {
        get { sync { _movedInto } }
        _modify { let owner = lockForMutation(); defer { unlockAfterMutation(owner) }; yield &_movedInto }
    }
    private var _movedInto: Set<String> = []

    public var shouldFailTrash: Bool = false
    /// When set, the next `trashItem` throws this specific error (then clears), letting tests pin
    /// how a particular failure — e.g. a transient EBUSY vs. an unsupported-volume error — is
    /// classified by `deleteItems`. Checked before `shouldFailTrash`.
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

    /// Deterministic enumerator gate: when set, the FIRST enumerator call signals `entered` and
    /// then parks until `release` is signalled. Use this — not `enumeratorDelay` sleeps — for
    /// "load observably in flight" tests: any fixed delay/sleep pairing loses its race under a
    /// loaded parallel test run.
    ///
    /// The park is bounded, and `ParkGate` records a timed-out release: check
    /// `try #require(!gate.releasedByTimeout)` after the load completes, or a walk that resumed
    /// on its own reads exactly like one the test held.
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
                // Simulate network drive without trash bin
                throw NSError(domain: POSIXError.errorDomain, code: Int(POSIXError.ENOTSUP.rawValue))
            }

            let path = url.path
            guard virtualDisk[path] != nil else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
            }

            // Emulate moving to ~/.Trash
            let trashedTarget = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(url.lastPathComponent)

            // Use a direct copy+remove path so injected move-failure flags continue to apply
            // only to the operation under test, not to trash bookkeeping.
            try copyItem(at: url, to: trashedTarget)
            try removeItem(at: url)
            trashedPaths.append(trashedTarget.path)

            outResultingURL?.pointee = trashedTarget as NSURL
        }
    }

    /// Every path `removeItem` was called with, whether or not the removal succeeded. The mock
    /// disk is case-sensitive, so a removal that would hit a case-variant of an existing entry
    /// on a real (case-insensitive) volume shows up here even though the mock throws no-such-file.
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
    /// injected failure flags still bite — in particular the staged URL is a `.tmp_`, so
    /// `shouldFailMoveOnTempRename` fires on the swap-in and lets the rollback pin tests drive a
    /// mid-replace failure. On failure the original destination is restored, mirroring the real
    /// primitive's guarantee that a failed replace leaves the destination untouched.
    public func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? {
        try sync {
            calledReplaceItem = true
            let backupURL = destinationURL.deletingLastPathComponent().appendingPathComponent(backupItemName)
            let hadDestination = virtualDisk[destinationURL.path] != nil
            if hadDestination {
                do {
                    try moveItem(at: destinationURL, to: backupURL)
                } catch {
                    // Backing up the destination failed; nothing was swapped, so the destination
                    // must be left untouched (the real primitive's atomicity guarantee). Clean any
                    // partial backup copy so no stray artifact survives a failed replace.
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

        // An unlistable ROOT: report it and yield nothing, exactly as the real enumerator does.
        // The enumerator stays non-nil — that is the whole point of modelling this.
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

                    // An unlistable DESCENDANT is still yielded as an entry — it exists, it just
                    // cannot be descended into — while everything below it is withheld. Matches
                    // the measured shape: a listable root holding one locked subdirectory yields
                    // the subdirectory and reports it through the handler.
                    //
                    // Sorted by (length, path) rather than taken with `first(where:)`: a Set
                    // iterates in an order Swift's per-launch hash seed decides, so with nested
                    // unlistable directories (/a and /a/b) the one reported would change between
                    // runs of an unchanged test. Shortest = outermost, which is the one the real
                    // enumerator meets first on its way down.
                    //
                    // Skipped wholesale when nothing is armed, which is every existing test: the
                    // filter-and-sort allocates two collections PER ENTRY, and this loop runs over
                    // every key of the virtual disk on every enumeration.
                    let ancestors = unlistableDirectories.isEmpty ? [] : unlistableDirectories
                        .filter { key.hasPrefix($0 + "/") }
                        .sorted { ($0.count, $0) < ($1.count, $1) }
                    if let blocked = ancestors.first {
                        blockedDescendants.append(URL(fileURLWithPath: blocked))
                        // The blocked directory is itself a real entry, and the real enumerator
                        // yields it whether or not this virtual disk happens to hold a stub for it.
                        // Without this, a fixture that created only `/root/a/b` would withhold
                        // `/root/a` as well, the listing would come back with nothing at all, and a
                        // genuinely PARTIAL answer would read as a wholly unreadable root.
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

        // `.producesRelativePathURLs` is modelled rather than ignored, because a caller reads the
        // answer through `relativePath`, not through `path`. `FileManaging.listing(of:)` re-spells
        // every entry as "the URL I was asked about" + `relativePath` — that is how a folder
        // reached through a symlink keeps the caller's spelling at every depth — so an enumerator
        // that quietly hands back an ABSOLUTE `relativePath` makes it build `/p//p/Health` and lose
        // the lot. Measured: with the option unmodelled, `listSubfolders(of: "/p")` on this double
        // came back empty while the real filesystem answered correctly.
        //
        // `path` is unchanged either way, which is what every existing assertion reads, so this
        // only moves for a caller that asked for it — today, `listing(of:)` alone.
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
