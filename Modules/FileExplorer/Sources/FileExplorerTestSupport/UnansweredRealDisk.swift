import Foundation
import Sync

/// The real disk, except that one folder is dataless and its provider is not answering: listing it
/// parks until `answerAtOnce()` or the bound. Answered, the folder is materialized — no longer
/// dataless, listed at once — as listing a real one leaves it. Its listings ask through a
/// short-deadline registry of its own.
public final class UnansweredRealDisk: FileManaging, @unchecked Sendable {
    private let base = FileManager.default
    private let unanswered: String
    /// `unanswered` as the reads key it: symlinks resolved (`/var` is `/private/var`).
    private let unansweredKey: String
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
        self.unansweredKey = URL(fileURLWithPath: unanswered).resolvingSymlinksInPath().path
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
        // A stopped provider never answers, so only `answerAtOnce()` or `finish` lets this go.
        // The bound keeps a listing that ignores the reads' deadline from hanging its test: two
        // minutes while the reads still hold the folder. Once they have given it up, only a
        // starved pool delays the release, and answering first would turn "came back while still
        // parked" red, so then it is half an hour.
        let since = ContinuousClock.now
        while release.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            let givenUp = datalessFolderReads.unansweredPaths().contains(unansweredKey)
            if ContinuousClock.now - since > (givenUp ? .seconds(1800) : .seconds(120)) { break }
        }
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
    /// run, or has had thirty seconds to — so a blocked `body` keeps it out for the whole thirty,
    /// and `ranWhileWaiting` is that job finding the provider still parked and `body` unfinished.
    /// Give the disk's reads a deadline far longer than the test, so none is raced. `asked` is
    /// false when the provider was never asked — a test reading `ranWhileWaiting` without checking
    /// it measured nothing.
    ///
    /// **Everything from the ask to the answer runs on a thread of its own, never the cooperative
    /// pool.** The disk answers by itself after two minutes, so a starved pool running this part
    /// could let it answer first and report a suspending `body` as one that held its thread. On
    /// its own thread, a starved pool delays only the result.
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
        let (asked, ranWhileWaiting) = await withCheckedContinuation { (done: CheckedContinuation<(Bool, Bool), Never>) in
            Thread {
                guard disk.entered.wait(timeout: .now() + 60) == .success else {
                    disk.answerAtOnce()
                    return done.resume(returning: (false, false))
                }
                let ran = DispatchSemaphore(value: 0)
                let sawItWaiting = Finished()
                Task(executorPreference: executor) {
                    if disk.isParked && !finished.isSet { sawItWaiting.set() }
                    ran.signal()
                }
                let ranInTime = ran.wait(timeout: .now() + 30) == .success
                disk.answerAtOnce()             // the provider answers, whichever way that went
                done.resume(returning: (true, ranInTime && sawItWaiting.isSet))
            }.start()
        }
        let value = await waiting.value
        return (asked, ranWhileWaiting, value)
    }

    private final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}
