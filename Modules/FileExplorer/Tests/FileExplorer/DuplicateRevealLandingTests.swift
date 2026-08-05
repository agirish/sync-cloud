import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// The landing itself, driven through the real path: a mounted Duplicates lens handed a reveal
/// request, resolving through its own `.task` exactly as it does when the workspace switch mounts
/// it.
///
/// **Mounted, not called.** The tempting shape is to build a `TidyView` value and invoke
/// `applyRevealRequest()` on it — which writes `@State` on a view SwiftUI never installed, so
/// every assertion afterwards reads back the initial values and passes with the whole feature
/// disconnected. These mount the view and read back what it PAINTS, so the task, the state writes
/// and the re-render all have to actually happen.
///
/// **Pixels, not geometry and not captions.** The lens fills a fixed frame, so `fittingSize` is
/// the frame whatever the content does — it cannot see a card open. And nothing here can read a
/// caption: with no assistive client attached to this process, accessibility assertions pass
/// vacuously. What is left, and what is actually being claimed, is what ends up on screen.
///
/// The sharp assertion is `theGroupHoldingTheFileIsTheOneOpened`: revealing one file must paint
/// something DIFFERENT from revealing another. A resolver that always opened the first group would
/// satisfy every "something changed" case in here and fail only that one.
@MainActor
@Suite struct DuplicateRevealLandingTests {

    private static let canvas = CGSize(width: 520, height: 620)

    private static func copy(_ path: String, keeper: Bool) -> DuplicateCopy {
        DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                      size: 4_096, itemCount: 1, modificationDate: Date(timeIntervalSince1970: 0),
                      uniqueItemCount: 0, depth: 1, isRecommendedKeeper: keeper)
    }

    private static func group(_ paths: [String], name: String) -> DuplicateGroup {
        DuplicateGroup(matchType: .identical, name: name, isDirectory: false,
                       copies: paths.enumerated().map { copy($1, keeper: $0 == 0) },
                       reclaimableBytes: 4_096)
    }

    /// A manager holding a COMPLETED scan of `/root` with the given groups.
    private static func manager(groups: [DuplicateGroup]) -> FileSyncManager {
        let m = FileSyncManager()
        m.duplicateGroups = groups
        m.hasFoundDuplicates = true
        m.duplicateScanRoot = "/root"
        return m
    }

    /// One mounted lens, kept alive together with the window it needs to paint into.
    private final class Mounted {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        init(host: NSHostingView<AnyView>, window: NSWindow) {
            self.host = host
            self.window = window
        }
    }

    /// Mounts the Duplicates lens.
    ///
    /// The window background is not decoration: without one the content composites against the
    /// borderless window's own buffer and every comparison below reads as zero difference —
    /// "nothing painted", whatever the code did.
    private func mount(_ manager: FileSyncManager, request: DuplicateRevealRequest?) -> Mounted {
        let subject = TidyView(syncManager: manager, lens: .duplicates,
                               providerName: "Projects", scanTargetFolder: "/root",
                               onFindDuplicates: {}, revealRequest: request)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)

        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return Mounted(host: host, window: window)
    }

    private func snapshot(_ mounted: Mounted) -> NSBitmapImageRep? {
        mounted.host.layoutSubtreeIfNeeded()
        guard let rep = mounted.host.bitmapImageRepForCachingDisplay(in: mounted.host.bounds)
        else { return nil }
        mounted.host.cacheDisplay(in: mounted.host.bounds, to: rep)
        return rep
    }

    private func pixelsDiffering(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        var differing = 0
        for y in stride(from: 0, to: min(lhs.pixelsHigh, rhs.pixelsHigh), by: 2) {
            for x in stride(from: 0, to: min(lhs.pixelsWide, rhs.pixelsWide), by: 2) {
                guard let a = lhs.colorAt(x: x, y: y), let b = rhs.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(a.redComponent - b.redComponent),
                                max(abs(a.greenComponent - b.greenComponent),
                                    abs(a.blueComponent - b.blueComponent)))
                if delta > 0.02 { differing += 1 }
            }
        }
        return differing
    }

    /// The lens's painted state once it has settled — i.e. once the reveal task has run, the state
    /// has been written and SwiftUI has re-rendered.
    ///
    /// **Bounded by `LayoutPumpWait`, which floors on PASSES rather than seconds**, and it reports
    /// the pass count on failure. What these waits wait for arrives on main-actor turns, and under
    /// full-suite congestion a wall-clock deadline buys fewer of those exactly when more are
    /// needed — see `docs/flaky-tests.md`, mechanism 2. The count is the diagnosis: a wait that
    /// gave up after a handful of passes was starved and says nothing about the code, while one
    /// that gave up after a thousand was genuinely disproved.
    private func settled(_ mounted: Mounted,
                         differingFrom baseline: NSBitmapImageRep? = nil,
                         within timeout: TimeInterval = 5,
                         _ what: String,
                         sourceLocation: SourceLocation = #_sourceLocation) async -> NSBitmapImageRep? {
        guard let baseline else { return snapshot(mounted) }
        var latest: NSBitmapImageRep?
        let (held, pumps) = await LayoutPumpWait.pump(mounted.host, upTo: timeout) {
            latest = snapshot(mounted)
            guard let latest else { return false }
            return pixelsDiffering(baseline, latest) > 0
        }
        #expect(held, "\(what) — gave up after \(pumps) layout passes",
                sourceLocation: sourceLocation)
        return latest ?? snapshot(mounted)
    }

    /// Polls until the mounted lens paints the same screen as `reference`. The arrival check: a
    /// landing is not "a repaint happened", it is "the screen is now the one it should be".
    private func settled(_ mounted: Mounted,
                         matching reference: NSBitmapImageRep,
                         within timeout: TimeInterval = 5,
                         _ what: String,
                         sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        var differing = Int.max
        let (held, pumps) = await LayoutPumpWait.pump(mounted.host, upTo: timeout) {
            guard let current = snapshot(mounted) else { return false }
            differing = pixelsDiffering(reference, current)
            return differing == 0
        }
        #expect(held, "\(what) — \(differing) pixels still differ after \(pumps) layout passes",
                sourceLocation: sourceLocation)
        return held
    }

    // MARK: The premise

    /// **A reveal changes what is on screen at all.** Every case below reads a landing as a change
    /// in paint, so if the mount painted identically with and without a request they would all
    /// pass against a feature that does nothing.
    @Test func aRevealChangesWhatIsPainted() async throws {
        let target = Self.group(["/root/a/x.txt", "/root/b/x.txt"], name: "x.txt")
        let quiet = try #require(await settled(mount(Self.manager(groups: [target]), request: nil),
                                              "no request"))
        let landed = try #require(await settled(
            mount(Self.manager(groups: [target]),
                  request: DuplicateRevealRequest(path: "/root/b/x.txt")),
            differingFrom: quiet, "the reveal painted nothing new — the card never opened"))
        #expect(pixelsDiffering(quiet, landed) > 0)
    }

    // MARK: Landing on the right group

    /// **The group holding the FILE is the one opened — not simply the first one.**
    ///
    /// Two groups, and two requests naming a file in each. A resolver that always opened the first
    /// group (or that opened all of them, or none) paints the same thing both times; only one that
    /// follows the requested path paints differently. This is the assertion the "something
    /// changed" cases cannot make.
    @Test func theGroupHoldingTheFileIsTheOneOpened() async throws {
        let first = Self.group(["/root/a/aaa.txt", "/root/b/aaa.txt"], name: "aaa.txt")
        let second = Self.group(["/root/a/zzz.txt", "/root/b/zzz.txt"], name: "zzz.txt")

        let openFirst = try #require(await settled(
            mount(Self.manager(groups: [first, second]),
                  request: DuplicateRevealRequest(path: "/root/b/aaa.txt")), "first"))
        let openSecond = try #require(await settled(
            mount(Self.manager(groups: [first, second]),
                  request: DuplicateRevealRequest(path: "/root/b/zzz.txt")),
            differingFrom: openFirst,
            "revealing two different files opened the same group — the request's path is not "))
        #expect(pixelsDiffering(openFirst, openSecond) > 0)
    }

    /// **A request made mid-scan resolves when the results land, not before.** The common
    /// first-use shape — no scan yet, so the handoff starts one — and the case a fixture that only
    /// ever tests completed scans would miss entirely.
    ///
    /// The scan is ended here the way `findDuplicates` ends one: publish the results, then clear
    /// the running flag. Nothing else is touched, and nothing re-triggers the request.
    @Test func aRequestMadeDuringAScanLandsWhenTheResultsArrive() async throws {
        let target = Self.group(["/root/a/x.txt", "/root/b/x.txt"], name: "x.txt")
        let manager = FileSyncManager()
        manager.isFindingDuplicates = true

        let mounted = mount(manager, request: DuplicateRevealRequest(path: "/root/b/x.txt"))
        let scanning = try #require(await settled(mounted, "scanning"))

        manager.duplicateGroups = [target]
        manager.hasFoundDuplicates = true
        manager.duplicateScanRoot = "/root"
        manager.isFindingDuplicates = false

        let landed = try #require(await settled(
            mounted, differingFrom: scanning,
            "the pending request never resolved once the scan published its results"))
        #expect(pixelsDiffering(scanning, landed) > 0)

        // **"Something repainted" is not the claim.** The results arriving repaints the lens on
        // its own — a request that had already given up and answered `notFound` from the empty
        // pre-scan groups would repaint too, and would satisfy the assertion above while never
        // opening anything. So the late landing is held to the EAGER one: mounting the same
        // request against the same completed results is known (from the cases above) to open the
        // group, and resolving late must arrive at exactly that screen.
        let eager = mount(Self.manager(groups: [target]),
                          request: DuplicateRevealRequest(path: "/root/b/x.txt"))
        let reference = try #require(await settled(eager, "eager reference"))
        let arrived = await settled(mounted, matching: reference,
                                    "resolving after the scan landed somewhere other than where resolving immediately lands")
        #expect(arrived)
    }

    /// The named empty state: a file in no group must land on an answer, not on a list that has
    /// quietly filtered itself to nothing.
    ///
    /// Compared against revealing a file that IS grouped, in the same results — so the difference
    /// is the outcome and not merely "a request happened".
    @Test func aFileInNoGroupLandsSomewhereElseThanAGroupedOne() async throws {
        let groups = [Self.group(["/root/a/x.txt", "/root/b/x.txt"], name: "x.txt")]
        let grouped = try #require(await settled(
            mount(Self.manager(groups: groups),
                  request: DuplicateRevealRequest(path: "/root/b/x.txt")), "grouped"))
        let lonely = try #require(await settled(
            mount(Self.manager(groups: groups),
                  request: DuplicateRevealRequest(path: "/root/c/lonely.txt")),
            differingFrom: grouped,
            "a file in no group landed on the same screen as one that has a group"))
        #expect(pixelsDiffering(grouped, lonely) > 0)
    }

    /// A scan that found NO groups at all still answers about the file rather than showing the
    /// folder's generic all-clear. The user asked about a file; an answer about the folder leaves
    /// them to infer it covered the thing they clicked.
    @Test func aScanWithNoGroupsAtAllStillAnswersAboutTheFile() async throws {
        func emptyManager() -> FileSyncManager {
            let m = FileSyncManager()
            m.hasFoundDuplicates = true
            m.duplicateScanRoot = "/root"
            return m
        }
        let clean = try #require(await settled(mount(emptyManager(), request: nil), "clean state"))
        let named = try #require(await settled(
            mount(emptyManager(), request: DuplicateRevealRequest(path: "/root/c/lonely.txt")),
            differingFrom: clean,
            "the folder's all-clear was shown for a question about one file"))
        #expect(pixelsDiffering(clean, named) > 0)
    }
}
