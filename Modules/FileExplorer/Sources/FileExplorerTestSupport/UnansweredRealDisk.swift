import Foundation
import Sync

/// The real disk, except that one folder is dataless and its provider is not answering: listing it
/// parks until `answerAtOnce()` or the bound. Answered, the folder is materialized — no longer
/// dataless, listed at once — as listing a real one leaves it. Its listings ask through a
/// short-deadline registry of its own.
public final class UnansweredRealDisk: FileManaging, @unchecked Sendable {
    private let base = FileManager.default
    private let unanswered: String
    public let datalessFolderReads: FileSyncManager.DatalessFolderReads
    /// Signalled when the provider is first asked.
    public let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var answered = false
    private var parked = false
    private var reads = 0

    public init(unanswered: String, reads: FileSyncManager.DatalessFolderReads) {
        self.unanswered = unanswered
        self.datalessFolderReads = reads
    }

    public var providerReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    public var isParked: Bool { lock.lock(); defer { lock.unlock() }; return parked }

    /// The provider answers every ask from now on.
    public func answerAtOnce() { release.signal() }

    /// Lets a parked ask go and removes the fixture.
    public func finish(removing folder: String) {
        release.signal()
        try? base.removeItem(atPath: (folder as NSString).deletingLastPathComponent)
    }

    public func isDataless(at url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return url.path == unanswered && !answered
    }

    private func askTheProvider() {
        lock.lock()
        guard !answered else { lock.unlock(); return }
        reads += 1
        parked = true
        lock.unlock()
        entered.signal()
        // Two minutes, so "came back while still parked" stays true on a loaded machine.
        _ = release.wait(timeout: .now() + 120)
        release.signal()            // every later ask is answered too
        lock.lock(); parked = false; answered = true; lock.unlock()
    }

    public func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                           options mask: FileManager.DirectoryEnumerationOptions,
                           errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
        if url.path == unanswered { askTheProvider() }
        return base.enumerator(at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: handler)
    }

    public func fileExists(atPath path: String) -> Bool { base.fileExists(atPath: path) }
    public func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        base.fileExists(atPath: path, isDirectory: isDirectory)
    }
    public func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] { try base.attributesOfItem(atPath: path) }
    public func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try base.setAttributes(attributes, ofItemAtPath: path)
    }
    public func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                attributes: [FileAttributeKey: Any]?) throws {
        try base.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
    public func copyItem(at srcURL: URL, to dstURL: URL) throws { try base.copyItem(at: srcURL, to: dstURL) }
    public func moveItem(at srcURL: URL, to dstURL: URL) throws { try base.moveItem(at: srcURL, to: dstURL) }
    public func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        try base.trashItem(at: url, resultingItemURL: outResultingURL)
    }
    public func removeItem(at URL: URL) throws { try base.removeItem(at: URL) }
    public func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? {
        try base.replaceItem(at: destinationURL, withItemAt: stagedURL, backupItemName: backupItemName)
    }
}

/// A task executor with ONE thread, so whether an async call SUSPENDS or BLOCKS while it waits is
/// visible from outside: a job queued behind a suspended call runs; behind a blocked one it cannot.
/// Shared by FileExplorer's and Dashboard's tests; the Sync tests carry the same harness, with
/// its control (`theSynchronousListingHoldsItsThreadForTheDeadline`), since Sync cannot see this.
public final class OneThreadExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "UnansweredFolderListingTests.one-thread")

    public init() {}

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }

    /// Runs `body` on a fresh one-thread executor and, once `disk` says the provider is being
    /// asked, queues a second job on the same thread. The provider answers only AFTER that job has
    /// had five seconds to run — so a blocked `body` keeps it out for the whole five, and a load
    /// spike cannot let `body` finish first and pass for one that suspended. Give the disk's reads
    /// a deadline far longer than the test, so none is raced. `asked` is false when the provider was
    /// never asked — a test reading `ranWhileWaiting` without checking it measured nothing.
    public static func letsAnotherJobRun<T: Sendable>(
        whileAsking disk: UnansweredRealDisk,
        _ body: @escaping @Sendable () async -> T
    ) async -> (asked: Bool, ranWhileWaiting: Bool, value: T) {
        let executor = OneThreadExecutor()
        let finished = Finished()
        let waiting = Task(executorPreference: executor) { () -> T in
            let value = await body()
            finished.set()
            return value
        }
        let asked = await Self.wait(for: disk.entered, seconds: 60)
        let ran = DispatchSemaphore(value: 0)
        let sawItUnfinished = Finished()
        let probe = Task(executorPreference: executor) {
            if !finished.isSet { sawItUnfinished.set() }
            ran.signal()
        }
        let ranInTime = await Self.wait(for: ran, seconds: 5)
        disk.answerAtOnce()                 // the provider answers, whichever way that went
        await probe.value
        let value = await waiting.value
        return (asked, ranInTime && sawItUnfinished.isSet, value)
    }

    private static func wait(for semaphore: DispatchSemaphore, seconds: Int) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                done.resume(returning: semaphore.wait(timeout: .now() + .seconds(seconds)) == .success)
            }
        }
    }

    private final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}
