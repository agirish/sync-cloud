import Foundation
@testable import Sync

/// A RAM-only filesystem simulator built for Unit Tests.
/// It intercepts `FileManaging` protocol endpoints to emulate standard volume constraints,
/// read/write states, and failure behaviors without interacting with the physical local disk.
///
/// All virtual-disk access is guarded by a recursive lock so the mock is safe to drive from the
/// parallel worker pools in `syncAll` / bulk verify (up to 4 concurrent operations). A recursive
/// lock is required because `moveItem`/`trashItem` call `copyItem`/`removeItem` while already holding it.
public final class MockFileManager: FileManaging, @unchecked Sendable {

    public struct FileStub {
        var isDirectory: Bool
        let attributes: [FileAttributeKey: Any]?
        var contents: [String]? // Child names if directory
    }

    // The dictionary-backed RAM virtual disk
    public var virtualDisk: [String: FileStub] = [:]

    private let lock = NSRecursiveLock()
    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public init() {}

    /// Invoked (under the lock) after each `fileExists` check (both the plain and the
    /// `isDirectory:` overloads), with the queried path. Lets tests plant a file right after an
    /// existence check to simulate TOCTOU races (e.g. a cloud placeholder hydrating between the
    /// backup stat and the final move, or between the collision stat and the operation running).
    /// The returned existence reflects state *before* the callback runs, matching a real stat.
    public var onFileExists: ((String) -> Void)?

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
    public var unlistableDirectories: Set<String> = []

    public func fileExists(atPath path: String) -> Bool {
        sync {
            let exists = virtualDisk.keys.contains(path)
            onFileExists?(path)
            return exists
        }
    }

    public func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        sync {
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
            attrs[.type] = stub.isDirectory ? FileAttributeType.typeDirectory : FileAttributeType.typeRegular
            // A real regular file always reports a size; a stub built without an attributes
            // dictionary reported none, so anything reading size off this double saw "unknown"
            // for an ordinary file — a state the real filesystem does not produce. Synthesized for
            // the same reason `.type` above is, and only when the fixture did not state one.
            if !stub.isDirectory, attrs[.size] == nil {
                attrs[.size] = NSNumber(value: 0)
            }
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

    /// Invoked with the source path immediately BEFORE each `copyItem`, and deliberately
    /// OUTSIDE the virtual disk's lock so a test may block in it: that is what lets a bulk run
    /// be held genuinely mid-flight, by its own I/O, instead of by a foreign operation parked
    /// on the queue ahead of it (which moves `fileOperationsEpoch` and so cannot coexist with a
    /// live copy offer).
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

            if (shouldFailMoveOnTempRename || tempRenameFailuresRemaining > 0) && srcURL.path.contains(".tmp_") {
                shouldFailMoveOnTempRename = false
                if tempRenameFailuresRemaining > 0 { tempRenameFailuresRemaining -= 1 }
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: nil)
            }

            // Simple mock of move (copy + delete)
            try copyItem(at: srcURL, to: dstURL)
            try removeItem(at: srcURL)
        }
    }

    public var shouldFailTrash: Bool = false
    /// When set, the next `trashItem` throws this specific error (then clears), letting tests pin
    /// how a particular failure — e.g. a transient EBUSY vs. an unsupported-volume error — is
    /// classified by `deleteItems`. Checked before `shouldFailTrash`.
    public var trashErrorOnce: Error? = nil
    public var trashedPaths: [String] = []
    public var enumeratorDelay: TimeInterval = 0
    public var failRemovePathsOnce: Set<String> = []

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
    public var attemptedRemovePaths: [String] = []

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
        // Read under the lock like every other virtual-disk access: this mock is driven from the
        // parallel worker pools, so an unsynchronised Set read races any test that arms a failure
        // while a walk is in flight.
        if sync({ unlistableDirectories.contains(url.path) }) {
            _ = handler?(url, NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))
            return MockEnumerator(urls: [])
        }

        // Snapshot the matching children under the lock, then hand off to the enumerator.
        let allChildren: [URL] = sync {
            var children: [URL] = []
            let root = url.path
            var blockedDescendants: [URL] = []
            var blockedEntries = Set<String>()

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

        // Return a mock MockDirectoryEnumerator
        return MockEnumerator(urls: allChildren)
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
