import Testing
import AppKit
import SwiftUI
import Sync
@testable import Dashboard

/// Pins DetailsMetadataCache: per-path memoization and the two invalidations, a refreshSubject
/// event and a scan completing. Only isScanning flipping to false drops the cache; a scan starting
/// must not. `TheLoadNeverBlocksTheMainThread`, below, pins that the main thread never waits on the
/// filesystem work.
@MainActor
@Suite struct DetailsMetadataCacheTests {

    /// Stands in for DetailsSidebar.loadMetadata(for:), counting stat calls and returning
    /// configurable values. Lock-guarded and `@unchecked Sendable` because the cache runs the
    /// loader on its own queue; the tests await each load, so the lock is never contended.
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
                return loadedMetadata(path, size: _size, created: "Jan 1, 2026 at 9:00:00 AM",
                                      modified: _modificationDate)
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
        // A hit must not bump the generation, or every selection would restart the size walk.
        #expect(cache.generation == 0)
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

        // Switching back is a path change too: the cache holds a single entry.
        _ = await cache.load(for: "/vault/a.txt")
        #expect(loader.statCount == 3)
        #expect(cache.generation == 0, "a path change bumped the generation")
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

    /// The directory-size task keys on `generation`, so the events that drop the memo must bump it;
    /// that clears a stale folder total after a copy or delete inside the selected folder.
    @Test func generationBumpsOnRefreshAndScanCompletionOnly() {
        let loader = CountingLoader()
        let cache = makeCache(loader: loader)

        #expect(cache.generation == 0)

        cache.refreshOccurred()
        #expect(cache.generation == 1)

        // Scan starting keeps the metadata cache, and must keep the computed size too.
        cache.scanningChanged(true)
        #expect(cache.generation == 1)

        cache.scanningChanged(false)
        #expect(cache.generation == 2)
    }

    // MARK: The unreadable-item warning

    /// A loader whose stat fails, reporting the reason as `DetailsSidebar.loadMetadata` does for an
    /// item it may not read, with a switch to make the item readable again.
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
                    return loadedMetadata(path)
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
        // `refreshOccurred` drops the memo every time, so only the rate limit stops N identical
        // warnings, each a real disk write in the log writer.
        for _ in 0..<8 {
            _ = await cache.load(for: "/Volumes/Cloud/locked.pdf")
            cache.refreshOccurred()
        }

        #expect(spy.messages.count == 1)
        // The premise: the stat re-ran every time, so the single warning comes from the rate limit,
        // not from a memo that survived the invalidations.
        #expect(loader.statCount == 8)
        #expect(spy.messages.first?.contains("/Volumes/Cloud/locked.pdf") == true)
    }

    @Test func eachUnreadablePathGetsItsOwnWarning() async {
        // Per path, not per session: the limit must not swallow a different item's failure.
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
        // is a new fact, and suppressing it would hide it.
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

/// Guards against a launch hang: a `getxattr` in `DetailsSidebar`'s stat against a wedged file
/// provider parks the main thread, leaving the app alive with no windows.
///
/// Moving the stat into a `.task` is not enough: a `View`'s `.task` inherits the view's
/// `@MainActor` isolation, so the syscall leaves the render pass but not the main thread. The
/// property pinned is "the main thread never waits on the loader". Each test holds the loader
/// hostage on a semaphore, as a wedged provider does, and asserts the main actor keeps working.
@MainActor
@Suite struct TheLoadNeverBlocksTheMainThread {

    /// Parks whoever calls it until released, standing in for a `getxattr` against a wedged
    /// provider. The wait is bounded so a regression fails the suite instead of hanging it; the
    /// assertions below report it.
    final class HostageLoader: @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let entered = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let timeout: Double
        private var _callCount = 0
        private var _returnCount = 0

        init(timeout: Double = 30) { self.timeout = timeout }

        var callCount: Int { lock.withLock { _callCount } }
        /// Loads that have come back, released or timed out. Zero means every stat is still parked.
        var returnCount: Int { lock.withLock { _returnCount } }

        func load(_ path: String) -> DetailsSidebar.MetadataLoad {
            lock.withLock { _callCount += 1 }
            entered.signal()
            _ = gate.wait(timeout: .now() + timeout)
            lock.withLock { _returnCount += 1 }
            return loadedMetadata(path)
        }

        /// Blocks until the loader has been entered, so the stat is known to be in flight and stuck,
        /// not merely not started.
        func waitUntilEntered(seconds: Double = 5) { _ = entered.wait(timeout: .now() + seconds) }

        /// Lets every parked call finish, so no queue thread leaks past the test. Signals once per
        /// call because more than one load can be in flight (see the re-key note in
        /// `aStatThatNeverReturnsStillLetsTheFirstFramePaint`).
        func release() {
            for _ in 0..<max(lock.withLock { _callCount }, 1) { gate.signal() }
        }
    }

    /// A loader with a per-path gate, so a test chooses the order two in-flight loads finish in.
    /// `ioQueue` is `.concurrent`, so finish order need not match start order.
    final class OrderedLoader: @unchecked Sendable {
        private let lock = NSLock()
        private var gates: [String: DispatchSemaphore] = [:]
        private var _entered: Set<String> = []

        var entered: Set<String> { lock.withLock { _entered } }

        private func gate(_ path: String) -> DispatchSemaphore {
            lock.withLock {
                if let g = gates[path] { return g }
                let g = DispatchSemaphore(value: 0)
                gates[path] = g
                return g
            }
        }

        func load(_ path: String) -> DetailsSidebar.MetadataLoad {
            let g = gate(path)
            lock.withLock { _entered.insert(path) }
            _ = g.wait(timeout: .now() + 30)
            return loadedMetadata(path)
        }

        func release(_ path: String) { gate(path).signal() }
    }

    /// The memo must track the last path requested, not the last load to come back.
    ///
    /// A superseded load can't be cancelled: `.task(id:)` cancels its Task, but the queue block
    /// behind its continuation runs to completion and then writes the memo, and with a
    /// `.concurrent` `ioQueue` the stale one can land last. Unguarded, the cache memoizes `/a`
    /// while the inspector shows `/b`, and a later re-selection of `/a` is served a superseded
    /// entry.
    @Test func aSupersededLoadMustNotOverwriteTheMemoWithItsStalePath() async {
        let loader = OrderedLoader()
        let cache = DetailsMetadataCache(loadMetadata: loader.load, loadIcon: { _ in NSImage() })

        // Selection moves /a -> /b: two loads in flight, /b requested last.
        let first = Task { await cache.load(for: "/vault/a.txt") }
        let second = Task { await cache.load(for: "/vault/b.txt") }

        // Yield, never block (these Tasks are main-actor isolated, so a blocking wait deadlocks
        // them), until both are parked inside the loader.
        await waitUntil("both loads in flight, or this proves nothing") { loader.entered.count == 2 }

        // The superseding load lands first, the superseded one last.
        loader.release("/vault/b.txt")
        _ = await second.value
        loader.release("/vault/a.txt")
        _ = await first.value

        #expect(cache.cached(for: "/vault/b.txt") != nil, "the memo lost the path actually selected")
        #expect(cache.cached(for: "/vault/a.txt") == nil, "a superseded load overwrote the memo")
    }

    /// An invalidation that lands while a load is in flight must not be undone by that load
    /// finishing. `refreshOccurred()` follows every file operation; a load started before it
    /// carries pre-operation attributes, and committing it would put a stale size and dates back
    /// into a card that looks current.
    @Test func aLoadStartedBeforeAnInvalidationMustNotResurrectTheMemo() async {
        let loader = OrderedLoader()
        let cache = DetailsMetadataCache(loadMetadata: loader.load, loadIcon: { _ in NSImage() })

        let inFlight = Task { await cache.load(for: "/vault/report.pdf") }
        await waitUntil("the load to start") { loader.entered.contains("/vault/report.pdf") }

        // A file operation completes while the stat is still out.
        cache.refreshOccurred()

        loader.release("/vault/report.pdf")
        _ = await inFlight.value

        #expect(cache.cached(for: "/vault/report.pdf") == nil,
                "a pre-invalidation load repopulated the memo the refresh had just dropped")
    }

    /// The timing-free version: a miss is answered from memory at once, without consulting the
    /// loader. `body` and the `.task` make this call first, which is why neither can block.
    @Test func aCacheMissAnswersFromMemoryWithoutTouchingTheLoader() {
        let loader = HostageLoader()
        defer { loader.release() }
        let cache = DetailsMetadataCache(loadMetadata: loader.load, loadIcon: { _ in NSImage() })

        #expect(cache.cached(for: "/Volumes/Cloud/wedged.pdf") == nil)
        // A miss is nil, not a stat. If `cached(for:)` filled misses itself, this call would park
        // inside the loader and never reach the next line.
        #expect(loader.callCount == 0)
    }

    /// End to end: a stat that never returns, and a first frame that paints anyway. Renders the
    /// real `DetailsSidebar` with its loader held hostage and asserts the frame lays out while the
    /// stat is still parked. If the `.task` called a `@MainActor` loader synchronously, the main
    /// thread could only get there once the hostage timed out, so the stat would have returned.
    @Test func aStatThatNeverReturnsStillLetsTheFirstFramePaint() async throws {
        // Longer than the default: the verdict is lost only if something else holds the main thread
        // for the whole hostage, and on hosted CI something has held it for 9 s.
        let loader = HostageLoader(timeout: 60)
        defer { loader.release() }

        let manager = FileSyncManager()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("details-hostage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let sidebar = DetailsSidebar(
            syncManager: manager, leftPath: folder.path, rightPath: "",
            overridePath: nil, singleSource: false,
            cache: DetailsMetadataCache(loadMetadata: loader.load, loadIcon: { _ in NSImage() }))

        let host = NSHostingView(rootView: sidebar)
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host

        // First layout makes the view appear and arms its `.task`; the drain lets that task reach
        // the loader. Bounded by turns, and it exits as soon as the stat is in flight.
        host.layoutSubtreeIfNeeded()
        for _ in 0..<300 where loader.callCount == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        // A generous wait, since how soon the stat starts isn't under test.
        loader.waitUntilEntered(seconds: 30)
        // At least one, not exactly one: `.onReceive` on `$isScanning` fires at once with the
        // current value and `scanningChanged(false)` invalidates, so the first render loads twice.
        #expect(loader.callCount >= 1, "the stat never ran — this test would prove nothing")

        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        #expect(size.height > 0, "the card laid out to nothing")
        // No stopwatch: on hosted CI the main thread is held for seconds by work that is not this
        // test's, and a clock cannot tell that from waiting on the stat. A main thread that waited
        // on the stat could only reach this line after the stat returned.
        #expect(loader.returnCount == 0,
                "the inspector waited on the stat: it laid out only after \(loader.returnCount) of \(loader.callCount) loads came back")
    }
}

/// A file's metadata as a loader that read it answers: the shape every loader above returns.
private func loadedMetadata(_ path: String, size: String = "1 KB", created: String = "",
                            modified: String = "") -> DetailsSidebar.MetadataLoad {
    DetailsSidebar.MetadataLoad(
        metadata: DetailsSidebar.FileMetadata(
            name: (path as NSString).lastPathComponent, path: path, kind: "Document", size: size,
            creationDate: created, modificationDate: modified, permissions: "644", isDirectory: false),
        failure: nil)
}
