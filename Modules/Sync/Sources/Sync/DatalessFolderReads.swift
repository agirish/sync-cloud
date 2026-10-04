import Events
import Foundation

/// **A folder whose contents are not on this Mac is read off the cooperative pool, and only for so
/// long** — so a cloud provider that never answers costs a walk a bounded wait, and never a thread.
///
/// Measured 2026-10-02/03, with OneDrive not running: listing `~/Library/CloudStorage/OneDrive-
/// Personal/.Trash` (and the HPE account's) blocks indefinitely — `ls` from Terminal too, sampled
/// sitting in `getattrlistbulk` after a successful `open`. Both folders carry `SF_DATALESS`; every
/// other folder in both accounts is materialized and lists at once. That is the documented rule,
/// not a coincidence: "traversals of dataless directories by applications trigger an enumeration
/// against the file provider extension; traversals of materialized directories do not"
/// (`NSFileProviderReplicatedExtension.h`). So the flag is exactly the set of folders a listing can
/// hang on, and `FileManaging.isDataless(at:)` asks for it.
///
/// What one such folder did to the app: the Home pane's walk reached it, a cooperative-pool thread
/// blocked inside the listing, `buildTree` never returned and so the refresh never reached its
/// comparison — "Nothing scanned yet" for good. A superseding refresh cancels the walk but cannot
/// unblock a syscall, so every Refresh leaked one more pool thread and one more open directory
/// (9 `.Trash` fds after ~25 clicks) until the pool was gone and the OTHER pane stopped loading too.
///
/// **Three properties, each one of those failures:**
///
/// - **Off the pool.** The listing runs on a dispatch queue, whose threads may block — the kernel
///   workqueue adds one when another sleeps — while the walk SUSPENDS on the answer. A pool thread
///   is never held, however long the provider takes.
/// - **Bounded.** After `deadline` the walk stops waiting and the folder comes back unexplored —
///   "Can't be read", never empty, so the comparison reports nothing under it as missing.
/// - **One read per folder.** A folder whose read is still out is not read again: a walk arriving
///   while it is within its deadline waits on that same read, and one arriving after the deadline
///   is told at once that the folder is still unanswered. Without this a dead provider would cost
///   one more blocked thread per Refresh, off the pool or not.
///
/// **A late answer is not lost.** Listing a dataless folder is what materializes it — measured: a
/// dataless Google Drive and iCloud folder each listed in ~0.1 s and was no longer dataless after —
/// so a read that answers after its deadline leaves the folder on disk, the next walk finds it
/// materialized and lists it inline. The deadline defers a slow folder; it never drops it.
///
/// **Five seconds** is fifty times the measured healthy answer, and it is what a provider that has
/// stopped answering costs: the first walk to reach each of its dataless folders waits that long
/// once, and every walk after it skips them at once until they answer. Measured on the Home pane,
/// which reaches both `.Trash` folders through OneDrive's links in the home folder, side by side in
/// the fan-out: its first walk took 5.5 s and the two after it 3.0 and 2.4 s, skipping both. Folders
/// a walk meets one after another — below the fan-out's horizon, `TreeBuilder.maxFanLevel` — wait
/// one after another.
extension FileSyncManager {

    final class DatalessFolderReads: @unchecked Sendable {

        /// The one the app's walks share — so the storage lens, a column's graft and the panes all
        /// know the same unanswered folders. Tests make their own, with a short deadline.
        static let shared = DatalessFolderReads(deadline: .seconds(5))

        /// How long a walk waits for a folder's provider before calling it unanswered.
        let deadline: Duration

        init(deadline: Duration) {
            self.deadline = deadline
        }

        /// One folder's read in flight, from the moment a walk starts it until the provider answers
        /// — which, for a provider that is not running, is never. Every mutable field is touched only
        /// under the registry's lock, which is what the `@unchecked` stands on.
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

        /// Runs `body` — the listing of the folder at `path` — off the cooperative pool and hands
        /// back what it returned, or `nil` when the folder did not answer within `deadline`, was
        /// already known not to, or the calling task was cancelled while it waited.
        ///
        /// Suspends rather than blocks, so the walk costs no thread while it waits.
        func read<T: Sendable>(_ path: String, _ body: @escaping @Sendable () -> T) async -> T? {
            let path = Self.key(path)
            while !Task.isCancelled {
                switch admit(path) {
                case .refused:
                    return nil
                case .joined(let read):
                    // Another walk's read of this folder is still within its deadline. Its answer
                    // means the folder is on disk now, so go round and read it afresh — this walk's
                    // own listing, in its own spelling, and no longer a provider round trip.
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

        /// `read(_:_:)` for a caller that cannot suspend — the comparison's disk walk, which runs
        /// inside a `FileManager.DirectoryEnumerator` loop. The listing still runs off the pool; it is
        /// the CALLER that waits here, blocking its thread for at most `deadline` and only the first
        /// time a folder goes unanswered — after that the answer is immediate. Wakes every 50 ms to
        /// see whether its task was cancelled, so a superseded scan does not sit out the deadline.
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

        /// Whether a read of `path` is still out — running or past its deadline. For the tests that
        /// release a parked listing and then need to know it has come back.
        func isOutstanding(_ path: String) -> Bool {
            let path = Self.key(path)
            lock.lock(); defer { lock.unlock() }
            return reads[path] != nil
        }

        /// **One folder, one read, however the walk spelled it.** The Home pane reaches each OneDrive
        /// `.Trash` through OneDrive's link in the home folder — `~/OneDrive/.Trash`, measured — and
        /// can reach the same folder again under `~/Library/CloudStorage/…`. Keyed by spelling, that
        /// is two reads of one folder that is not answering: two blocked threads, and a second wait.
        /// Resolved here, where only a dataless folder arrives, so no other folder pays for it; a
        /// path that does not resolve is its own key. The log names the folder by this key too.
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
            // `finish` takes an answered read out in the same breath as it answers, so `.answered`
            // never sits here — but if one did, joining it would loop `read` forever, so it is
            // simply replaced.
            if let read = reads[path], read.state != .answered {
                let expired = read.state == .expired
                lock.unlock()
                guard expired else { return .joined(read) }
                // Debug, not a warning: the warning was said once, when the deadline passed, and a
                // line per walk per Refresh would bury it.
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
            }
            for tell in waiters.values { tell(true) }
        }

        /// Arms the deadline. The read stays registered when it passes — that is what turns the next
        /// walk away at once instead of starting another read of a folder that is not answering.
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
