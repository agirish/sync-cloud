import AppKit
import Design
import Quartz
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The Compare Copies surface: the payload, the clamp, the branch that decides which host a pair
/// goes to, and the sheet laid out at the window floor.
@MainActor
@Suite struct CompareCopiesSurfaceTests {

    private static let scanned = Date(timeIntervalSince1970: 1_700_000_000)

    private func copy(_ path: String, keeper: Bool = false, size: Int = 1000,
                      isDirectory: Bool = false) -> DuplicateCopy {
        DuplicateCopy(id: path, name: (path as NSString).lastPathComponent,
                      isDirectory: isDirectory, size: size, itemCount: 1,
                      modificationDate: Self.scanned, uniqueItemCount: 0, depth: 1,
                      isRecommendedKeeper: keeper)
    }

    private func group(_ copies: [DuplicateCopy], isDirectory: Bool = false,
                       matchType: DuplicateMatchType = .identical) -> DuplicateGroup {
        DuplicateGroup(matchType: matchType, name: copies[0].name, isDirectory: isDirectory,
                       copies: copies, reclaimableBytes: 1000)
    }

    // MARK: The clamp

    /// **The size nobody develops at.** The window floor is 760×560 and the overlay has to be
    /// usable there — that is the whole reason this is an overlay and not a sheet, since macOS
    /// would silently squeeze a 1080pt sheet to the window's content width exactly here.
    @Test func atTheWindowFloorTheOverlayGetsTwoWorkablePanes() {
        let size = CompareOverlayMetrics.size(available: CGSize(width: 760, height: 560))
        #expect(size == CGSize(width: 712, height: 512))
    }

    /// And it stops growing: a 27-inch window must not hand two previews 1,900 points each.
    @Test func onALargeWindowTheOverlayStopsAtItsIdealSize() {
        let size = CompareOverlayMetrics.size(available: CGSize(width: 2400, height: 1400))
        #expect(size == CGSize(width: CompareOverlayMetrics.idealWidth,
                               height: CompareOverlayMetrics.idealHeight))
    }

    /// Below the minimum it overhangs rather than shrinking. A 40pt-wide preview pane is invisible
    /// as a bug; an overhanging card is not.
    @Test func belowTheMinimumTheOverlayOverhangsRatherThanShrinking() {
        let size = CompareOverlayMetrics.size(available: CGSize(width: 300, height: 200))
        #expect(size == CGSize(width: CompareOverlayMetrics.minimumWidth,
                               height: CompareOverlayMetrics.minimumHeight))
    }

    // MARK: The remembered size

    /// A card that has never been resized opens at the default — which is what every existing
    /// clamp case above is about.
    @Test func withNothingStoredTheCardOpensAtItsDefault() {
        let available = CGSize(width: 1600, height: 1000)
        #expect(CompareOverlayMetrics.size(available: available, stored: nil)
                    == CompareOverlayMetrics.size(available: available))
        // Zero is what `@AppStorage` holds before the first drag, and it must read as "unset"
        // rather than as a 0×0 card.
        #expect(CompareOverlayMetrics.size(available: available, stored: .zero)
                    == CompareOverlayMetrics.size(available: available))
    }

    @Test func aRememberedSizeIsHonoured() {
        let stored = CGSize(width: 900, height: 620)
        #expect(CompareOverlayMetrics.size(available: CGSize(width: 1600, height: 1000),
                                           stored: stored) == stored)
    }

    /// **A stored size is clamped on every render, not only when it is written.** The window can
    /// shrink between sessions — or between two launches on different displays — and a card that
    /// trusted what it stored would open wider than the window it is in, with its verdict bar off
    /// screen and no way to reach the grip that would fix it.
    @Test func aRememberedSizeIsReClampedToASmallerWindow() {
        let stored = CGSize(width: 1600, height: 1000)
        let available = CGSize(width: 900, height: 700)
        #expect(CompareOverlayMetrics.size(available: available, stored: stored) == available)
    }

    @Test func aRememberedSizeCannotSitBelowTheFloor() {
        let stored = CGSize(width: 100, height: 100)
        let size = CompareOverlayMetrics.size(available: CGSize(width: 1600, height: 1000),
                                              stored: stored)
        #expect(size == CompareOverlayMetrics.minimum)
    }

    // MARK: The payload

    /// Opening the same two copies from either side is the same surface, not a second one sliding
    /// in over the first — so the id cannot depend on which copy was clicked.
    @Test func thePairIdIsStableUnderACopyOrderSwap() {
        let a = copy("/root/a/x.txt", keeper: true)
        let b = copy("/root/b/x.txt")
        let one = DuplicateComparePair(keeper: a, other: b, matchType: .identical, groupName: "x.txt")
        let two = DuplicateComparePair(keeper: b, other: a, matchType: .identical, groupName: "x.txt")
        #expect(one.id == two.id)
        #expect(one != two, "the id is stable; the drawn order is not, and must not be")
    }

    /// The keeper opens on the left, which is where every other two-copy surface in this app puts
    /// it — the Compare review's banner says "keep left, trash right".
    @Test func theKeeperOpensOnTheLeft() {
        let a = copy("/root/a/x.txt", keeper: true)
        let b = copy("/root/b/x.txt")
        let pair = DuplicateComparePair(keeper: a, other: b, matchType: .identical, groupName: "x.txt")
        #expect(pair.left.path == "/root/a/x.txt")
        #expect(pair.other(than: "/root/a/x.txt")?.path == "/root/b/x.txt")
        #expect(pair.other(than: "/root/b/x.txt")?.path == "/root/a/x.txt",
                "flipping the keeper flips which copy the verdict acts on, without moving a pane")
    }

    /// A keeper path naming neither side is what a stale payload looks like — there is no "other
    /// copy" to trash, and the surface must not invent one.
    @Test func aKeeperPathFromOutsideThePairHasNoOtherCopy() {
        let pair = DuplicateComparePair(keeper: copy("/root/a/x.txt", keeper: true),
                                        other: copy("/root/b/x.txt"),
                                        matchType: .identical, groupName: "x.txt")
        #expect(pair.other(than: "/root/c/x.txt") == nil)
    }

    // MARK: The branch

    /// **A file pair must never reach the Compare-workspace hand-off.** That path relativizes both
    /// paths against provider roots and re-pins the two panes — the right tool for two folders and
    /// the wrong one for two files.
    @Test func aFilePairOpensTheOverlayAndNeverTheWorkspaceHandoff() {
        final class Box: @unchecked Sendable {
            var workspace: [(String, String)] = []
            var overlay: [DuplicateComparePair] = []
        }
        let box = Box()
        let manager = FileSyncManager()
        let view = LensWorkspaceView(
            syncManager: manager, lens: .filing, providerName: "Projects",
            scanTargetFolder: "/root", onFindDuplicates: {},
            onCompareCopies: { k, o in box.workspace.append((k.path, o.path)) },
            onCompareFilePair: { box.overlay.append($0) })

        let keeper = copy("/root/a/x.txt", keeper: true)
        let other = copy("/root/b/x.txt")
        view.compareCopies(keep: keeper, other: other,
                           in: group([keeper, other], isDirectory: false))

        #expect(box.workspace.isEmpty, "a file pair was sent down the folder path")
        #expect(box.overlay.count == 1)
        #expect(box.overlay.first?.left.path == "/root/a/x.txt")
    }

    /// And the other direction, which is the half a swapped branch would still pass without: a
    /// folder pair keeps the existing hand-off and never opens the overlay, whose panes are Quick
    /// Look previews of a directory — i.e. nothing.
    @Test func aFolderPairKeepsTheWorkspaceHandoff() {
        final class Box: @unchecked Sendable {
            var workspace: [(String, String)] = []
            var overlay: [DuplicateComparePair] = []
        }
        let box = Box()
        let manager = FileSyncManager()
        let view = LensWorkspaceView(
            syncManager: manager, lens: .filing, providerName: "Projects",
            scanTargetFolder: "/root", onFindDuplicates: {},
            onCompareCopies: { k, o in box.workspace.append((k.path, o.path)) },
            onCompareFilePair: { box.overlay.append($0) })

        let keeper = copy("/root/a/Docs", keeper: true, isDirectory: true)
        let other = copy("/root/b/Docs", isDirectory: true)
        view.compareCopies(keep: keeper, other: other,
                           in: group([keeper, other], isDirectory: true))

        #expect(box.overlay.isEmpty, "a folder pair opened a surface that previews files")
        #expect(box.workspace.map(\.0) == ["/root/a/Docs"])
    }

    // MARK: The card's gate is gone

    /// **The two-line gate this feature exists to delete.** `if group.isDirectory { compareControl }`
    /// was the whole reason a file group had no way to compare its copies, and re-adding it is a
    /// two-line edit that breaks the feature completely while every test above still passes: the
    /// branch, the payload and the sheet are all reachable from a test, and the card's button is
    /// what actually reaches them.
    ///
    /// **A source assertion, because a rendered one is not available here.** Measured: a mounted
    /// `DuplicateGroupCard` contains no `NSButton` at all — SwiftUI's macOS buttons in these styles
    /// bridge to `_NSGraphicsView`, and SwiftUI builds no accessibility tree in a test process
    /// without an assistive client, so neither a control walk nor a label query can see this. The
    /// structure is the only place the answer is legible, which is the same reason
    /// `OrganizeScopeCallSiteTests` reads source for the confirmation wording.
    ///
    /// The check is INDENTATION against a sibling that is unconditionally drawn: `compareControl`
    /// must sit at the same nesting level as the Reveal button beside it. A re-added gate would
    /// indent it one level deeper, whatever the condition was spelled.
    @Test func theCardOffersCompareToEveryGroupNotJustFolders() throws {
        let source = try String(contentsOf: Self.cardSource, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let compareIndex = try #require(lines.firstIndex {
            $0.trimmingCharacters(in: .whitespaces) == "compareControl"
        }, "`compareControl` is no longer rendered by name — this scan is stale")
        let revealIndex = try #require(lines.firstIndex {
            $0.trimmingCharacters(in: .whitespaces) == "Button(action: onReveal) {"
        }, "the Reveal button moved — this scan needs a new unconditional sibling")
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        #expect(indent(lines[compareIndex]) == indent(lines[revealIndex]),
                "`compareControl` is nested deeper than the Reveal button beside it — something is gating it again")
    }

    private static var cardSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // FileExplorer (tests)
            .deletingLastPathComponent()        // Tests
            .deletingLastPathComponent()        // Modules/FileExplorer
            .appendingPathComponent("Sources/FileExplorer/DuplicateGroupCard.swift")
    }

    // MARK: Verify's three outcomes

    /// `filesHaveSameContent` returns `Bool?` and answers nil when EITHER side cannot be hashed —
    /// three different situations the surface must not flatten into one failure.
    @Test func verifyReportsWhichSideCouldNotBeHashedAndWhy() {
        #expect(ComparePairVerify.outcome(left: .hashed("a"), right: .hashed("a")) == .matched)
        #expect(ComparePairVerify.outcome(left: .hashed("a"), right: .hashed("b")) == .differed)
        #expect(ComparePairVerify.outcome(left: .skippedCloudOnly, right: .hashed("a"))
                    == .couldNotVerify(reason: "the left copy is not downloaded"))
        #expect(ComparePairVerify.outcome(left: .hashed("a"), right: .unverifiable)
                    == .couldNotVerify(reason: "the right copy is unreadable, or changed while being read"))
        #expect(ComparePairVerify.outcome(left: .skippedCloudOnly, right: .skippedCloudOnly)
                    == .couldNotVerify(reason: "both copies are not downloaded"))
    }

    /// Two different causes are both named. Collapsing them to the first would tell the user to
    /// download a file whose twin is over the size cap, and leave them going in circles.
    @Test func twoDifferentCausesAreBothNamed() {
        let outcome = ComparePairVerify.outcome(left: .skippedCloudOnly, right: .skippedTooLarge)
        guard case .couldNotVerify(let reason) = outcome else {
            Issue.record("expected couldNotVerify, got \(outcome)")
            return
        }
        #expect(reason.contains("not downloaded"))
        #expect(reason.contains("100 MB"))
    }

    /// A "differed" verdict is not a small correction — it means the scan is stale and neither
    /// copy may be removed on its say-so. The caption has to say that, not "not identical".
    @Test func aDifferedVerdictSendsTheUserToARescan() {
        #expect(ComparePairVerify.differed.caption.lowercased().contains("rescan"))
        #expect(ComparePairVerify.matched.caption.contains("identical"))
        #expect(ComparePairVerify.couldNotVerify(reason: "x").caption == "Couldn't verify: x.")
    }

    // MARK: The claim per match kind

    /// Only ONE of the three kinds claims "these are the same file". A same-text pair proved that
    /// two documents READ the same, which the measured signed-copy and redacted-copy cases show is
    /// not the same thing — and it is the pair most worth actually looking at, so it gets no
    /// "nothing to see here" verify shortcut.
    @Test func onlyAByteIdenticalPairClaimsToBeTheSameFile() {
        #expect(ComparePairClaim.headline(kind: .identical, contentUnverified: false)?
            .contains("byte-for-byte") == true)
        #expect(ComparePairClaim.headline(kind: .sameText, contentUnverified: false)?
            .contains("bytes differ") == true)
        #expect(ComparePairClaim.headline(kind: .versions, contentUnverified: false) == nil)
        #expect(ComparePairClaim.offersVerify(kind: .identical))
        #expect(!ComparePairClaim.offersVerify(kind: .sameText))
    }

    /// An unverified copy weakens the identical claim rather than deleting it: the scan DID group
    /// these, and saying nothing would leave the reader to assume the strong form.
    @Test func anUnhashedCopyWeakensTheIdenticalClaimWithoutRemovingIt() throws {
        let text = try #require(ComparePairClaim.headline(kind: .identical, contentUnverified: true))
        #expect(!text.contains("byte-for-byte"))
        #expect(text.contains("couldn't hash"))
    }

    // MARK: Mounted, at the floor

    private struct Harness: View {
        let pair: DuplicateComparePair
        let keeperPath: String
        let isStale: Bool
        let available: CGSize
        let source: ColumnPreviewSource

        var body: some View {
            CompareCopiesSheet(
                pair: pair, keeperPath: keeperPath, allowsKeeperChoice: true,
                protectedPaths: [], isStale: isStale, scanRoot: "/root",
                providerName: "Projects", hue: .blue, availableSize: available,
                onChooseKeeper: { _ in }, onTrash: { _, _ in }, onClose: {},
                probe: { [source] _ in source },
                hash: { _ in .hashed("a") })
        }
    }

    private struct Mounted {
        let window: NSWindow
        let host: NSHostingView<Harness>
    }

    /// A real directory with real files: the Quick Look panes mount only for a path that exists.
    private final class Fixture {
        let root: String
        let left: String
        let right: String
        init() throws {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("CompareCopiesSurfaceTests-\(UUID().uuidString)")
            let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            root = dir.path
            let one = a.appendingPathComponent("note.txt")
            let two = b.appendingPathComponent("note.txt")
            try Data("hello".utf8).write(to: one)
            try Data("hello".utf8).write(to: two)
            left = one.path
            right = two.path
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }
    }

    private func mount(_ fixture: Fixture, available: CGSize, isStale: Bool = false,
                       source: ColumnPreviewSource = .quickLook) -> Mounted {
        let keeper = copy(fixture.left, keeper: true)
        let other = copy(fixture.right)
        let host = NSHostingView(rootView: Harness(
            pair: DuplicateComparePair(keeper: keeper, other: other,
                                       matchType: .identical, groupName: "note.txt"),
            keeperPath: fixture.left, isStale: isStale, available: available, source: source))
        host.frame = CGRect(origin: .zero, size: available)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return Mounted(window: window, host: host)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// **Through `LayoutPumpWait`, never a hand-rolled deadline.** What these waits wait for
    /// arrives on main-actor TURNS, and under full-package congestion seconds buy very few of
    /// them — measured in this repo at 5–7 seconds per pass on a saturated actor. A wall-clock
    /// loop passes in isolation and fails in the suite, which is `docs/flaky-tests.md`'s
    /// mechanism 2 and is exactly how these two tests first failed.
    @discardableResult
    private func pump(_ mounted: Mounted, upTo seconds: Double,
                      until condition: @escaping () -> Bool) async -> Bool {
        let (held, pumps) = await LayoutPumpWait.pump(mounted.window, upTo: seconds,
                                                      until: condition)
        if !held { Issue.record("the condition never held (\(pumps) pumps)") }
        return held
    }

    /// **Two Quick Look panes, both of them, at the window floor.** The failure this catches is
    /// the one a screenshot on a big display never shows: a surface that lays out fine at 1080
    /// and squeezes one pane to nothing at 712.
    @Test func atTheFloorBothPanesMountAndAreWorkablyWide() async throws {
        let fixture = try Fixture()
        let mounted = mount(fixture, available: CGSize(width: 760, height: 560))
        guard await pump(mounted, upTo: 3, until: {
            descendants(of: mounted.host).compactMap { $0 as? QLPreviewView }.count == 2
        }) else { return }
        let previews = descendants(of: mounted.host).compactMap { $0 as? QLPreviewView }
        #expect(previews.count == 2, "expected two preview panes, found \(previews.count)")
        for preview in previews {
            #expect(preview.frame.width >= 300,
                    "a pane laid out at \(preview.frame.width)pt — not a preview")
            #expect(preview.frame.height >= 120)
        }
    }

    /// The card stays inside the space it was clamped to. An overlay that draws past its own
    /// frame puts the verdict bar — the only thing that trashes a file — off screen.
    @Test func theSheetDrawsInsideItsClampedFrame() async throws {
        let fixture = try Fixture()
        let available = CGSize(width: 760, height: 560)
        let mounted = mount(fixture, available: available)
        let expected = CompareOverlayMetrics.size(available: available)
        await pump(mounted, upTo: 3, until: {
            abs(mounted.host.fittingSize.width - expected.width) < 1
        })
        let drawn = mounted.host.fittingSize
        #expect(abs(drawn.width - expected.width) < 1, "drew \(drawn.width), clamped to \(expected.width)")
        #expect(abs(drawn.height - expected.height) < 1, "drew \(drawn.height), clamped to \(expected.height)")
    }

    /// **The grips are really on the card, and a remembered size really reaches it.** The drag
    /// itself is an AppKit gesture a test cannot post through SwiftUI, so what is pinned here is
    /// the half a test can see: the card mounts at the size the arithmetic resolves — including a
    /// stored one — so a committed drag has somewhere to land. `ResizableCardTests` pins the
    /// arithmetic; together they cover the path.
    @Test func theCardMountsAtItsRememberedSize() async throws {
        let fixture = try Fixture()
        let available = CGSize(width: 1600, height: 1000)
        let defaults = ScratchDefaults("CompareCopiesSurfaceTests-size")
        defaults.set(880.0, forKey: CompareOverlayMetrics.widthDefaultsKey)
        defaults.set(600.0, forKey: CompareOverlayMetrics.heightDefaultsKey)
        let keeper = copy(fixture.left, keeper: true)
        let other = copy(fixture.right)
        let host = NSHostingView(rootView: AnyView(
            Harness(pair: DuplicateComparePair(keeper: keeper, other: other,
                                               matchType: .identical, groupName: "note.txt"),
                    keeperPath: fixture.left, isStale: false, available: available,
                    source: .missing)
                .defaultAppStorage(defaults)))
        host.frame = CGRect(origin: .zero, size: available)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let (held, pumps) = await LayoutPumpWait.pump(window, upTo: 3) {
            abs(host.fittingSize.width - 880) < 1
        }
        #expect(held, "the card drew at \(host.fittingSize.width)pt, not the remembered 880 (\(pumps) pumps)")
        #expect(abs(host.fittingSize.height - 600) < 1, "height \(host.fittingSize.height)")
    }

    /// A cloud-only side mounts NO Quick Look view — rendering one would force the provider to
    /// download the whole file, which is exactly what the placeholder exists to avoid.
    @Test func aCloudOnlySideMountsNoPreviewAtAll() async throws {
        let fixture = try Fixture()
        let available = CGSize(width: 1200, height: 800)
        // **The positive control comes first, and it is what makes the negative one mean
        // anything.** "No preview mounted" is also what an unrendered pane looks like, so the same
        // fixture is mounted with the same pump budget and only the classification changed: if the
        // materialized mount reaches two panes, the budget is sufficient, and zero on the
        // cloud-only mount is a fact about the classification rather than about the clock.
        let materialized = mount(fixture, available: available, source: .quickLook)
        guard await pump(materialized, upTo: 3, until: {
            descendants(of: materialized.host).compactMap { $0 as? QLPreviewView }.count == 2
        }) else { return }

        let cloudOnly = mount(fixture, available: available, source: .cloudOnly)
        // A settle measured in main-actor TURNS, not seconds: `upTo: 0` still runs
        // `LayoutPumpWait.pumpFloor` passes, which is the same floor the positive mount cleared.
        _ = await LayoutPumpWait.pump(cloudOnly.window, upTo: 0) { false }
        let previews = descendants(of: cloudOnly.host).compactMap { $0 as? QLPreviewView }
        #expect(previews.isEmpty, "a cloud-only placeholder started a download by previewing it")
    }
}
