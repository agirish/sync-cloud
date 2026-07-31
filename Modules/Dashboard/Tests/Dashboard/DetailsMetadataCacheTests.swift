import Testing
import AppKit
import SwiftUI
import Sync
@testable import Dashboard

/// Pins DetailsMetadataCache (extracted from DetailsSidebar's view body): per-path
/// memoization and the two invalidation gestures — a refreshSubject event and a scan
/// completing. The scan trigger is deliberately one-sided: only isScanning flipping to
/// false drops the cache; a scan starting must not.
///
/// Plus the property the whole thing exists to guarantee: the filesystem work happens somewhere
/// the main thread never waits on it. See `TheLoadNeverBlocksTheMainThread` at the bottom.
@MainActor
@Suite struct DetailsMetadataCacheTests {

    /// Injected metadata loader that counts stat calls and returns configurable values,
    /// standing in for DetailsSidebar.loadMetadata(for:).
    ///
    /// Lock-guarded and `@unchecked Sendable` because the cache now runs the loader on its own
    /// queue rather than on the main actor. In practice these tests await each load before
    /// touching the loader again, so the lock is never contended — it is here to make the
    /// concurrency claim honest rather than to resolve a real race.
    final class CountingLoader: @unchecked Sendable {
        private let lock = NSLock()
        private var _statCount = 0
        private var _size = "1 KB"
        private var _modificationDate = "Jul 1, 2026 at 10:00:00 AM"

        var statCount: Int { lock.withLock { _statCount } }

        func fileChangedOnDisk(size: String, modificationDate: String) {
            lock.withLock { _size = size; _modificationDate = modificationDate }
        }

        func load(_ path: String) -> DetailsSidebar.MetadataLoad {
            lock.withLock {
                _statCount += 1
                return DetailsSidebar.MetadataLoad(
                    metadata: DetailsSidebar.FileMetadata(
                        name: (path as NSString).lastPathComponent,
                        path: path,
                        kind: "Document",
                        size: _size,
                        creationDate: "Jan 1, 2026 at 9:00:00 AM",
                        modificationDate: _modificationDate,
                        permissions: "644",
                        isDirectory: false
                    ),
                    failure: nil)
            }
        }
    }

    private func makeCache(loader: CountingLoader) -> DetailsMetadataCache {
        DetailsMetadataCache(loadMetadata: loader.load, loadIcon: { _ in NSImage() })
    }

    @Test func repeatedLookupsForSamePathStatOnce() async {
        let loader = CountingLoader()
        let cache = makeCache(loader: loader)

        let first = await cache.load(for: "/vault/report.pdf")
        _ = await cache.load(for: "/vault/report.pdf")
        let third = await cache.load(for: "/vault/report.pdf")

        #expect(loader.statCount == 1)
        #expect(first.metadata?.path == "/vault/report.pdf")
        #expect(third.metadata?.size == "1 KB")
        #expect(third.icon != nil)
    }

    @Test func refreshEventInvalidatesAndNextLookupRestats() async {
        let loader = CountingLoader()
        let cache = makeCache(loader: loader)

        _ = await cache.load(for: "/vault/report.pdf")
        cache.refreshOccurred()
        _ = await cache.load(for: "/vault/report.pdf")

        #expect(loader.statCount == 2)
    }

    @Test func scanCompletionInvalidatesButScanStartDoesNot() async {
        let loader = CountingLoader()
        let cache = makeCache(loader: loader)

        _ = await cache.load(for: "/vault/report.pdf")

        // Scan starting: the memoized metadata must survive.
        cache.scanningChanged(true)
        _ = await cache.load(for: "/vault/report.pdf")
        #expect(loader.statCount == 1)

        // Scan completing: the next lookup must re-stat.
        cache.scanningChanged(false)
        _ = await cache.load(for: "/vault/report.pdf")
        #expect(loader.statCount == 2)
    }

    @Test func pathChangeRestats() async {
        let loader = CountingLoader()
        let cache = makeCache(loader: loader)

        _ = await cache.load(for: "/vault/a.txt")
        let second = await cache.load(for: "/vault/b.txt")

        #expect(loader.statCount == 2)
        #expect(second.metadata?.name == "b.txt")

        // Switching back is a path change too — the cache holds a single entry.
        _ = await cache.load(for: "/vault/a.txt")
        #expect(loader.statCount == 3)
    }

    @Test func invalidationSurfacesFreshLoaderValues() async {
        let loader = CountingLoader()
        let cache = makeCache(loader: loader)

        let stale = await cache.load(for: "/vault/report.pdf")
        #expect(stale.metadata?.size == "1 KB")

        // The file changed on disk (e.g. a copy overwrote it); the loader now sees new attributes.
        loader.fileChangedOnDisk(size: "2 MB", modificationDate: "Jul 6, 2026 at 3:00:00 PM")

        // Without invalidation the memoized values keep being served.
        let memoized = await cache.load(for: "/vault/report.pdf")
        #expect(memoized.metadata?.size == "1 KB")

        cache.refreshOccurred()
        let fresh = await cache.load(for: "/vault/report.pdf")
        #expect(fresh.metadata?.size == "2 MB")
        #expect(fresh.metadata?.modificationDate == "Jul 6, 2026 at 3:00:00 PM")
    }

    /// The computed-directory-size task keys on `generation`, so the same events that drop the
    /// memoized metadata must bump it — that is what clears a stale folder total after a
    /// copy/delete inside the selected folder and triggers the recompute.
    @Test func generationBumpsOnRefreshAndScanCompletionOnly() {
        let loader = CountingLoader()
        let cache = makeCache(loader: loader)

        #expect(cache.generation == 0)

        cache.refreshOccurred()
        #expect(cache.generation == 1)

        // Scan starting keeps the metadata cache — and must keep the computed size too.
        cache.scanningChanged(true)
        #expect(cache.generation == 1)

        cache.scanningChanged(false)
        #expect(cache.generation == 2)
    }

    /// Lookups (hits or path changes) must not bump the generation, or every selection change
    /// would needlessly restart the directory-size walk twice.
    @Test func lookupsDoNotBumpGeneration() async {
        let loader = CountingLoader()
        let cache = makeCache(loader: loader)

        _ = await cache.load(for: "/vault/a.txt")
        _ = await cache.load(for: "/vault/a.txt")
        _ = await cache.load(for: "/vault/b.txt")

        #expect(cache.generation == 0)
    }

    // MARK: The unreadable-item warning

    /// A loader whose stat always fails, reporting the reason exactly as
    /// `DetailsSidebar.loadMetadata` does for an item it is not allowed to read — with a switch so
    /// a test can let the item become readable again.
    final class FailingLoader: @unchecked Sendable {
        private let lock = NSLock()
        private var _statCount = 0
        private var _succeeds = false

        var statCount: Int { lock.withLock { _statCount } }
        func setSucceeds(_ value: Bool) { lock.withLock { _succeeds = value } }

        func load(_ path: String) -> DetailsSidebar.MetadataLoad {
            lock.withLock {
                _statCount += 1
                guard !_succeeds else {
                    return DetailsSidebar.MetadataLoad(
                        metadata: DetailsSidebar.FileMetadata(
                            name: (path as NSString).lastPathComponent, path: path, kind: "Document",
                            size: "1 KB", creationDate: "", modificationDate: "", permissions: "644",
                            isDirectory: false),
                        failure: nil)
                }
                return DetailsSidebar.MetadataLoad(
                    metadata: nil,
                    failure: "Details: couldn't read attributes of \(path): You do not have permission to view it.")
            }
        }
    }

    /// Collects the warnings that survive the rate limit.
    @MainActor
    final class WarningSpy {
        var messages: [String] = []
    }

    private func makeCache(loader: FailingLoader, spy: WarningSpy) -> DetailsMetadataCache {
        DetailsMetadataCache(loadMetadata: loader.load, loadIcon: { _ in NSImage() },
                             logWarning: { spy.messages.append($0) })
    }

    @Test func anUnreadableItemIsWarnedAboutOncePerPathNotOncePerRefresh() async {
        let loader = FailingLoader()
        let spy = WarningSpy()
        let cache = makeCache(loader: loader, spy: spy)

        // A bulk run: N file operations, each posting a refresh, with an unreadable item selected.
        // The memo cannot carry the "once per path" claim its doc used to make — `refreshOccurred`
        // drops it every time — so this wrote N identical warnings, each a real disk write in the
        // log writer.
        for _ in 0..<8 {
            _ = await cache.load(for: "/Volumes/Cloud/locked.pdf")
            cache.refreshOccurred()
        }

        #expect(spy.messages.count == 1)
        // The premise: the stat really did re-run every time, so the single warning comes from the
        // rate limit and not from a memo that quietly survived the invalidations.
        #expect(loader.statCount == 8)
        #expect(spy.messages.first?.contains("/Volumes/Cloud/locked.pdf") == true)
    }

    @Test func eachUnreadablePathGetsItsOwnWarning() async {
        // Per PATH, not per session: the limit must not swallow a different item's failure.
        let loader = FailingLoader()
        let spy = WarningSpy()
        let cache = makeCache(loader: loader, spy: spy)

        _ = await cache.load(for: "/Volumes/Cloud/a.pdf")
        _ = await cache.load(for: "/Volumes/Cloud/b.pdf")
        _ = await cache.load(for: "/Volumes/Cloud/a.pdf")   // back to the first: already said

        #expect(spy.messages.count == 2)
        #expect(spy.messages.contains { $0.contains("a.pdf") })
        #expect(spy.messages.contains { $0.contains("b.pdf") })
    }

    @Test func anItemThatBecomesReadableAgainCanBeWarnedAboutAgain() async {
        // The limit remembers a failure, not a path: a volume that came back and went away again
        // is a new fact, and suppressing it would trade one noisy bug for a silent one.
        let loader = FailingLoader()
        let spy = WarningSpy()
        let cache = makeCache(loader: loader, spy: spy)

        _ = await cache.load(for: "/Volumes/Cloud/flaky.pdf")
        #expect(spy.messages.count == 1)

        loader.setSucceeds(true)
        cache.refreshOccurred()
        _ = await cache.load(for: "/Volumes/Cloud/flaky.pdf")
        #expect(spy.messages.count == 1)   // a success says nothing

        loader.setSucceeds(false)
        cache.refreshOccurred()
        _ = await cache.load(for: "/Volumes/Cloud/flaky.pdf")
        #expect(spy.messages.count == 2)
    }

    @Test func missingPathMemoizesNilResult() async {
        let loader = CountingLoader()
        let cache = DetailsMetadataCache(
            loadMetadata: { path in
                _ = loader.load(path)
                return DetailsSidebar.MetadataLoad(metadata: nil, failure: nil)
            },
            loadIcon: { _ in NSImage() }
        )

        let first = await cache.load(for: "/vault/gone.txt")
        let second = await cache.load(for: "/vault/gone.txt")

        #expect(first.metadata == nil)
        #expect(first.icon == nil)
        #expect(second.metadata == nil)
        #expect(loader.statCount == 1)
    }
}

/// The regression net for the launch hang reproduced on `4d55246` and its parent `80a235d`:
/// the app alive with zero windows and an empty log, 100% of samples parked on the main thread in
/// `getxattr` under `DetailsSidebar`'s stat.
///
/// `f77bdc3` had already moved that stat out of the render pass into a `.task`, which is why the
/// sampled frame reads `body.getter closure #4` — a `.task` closure is lexically inside `body`.
/// That was the right shape and still hung, because a `View`'s `.task` inherits the view's
/// `@MainActor` isolation: the syscall left the render pass but never left the main thread.
///
/// So the property worth pinning is not "not in `body`" — it is **"the main thread never waits on
/// the loader"**. Each test here holds the loader hostage on a semaphore, which is what a wedged
/// file provider does, and asserts the main actor keeps working anyway.
@MainActor
@Suite struct TheLoadNeverBlocksTheMainThread {

    /// A loader that parks whoever calls it until released — standing in for a `getxattr` against a
    /// wedged provider. The wait is bounded so that a regression FAILS the suite instead of hanging
    /// it: nothing here should ever get near the ceiling, and if it does, the elapsed-time
    /// assertions below report it as a plain failure.
    final class HostageLoader: @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let entered = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _callCount = 0

        var callCount: Int { lock.withLock { _callCount } }

        func load(_ path: String) -> DetailsSidebar.MetadataLoad {
            lock.withLock { _callCount += 1 }
            entered.signal()
            _ = gate.wait(timeout: .now() + 30)
            return DetailsSidebar.MetadataLoad(
                metadata: DetailsSidebar.FileMetadata(
                    name: (path as NSString).lastPathComponent, path: path, kind: "Document",
                    size: "1 KB", creationDate: "", modificationDate: "", permissions: "644",
                    isDirectory: false),
                failure: nil)
        }

        /// Blocks until the loader has actually been entered, so a test can be sure the stat is
        /// genuinely in flight and stuck rather than merely not started yet.
        func waitUntilEntered() { _ = entered.wait(timeout: .now() + 5) }

        /// Lets every parked call finish, so no queue thread is leaked past the test. Signals once
        /// per recorded call because more than one load can be in flight at a time — see the
        /// re-key note in `aStatThatNeverReturnsStillLetsTheFirstFramePaint`.
        func release() {
            for _ in 0..<max(lock.withLock { _callCount }, 1) { gate.signal() }
        }
    }

    /// The narrow, timing-free version of the claim: a miss is answered out of memory, immediately,
    /// without the loader being consulted at all. This is the call `body` and the `.task` make
    /// first, and it is the reason neither can be made to block.
    @Test func aCacheMissAnswersFromMemoryWithoutTouchingTheLoader() {
        let loader = HostageLoader()
        defer { loader.release() }
        let cache = DetailsMetadataCache(loadMetadata: loader.load, loadIcon: { _ in NSImage() })

        #expect(cache.cached(for: "/Volumes/Cloud/wedged.pdf") == nil)
        // The point: a miss is nil, not a stat. If `cached(for:)` ever filled misses itself, this
        // call would still be parked inside the loader and we would never reach the next line.
        #expect(loader.callCount == 0)
    }

    /// The whole bug, end to end: a stat that never returns, and a first frame that paints anyway.
    ///
    /// Renders the real `DetailsSidebar` through `NSHostingView` with its cache's loader held
    /// hostage, then asserts a laid-out size comes back promptly. Against the pre-fix code — the
    /// `.task` calling a `@MainActor` loader synchronously — the main thread is inside the loader
    /// and this measures the full 30s hostage timeout instead of milliseconds.
    @Test func aStatThatNeverReturnsStillLetsTheFirstFramePaint() async throws {
        let loader = HostageLoader()
        defer { loader.release() }

        let manager = FileSyncManager()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("details-hostage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let sidebar = DetailsSidebar(
            syncManager: manager, leftPath: folder.path, rightPath: "", compact: false,
            overridePath: nil, singleSource: false,
            cache: DetailsMetadataCache(loadMetadata: loader.load, loadIcon: { _ in NSImage() }))

        let host = NSHostingView(rootView: sidebar)
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host

        // The clock starts here and covers everything the regression would stall, not just the
        // final layout. That matters: against the pre-fix code the main thread parks INSIDE the
        // `.task` during the drain below, and a stopwatch started after it would time a main
        // thread that had already been released and read as a pass.
        let start = Date()

        // First layout is what makes the view appear and arms its `.task`; the drain then lets
        // that task run and reach the loader. Bounded by turns taken, and it exits the moment the
        // stat is in flight rather than burning the whole budget.
        host.layoutSubtreeIfNeeded()
        for _ in 0..<300 where loader.callCount == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        loader.waitUntilEntered()
        // At least one, not exactly one: appearing re-keys the task once by itself. `.onReceive`
        // on `$isScanning` fires immediately with the current value, and `scanningChanged(false)`
        // invalidates, so the first render always loads twice. That predates this change — the
        // pre-fix code took the same two trips, just one after the other on the main thread.
        #expect(loader.callCount >= 1, "the stat never ran — this test would prove nothing")

        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let elapsed = Date().timeIntervalSince(start)

        #expect(size.height > 0, "the card laid out to nothing")
        // Well under the 30s hostage ceiling: generous enough not to flake on a loaded machine,
        // tight enough that a main thread parked on the stat cannot pass.
        #expect(elapsed < 5.0, "the inspector waited on the stat (\(elapsed)s)")
    }
}
