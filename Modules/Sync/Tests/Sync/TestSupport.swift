import Foundation
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

    public init() {}

    /// True if the parked call gave up waiting instead of being released.
    public var releasedByTimeout: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }

    /// Signals `entered`, then blocks until `release` arrives or the bound expires.
    public func park(timeout: TimeInterval = 10) {
        entered.signal()
        if release.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); timedOut = true; lock.unlock()
        }
    }
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

    func fileExists(atPath p: String) -> Bool { inner.fileExists(atPath: p) }
    func fileExists(atPath p: String, isDirectory d: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        gateIfFirst()
        return inner.fileExists(atPath: p, isDirectory: d)
    }
    func attributesOfItem(atPath p: String) throws -> [FileAttributeKey: Any] { try inner.attributesOfItem(atPath: p) }
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
