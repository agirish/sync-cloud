import Combine
import Foundation
import Events
import Testing
@testable import Sync

/// Awaits a semaphore off the main actor (a blocking `wait` on the test's actor would deadlock
/// anything the signaller needs from it). Bounded, and the timeout is RECORDED as a failure —
/// discarding it made the bound worse than useless: a test whose signal never arrives would
/// wait out the ten seconds and then carry on ungated, asserting against a state it never
/// actually reached. A positive control is where that hurts most, because "the gate never
/// engaged" and "the gate engaged and the pass still published" look identical afterwards.
func awaitSignal(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval = 10,
    _ what: Comment = "the signal never arrived — the test ran on ungated state",
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let result = await withCheckedContinuation { cont in
        DispatchQueue.global().async {
            cont.resume(returning: semaphore.wait(timeout: .now() + timeout))
        }
    }
    #expect(result == .success, what, sourceLocation: sourceLocation)
}

/// A two-semaphore park for holding a SYNCHRONOUS seam call in flight: the seam calls `park()`,
/// which signals `entered` and blocks until the test signals `release`.
///
/// The wait is bounded so a mis-wired test fails instead of hanging — and the bound RECORDS
/// itself, which is the half that actually matters. A discarded timeout is worse than no bound
/// at all: the parked call quietly resumes on its own and the test goes on asserting against a
/// state it never held, so "the gate never engaged" and "the gate engaged and the behaviour
/// happened anyway" become indistinguishable afterwards. Every user must
/// `try #require(!gate.releasedByTimeout)` once the work under test has finished. `FirstStatGate`
/// carries the same flag, for the same reason; use this wherever a gate is not also a
/// `FileManaging` stand-in.
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
    /// that was held and released AND for one that never engaged at all, so on its own it cannot
    /// tell those apart; consumers detect the second through `awaitSignal(gate.entered)`, and
    /// `ParkBudgetTests` pins both directions through this.
    public var didPark: Bool {
        lock.lock(); defer { lock.unlock() }
        return everParked
    }

    /// True while a call is blocked inside `park()`. Only `ParkBudgetTests` reads it — a consumer
    /// waits on `entered` and `release`, never on this.
    public var isParked: Bool {
        lock.lock(); defer { lock.unlock() }
        return parked
    }

    /// Signals `entered`, then blocks until `release` arrives or the bound expires.
    ///
    /// **This blocks a REAL THREAD, and under a package run that thread is a cooperative-pool
    /// one** — production reaches its `FileManaging` seams from `Task.detached`. A test whose gate
    /// gets here must declare `.parksAThread` so the pool keeps enough width to deliver the
    /// release; see ``ParkThreadBudget`` and `docs/flaky-tests.md`, "Every gate parks at once, on
    /// the pool their releases need".
    public func park(timeout: TimeInterval = 10) {
        lock.lock(); parked = true; everParked = true; lock.unlock()
        entered.signal()
        let expired = release.wait(timeout: .now() + timeout) == .timedOut
        lock.lock(); parked = false; if expired { timedOut = true }; lock.unlock()
    }
}

// MARK: - The park-thread budget

/// How many REAL THREADS the thread-blocking parks in this target may hold at once, process-wide.
///
/// A quarter of the cooperative pool, whose width is the core count. The point is the other three
/// quarters: every park is released by async work that needs a pool thread to get there, so the
/// budget is sized by what has to keep running, not by what is allowed to stop.
let parkThreadBudget = max(2, ProcessInfo.processInfo.activeProcessorCount / 4)

/// Admits at most ``parkThreadBudget`` threads' worth of thread-blocking parks at once.
///
/// **Why this exists.** A park holds a SYNCHRONOUS seam call in flight — `FileManaging`'s
/// `fileExists`/`attributesOfItem`/`copyItem` are not `async`, so the only way to hold one is to
/// block the thread it was called on, and production reaches those seams from
/// `Task.detached(priority: .userInitiated)`, i.e. from the Swift cooperative pool. That pool's
/// width is the core count and it does not grow when a thread blocks. swift-testing starts every
/// suite at once, so without this the gated tests all park within the same instant, near the
/// start of the run: 9 of 10 pool threads blocked, measured 2026-08-11. The async side that would
/// signal `release` then needs a thread from what is left, alongside every other test that also
/// just started, and some parks reach their 10 s bound instead of being released.
///
/// **Why a limiter rather than a rewrite.** The park cannot stop blocking a thread — that is what
/// holding a synchronous call in flight *is*. `DuplicateBatchRedesignTests`'s continuation-backed
/// `Latch` is the right answer for what it parks (an enqueued *async* operation), and cannot be
/// applied here without making `FileManaging` async, which is production API. What can change is
/// how many park at once.
///
/// **Why the wait has to be asynchronous, and on the test side.** Making `park()` itself queue for
/// a slot would not help: a seam call blocked waiting for a slot holds exactly the same pool thread
/// as one blocked in the park. The reservation must therefore be taken by the test, in async
/// context, BEFORE the work that reaches the seam starts — which is what ``ParksThreads`` does.
///
/// FIFO, so a wide reservation cannot be starved by a stream of narrow ones: a waiter only tries
/// once it is at the head of the queue. Waiting costs no thread — it suspends.
actor ParkThreadBudget {
    static let shared = ParkThreadBudget()

    /// How long a reservation waits before giving up and going ahead anyway. Far longer than any
    /// legitimate queue — every gated test is under two seconds and there are about two dozen of
    /// them — so reaching it means the budget itself is wedged.
    ///
    /// **Bounded, and the bound RECORDS itself**, for the same reason the parks it governs are:
    /// this is a limiter, not a correctness device, so letting an extra park through is a far
    /// smaller failure than hanging the package run — but a limiter that has quietly stopped
    /// limiting must not look like one that is working. Both halves are pinned by
    /// `aReservationThatCanNeverBeServedGivesUpAndSaysSo`; removing the deadline check below turns
    /// that test from a red one into a run that never finishes, which is how it was found.
    let giveUpAfter: Duration

    /// Where a give-up is reported. The default is a real test failure, because the whole point of
    /// the bound is that a limiter which has quietly stopped limiting must not look like one that
    /// is working.
    ///
    /// Injectable **only** so `ParkBudgetTests` can exercise the give-up without a `withKnownIssue`
    /// — which would put "with 1 known issue" on the summary line of every `Modules/Sync` run
    /// forever, and that line is the first thing anyone reads off a run here. The cost of the seam
    /// is that the test drives an injected reporter rather than the shipped one, so
    /// `theGiveUpDefaultsToARealTestFailure` checks the default by reading this source.
    private let report: @Sendable (String) -> Void

    init(giveUpAfter: Duration = .seconds(60),
         report: @escaping @Sendable (String) -> Void = { Issue.record(Comment(rawValue: $0)) }) {
        self.giveUpAfter = giveUpAfter
        self.report = report
    }

    private var held = 0
    private var nextTicket = 0
    /// Waiting reservations, oldest first. An array of ids rather than a served counter, because a
    /// reservation can leave the queue OUT OF ORDER when it gives up, and a counter that skipped
    /// to its ticket would strand everyone still waiting behind it.
    private var queue: [Int] = []

    /// The most threads ever reserved at once. Not used by the limiter — it is what
    /// ``ParkBudgetTests`` measures the limiter with, and what a future "is this still doing
    /// anything?" question is answered from.
    private(set) var highWaterMark = 0

    /// Threads reserved right now.
    var inFlight: Int { held }

    /// Suspends until `threads` more parked threads fit inside the budget. A single reservation
    /// wider than the whole budget is admitted alone rather than deadlocking — the `held == 0`
    /// arm — which is what lets a four-worker rendezvous run at all.
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
            // Cancellation ends the wait, and the `defer` still balances the `relinquish` the
            // trait will make. Without this the loop spins at full speed once cancelled —
            // `try?` swallows the `Task.sleep` cancellation error and the sleep stops
            // sleeping — so a swift-testing `.timeLimit` could not stop it either. Found by
            // mutation: removing the deadline above hung the run instead of failing it.
            if Task.isCancelled { return }
            // A suspension, not a block: a waiter holds no thread, which is the whole point.
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func relinquish(_ threads: Int) { held -= threads }
}

/// Declares that a test parks `threads` real threads at a gate, and takes that many out of
/// ``ParkThreadBudget`` for the test's duration.
///
/// Applied per test rather than per suite because the gated tests sit in suites that are mostly
/// NOT gated (six of `AutoVerifyOnScanTests`, three of `VerifyAllWithChecksumTests`), and
/// serialising a whole suite to slow down six of its tests is a much larger bill than the problem.
///
/// **The reservation covers the whole test, not just the park.** It could be tightened to the
/// parked window, but for these tests the park IS most of the test: the body launches the work,
/// waits for `entered`, does its staging, signals `release` and joins. There is nothing
/// meaningful outside it to reclaim.
struct ParksThreads: SuiteTrait, TestTrait, TestScoping {
    let threads: Int

    /// So the trait can also be written on a suite, and mean "each of its tests", rather than
    /// "this whole suite runs alone".
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        // The suite-level invocation wraps the whole suite; only the per-test one should reserve.
        guard testCase != nil else { return try await function() }
        await ParkThreadBudget.shared.reserve(threads)
        do {
            try await function()
        } catch {
            // Relinquished on the failure path too — a throwing test must not strand every other
            // gated test behind it, which would turn one failure into a whole-run timeout.
            await ParkThreadBudget.shared.relinquish(threads)
            throw error
        }
        await ParkThreadBudget.shared.relinquish(threads)
    }
}

extension Trait where Self == ParksThreads {
    /// The test holds ONE real thread parked at a gate for its duration.
    static var parksAThread: Self { Self(threads: 1) }

    /// The test holds `count` real threads parked at once — two gates in one run, or a rendezvous
    /// several workers wide.
    static func parksThreads(_ count: Int) -> Self { Self(threads: count) }
}

/// A tiny lock-guarded box for collecting values out of `@Sendable` callbacks in tests
/// (e.g. recording the paths a seam closure was consulted with).
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// Polls a main-actor condition until it holds or the timeout expires, recording a labeled
/// test failure on timeout. The single shared replacement for the per-suite polling helpers
/// and the fixed post-operation sleeps that flaked under parallel-suite main-actor
/// congestion: always wait for the observable effect, never a guessed duration.
///
/// The timeout is reported at the CALL SITE, like `awaitSignal` above. Without the forwarded
/// `sourceLocation` every one of this helper's ~150 callers anchors its failure to the `#expect`
/// below, so a full-suite run with several timeouts names this one line several times and no test
/// file at all. That is expensive precisely when it is least affordable — a run whose failures you
/// cannot place is the problem mechanism 8 exists for.
///
/// **Bounded by POLLS as well as by seconds**, and the seconds are the weaker of the two.
/// Everything this waits for arrives on main-actor turns, and a congested run has fewer of them
/// per second, not more — so the deadline shrinks, in the only unit that matters, exactly when the
/// wait needs it most. Measured across a full Sync run on 2026-08-08: nominally a poll costs its
/// 10 ms sleep, and under the CPU-spin load in `docs/flaky-tests.md` the worst observed rate was
/// **223 ms per poll**, 22× that. Five seconds buys ~500 evaluations at the nominal rate and ~22 at
/// that one. A sibling helper elsewhere in the repo was measured at 4 polls in 4.44s on a loaded CI
/// runner and failed there, which is the outcome this floor exists to prevent.
///
/// Every one of the ~160 real callers takes the default `timeout:` — `WaitUntilFloorTests`, which
/// passes 0 deliberately to leave the floor as the only thing driving the loop, is the sole
/// exception — so the floor cannot collide with a deliberately short budget, and it costs a passing
/// wait nothing: the loop still returns the moment the condition holds.
///
/// **Keep this in step with the copies in `SyncCloudTests/TestSupport.swift` and
/// `Modules/Dashboard/Tests/Dashboard/WaitSupport.swift`**, which cannot import this one — a test
/// target's code is not visible to another target. All three bodies are identical on purpose.
/// Dashboard joined them on 2026-08-22, replacing a suite-local wait that returned silently when it
/// gave up; the failure that cost is in `docs/flaky-tests.md` under "Fixed pumps and fixed sleeps".
@MainActor
func waitUntil(
    _ what: Comment,
    timeout: TimeInterval = 5,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    var polls = 0
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while polls < waitPollFloor || ContinuousClock.now < deadline {
        polls += 1
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    // The poll count IS the diagnosis, so it goes in the message: a wait that gave up after a
    // handful was starved and says nothing about the code, while one that gave up after hundreds
    // was genuinely disproved.
    #expect(condition(), "\(what.rawValue) — still false after \(polls) polls",
            sourceLocation: sourceLocation)
}

/// Waits for NSUndoManager's event-scoped group to CLOSE, so the next registration starts a new
/// top-level step instead of nesting into the previous action's — the separation two undo suites
/// depend on when they perform an unrelated operation and then the one under test.
///
/// **This replaced `RunLoop.main.run(until: Date().addingTimeInterval(0.02))`, which both suites
/// carried and which did nothing at all.** Measured in this test process: that call returns in
/// ~2 µs and `groupingLevel` reads 1 on the line after it — `run(until:)` exits immediately when
/// no input source is attached to the main runloop, which is the case under `swift test`. So it
/// was neither a pump nor even the fixed sleep it looked like. What actually closes the group in
/// these tests is the ordinary `await` that comes next: a `Task.sleep` hands the main thread
/// back, the main queue is serviced, and the group closes — measured as level 1 → 0 across a
/// single 10 ms `Task.sleep`. The separation the helper claimed to establish was being provided
/// by whichever suspension happened to follow it.
///
/// Condition-based and bounded, never a duration: it polls the level that has to reach zero and
/// fails, naming the level and the poll count, if it never does.
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
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while polls < waitPollFloor || ContinuousClock.now < deadline {
        polls += 1
        if undoManager.groupingLevel == 0 { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(undoManager.groupingLevel == 0,
            "the undo event group never closed — still at level \(undoManager.groupingLevel) after \(polls) polls",
            sourceLocation: sourceLocation)
}

/// The fewest polls `waitUntil` will make before it may give up, however little of its deadline is
/// left. Same number, and the same reason, as `LayoutPumpWait.pumpFloor` in the FileExplorer test
/// target — the one sibling that exists on both release lines.
let waitPollFloor = 50

/// Creates a fresh, uniquely named temp directory for real-filesystem tests and returns it
/// CANONICALIZED — macOS's temporaryDirectory lives behind the /var -> /private/var symlink,
/// while the real enumerator and contentsOfDirectory(at:) yield canonical (/private/var/...)
/// child URLs. Code under test matches roots against those children by exact path prefix
/// (the diff engine's relative-key trim, buildTree's cache/subtree helpers), so a test using
/// the raw /var/... root would silently mismatch and pass vacuously or flake.
/// resolvingSymlinksInPath can't do this job: it deliberately STRIPS /private instead of
/// adding it — only the canonicalPath resource value gives the enumerator's form.
///
/// The caller owns cleanup: `defer { try? FileManager.default.removeItem(at: root) }`.
func makeCanonicalTempRoot(prefix: String) throws -> URL {
    let fm = FileManager.default
    let raw = fm.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try fm.createDirectory(at: raw, withIntermediateDirectories: true)
    let canonical = try raw.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
    return URL(fileURLWithPath: canonical ?? raw.path, isDirectory: true)
}

/// Every set-aside a store has written beside `url`, sorted by name.
///
/// The kept name is unique PER EPISODE (``UnreadableSetAside``), so a test discovers the rescued
/// files rather than assuming the single fixed slot the three stores used to share — assuming it
/// is what let a second episode's `removeItem` delete the first episode's only copy.
func setAsidesBeside(_ url: URL) -> [URL] {
    let dir = url.deletingLastPathComponent()
    let prefix = url.lastPathComponent + ".unreadable"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasPrefix(prefix) }.sorted().map { dir.appendingPathComponent($0) }
}

/// Fails `moveItem` a fixed number of times, then lets it through — the seam for "the set-aside
/// rename itself failed", which no arrangement of real permissions can produce while leaving the
/// directory writable enough for the destructive write the guard has to refuse.
///
/// Shared by the person-tag and verdict-cache set-aside suites: both drive the same guard, and a
/// second copy of this double is exactly the drift this module has paid for before.
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

/// Parks the FIRST stat the checksummer makes on a semaphore, signalling `entered` — so a
/// test can hold a checksum pass (`autoVerifySameSizePairs`, `verifyAllWithChecksum`) mid-hash
/// while it runs a file operation, then release the hash and observe what the pass commits.
/// Everything else passes straight through to the real `FileManager` the fixture's temp files
/// live on.
final class FirstStatGate: FileManaging, @unchecked Sendable {
    private let inner: FileManager
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var gated = false
    private var timedOut = false

    init(inner: FileManager) { self.inner = inner }

    /// True if the parked stat gave up waiting instead of being released. The wait is bounded so
    /// a mis-wired test fails instead of hanging, but a bound whose result is discarded turns a
    /// hang into something worse: the hash resumes on its own and the test goes on to assert
    /// against a pass that was never actually held. Tests `try #require(!gate.releasedByTimeout)`
    /// after the pass, so that becomes a stated failure rather than a silent one.
    var releasedByTimeout: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }

    private func gateIfFirst() {
        lock.lock(); let first = !gated; if first { gated = true }; lock.unlock()
        guard first else { return }
        entered.signal()
        if release.wait(timeout: .now() + 10) == .timedOut {
            lock.lock(); timedOut = true; lock.unlock()
        }
    }

    // **Both metadata entry points gate, not just one.** `gateIfFirst` fires once, so hooking both
    // parks the pass at whichever it reaches first and asks nothing about which that is. It used to
    // hook `fileExists(atPath:isDirectory:)` alone, which was the verifier's opening call at the
    // time — so when the verifier collapsed its three metadata reads into one `attributesOfItem`,
    // eleven tests across two suites stopped being held at all and failed on their 10 s bound
    // instead. Nothing about the pass had changed; the seam had simply been pinned to a syscall
    // rather than to the moment it names.
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

/// Removes a throwaway defaults suite *and* its backing plist.
///
/// `removePersistentDomain(forName:)` only empties the domain: cfprefsd still leaves an empty
/// `~/Library/Preferences/<suite>.plist` behind, and neither `removeSuite(named:)` nor
/// `CFPreferencesAppSynchronize` reclaims it either — all four combinations were measured on
/// 2026-07-26 and every one left the file on disk. Because each scratch suite is named with a
/// fresh UUID, that is one stray file per suite per run: 26,047 had accumulated across the six
/// test targets before this was caught, at which point `defaults domains` — which enumerates the
/// whole directory — took minutes. Unlinking the file is the only thing that actually reclaims it.
///
/// Mirrored verbatim in every test target, since they are separate SPM packages with no shared
/// test-support module; keep the copies in step.
func wipeDefaultsSuite(_ name: String) {
    // Recorded here rather than at the call sites because this is the one funnel every cleanup
    // path — `defer`, `TestDefaults.wipe()`, `ScratchDefaults.deinit` — already goes through.
    // Recording only in `ScratchDefaults` missed the 46 `defer` sites, which build their suite
    // with a plain `UserDefaults(suiteName:)`, and Sync's leftovers grew 58 -> 89 -> 135 over
    // three runs because nothing was there to re-delete what cfprefsd had resurrected.
    scratchDefaultsLedger.record(name)
    UserDefaults.standard.removePersistentDomain(forName: name)
    UserDefaults.standard.removeSuite(named: name)
    CFPreferencesAppSynchronize(name as CFString)
    let path = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Preferences/\(name).plist")
    try? FileManager.default.removeItem(atPath: path)
}

/// Finishes the cleanup that the previous test run could not.
///
/// `wipeDefaultsSuite` reclaims the file for the great majority of suites, but cfprefsd is a
/// separate daemon and may write a suite's plist back out *after* the test process has exited.
/// That race is not winnable from inside the process: an `atexit` sweep that unlinked all 34 of a
/// Dashboard run's suites still lost it for the two whose defaults object was held past the test
/// by an undo registration. So every suite handed to `wipeDefaultsSuite` is recorded, and the next
/// run deletes whatever the last one left behind, which keeps the directory bounded at about one
/// run's stragglers instead of growing without limit. The gap this cannot close is a run that dies
/// before its cleanup runs at all: those suites are never recorded, so they are never swept.
let scratchDefaultsLedger = ScratchDefaultsLedger()

final class ScratchDefaultsLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var didSweepPreviousRun = false

    private let ledgerPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Caches/SyncCloudTestScratchSuites.ledger")
    private let preferencesDirectory = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Preferences")

    /// Records `name`, sweeping the previous run's leftovers on the first call of this process.
    func record(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        if !didSweepPreviousRun {
            didSweepPreviousRun = true
            sweepPreviousRun()
        }
        guard let line = "\(name)\n".data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: ledgerPath) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try? line.write(to: URL(fileURLWithPath: ledgerPath))
        }
    }

    private func sweepPreviousRun() {
        sweepStaleScratchPlists()
        guard let recorded = try? String(contentsOfFile: ledgerPath, encoding: .utf8) else { return }
        for name in recorded.split(separator: "\n") {
            try? FileManager.default.removeItem(atPath: "\(preferencesDirectory)/\(name).plist")
        }
        try? FileManager.default.removeItem(atPath: ledgerPath)
    }

    /// Deletes scratch plists the ledger can never account for, matching by SHAPE rather than name.
    ///
    /// A name only reaches the ledger when the test owning it gets to its cleanup. Most creation
    /// sites are a bare `UserDefaults(suiteName:)` paired with a `defer`, so a run that is KILLED
    /// — a cancelled CI job, an interrupted `swift test`, a mutation experiment stopped by hand —
    /// leaves suites that were never recorded and that no later run can name. That is not a
    /// theoretical gap: 3,551 had accumulated by 2026-08-03, and a cold `defaults domains`, which
    /// enumerates this directory, had gone from ~0.1s to 2.38s. Matching by shape closes it for
    /// every creation site at once, recorded or not.
    ///
    /// The age floor is what makes this safe to run while other sessions are testing — this Mac
    /// routinely has several worktrees running suites at once, and their live suites are minutes
    /// old at most. An hour is far past any test's lifetime, and still bounds the directory at
    /// about one hour of stragglers rather than letting it grow without limit.
    /// Internal, not private, so its two dangerous edges can be tested directly: a stale scratch
    /// plist really is deleted, and a real domain with a lowercase UUID really is not. Going
    /// through `record`'s once-per-process trigger instead would make those tests depend on
    /// which one ran first, and pass vacuously in whichever order lost.
    func sweepStaleScratchPlists() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: preferencesDirectory) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for name in names where Self.isScratchSuitePlist(name) {
            let path = "\(preferencesDirectory)/\(name)"
            guard let modified = try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            try? fm.removeItem(atPath: path)
        }
    }

    /// `<prefix><separator><UUID>.plist`, with the UUID in the UPPERCASE form `UUID().uuidString`
    /// emits — which is what every scratch suite name here ends in. Both separators are in use:
    /// `ScratchDefaults` joins with `-`, a few call sites with `.`.
    ///
    /// The uppercase requirement is the safety margin, not a detail: real preference domains that
    /// carry a UUID write it lowercase (`com.openai.chat.RemoteFeatureFlags.164320f2-…`), so they
    /// cannot match. Loosen this to case-insensitive and the sweep starts eating real domains.
    /// Scratch suites belonging to OTHER projects that share this machine's preferences
    /// directory. `pdfutils` is a separate project of the owner's; its test suites leak into the
    /// same place and are tracked separately THERE. A SyncCloud test run quietly deleting them
    /// would be destructive to someone else's investigation of their own leak, and invisible from
    /// this repo. Ownership is not inferable from the shape — only from the prefix — so this list
    /// is the only thing keeping the sweep inside its own house, and it must grow whenever another
    /// project starts sharing the directory.
    private static let foreignSuitePrefixes = ["pdfutils.", "PDFExportCoordinatorTests"]

    static func isScratchSuitePlist(_ name: String) -> Bool {
        guard name.hasSuffix(".plist") else { return false }
        guard !foreignSuitePrefixes.contains(where: name.hasPrefix) else { return false }
        let stem = name.dropLast(".plist".count)
        // A prefix character, a separator, then the 36-character UUID.
        guard stem.count > 37 else { return false }
        let separator = stem[stem.index(stem.endIndex, offsetBy: -37)]
        guard separator == "-" || separator == "." else { return false }
        let groups = stem.suffix(36).split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.allSatisfy { $0.isHexDigit && !$0.isLowercase } }
    }
}

/// A `UserDefaults` on a throwaway suite that cleans itself up — domain *and* plist — once its last
/// reference goes away. Prefer it to a bare `UserDefaults(suiteName:)`: teardown rides on the
/// object's lifetime rather than on a `defer` that a test added later can forget.
final class ScratchDefaults: UserDefaults {
    let scratchSuiteName: String

    /// - Parameter prefix: names the owning test in `~/Library/Preferences` while the suite is
    ///   alive; a fresh UUID is appended so parallel tests never share a domain.
    init(_ prefix: String) {
        self.scratchSuiteName = "\(prefix)-\(UUID().uuidString)"
        super.init(suiteName: scratchSuiteName)!   // a fresh UUID is never a reserved domain name
        scratchDefaultsLedger.record(scratchSuiteName)
    }

    deinit { wipeDefaultsSuite(scratchSuiteName) }
}

/// Reads the log lines one operation produced, from the on-disk log rather than
/// `Logger.shared.entries`.
///
/// **`entries` cannot carry a window across a multi-step operation in a parallel run.** It is
/// trimmed to the newest 1000 (`Logger.flushPendingEntries`) and every suite in the process writes
/// to the same array, so an opening marker written before the operation is routinely EVICTED before
/// the assertion reads it. Measured on `main` at `140d4773`: four tests across three suites pass
/// under `swift test --no-parallel` and fail under plain `swift test`, three of them reporting the
/// marker itself as `nil` — the failure names the missing marker, not the missing log line, so it
/// reads like the production code stopped logging when nothing of the sort happened.
///
/// The per-process temp file the test logger writes to (`Logger.defaultLogFileURL`) does not have
/// that problem: it holds every line, in call order, at any volume a test run reaches. Other suites
/// still interleave their lines into it — that is why the window is still delimited by a unique tag,
/// and why callers should filter for a line only they could have written.
///
/// **The bytes do not arrive by themselves, and this used to assume they did.** `Logger.log` calls
/// `logWriter.append`, which is `queue.async` on a serial queue at **`qos: .background`** — the call
/// is synchronous, the WRITE is not, and background QoS is exactly what the scheduler starves when
/// the machine is busy. This helper polled for the marker instead, on the belief that the append
/// "needs no flush marker to become visible"; measured across repeated full-package serial runs,
/// that poll expired after 250+ real polls (so: not a starved wait — five seconds of genuine
/// asking) with BOTH markers still absent, and the test it hit moved from run to run because
/// swift-testing randomizes order. `Logger.flushToDisk()` is `queue.sync {}`: it blocks until the
/// writer drains AND boosts the background queue's priority to the caller's for the duration, which
/// is the half a poll can never supply. Its own doc said so all along.
///
/// - Parameter tag: Something unique to this test — a `UUID().uuidString`. It goes in both markers.
/// - Returns: The lines strictly between this window's markers, in call order.
@MainActor
func logLines(tag: String, during body: () async throws -> Void) async throws -> [String] {
    let url = Logger.shared.logFileURL
    await Logger.shared.debug("log-window opens \(tag)").value
    try await body()
    await Logger.shared.debug("log-window closes \(tag)").value

    // Drain the writer, rather than waiting for a background-QoS queue to get around to it. This
    // returns only once every append issued above has hit the file, so the read below needs no
    // poll and cannot expire — a marker missing after this is a real absence, which is what the
    // two `#require`s are entitled to claim.
    Logger.shared.flushToDisk()
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let opened = try #require(lines.firstIndex { $0.contains("log-window opens \(tag)") },
                              "the log window's opening marker never reached disk — this read would be vacuous")
    let closed = try #require(lines.lastIndex { $0.contains("log-window closes \(tag)") },
                              "the log window's closing marker never reached disk — this read would be vacuous")
    return Array(lines[(opened + 1)..<closed])
}

/// The last log line containing `fragment`, read from the on-disk log.
///
/// The `Logger.shared.entries.last { … }` spelling this replaces is the same eviction hazard
/// `logLines(tag:during:)` documents, one step milder: with no window to lose, it survives until the
/// asserted line ITSELF is trimmed out of the newest 1000 — which a parallel run does, and which
/// surfaces as `line?.contains(…) == false` rather than as anything naming the logger. Measured:
/// `aFoldIsRefusedWhenTheKeeperNoLongerHoldsTheFilesItFolded` and both `theSingleResolve…` tests
/// fail exactly this way under plain `swift test` and pass under `--no-parallel`.
///
/// Callers must still pass a fragment only they could have written — the disk log is per-process,
/// so every suite's lines are in it.
@MainActor
func loggedLineOnDisk(containing fragment: String) async -> String? {
    // Drained, not polled — see `logLines(tag:during:)` for why a background-QoS append cannot be
    // waited out. The marker line goes with it: with the queue drained there is nothing to detect
    // the arrival OF, and a marker keyed on `hashValue` was never unique anyway.
    let url = Logger.shared.logFileURL
    Logger.shared.flushToDisk()
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init).last { $0.contains(fragment) }
}

// MARK: - Reading the log without racing every other suite

/// Accumulates every entry the shared `Logger` publishes, from construction until it is released.
///
/// **`Logger.shared.entries` is capped at 1,000 and this package runs ~2,850 tests across ~260
/// suites in parallel, so a whole-buffer read is a race with every other suite's logging.** When it
/// loses, `contains` finds nothing and the assertion reports a missing log line — indistinguishable
/// from the defect the test exists to catch. That is mechanism 12 in `docs/flaky-tests.md`, and it
/// reddened the v4.4 release run and two attempts at the v4.5 one.
///
/// **The rules written in that section diagnose it; they do not fix it.** An opening marker plus a
/// `#require` makes an evicted window *say* it was evicted rather than report an absence — which is
/// the right diagnosis and still a red, and in fact a redder one, because the marker is older than
/// the lines it bounds and so is evicted first. Measured: applying them to `FilingRenamePassTests`
/// took the full package from green to failing-with-a-better-message.
///
/// This removes the race instead. An entry captured at publish time cannot be taken away by a later
/// trim, and every entry appears in at least the publish that appended it (`flushPendingEntries`
/// appends and then trims, and both mutations publish), so accumulating across publishes sees
/// everything. Deduplicated by `LogEntry.id`, since each publish carries the whole array.
///
/// **Construct it BEFORE the call under test** — it is a window opening, not a query:
/// ```swift
/// let log = LogCapture()
/// await manager.doTheThing()
/// #expect(await log.holds(.warning, containing: "the thing went wrong"))
/// ```
@MainActor
final class LogCapture {
    private var seen: [LogEntry] = []
    private var ids: Set<UUID> = []
    private var cancellable: AnyCancellable?

    init() {
        // `dropFirst()` because a `@Published` publisher replays its CURRENT value on subscribe, and
        // a capture meaning "since I started" must not include what came before. What that rules
        // out is a sibling's identical sentence satisfying the assertion before the call under test
        // has run. Recorded honestly: that has not been reproduced — deleting `dropFirst()`,
        // removing a production log line and running the whole package still fails. It is kept as
        // the correct semantics for a capture, not as a guard anything here demonstrates.
        cancellable = Logger.shared.$entries.dropFirst().sink { [weak self] published in
            MainActor.assumeIsolated {
                guard let self else { return }
                for entry in published where !self.ids.contains(entry.id) {
                    self.ids.insert(entry.id)
                    self.seen.append(entry)
                }
            }
        }
    }

    /// Everything captured since construction, oldest first.
    var entries: [LogEntry] {
        get async {
            // The visibility half of mechanism 12's rule 1, which this still needs: `Logger.log` is
            // `nonisolated` and hands the entry to a FIFO queue a `@MainActor` task drains, so
            // without awaiting one more entry a line the call under test just wrote may not have
            // been published yet. The queue being FIFO, this drains everything enqueued before it.
            await Logger.shared.debug("log-capture flush marker").value
            return seen
        }
    }

    /// True when anything captured since construction is at `level` and contains `fragment`.
    func holds(_ level: LogLevel, containing fragment: String) async -> Bool {
        await entries.contains { $0.level == level && $0.message.contains(fragment) }
    }

    /// True when anything captured since construction contains `fragment`, at any level.
    func holds(containing fragment: String) async -> Bool {
        await entries.contains { $0.message.contains(fragment) }
    }

    /// The most recent captured message containing `fragment`, or nil.
    func line(containing fragment: String) async -> String? {
        await entries.last { $0.message.contains(fragment) }?.message
    }
}
