import Foundation
import Events
import Testing
@testable import Sync

/// Awaits a semaphore off the main actor (a blocking `wait` on the test's actor would deadlock
/// anything the signaller needs from it). Bounded, and a timeout is recorded as a failure: a test
/// whose signal never arrives must not carry on ungated, asserting against a state it never
/// reached. Bounded by scheduler turns as well as seconds (``TurnDeadline``), since what signals
/// here is work the test started, which runs on main-actor and pool turns.
func awaitSignal(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval = 10,
    turns: Int = signalTurnFloor,
    _ what: Comment = "the signal never arrived — the test ran on ungated state",
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = TurnDeadline(seconds: timeout, turns: turns)
    let arrived = await withCheckedContinuation { cont in
        DispatchQueue.global().async {
            cont.resume(returning: semaphore.wait(until: deadline))
        }
    }
    #expect(arrived, "\(what.rawValue) — \(deadline.spent)", sourceLocation: sourceLocation)
}

// MARK: - Scheduler turns

/// The fewest scheduler turns ``awaitSignal`` waits before it may give up: twice `waitUntil`'s
/// poll floor, as its 10 s default is twice `waitUntil`'s 5 s.
public let signalTurnFloor = 2 * waitPollFloor

/// The fewest scheduler turns a park waits for its release before it may give up. A release comes
/// after the test's own waits (an `awaitSignal`, a `waitUntil` or several), so the park must outlast
/// all of them in the unit they are counted in: ten `waitUntil` floors.
public let parkTurnFloor = 10 * waitPollFloor

/// A process-wide count of scheduler turns: one each time a probe has slept 10 ms on the
/// cooperative pool, crossed to the main actor, and come back.
///
/// A gate's release comes from the test's async side, which advances on main-actor and pool turns;
/// a loaded run has fewer per second, so a bound in seconds alone runs out exactly when the release
/// is slowest (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps"). A park can't count its own
/// turns: it is blocked on a thread, or (``parkUntilReleased``) polling on the pool, not where the
/// release waits. This probe needs one turn of each, so it slows whenever either is starved, at the
/// pace of a `waitUntil` poll (a 10 ms sleep, then a main-queue trip). Started on first use and
/// never stopped; it costs one main-actor job per 10 ms.
enum SchedulerTurns {
    private static let box = TurnBox()
    private static let ticker: Void = {
        Task.detached(priority: .medium) {
            while true {
                try? await Task.sleep(nanoseconds: 10_000_000)
                await MainActor.run {}
                box.tick()
            }
        }
    }()

    static var now: Int {
        _ = ticker
        return box.value
    }

    private final class TurnBox: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func tick() { lock.lock(); count += 1; lock.unlock() }
    }
}

/// A bound that passes only once both its seconds and its scheduler turns have run out, the shape
/// `waitUntil` has, for waits that can't count their own polls. An idle run is held to the seconds,
/// a loaded one to the turns, which is what its release is made of. A wall-clock ceiling at thirty
/// times the seconds remains, reached only if the turns stop altogether (a wedged main thread), so
/// a hang still becomes a verdict.
public struct TurnDeadline: Sendable {
    private let start = ContinuousClock.now
    private let seconds: Duration
    private let ceiling: Duration
    private let firstTurn: Int
    private let turns: Int

    public init(seconds: TimeInterval, turns: Int) {
        self.seconds = .milliseconds(Int(seconds * 1000))
        self.ceiling = self.seconds * 30
        self.turns = turns
        firstTurn = turns > 0 ? SchedulerTurns.now : 0
    }

    private var turnsSpent: Int { turns > 0 ? SchedulerTurns.now - firstTurn : 0 }

    public var hasPassed: Bool {
        let elapsed = ContinuousClock.now - start
        return elapsed >= ceiling || (elapsed >= seconds && turnsSpent >= turns)
    }

    /// What the wait spent, for a failure message: a wait that gave up after hundreds of turns was
    /// disproved; one that gave up at the ceiling after a handful was starved.
    public var spent: String {
        let elapsed = (ContinuousClock.now - start).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return "gave up after \(String(format: "%.1f", seconds)) s and \(turnsSpent) scheduler turns"
    }
}

extension DispatchSemaphore {
    /// Blocks until signalled or `deadline` has passed; true if signalled. Waits in 50 ms slices so
    /// it can read the turn count between them.
    public func wait(until deadline: TurnDeadline) -> Bool {
        while true {
            if self.wait(timeout: .now() + 0.05) == .success { return true }
            if deadline.hasPassed { return false }
        }
    }
}

/// A two-semaphore park for holding a synchronous seam call in flight: the seam calls `park()`,
/// which signals `entered` and blocks until the test signals `release`. The wait is bounded so a
/// mis-wired test fails instead of hanging, and the bound records itself: a silent timeout would
/// let the parked call resume on its own and the test assert against a state it never held. Every
/// user must `try #require(!gate.releasedByTimeout)` once the work under test has finished.
/// `FirstStatGate` carries the same flag; use this wherever a gate isn't also a `FileManaging`
/// stand-in.
public final class ParkGate: @unchecked Sendable {
    public let entered = DispatchSemaphore(value: 0)
    public let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var timedOut = false
    private var parked = false
    private var everParked = false

    public init() {}

    /// True if the parked call gave up waiting instead of being released.
    public var releasedByTimeout: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }

    /// True once `park()` has engaged at least once. `releasedByTimeout` is false both for a gate
    /// that was held and released and for one that never engaged, so alone it can't tell them
    /// apart; consumers catch the second through `awaitSignal(gate.entered)`, and `ParkBudgetTests`
    /// pins both directions through this.
    public var didPark: Bool {
        lock.lock(); defer { lock.unlock() }
        return everParked
    }

    /// True while a call is blocked inside `park()`. Only `ParkBudgetTests` reads it; a consumer
    /// waits on `entered` and `release`, never on this.
    public var isParked: Bool {
        lock.lock(); defer { lock.unlock() }
        return parked
    }

    /// Signals `entered`, then blocks until `release` arrives or the bound expires.
    ///
    /// **This blocks a real thread, and under a package run that thread is a cooperative-pool
    /// one**, because production reaches its `FileManaging` seams from `Task.detached`. A test whose
    /// gate gets here must declare `.parksAThread` so the pool keeps enough width to deliver the
    /// release; see ``ParkThreadBudget`` and `docs/flaky-tests.md`, "Every gate parks at once, on
    /// the pool their releases need". Bounded by ``parkTurnFloor`` scheduler turns as well as by
    /// `timeout` (``TurnDeadline``).
    public func park(timeout: TimeInterval = 10, turns: Int = parkTurnFloor) {
        lock.lock(); parked = true; everParked = true; lock.unlock()
        entered.signal()
        let expired = !release.wait(until: TurnDeadline(seconds: timeout, turns: turns))
        lock.lock(); parked = false; if expired { timedOut = true }; lock.unlock()
    }
}

// MARK: - The park-thread budget

/// The width of the Swift cooperative pool: one thread per core, and it does not grow when one
/// blocks. Every park below holds one of these threads, and every release needs one.
///
/// `SYNC_TESTS_POOL_WIDTH=3` narrows it to a hosted runner's on a wider Mac by holding the threads
/// above that for the rest of the run, so a red that needs GitHub's three vCPUs reproduces here
/// (`docs/flaky-tests.md`, "Every gate parks at once, on the pool their releases need"). The hold
/// starts at the first park reservation, which every run reaches at once.
let cooperativePoolWidth: Int = {
    let cores = ProcessInfo.processInfo.activeProcessorCount
    guard let width = ProcessInfo.processInfo.environment["SYNC_TESTS_POOL_WIDTH"].flatMap(Int.init),
          width >= 1, width < cores else { return cores }
    for _ in width..<cores { Task.detached { holdAPoolThreadForTheRun() } }
    return width
}()

private func holdAPoolThreadForTheRun() { DispatchSemaphore(value: 0).wait() }

/// How many real threads the thread-blocking parks in this target may hold at once, process-wide:
/// a quarter of the cooperative pool, at least one, so 2 on a ten-core Mac and 1 on GitHub's
/// 3-vCPU runners. Sized by what has to keep running: every park is released by async work that
/// needs a pool thread, and any other test may be holding one in a long synchronous loop, so two
/// parks plus one such loop would take all of a runner's three threads.
let parkThreadBudget = max(1, cooperativePoolWidth / 4)

/// Admits at most ``parkThreadBudget`` threads' worth of thread-blocking parks at once.
///
/// A park holds a synchronous seam call in flight (`FileManaging`'s `fileExists`,
/// `attributesOfItem`, `copyItem` are not `async`), so it must block the thread it was called on,
/// and production calls those seams from `Task.detached`, on the cooperative pool. The pool is one
/// thread per core and doesn't grow when one blocks. swift-testing starts every suite at once, so
/// without a limit the gated tests park in the same instant, nearly filling the pool, and the async
/// side that would signal `release` can't get a thread, so parks hit their bound instead.
///
/// A limiter, not a rewrite: a park can't stop blocking a thread, and a continuation-backed latch
/// (like `DuplicateBatchRedesignTests`' `Latch`, for async operations) would need `FileManaging`
/// to be async, which is production API. The wait must be asynchronous and on the test side:
/// `park()` queueing for a slot would hold the same pool thread as parking. So the test reserves
/// in async context before the work that reaches the seam starts (``ParksThreads``).
///
/// FIFO, so a wide reservation can't be starved by a stream of narrow ones: a waiter only tries
/// once it is at the head of the queue. Waiting suspends and costs no thread.
actor ParkThreadBudget {
    static let shared = ParkThreadBudget()

    /// How long a reservation waits before giving up and going ahead anyway: far longer than any
    /// legitimate queue, so reaching it means the budget itself is wedged. Bounded, and the bound
    /// records itself: letting an extra park through is a smaller failure than hanging the package
    /// run, but a limiter that has stopped limiting must not look like one that works. Pinned by
    /// `aReservationThatCanNeverBeServedGivesUpAndSaysSo`; without the deadline check that test
    /// never finishes.
    let giveUpAfter: Duration

    /// Where a give-up is reported. The default is a real test failure, so a limiter that has
    /// stopped limiting can't look like one that works. Injectable only so `ParkBudgetTests` can
    /// exercise the give-up without `withKnownIssue`, which would put "with 1 known issue" on every
    /// `Modules/Sync` run's summary line; `theGiveUpDefaultsToARealTestFailure` checks the default by
    /// reading this source.
    private let report: @Sendable (String) -> Void

    init(giveUpAfter: Duration = .seconds(60),
         report: @escaping @Sendable (String) -> Void = { Issue.record(Comment(rawValue: $0)) }) {
        self.giveUpAfter = giveUpAfter
        self.report = report
    }

    private var held = 0
    private var nextTicket = 0
    /// Waiting reservations, oldest first. An array of ids, not a served counter: a reservation can
    /// leave out of order when it gives up, and a counter that skipped to its ticket would strand
    /// everyone still waiting behind it.
    private var queue: [Int] = []

    /// The most threads ever reserved at once. Not used by the limiter; ``ParkBudgetTests``
    /// measures the limiter with it.
    private(set) var highWaterMark = 0

    /// Threads reserved right now.
    var inFlight: Int { held }

    /// Suspends until `threads` more parked threads fit inside the budget. A single reservation
    /// wider than the whole budget is admitted alone (the `held == 0` arm) rather than
    /// deadlocking, which lets a four-worker rendezvous run at all.
    func reserve(_ threads: Int) async {
        let ticket = nextTicket
        nextTicket += 1
        queue.append(ticket)
        defer {
            queue.removeAll { $0 == ticket }
            held += threads
            highWaterMark = max(highWaterMark, held)
        }
        let deadline = ContinuousClock.now.advanced(by: giveUpAfter)
        while queue.first != ticket || (held > 0 && held + threads > parkThreadBudget) {
            if ContinuousClock.now >= deadline {
                report("""
                    a park reservation for \(threads) thread(s) waited out \(giveUpAfter) and went
                    ahead ungoverned. \(held) thread(s) are reserved and \(queue.count) more are
                    queued, so something took a reservation and never gave it back. See
                    docs/flaky-tests.md, "Every gate parks at once, on the pool their releases need".
                    """)
                return
            }
            // Cancellation ends the wait, and the `defer` still balances the trait's `relinquish`.
            // Without it the loop would spin once cancelled (`try?` swallows the `Task.sleep`
            // cancellation error and the sleep stops sleeping), and even `.timeLimit` couldn't
            // stop it.
            if Task.isCancelled { return }
            // A suspension, not a block: a waiter holds no thread.
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func relinquish(_ threads: Int) { held -= threads }
}

/// Declares that a test parks `threads` real threads at a gate, and takes that many out of
/// ``ParkThreadBudget`` for the test's duration. Per test, not per suite: most tests in the gated
/// suites aren't gated, and serialising a whole suite for a few would cost far more. The
/// reservation covers the whole test, since for these tests the park is most of it: launch, wait
/// for `entered`, stage, signal `release`, join.
struct ParksThreads: SuiteTrait, TestTrait, TestScoping {
    let threads: Int

    /// So the trait can also be written on a suite and mean "each of its tests", not "this whole
    /// suite runs alone".
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        // The suite-level invocation wraps the whole suite; only the per-test one should reserve.
        guard testCase != nil else { return try await function() }
        await ParkThreadBudget.shared.reserve(threads)
        do {
            try await function()
        } catch {
            // Relinquished on the failure path too: a throwing test must not strand every other
            // gated test behind it and turn one failure into a whole-run timeout.
            await ParkThreadBudget.shared.relinquish(threads)
            throw error
        }
        await ParkThreadBudget.shared.relinquish(threads)
    }
}

extension Trait where Self == ParksThreads {
    /// The test holds one real thread parked at a gate for its duration.
    static var parksAThread: Self { Self(threads: 1) }

    /// The test holds `count` real threads parked at once: two gates in one run, or a rendezvous
    /// several workers wide.
    static func parksThreads(_ count: Int) -> Self { Self(threads: count) }
}

/// A small lock-guarded box for collecting values out of `@Sendable` callbacks in tests (the
/// paths a seam closure was consulted with, say).
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// Polls a main-actor condition until it holds or the timeout expires, recording a labeled failure
/// on timeout. Always wait for the observable effect, never a guessed duration. The failure is
/// reported at the call site (`sourceLocation`), so a full run with several timeouts names each
/// test rather than this helper's `#expect`.
///
/// Bounded by polls as well as seconds, and the seconds are the weaker bound: everything this
/// waits for arrives on main-actor turns, and a congested run has fewer per second, so a deadline
/// in seconds shrinks exactly when the wait needs it most. A poll nominally costs its 10 ms sleep,
/// but under CPU load it has been measured above 200 ms, leaving five seconds only about 20
/// evaluations. Callers take the default `timeout:` (`WaitUntilFloorTests` passes 0 on purpose),
/// so the floor never collides with a short budget, and a passing wait still returns the moment
/// the condition holds.
///
/// **Keep this in step with the copies in `SyncCloudTests/TestSupport.swift` and
/// `Modules/Dashboard/Tests/Dashboard/WaitSupport.swift`**, which can't import this one (a test
/// target's code isn't visible to another target). All three bodies are identical on purpose.
@MainActor
func waitUntil(
    _ what: Comment,
    timeout: TimeInterval = 5,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    // Bounded by scheduler turns as well as seconds (``TurnDeadline``): on a starved run, such as
    // a hosted 3-vCPU VM with every suite queued on the main actor, the polls themselves slow down.
    // A turn needs the pool and the main actor, so a starved run stops this clock instead of
    // spending it.
    var polls = 0
    let deadline = TurnDeadline(seconds: timeout, turns: waitPollFloor)
    while polls < waitPollFloor || !deadline.hasPassed {
        polls += 1
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    // The poll count is the diagnosis, so it goes in the message: a wait that gave up after a
    // handful was starved and says nothing about the code; one that gave up after hundreds was
    // genuinely disproved.
    #expect(condition(), "\(what.rawValue) — still false after \(polls) polls; \(deadline.spent)",
            sourceLocation: sourceLocation)
}

/// Waits for NSUndoManager's event-scoped group to close, so the next registration starts a new
/// top-level step instead of nesting into the previous action's: the separation undo suites need
/// when they perform an unrelated operation and then the one under test.
///
/// `RunLoop.main.run(until:)` can't do this: under `swift test` no input source is attached to the
/// main runloop, so it returns at once with the group still open. What closes the group is an
/// ordinary suspension, which hands the main thread back so the main queue is serviced. This polls
/// the level that must reach zero, bounded, and fails naming the level and poll count if it never
/// does.
@MainActor
func closeTheUndoEventGroup(_ undoManager: UndoManager?,
                            timeout: TimeInterval = 5,
                            sourceLocation: SourceLocation = #_sourceLocation) async {
    guard let undoManager else {
        #expect(Bool(false), "no UndoManager to close a group on — the test's premise is void",
                sourceLocation: sourceLocation)
        return
    }
    var polls = 0
    let deadline = TurnDeadline(seconds: timeout, turns: waitPollFloor)  // as `waitUntil`
    while polls < waitPollFloor || !deadline.hasPassed {
        polls += 1
        if undoManager.groupingLevel == 0 { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(undoManager.groupingLevel == 0,
            "the undo event group never closed — still at level \(undoManager.groupingLevel) after \(polls) polls",
            sourceLocation: sourceLocation)
}

/// The fewest polls `waitUntil` makes before it may give up, however little of its deadline is
/// left. Same number, and the same reason, as `LayoutPumpWait.pumpFloor` in the FileExplorer test
/// target.
let waitPollFloor = 50

/// Creates a fresh, uniquely named temp directory for real-filesystem tests and returns it
/// canonicalized. macOS's temporaryDirectory sits behind the /var -> /private/var symlink, while
/// the real enumerator and contentsOfDirectory(at:) yield canonical (/private/var/...) children.
/// Code under test matches roots against those children by exact path prefix (the diff engine's
/// relative-key trim, buildTree's cache and subtree helpers), so a raw /var/... root would
/// mismatch and pass vacuously or flake. resolvingSymlinksInPath strips /private instead of adding
/// it; only the canonicalPath resource value gives the enumerator's form.
///
/// The caller owns cleanup: `defer { try? FileManager.default.removeItem(at: root) }`.
func makeCanonicalTempRoot(prefix: String) throws -> URL {
    let fm = FileManager.default
    let raw = fm.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try fm.createDirectory(at: raw, withIntermediateDirectories: true)
    let canonical = try raw.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
    return URL(fileURLWithPath: canonical ?? raw.path, isDirectory: true)
}

/// A `SyncHistoryStore` on its own temp file, so a test's records stay out of the per-process
/// shared store. The caller owns cleanup: `defer { removeHistoryStoreFiles(store) }`.
@MainActor
func makeTempHistoryStore(prefix: String) -> SyncHistoryStore {
    SyncHistoryStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString).jsonl"))
}

/// Removes what a ``makeTempHistoryStore(prefix:)`` store put on disk: its file and the `.lock`
/// sidecar `LogFileWriter`'s trim takes beside it. Flushes first: the writer creates both on its
/// background queue from `init` onwards, so a remove that doesn't wait runs before they exist and
/// the queue writes them afterwards.
@MainActor
func removeHistoryStoreFiles(_ store: SyncHistoryStore) {
    store.flushToDisk()
    try? FileManager.default.removeItem(at: store.fileURL)
    try? FileManager.default.removeItem(atPath: store.fileURL.path + ".lock")
}

/// Every set-aside a store has written beside `url`, sorted by name. The kept name is unique per
/// episode (``UnreadableSetAside``), so a test discovers the rescued files rather than assuming a
/// single fixed slot.
func setAsidesBeside(_ url: URL) -> [URL] {
    let dir = url.deletingLastPathComponent()
    let prefix = url.lastPathComponent + ".unreadable"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasPrefix(prefix) }.sorted().map { dir.appendingPathComponent($0) }
}

/// Fails `moveItem` a fixed number of times, then lets it through: the seam for "the set-aside
/// rename itself failed", which no arrangement of real permissions can produce while leaving the
/// directory writable enough for the destructive write the guard has to refuse. Shared by the
/// person-tag and verdict-cache set-aside suites, which drive the same guard, so the double can't
/// drift between copies.
final class MoveBlockedFileManager: FileManager, @unchecked Sendable {
    /// How many more `moveItem` calls fail before the obstruction "clears".
    nonisolated(unsafe) var movesToRefuse = 0

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if movesToRefuse > 0 {
            movesToRefuse -= 1
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

/// Parks the first stat the checksummer makes, signalling `entered`, so a test can hold a checksum
/// pass (`autoVerifySameSizePairs`, `verifyAllWithChecksum`) mid-hash while it runs a file
/// operation, then release the hash and see what the pass commits. Everything else passes straight
/// through to the real `FileManager` the fixture's temp files live on.
final class FirstStatGate: FileManaging, @unchecked Sendable {
    private let inner: FileManager
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var gated = false
    private var timedOut = false

    init(inner: FileManager) { self.inner = inner }

    /// True if the parked stat gave up waiting instead of being released. The wait is bounded so a
    /// mis-wired test fails instead of hanging; a silent timeout would let the hash resume and the
    /// test assert against a pass that was never held. Tests `try #require(!gate.releasedByTimeout)`
    /// after the pass.
    var releasedByTimeout: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }

    private func gateIfFirst() {
        lock.lock(); let first = !gated; if first { gated = true }; lock.unlock()
        guard first else { return }
        entered.signal()
        if !release.wait(until: TurnDeadline(seconds: 10, turns: parkTurnFloor)) {
            lock.lock(); timedOut = true; lock.unlock()
        }
    }

    // Both metadata entry points gate, not just one. `gateIfFirst` fires once, so hooking both
    // parks the pass at whichever it reaches first. A gate pinned to one syscall stops holding
    // anything the moment the verifier reads metadata another way; pin it to the moment, not the
    // call.
    func fileExists(atPath p: String) -> Bool { inner.fileExists(atPath: p) }
    func fileExists(atPath p: String, isDirectory d: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        gateIfFirst()
        return inner.fileExists(atPath: p, isDirectory: d)
    }
    func attributesOfItem(atPath p: String) throws -> [FileAttributeKey: Any] {
        gateIfFirst()
        return try inner.attributesOfItem(atPath: p)
    }
    func setAttributes(_ a: [FileAttributeKey: Any], ofItemAtPath p: String) throws { try inner.setAttributes(a, ofItemAtPath: p) }
    func createDirectory(at u: URL, withIntermediateDirectories c: Bool, attributes a: [FileAttributeKey: Any]?) throws {
        try inner.createDirectory(at: u, withIntermediateDirectories: c, attributes: a)
    }
    func copyItem(at s: URL, to d: URL) throws { try inner.copyItem(at: s, to: d) }
    func moveItem(at s: URL, to d: URL) throws { try inner.moveItem(at: s, to: d) }
    func trashItem(at u: URL, resultingItemURL o: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        try inner.trashItem(at: u, resultingItemURL: o)
    }
    func removeItem(at u: URL) throws { try inner.removeItem(at: u) }
    func replaceItem(at d: URL, withItemAt s: URL, backupItemName n: String) throws -> URL? {
        try inner.replaceItem(at: d, withItemAt: s, backupItemName: n)
    }
    func enumerator(at u: URL, includingPropertiesForKeys k: [URLResourceKey]?, options m: FileManager.DirectoryEnumerationOptions, errorHandler h: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
        inner.enumerator(at: u, includingPropertiesForKeys: k, options: m, errorHandler: h)
    }
}

// MARK: - Scratch defaults suites

// `wipeDefaultsSuite`, `ScratchDefaults` and the ledger live in `EventsTestSupport`, shared by every
// test target.

/// Reads the log lines one operation produced, from the on-disk log rather than
/// `Logger.shared.entries`. `entries` can't hold a window across a multi-step operation in a
/// parallel run: it is trimmed to the newest 1000 (`Logger.flushPendingEntries`) and every suite
/// writes to it, so an opening marker can be evicted before the assertion reads it, and the
/// failure then names the missing marker, as if production had stopped logging.
///
/// The per-process temp file the test logger writes (`Logger.defaultLogFileURL`) holds every line
/// in call order. Other suites still interleave into it, which is why the window is delimited by a
/// unique tag and callers should filter for a line only they could have written.
///
/// The bytes don't arrive by themselves: `Logger.log` hands the write to a serial queue at
/// `qos: .background`, which a busy machine starves, so polling for the marker can expire with the
/// line still unwritten. `Logger.flushToDisk()` is `queue.sync {}`: it blocks until the writer
/// drains and lends the queue the caller's priority meanwhile, which no poll can do.
///
/// - Parameter tag: Something unique to this test — a `UUID().uuidString`. It goes in both markers.
/// - Returns: The lines strictly between this window's markers, in call order.
@MainActor
func logLines(tag: String, during body: () async throws -> Void) async throws -> [String] {
    let url = Logger.shared.logFileURL
    await Logger.shared.debug("log-window opens \(tag)").value
    try await body()
    await Logger.shared.debug("log-window closes \(tag)").value

    // Drain the writer rather than wait for a background-QoS queue. This returns once every append
    // above has hit the file, so the read needs no poll and can't expire: a marker missing after
    // this is a real absence, which the two `#require`s may claim.
    Logger.shared.flushToDisk()
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let opened = try #require(lines.firstIndex { $0.contains("log-window opens \(tag)") },
                              "the log window's opening marker never reached disk — this read would be vacuous")
    let closed = try #require(lines.lastIndex { $0.contains("log-window closes \(tag)") },
                              "the log window's closing marker never reached disk — this read would be vacuous")
    return Array(lines[(opened + 1)..<closed])
}

/// The last log line containing `fragment`, read from the on-disk log. `Logger.shared.entries`
/// has the same eviction hazard as `logLines(tag:during:)`, milder: the asserted line itself is
/// trimmed out of the newest 1000 in a parallel run, and the test fails as
/// `line?.contains(…) == false`, naming nothing about the logger. Callers must still pass a
/// fragment only they could have written, since the disk log holds every suite's lines.
@MainActor
func loggedLineOnDisk(containing fragment: String) async -> String? {
    // Drained, not polled: see `logLines(tag:during:)` for why a background-QoS append can't be
    // waited out. With the queue drained there is no arrival to detect, so no marker is needed.
    let url = Logger.shared.logFileURL
    Logger.shared.flushToDisk()
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init).last { $0.contains(fragment) }
}
