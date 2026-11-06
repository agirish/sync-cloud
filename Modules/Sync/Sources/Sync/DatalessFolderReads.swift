import Events
import Foundation

/// **A folder whose contents are not on this Mac is read off the cooperative pool, and only for so
/// long**, so a cloud provider that never answers costs a walk a bounded wait, never a thread.
///
/// Listing a dataless folder (`SF_DATALESS`) asks the file provider to enumerate it, and with the
/// provider not running the listing can block forever in `getattrlistbulk`. A refresh can cancel a
/// walk but not unblock a syscall, so each Refresh would leak a pool thread and a descriptor until
/// the pool ran dry and every pane stopped loading. `FileManaging.isDataless(at:)` finds them.
///
/// - **Off the pool.** The listing runs on a dispatch queue, whose threads may block, while the
///   walk suspends on the answer.
/// - **Bounded.** After `deadline` the folder comes back unexplored ("Can't be read", never empty),
///   so the comparison reports nothing under it as missing.
/// - **One read per folder.** A walk arriving while a read is within its deadline waits on that
///   read; one arriving after it is told at once the folder is unanswered. Otherwise a dead provider
///   would still cost a blocked thread per Refresh.
///
/// A late answer isn't lost: listing a folder materializes it, so the next walk lists it inline.
/// Five seconds is about fifty times a healthy answer; a dead provider costs that once per folder,
/// and walks skip the folder after. Folders met in sequence, below `TreeBuilder.maxFanLevel`, wait
/// in sequence.
///
/// **Every listing goes through it, not just the walks.** `FileManaging.listing(of:)` and
/// `childCount(of:)` route a dataless folder here, and skip one inside a recursive listing. Those
/// callers are synchronous and block in `readBlocking`, at most the deadline and only the first
/// time, on their own thread (the main actor, for a move's undo registration). A caller that can
/// suspend asks `waitForContents(of:)` first, holding no thread. One that lists with its own API
/// (Restructure's plan view and its landing's emptiness walk) asks `waitForContentsBlocking(of:)`
/// first and treats an unanswered folder as unreadable.
extension FileSyncManager {

    public final class DatalessFolderReads: @unchecked Sendable {

        /// Shared by the app's walks and listings, so they all know the same unanswered folders.
        /// Tests make their own, with a short deadline.
        public static let shared = DatalessFolderReads(deadline: .seconds(5))

        /// How long a walk waits for a folder's provider before calling it unanswered.
        public let deadline: Duration

        public init(deadline: Duration) {
            self.deadline = deadline
        }

        /// One folder's read in flight, until the provider answers (never, if it isn't running).
        /// Every mutable field is touched only under the registry's lock, which the `@unchecked`
        /// relies on.
        private final class Read: @unchecked Sendable {
            /// Both clocks, for `Elapsed`'s reason: a Mac asleep mid-read is not a slow provider.
            let since = Elapsed()
            var state = State.running
            /// Each waiter is told the outcome exactly once, outside the lock.
            var waiters: [Int: @Sendable (Bool) -> Void] = [:]

            enum State { case running, answered, expired }
        }

        private let lock = NSLock()
        /// Reads still out, by path: running ones and expired ones. An answered read leaves.
        private var reads: [String: Read] = [:]
        private var nextWaiter = 0

        /// Concurrent, so two folders' reads never queue behind each other; its threads come from
        /// the dispatch pool, which is allowed to block.
        private let queue = DispatchQueue(label: "com.abhishekgirish.SyncCloud.dataless-folder-reads",
                                          qos: .userInitiated, attributes: .concurrent)

        // MARK: - Reading

        /// Runs `body`, the listing of the folder at `path`, off the cooperative pool and returns its
        /// result, or `nil` when the folder didn't answer within `deadline`, was already known not
        /// to, or the task was cancelled while waiting. Suspends, so it holds no thread.
        func read<T: Sendable>(_ path: String, _ body: @escaping @Sendable () -> T) async -> T? {
            let path = Self.key(path)
            while !Task.isCancelled {
                switch admit(path) {
                case .refused:
                    return nil
                case .joined(let read):
                    // Another walk's read is within its deadline. Once it answers the folder is on
                    // disk, so loop and read it afresh, in this walk's own spelling.
                    guard await outcome(of: read) else { return nil }
                case .started(let read):
                    let answer = Answer<T>()
                    queue.async {
                        answer.set(body())
                        self.finish(read, path: path)
                    }
                    expire(read, path: path)
                    guard await outcome(of: read) else { return nil }
                    return answer.value
                }
            }
            return nil
        }

        /// `read(_:_:)` for a caller that can't suspend: the comparison's disk walk inside a
        /// `FileManager.DirectoryEnumerator` loop, and `FileManaging.listing(of:)`. The listing still
        /// runs off the pool; the caller blocks for at most `deadline`, only the first time a folder
        /// goes unanswered. Checks for cancellation every 50 ms, so a superseded scan doesn't wait.
        func readBlocking<T: Sendable>(_ path: String, _ body: @escaping @Sendable () -> T) -> T? {
            let path = Self.key(path)
            while !Task.isCancelled {
                switch admit(path) {
                case .refused:
                    return nil
                case .joined(let read):
                    guard outcomeBlocking(of: read) else { return nil }
                case .started(let read):
                    let answer = Answer<T>()
                    queue.async {
                        answer.set(body())
                        self.finish(read, path: path)
                    }
                    expire(read, path: path)
                    guard outcomeBlocking(of: read) else { return nil }
                    return answer.value
                }
            }
            return nil
        }

        /// Whether a read of `path` is still out, running or past its deadline. For tests that
        /// release a parked listing and need to know it came back.
        public func isOutstanding(_ path: String) -> Bool {
            let path = Self.key(path)
            lock.lock(); defer { lock.unlock() }
            return reads[path] != nil
        }

        /// Folders whose read passed its deadline and hasn't answered since, which the cloud app
        /// status shows as "not responding". A folder leaves when its read answers.
        public func unansweredPaths() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return reads.filter { $0.value.state == .expired }.map(\.key).sorted()
        }

        /// Forgets the unanswered folders at or under `roots`, so walks read them again. For when the
        /// app that syncs them has just launched: a read asked of the old process may never answer,
        /// and the new one isn't asked until a new read is. The stuck read is left to finish
        /// unheard. Returns how many were forgotten.
        @discardableResult
        public func forgetUnanswered(under roots: [String]) -> Int {
            let keys = roots.map(Self.key)
            lock.lock()
            let gone = reads.filter { path, read in
                read.state == .expired && keys.contains { path == $0 || path.hasPrefix($0 + "/") }
            }.map(\.key)
            for path in gone { reads[path] = nil }
            lock.unlock()
            guard !gone.isEmpty else { return 0 }
            Logger.shared.info("Scan: \(gone.count) unanswered folder(s) will be read again — the app that syncs them launched")
            announceUnansweredChange()
            return gone.count
        }

        /// Posted, on no particular thread, when a folder joins or leaves `unansweredPaths()`.
        public static let unansweredDidChange = Notification.Name("DatalessFolderReads.unansweredDidChange")

        private func announceUnansweredChange() {
            NotificationCenter.default.post(name: Self.unansweredDidChange, object: self)
        }

        /// One folder, one read, however the walk spelled it: a folder reached through a link (such
        /// as `~/OneDrive/.Trash`) and through `~/Library/CloudStorage/…` would otherwise cost two
        /// blocked threads. Only dataless folders get here, so only they pay for the resolve. The
        /// log names the folder by this key too.
        private static func key(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }

        // MARK: - The registry

        private enum Admission {
            case started(Read)
            case joined(Read)
            case refused
        }

        private func admit(_ path: String) -> Admission {
            lock.lock()
            // `finish` removes a read as it answers, so `.answered` never sits here; if one did,
            // joining it would loop `read` forever, so it is replaced.
            if let read = reads[path], read.state != .answered {
                let expired = read.state == .expired
                lock.unlock()
                guard expired else { return .joined(read) }
                // Debug, not a warning: the warning was logged once at the deadline, and a line per
                // walk per Refresh would bury it.
                Logger.shared.debug("Scan: skipped “\(path)” — its provider has not answered in \(read.since.text)")
                return .refused
            }
            let read = Read()
            reads[path] = read
            lock.unlock()
            return .started(read)
        }

        /// The listing came back. Tells every waiter, and lets the next walk read the folder anew.
        private func finish(_ read: Read, path: String) {
            lock.lock()
            let wasExpired = read.state == .expired
            read.state = .answered
            let waiters = read.waiters
            read.waiters = [:]
            if reads[path] === read { reads[path] = nil }
            lock.unlock()
            if wasExpired {
                Logger.shared.info("Scan: “\(path)” answered after \(read.since.text) — walks read it again from now on")
                announceUnansweredChange()
            }
            for tell in waiters.values { tell(true) }
        }

        /// Arms the deadline. The read stays registered past it, so the next walk is turned away at
        /// once instead of starting another read of a folder that isn't answering.
        private func expire(_ read: Read, path: String) {
            queue.asyncAfter(deadline: .now() + Self.interval(deadline)) { [deadline] in
                self.lock.lock()
                guard read.state == .running else { self.lock.unlock(); return }
                read.state = .expired
                let waiters = read.waiters
                read.waiters = [:]
                self.lock.unlock()
                Logger.shared.warning("Scan: “\(path)” did not answer in \(Self.text(deadline)) — its contents are not on this Mac and the app that syncs it did not supply them. Shown as unexplored, not empty; walks skip it until it answers")
                for tell in waiters.values { tell(false) }
                self.announceUnansweredChange()
            }
        }

        // MARK: - Waiting

        /// Whether `read` answered, suspending until it does, its deadline passes, or this task is
        /// cancelled — whichever is first.
        private func outcome(of read: Read) async -> Bool {
            let id = waiterID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    lock.lock()
                    // Cancellation is flagged BEFORE the handler below runs, and both sides hold the
                    // lock, so a waiter is either never registered or always found and told.
                    switch read.state {
                    case .answered:
                        lock.unlock(); continuation.resume(returning: true)
                    case .expired:
                        lock.unlock(); continuation.resume(returning: false)
                    case .running where Task.isCancelled:
                        lock.unlock(); continuation.resume(returning: false)
                    case .running:
                        read.waiters[id] = { continuation.resume(returning: $0) }
                        lock.unlock()
                    }
                }
            } onCancel: {
                lock.lock()
                let tell = read.waiters.removeValue(forKey: id)
                lock.unlock()
                tell?(false)
            }
        }

        /// `outcome(of:)` for `readBlocking`.
        private func outcomeBlocking(of read: Read) -> Bool {
            let id = waiterID()
            let told = DispatchSemaphore(value: 0)
            let answered = Answer<Bool>()
            lock.lock()
            switch read.state {
            case .answered: lock.unlock(); return true
            case .expired: lock.unlock(); return false
            case .running:
                read.waiters[id] = { answered.set($0); told.signal() }
                lock.unlock()
            }
            while told.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
                guard Task.isCancelled else { continue }
                lock.lock()
                let stillWaiting = read.waiters.removeValue(forKey: id) != nil
                lock.unlock()
                // Told in the instant before the removal: the answer is in, and it is the answer.
                if stillWaiting { return false }
            }
            return answered.value ?? false
        }

        private func waiterID() -> Int {
            lock.lock(); defer { lock.unlock() }
            nextWaiter += 1
            return nextWaiter
        }

        /// A value handed from the reading thread to the waiting one.
        private final class Answer<Value: Sendable>: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: Value?
            func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
            var value: Value? { lock.lock(); defer { lock.unlock() }; return stored }
        }

        private static func interval(_ duration: Duration) -> DispatchTimeInterval {
            let parts = duration.components
            return .nanoseconds(Int(parts.seconds) * 1_000_000_000 + Int(parts.attoseconds / 1_000_000_000))
        }

        private static func text(_ duration: Duration) -> String {
            let parts = duration.components
            let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            return seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.0f s", seconds)
        }
    }
}
