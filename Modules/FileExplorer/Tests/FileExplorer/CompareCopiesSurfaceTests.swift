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

    /// At the window floor, 810×560, the overlay must be usable. That is why it is an overlay, not a
    /// sheet: macOS would silently squeeze a 1080pt sheet to the window's width. It stops growing:
    /// a 27-inch window must not hand two previews 1,900 points each. And below the minimum it
    /// overhangs rather than shrinking: a 40pt-wide preview pane hides the bug, an overhanging card
    /// shows it.
    ///
    /// A remembered size is honoured, but clamped on every render, not only when written: the
    /// window can shrink between sessions or displays, and a card that trusted its stored size
    /// would open wider than the window, its verdict bar and grip off screen. Zero is what
    /// `@AppStorage` holds before the first drag, and it reads as "unset", not as a 0×0 card.
    @Test(arguments: [
        (CGSize(width: 810, height: 560), nil, CGSize(width: 762, height: 512)),
        (CGSize(width: 2400, height: 1400), nil,
         CGSize(width: CompareOverlayMetrics.idealWidth, height: CompareOverlayMetrics.idealHeight)),
        (CGSize(width: 300, height: 200), nil,
         CGSize(width: CompareOverlayMetrics.minimumWidth, height: CompareOverlayMetrics.minimumHeight)),
        (CGSize(width: 1600, height: 1000), nil,
         CompareOverlayMetrics.size(available: CGSize(width: 1600, height: 1000))),
        (CGSize(width: 1600, height: 1000), .zero,
         CompareOverlayMetrics.size(available: CGSize(width: 1600, height: 1000))),
        (CGSize(width: 1600, height: 1000), CGSize(width: 900, height: 620), CGSize(width: 900, height: 620)),
        (CGSize(width: 900, height: 700), CGSize(width: 1600, height: 1000), CGSize(width: 900, height: 700)),
        (CGSize(width: 1600, height: 1000), CGSize(width: 100, height: 100), CompareOverlayMetrics.minimum),
    ] as [(CGSize, CGSize?, CGSize)])
    func theOverlayIsClampedToTheWindow(available: CGSize, stored: CGSize?, expected: CGSize) {
        #expect(CompareOverlayMetrics.size(available: available, stored: stored) == expected)
        if stored == nil {
            #expect(CompareOverlayMetrics.size(available: available) == expected)
        }
    }

    // MARK: The payload

    /// Opening the same two copies from either side is the same surface, not a second one sliding
    /// in, so the id can't depend on which copy was clicked.
    @Test func thePairIdIsStableUnderACopyOrderSwap() {
        let a = copy("/root/a/x.txt", keeper: true)
        let b = copy("/root/b/x.txt")
        let one = DuplicateComparePair(keeper: a, other: b, matchType: .identical, groupName: "x.txt")
        let two = DuplicateComparePair(keeper: b, other: a, matchType: .identical, groupName: "x.txt")
        #expect(one.id == two.id)
        #expect(one != two, "the id is stable; the drawn order is not, and must not be")
    }

    /// The keeper opens on the left, as on every other two-copy surface: the Compare review's
    /// banner says "keep left, trash right".
    @Test func theKeeperOpensOnTheLeft() {
        let a = copy("/root/a/x.txt", keeper: true)
        let b = copy("/root/b/x.txt")
        let pair = DuplicateComparePair(keeper: a, other: b, matchType: .identical, groupName: "x.txt")
        #expect(pair.left.path == "/root/a/x.txt")
        #expect(pair.other(than: "/root/a/x.txt")?.path == "/root/b/x.txt")
        #expect(pair.other(than: "/root/b/x.txt")?.path == "/root/a/x.txt",
                "flipping the keeper flips which copy the verdict acts on, without moving a pane")
        // A keeper path naming neither side has no "other copy" to trash, and the surface must not
        // invent one.
        #expect(pair.other(than: "/root/c/x.txt") == nil)
    }

    /// The label the surface draws, at the call site that draws it. `DuplicateComparePrompt`'s own
    /// tests can't catch `keeper:` and `target:` passed the wrong way round, which would name the
    /// surviving copy. This reads the sheet's title on both sides of a keeper flip.
    @Test func theTrashButtonNamesTheCopyItDestroysOnEitherSideOfAFlip() {
        let older = copy("/root/a/Notes.md")
        let newer = DuplicateCopy(id: "/root/b/Notes.md", name: "Notes.md", isDirectory: false,
                                  size: 1000, itemCount: 1,
                                  modificationDate: Self.scanned.addingTimeInterval(86_400),
                                  uniqueItemCount: 0, depth: 1, isRecommendedKeeper: true)
        let pair = DuplicateComparePair(keeper: newer, other: older, matchType: .versions,
                                        groupName: "Notes.md")
        func sheet(keeping path: String) -> CompareCopiesSheet {
            CompareCopiesSheet(
                pair: pair, standing: .inPair(path), allowsKeeperChoice: true,
                protectedPaths: [], scanRoot: "/root",
                providerName: "Projects", hue: .blue,
                availableSize: CGSize(width: 900, height: 700),
                onChooseKeeper: { _ in }, onTrash: { _, _ in }, onClose: {})
        }
        #expect(sheet(keeping: newer.path).trashTitle == "Trash the Older Copy")
        #expect(sheet(keeping: older.path).trashTitle == "Trash the Newer Copy",
                "the button named the copy it was keeping after the keeper was flipped")
    }

    /// A stale payload, a keeper path naming neither side, has no target, so the title must not
    /// guess an age. (The verdict is disabled here anyway.)
    @Test func aTitleWithNoTargetClaimsNoAge() {
        let pair = DuplicateComparePair(keeper: copy("/root/a/x.md", keeper: true),
                                        other: copy("/root/b/x.md"),
                                        matchType: .versions, groupName: "x.md")
        let sheet = CompareCopiesSheet(
            pair: pair, standing: .noLiveGroup, allowsKeeperChoice: true,
            protectedPaths: [], scanRoot: "/root", providerName: "Projects",
            hue: .blue, availableSize: CGSize(width: 900, height: 700),
            onChooseKeeper: { _ in }, onTrash: { _, _ in }, onClose: {})
        #expect(sheet.trashTitle == "Trash the Other Copy")
    }

    // MARK: A keeper the pair cannot see

    /// A group may hold more copies than the two on screen, and the keeper can be one of the
    /// others. Falling back to the left pane would mark a copy nothing is keeping and leave
    /// "Trash the Other Copy" enabled, with no notice. The rule is a pure function of a pair and a
    /// group, because `sheet(available:)` is private and a `some View` can't be interrogated.
    @Test func theKeeperStandingTellsAThirdCopyApartFromAStaleScan() {
        let a = copy("/root/a/x.md", keeper: true)
        let b = copy("/root/b/x.md")
        let c = copy("/root/c/x.md")
        let pair = DuplicateComparePair(keeper: b, other: c, matchType: .identical,
                                        groupName: "x.md")

        #expect(CompareCopiesOverlay.keeperStanding(of: pair, in: group([a, b, c]))
                    == .outsidePair(name: "x.md"),
                "a keeper outside the pair was reported as one of the two on screen")
        #expect(CompareCopiesOverlay.keeperStanding(of: pair, in: group([a, b, c])).keeperPath == nil,
                "a keeper the pair does not hold was handed out as a path to mark")
        // The positive control: move the keeper INTO the pair and the same call answers with it.
        let bKept = copy("/root/b/x.md", keeper: true)
        #expect(CompareCopiesOverlay.keeperStanding(of: pair, in: group([bKept, c]))
                    == .inPair("/root/b/x.md"))
        #expect(CompareCopiesOverlay.keeperStanding(of: pair, in: nil) == .noLiveGroup)
    }

    /// Only one of the three standings marks a keeper, and only one is staleness. One enum, not
    /// three fields, so a surface that withholds its verdict without saying why, or claims a keeper
    /// while stale, can't be constructed.
    @Test func onlyAKeeperInThePairIsMarkedAndOnlyAMissingGroupIsStale() {
        let standings: [PairKeeperStanding] = [.inPair("/root/b/x.md"),
                                               .outsidePair(name: "kept.md"),
                                               .noLiveGroup]
        #expect(standings.map(\.keeperPath) == ["/root/b/x.md", nil, nil],
                "a standing that does not know the keeper handed one out anyway")
        #expect(standings.map(\.offersVerdict) == [true, false, false],
                "the destructive verdict was offered where there is no keeper to act against")
        #expect(standings.map { $0 == .noLiveGroup } == [false, false, true],
                "the three answers stopped being three distinct answers")
    }

    /// With the keeper outside the pair: no keeper, no verdict, and a notice naming the kept copy
    /// rather than asking for a rescan, since the facts are current. All three standings are
    /// driven, because the two that withhold the verdict must give reasons the reader can tell apart.
    @Test func eachStandingSaysWhyTheVerdictIsOrIsNotThere() throws {
        let pair = DuplicateComparePair(keeper: copy("/root/b/x.md"), other: copy("/root/c/x.md"),
                                        matchType: .identical, groupName: "x.md")
        func sheet(_ standing: PairKeeperStanding) -> CompareCopiesSheet {
            CompareCopiesSheet(
                pair: pair, standing: standing,
                allowsKeeperChoice: true, protectedPaths: [], scanRoot: "/root",
                providerName: "Projects", hue: .blue,
                availableSize: CGSize(width: 900, height: 700),
                onChooseKeeper: { _ in }, onTrash: { _, _ in }, onClose: {})
        }
        // The facts the viewer would hand the bar; two paths, so the summary has something to name.
        let facts = ComparePairFacts.make(left: pair.left, right: pair.right,
                                          scanRoot: "/root", providerName: "Projects")
        let outside = sheet(.outsidePair(name: "kept.md"))
        #expect(!outside.standing.offersVerdict, "the destructive verdict stayed offered with no keeper")
        let notice = try #require(outside.notice)
        #expect(notice.contains("kept.md"),
                "the notice did not name the copy the group is actually keeping")
        #expect(!notice.contains("moved on"),
                "current facts were reported as a stale scan, sending the reader to rescan")
        #expect(outside.verdictSummary(facts).contains("not one of these two"))
        #expect(outside.trashTitle == "Trash the Other Copy",
                "the button named a target it has no keeper to choose against")

        // Stale: also no verdict, but for the other reason, and it must say so.
        let stale = sheet(.noLiveGroup)
        #expect(!stale.standing.offersVerdict)
        #expect(try #require(stale.notice).contains("moved on"))
        #expect(stale.verdictSummary(facts).contains("Rescan"))

        // The positive control: with the keeper on screen the verdict returns and the notice goes.
        let inPair = sheet(.inPair("/root/b/x.md"))
        #expect(inPair.standing.offersVerdict)
        #expect(inPair.notice == nil)
        #expect(!inPair.verdictSummary(facts).contains("not one of these two"))
    }

    // MARK: The branch

    private final class BranchBox: @unchecked Sendable {
        var workspace: [(String, String)] = []
        var overlay: [DuplicateComparePair] = []
    }

    /// A lens whose two hosts record what each was handed.
    private func branchView() -> (LensWorkspaceView, BranchBox) {
        let box = BranchBox()
        let view = LensWorkspaceView(
            syncManager: FileSyncManager(), lens: .filing, providerName: "Projects",
            scanTargetFolder: "/root", onFindDuplicates: {},
            onCompareCopies: { k, o in box.workspace.append((k.path, o.path)) },
            onCompareFilePair: { box.overlay.append($0) })
        return (view, box)
    }

    /// A file pair never reaches the Compare-workspace hand-off, which relativizes both paths
    /// against provider roots and re-pins the two panes: right for two folders, wrong for files.
    @Test func aFilePairOpensTheOverlayAndNeverTheWorkspaceHandoff() {
        let (view, box) = branchView()

        let keeper = copy("/root/a/x.txt", keeper: true)
        let other = copy("/root/b/x.txt")
        view.compareCopies(keep: keeper, other: other,
                           in: group([keeper, other], isDirectory: false))

        #expect(box.workspace.isEmpty, "a file pair was sent down the folder path")
        #expect(box.overlay.count == 1)
        #expect(box.overlay.first?.left.path == "/root/a/x.txt")
    }

    /// The other direction, which a swapped branch would fail: a folder pair keeps the hand-off
    /// and never opens the overlay, whose Quick Look panes would preview a directory as nothing.
    @Test func aFolderPairKeepsTheWorkspaceHandoff() {
        let (view, box) = branchView()

        let keeper = copy("/root/a/Docs", keeper: true, isDirectory: true)
        let other = copy("/root/b/Docs", isDirectory: true)
        view.compareCopies(keep: keeper, other: other,
                           in: group([keeper, other], isDirectory: true))

        #expect(box.overlay.isEmpty, "a folder pair opened a surface that previews files")
        #expect(box.workspace.map(\.0) == ["/root/a/Docs"])
    }

    // MARK: The card's gate is gone

    /// The card offers Compare to every group, not just folders. A gate like
    /// `if group.isDirectory { compareControl }` would break the feature for files while every
    /// test above still passed, since the card's button is what reaches them.
    ///
    /// A source check, because a mounted `DuplicateGroupCard` has no `NSButton` (these buttons
    /// draw in `_NSGraphicsView`) and no accessibility tree without an assistive client, as with
    /// `OrganizeScopeCallSiteTests`. `compareControl` must sit at the same indentation as the
    /// unconditional Reveal button beside it; any gate would indent it deeper.
    @Test func theCardOffersCompareToEveryGroupNotJustFolders() throws {
        let source = try SourceText.fileExplorer("DuplicateGroupCard.swift")
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

    // MARK: Verify's three outcomes

    /// `filesHaveSameContent` answers nil when either side can't be hashed; the surface must name
    /// which side and why, not flatten it into one failure.
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

    /// Two different causes are both named; naming only the first would send the user to download
    /// a file whose twin is unreadable.
    @Test func twoDifferentCausesAreBothNamed() {
        let outcome = ComparePairVerify.outcome(left: .skippedCloudOnly, right: .unverifiable)
        #expect(outcome == .couldNotVerify(reason:
            "the left copy is not downloaded; the right copy is unreadable, or changed while being read"))
    }

    /// A stopped check learned nothing, so it claims nothing: the surface goes back to idle, with
    /// Verify on offer, rather than "Couldn’t verify", which would blame a copy.
    @Test func aStoppedCheckLeavesTheSurfaceIdle() {
        #expect(ComparePairVerify.outcome(left: .cancelled, right: .hashed("a")) == .idle)
        #expect(ComparePairVerify.outcome(left: .skippedCloudOnly, right: .cancelled) == .idle)
    }

    /// A "differed" verdict means the scan is stale and neither copy may be removed on its say-so,
    /// so the caption sends the user to rescan rather than saying "not identical".
    @Test func aDifferedVerdictSendsTheUserToARescan() {
        #expect(ComparePairVerify.differed.caption.lowercased().contains("rescan"))
        #expect(ComparePairVerify.matched.caption.contains("identical"))
        #expect(ComparePairVerify.couldNotVerify(reason: "x").caption == "Couldn’t verify: x.")
    }

    // MARK: The claim per match kind

    /// Only a byte-identical pair claims to be the same file. A same-text pair only reads the same
    /// (a signed or redacted copy can), so it is the pair most worth looking at and gets no
    /// Verify shortcut.
    @Test func onlyAByteIdenticalPairClaimsToBeTheSameFile() {
        #expect(ComparePairClaim.headline(kind: .identical, contentUnverified: false)?
            .contains("byte-for-byte") == true)
        #expect(ComparePairClaim.headline(kind: .sameText, contentUnverified: false)?
            .contains("bytes differ") == true)
        #expect(ComparePairClaim.headline(kind: .versions, contentUnverified: false) == nil)
        #expect(ComparePairClaim.offersVerify(kind: .identical))
        #expect(!ComparePairClaim.offersVerify(kind: .sameText))
    }

    /// An unhashed copy weakens the identical claim rather than removing it: the scan did group
    /// these, and saying nothing would leave the reader assuming the strong form.
    @Test func anUnhashedCopyWeakensTheIdenticalClaimWithoutRemovingIt() throws {
        let text = try #require(ComparePairClaim.headline(kind: .identical, contentUnverified: true))
        #expect(!text.contains("byte-for-byte"))
        #expect(text.contains("couldn’t hash"))
    }

    // MARK: Mounted, at the floor

    private struct Harness: View {
        let pair: DuplicateComparePair
        let keeperPath: String
        let isStale: Bool
        let available: CGSize
        let source: ColumnPreviewSource
        var startingMode: ComparePairMode?
        var probeCount: ProbeCount?

        var body: some View {
            CompareCopiesSheet(
                pair: pair, standing: isStale ? .noLiveGroup : .inPair(keeperPath),
                allowsKeeperChoice: true, protectedPaths: [], scanRoot: "/root",
                providerName: "Projects", hue: .blue, availableSize: available,
                onChooseKeeper: { _ in }, onTrash: { _, _ in }, onClose: {},
                probe: { [source, probeCount] path in probeCount?.record(path); return source },
                hash: { _ in .hashed("a") },
                initialMode: startingMode)
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
                       source: ColumnPreviewSource = .quickLook,
                       startingMode: ComparePairMode? = nil,
                       probeCount: ProbeCount? = nil) -> Mounted {
        let keeper = copy(fixture.left, keeper: true)
        let other = copy(fixture.right)
        let (host, window) = HostedView.host(Harness(
            pair: DuplicateComparePair(keeper: keeper, other: other,
                                       matchType: .identical, groupName: "note.txt"),
            keeperPath: fixture.left, isStale: isStale, available: available, source: source,
            startingMode: startingMode, probeCount: probeCount), size: available)
        return Mounted(window: window, host: host)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Through `LayoutPumpWait`, never a hand-rolled deadline: what these waits wait for arrives
    /// on main-actor turns, and under load seconds buy few of them. A wall-clock loop passes alone
    /// and fails in the suite ("Fixed pumps and fixed sleeps" in `docs/flaky-tests.md`).
    @discardableResult
    private func pump(_ mounted: Mounted, upTo seconds: Double,
                      until condition: @escaping () -> Bool) async -> Bool {
        let (held, pumps) = await LayoutPumpWait.pump(mounted.window, upTo: seconds,
                                                      until: condition)
        if !held { Issue.record("the condition never held (\(pumps) pumps)") }
        return held
    }

    /// Both Quick Look panes mount at the window floor and are workably wide: a surface can lay
    /// out fine at 1080 and squeeze one pane to nothing at 762.
    @Test func atTheFloorBothPanesMountAndAreWorkablyWide() async throws {
        let fixture = try Fixture()
        let mounted = mount(fixture, available: CGSize(width: 810, height: 560))
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

    /// The card stays inside its clamped space; drawing past it would put the verdict bar, the
    /// only thing that trashes a file, off screen.
    @Test func theSheetDrawsInsideItsClampedFrame() async throws {
        let fixture = try Fixture()
        let available = CGSize(width: 810, height: 560)
        let mounted = mount(fixture, available: available)
        let expected = CompareOverlayMetrics.size(available: available)
        await pump(mounted, upTo: 3, until: {
            abs(mounted.host.fittingSize.width - expected.width) < 1
        })
        let drawn = mounted.host.fittingSize
        #expect(abs(drawn.width - expected.width) < 1, "drew \(drawn.width), clamped to \(expected.width)")
        #expect(abs(drawn.height - expected.height) < 1, "drew \(drawn.height), clamped to \(expected.height)")
    }

    /// A remembered size reaches the mounted card. A test can't post the drag itself through
    /// SwiftUI, so this pins the visible half: the card mounts at the stored size.
    /// `ResizableCardTests` pins the arithmetic; together they cover the path.
    @Test func theCardMountsAtItsRememberedSize() async throws {
        let fixture = try Fixture()
        let available = CGSize(width: 1600, height: 1000)
        let defaults = ScratchDefaults("CompareCopiesSurfaceTests-size")
        defaults.set(880.0, forKey: CompareOverlayMetrics.widthDefaultsKey)
        defaults.set(600.0, forKey: CompareOverlayMetrics.heightDefaultsKey)
        let keeper = copy(fixture.left, keeper: true)
        let other = copy(fixture.right)
        let (host, window) = HostedView.host(AnyView(
            Harness(pair: DuplicateComparePair(keeper: keeper, other: other,
                                               matchType: .identical, groupName: "note.txt"),
                    keeperPath: fixture.left, isStale: false, available: available,
                    source: .missing)
                .defaultAppStorage(defaults)), size: available)
        let (held, pumps) = await LayoutPumpWait.pump(window, upTo: 3) {
            abs(host.fittingSize.width - 880) < 1
        }
        #expect(held, "the card drew at \(host.fittingSize.width)pt, not the remembered 880 (\(pumps) pumps)")
        #expect(abs(host.fittingSize.height - 600) < 1, "height \(host.fittingSize.height)")
    }

    /// A pair swapped under a live surface in a pixel mode classifies its new sides. If the probe
    /// ran only in the side-by-side preview, the raster refresh would bail on "not both readable"
    /// and nothing would re-trigger it. Swapping the pair matters: seeding the mode alone still
    /// renders one side-by-side frame first, which runs the probe anyway.
    @Test func aSwappedPairClassifiesItsNewSidesInAPixelMode() async throws {
        let first = try ImageFixture()
        let second = try ImageFixture()
        let probed = ProbeCount()
        let box = PairBox(pair: Self.pair(left: first.left, right: first.right, groupName: "a.png"))
        let available = CGSize(width: 1200, height: 800)
        let (_, window) = HostedView.host(AnyView(
            SwappableHarness(box: box, available: available, probeCount: probed)), size: available)

        let (firstDone, _) = await LayoutPumpWait.pump(window, upTo: 3) {
            probed.paths.isSuperset(of: [first.left, first.right])
        }
        try #require(firstDone, "the first pair was never classified — the swap proves nothing")

        box.pair = Self.pair(left: second.left, right: second.right, groupName: "a.png")
        let (secondDone, pumps) = await LayoutPumpWait.pump(window, upTo: 3) {
            probed.paths.isSuperset(of: [second.left, second.right])
        }
        #expect(secondDone, """
                the swapped-in pair's sides were never classified (\(pumps) pumps) — the raster \
                refresh can never start for it
                """)
    }

    /// Two real PNGs. The kind matters: `.difference` is offered only for a pair with pixel modes,
    /// and a `.txt` pair clamps back to side by side, where the test would pass with the bug.
    private final class ImageFixture {
        let dir: URL
        let left: String
        let right: String
        init() throws {
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("CompareImageFixture-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            left = try Self.write(dir.appendingPathComponent("a.png"))
            right = try Self.write(dir.appendingPathComponent("b.png"))
        }
        deinit { try? FileManager.default.removeItem(at: dir) }

        private static func write(_ url: URL) throws -> String {
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: url)
            return url.path
        }
    }

    /// Two files that are images by every metadata answer and can't be decoded: a `.png`
    /// extension over bytes that are not a PNG, as a truncated download or half-synced file looks.
    private final class CorruptImageFixture {
        let dir: URL
        let left: String
        let right: String
        init() throws {
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("CompareCorruptFixture-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            left = try Self.write(dir.appendingPathComponent("scan.png"))
            right = try Self.write(dir.appendingPathComponent("scan copy.png"))
        }
        deinit { try? FileManager.default.removeItem(at: dir) }

        private static func write(_ url: URL) throws -> String {
            try Data("not a png, whatever the extension says".utf8).write(to: url)
            return url.path
        }
    }

    private static func pair(left: String, right: String, groupName: String) -> DuplicateComparePair {
        func copy(_ path: String, keeper: Bool) -> DuplicateCopy {
            DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                          size: 1000, itemCount: 1, modificationDate: scanned,
                          uniqueItemCount: 0, depth: 1, isRecommendedKeeper: keeper)
        }
        return DuplicateComparePair(keeper: copy(left, keeper: true), other: copy(right, keeper: false),
                                    matchType: .identical, groupName: groupName)
    }

    final class PairBox: ObservableObject {
        @Published var pair: DuplicateComparePair
        init(pair: DuplicateComparePair) { self.pair = pair }
    }

    /// Mounts the surface in a pixel mode and lets the test swap the pair underneath it without
    /// tearing the view down: the state the pair-change reset exists for.
    private struct SwappableHarness: View {
        @ObservedObject var box: PairBox
        let available: CGSize
        let probeCount: ProbeCount

        var body: some View {
            CompareCopiesSheet(
                pair: box.pair, standing: .inPair(box.pair.left.path), allowsKeeperChoice: true,
                protectedPaths: [], scanRoot: "/root",
                providerName: "Projects", hue: .blue, availableSize: available,
                onChooseKeeper: { _ in }, onTrash: { _, _ in }, onClose: {},
                probe: { [probeCount] path in probeCount.record(path); return .quickLook },
                hash: { _ in .hashed("a") },
                initialMode: .difference)
        }
    }

    final class ProbeCount: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: Set<String> = []
        func record(_ path: String) { lock.lock(); seen.insert(path); lock.unlock() }
        var paths: Set<String> { lock.lock(); defer { lock.unlock() }; return seen }
    }

    /// The spinner stops for a corrupt file of a decodable type, which renders no raster; the page
    /// strip already calls the page `.unrenderable`, and the pane must not keep saying "wait".
    ///
    /// Asserted as a transition: no spinner also describes a pane that never mounted, so the test
    /// waits for the spinner to appear first, then to go. A SwiftUI `Text` can't be read back from
    /// a hosting view, so `ComparePairViewingTests` holds the message's wording.
    @MainActor
    @Test func aPairThatCannotBeRenderedStopsSpinningAndSaysWhy() async throws {
        let fixture = try CorruptImageFixture()
        let available = CGSize(width: 1000, height: 700)
        let (host, window) = HostedView.host(AnyView(
            SwappableHarness(box: PairBox(pair: Self.pair(left: fixture.left, right: fixture.right, groupName: "scan.png")), available: available,
                             probeCount: ProbeCount())), size: available)

        func spinners(_ view: NSView) -> [NSProgressIndicator] {
            view.subviews.flatMap {
                [$0].compactMap { $0 as? NSProgressIndicator } + spinners($0)
            }
        }
        // The positive control: while the render is in flight, the spinner is there. Without it
        // the check below proves nothing.
        let (spun, spinPumps) = await LayoutPumpWait.pump(window, upTo: 5) {
            !spinners(host).isEmpty
        }
        try #require(spun, """
                     no spinner ever appeared (\(spinPumps) pumps) — the surface is not in the \
                     state this test is about, so its verdict would be meaningless
                     """)

        let (stopped, pumps) = await LayoutPumpWait.pump(window, upTo: 5) {
            spinners(host).isEmpty
        }
        #expect(stopped, """
                \(spinners(host).count) spinner(s) still turning after \(pumps) pumps, for a page \
                that will never render — the strip has already called it unrenderable
                """)
    }

    /// A cloud-only side mounts no Quick Look view: rendering one would force the provider to
    /// download the whole file, which the placeholder exists to avoid.
    @Test func aCloudOnlySideMountsNoPreviewAtAll() async throws {
        let fixture = try Fixture()
        let available = CGSize(width: 1200, height: 800)
        // The positive control first: "no preview" also describes an unrendered pane, so the same
        // fixture with the same pump budget must reach two panes when materialized. Then zero on
        // the cloud-only mount is about the classification, not the clock.
        let materialized = mount(fixture, available: available, source: .quickLook)
        guard await pump(materialized, upTo: 3, until: {
            descendants(of: materialized.host).compactMap { $0 as? QLPreviewView }.count == 2
        }) else { return }

        let cloudOnly = mount(fixture, available: available, source: .cloudOnly)
        // A settle in main-actor turns, not seconds: `upTo: 0` still runs
        // `LayoutPumpWait.pumpFloor` passes, the floor the positive mount cleared.
        _ = await LayoutPumpWait.pump(cloudOnly.window, upTo: 0) { false }
        let previews = descendants(of: cloudOnly.host).compactMap { $0 as? QLPreviewView }
        #expect(previews.isEmpty, "a cloud-only placeholder started a download by previewing it")
    }
}
