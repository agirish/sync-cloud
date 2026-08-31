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

    /// **The size nobody develops at.** The window floor is 810×560 and the overlay has to be
    /// usable there — that is the whole reason this is an overlay and not a sheet, since macOS
    /// would silently squeeze a 1080pt sheet to the window's content width exactly here.
    @Test func atTheWindowFloorTheOverlayGetsTwoWorkablePanes() {
        let size = CompareOverlayMetrics.size(available: CGSize(width: 810, height: 560))
        #expect(size == CGSize(width: 762, height: 512))
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

    /// **The label the surface actually draws, at the call site that draws it.**
    ///
    /// `DuplicateComparePrompt` is unit-tested where it lives, and that is not enough here: passing
    /// it `keeper:` and `target:` the wrong way round would name the surviving copy on every
    /// versions pair and satisfy every test of the rule. This builds the sheet the host builds and
    /// reads its title, on both sides of a keeper flip — the two calls differ only in which copy is
    /// being kept, which is exactly the argument an inverted call site would get wrong.
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
        #expect(sheet(keeping: newer.path).trashTitle == "Trash the older copy")
        #expect(sheet(keeping: older.path).trashTitle == "Trash the newer copy",
                "the button named the copy it was keeping after the keeper was flipped")
    }

    /// A stale payload — a keeper path naming neither side — has no target, and the title must not
    /// guess an age for a copy it cannot find. (The verdict is disabled in this state anyway.)
    @Test func aTitleWithNoTargetClaimsNoAge() {
        let pair = DuplicateComparePair(keeper: copy("/root/a/x.md", keeper: true),
                                        other: copy("/root/b/x.md"),
                                        matchType: .versions, groupName: "x.md")
        let sheet = CompareCopiesSheet(
            pair: pair, standing: .noLiveGroup, allowsKeeperChoice: true,
            protectedPaths: [], scanRoot: "/root", providerName: "Projects",
            hue: .blue, availableSize: CGSize(width: 900, height: 700),
            onChooseKeeper: { _ in }, onTrash: { _, _ in }, onClose: {})
        #expect(sheet.trashTitle == "Trash the other copy")
    }

    /// A keeper path naming neither side is what a stale payload looks like — there is no "other
    /// copy" to trash, and the surface must not invent one.
    @Test func aKeeperPathFromOutsideThePairHasNoOtherCopy() {
        let pair = DuplicateComparePair(keeper: copy("/root/a/x.txt", keeper: true),
                                        other: copy("/root/b/x.txt"),
                                        matchType: .identical, groupName: "x.txt")
        #expect(pair.other(than: "/root/c/x.txt") == nil)
    }

    // MARK: A keeper the pair cannot see

    /// **A group may hold more copies than the two on screen, and the keeper can be one of the
    /// others.** Open a three-copy group's second and third copies against each other and the live
    /// group's keeper is neither of them — the host used to fall back to the LEFT pane, so the
    /// surface drew a keeper marker on a copy nothing was keeping and left "Trash the other copy"
    /// enabled beside it. Nothing was stale, so no notice contradicted it.
    ///
    /// The seam is a pure function of a pair and a group, which is what makes the rule assertable
    /// at all: `sheet(available:)` is private and a `some View` cannot be interrogated.
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

    /// **Only one of the three answers marks a keeper, and only one is staleness.** The standing
    /// replaced a keeper path, an outside-keeper name and an `isStale` flag — three fields whose
    /// eight combinations included a surface that withheld its verdict while saying nothing about
    /// why, and one that claimed a keeper while reporting itself stale. Read straight off the
    /// value, so those states cannot be constructed at all.
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

    /// The surface built from that standing: no keeper, no verdict, and a notice that says which
    /// copy is being kept rather than telling the reader to rescan — the facts here are current,
    /// and a rescan would change nothing. All three answers are driven, because the two that
    /// withhold the verdict have to withhold it for reasons the reader can tell apart.
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
        // The facts the viewer would hand the bar. Two copies at different paths, so the summary
        // this feeds has something real to name.
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
        #expect(outside.trashTitle == "Trash the other copy",
                "the button named a target it has no keeper to choose against")

        // Stale: also no verdict, but for the other reason — and it must SAY the other reason.
        let stale = sheet(.noLiveGroup)
        #expect(!stale.standing.offersVerdict)
        #expect(try #require(stale.notice).contains("moved on"))
        #expect(stale.verdictSummary(facts).contains("Rescan"))

        // The positive control, same pair: with the keeper on screen the verdict comes back and
        // the notice goes away.
        let inPair = sheet(.inPair("/root/b/x.md"))
        #expect(inPair.standing.offersVerdict)
        #expect(inPair.notice == nil)
        #expect(!inPair.verdictSummary(facts).contains("not one of these two"))
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
        let host = NSHostingView(rootView: Harness(
            pair: DuplicateComparePair(keeper: keeper, other: other,
                                       matchType: .identical, groupName: "note.txt"),
            keeperPath: fixture.left, isStale: isStale, available: available, source: source,
            startingMode: startingMode, probeCount: probeCount))
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
    /// and squeezes one pane to nothing at 762.
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

    /// The card stays inside the space it was clamped to. An overlay that draws past its own
    /// frame puts the verdict bar — the only thing that trashes a file — off screen.
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

    /// **A pair swapped under a live surface must classify its NEW sides.**
    ///
    /// The probe that classifies each side used to live inside the per-side preview, which only
    /// the side-by-side fallback mounts. In any other mode nothing ran it — so a surface handed a
    /// second pair while sitting in a pixel mode never learned whether the new sides were even
    /// readable, the raster refresh bailed on "not both readable", and nothing could re-trigger
    /// it, because the thing that would have was in a branch that mode never renders.
    ///
    /// **The first draft of this test was vacuous and said so when mutated**: seeding the mode in
    /// `onAppear` still lets one side-by-side frame render first, which mounts the panes and runs
    /// the probe anyway. Swapping the pair is what reaches the state with no such frame.
    @Test func aSwappedPairClassifiesItsNewSidesInAPixelMode() async throws {
        let first = try ImageFixture()
        let second = try ImageFixture()
        let probed = ProbeCount()
        let box = PairBox(pair: Self.pair(first))
        let available = CGSize(width: 1200, height: 800)
        let host = NSHostingView(rootView: AnyView(
            SwappableHarness(box: box, available: available, probeCount: probed)))
        host.frame = CGRect(origin: .zero, size: available)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let (firstDone, _) = await LayoutPumpWait.pump(window, upTo: 3) {
            probed.paths.isSuperset(of: [first.left, first.right])
        }
        try #require(firstDone, "the first pair was never classified — the swap proves nothing")

        box.pair = Self.pair(second)
        let (secondDone, pumps) = await LayoutPumpWait.pump(window, upTo: 3) {
            probed.paths.isSuperset(of: [second.left, second.right])
        }
        #expect(secondDone, """
                the swapped-in pair's sides were never classified (\(pumps) pumps) — the raster                 refresh can never start for it
                """)
    }

    /// Two real PNGs. **The kind matters**: `.difference` is only OFFERED for a pair with pixel
    /// modes, and a `.txt` pair clamps straight back to side by side — which is how the first two
    /// drafts of this test managed to pass with the bug in place.
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

    /// Two files that ARE images by every metadata answer and cannot be decoded by any of them:
    /// a `.png` extension over bytes that are not a PNG. This is what a truncated download or a
    /// half-synced file looks like, and it is the case classifying SVG out of the image viewer
    /// deliberately did not cover — every decodable format still has corrupt files in it.
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

    private static func pair(_ fixture: CorruptImageFixture) -> DuplicateComparePair {
        func copy(_ path: String, keeper: Bool) -> DuplicateCopy {
            DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                          size: 1000, itemCount: 1, modificationDate: scanned,
                          uniqueItemCount: 0, depth: 1, isRecommendedKeeper: keeper)
        }
        return DuplicateComparePair(keeper: copy(fixture.left, keeper: true),
                                    other: copy(fixture.right, keeper: false),
                                    matchType: .identical, groupName: "scan.png")
    }

    private static func pair(_ fixture: ImageFixture) -> DuplicateComparePair {
        func copy(_ path: String, keeper: Bool) -> DuplicateCopy {
            DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                          size: 1000, itemCount: 1, modificationDate: scanned,
                          uniqueItemCount: 0, depth: 1, isRecommendedKeeper: keeper)
        }
        return DuplicateComparePair(keeper: copy(fixture.left, keeper: true),
                                    other: copy(fixture.right, keeper: false),
                                    matchType: .identical, groupName: "a.png")
    }

    private static func pair(_ fixture: Fixture) -> DuplicateComparePair {
        func copy(_ path: String, keeper: Bool) -> DuplicateCopy {
            DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                          size: 1000, itemCount: 1, modificationDate: scanned,
                          uniqueItemCount: 0, depth: 1, isRecommendedKeeper: keeper)
        }
        return DuplicateComparePair(keeper: copy(fixture.left, keeper: true),
                                    other: copy(fixture.right, keeper: false),
                                    matchType: .identical, groupName: "note.txt")
    }

    final class PairBox: ObservableObject {
        @Published var pair: DuplicateComparePair
        init(pair: DuplicateComparePair) { self.pair = pair }
    }

    /// Mounts the surface in a PIXEL mode and lets the test swap the pair underneath it, without
    /// the view being torn down — which is the state the whole pair-change reset exists for and
    /// had no test at all.
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

    /// **The spinner has to stop.** A corrupt file of a decodable type renders no raster, and the
    /// pixel modes drew a `ProgressView` for exactly as long as the surface was open — while the
    /// page strip below had already marked the page `.unrenderable`. Two parts of one surface knew
    /// different things about the same failure, and the louder one said "wait".
    ///
    /// **Asserted as a transition, not as a state.** "No spinner" is also what an empty pane and a
    /// view that never mounted look like, so the test waits for the spinner to APPEAR first — the
    /// honest state while the render is in flight — and only then for it to go. A SwiftUI `Text`
    /// cannot be read back out of a hosting view (there is no `NSTextField`; it is drawn), so the
    /// message's wording is held by `ComparePairViewingTests` instead, and what this pins is the
    /// half that no unit test can see: the waiting ends.
    @MainActor
    @Test func aPairThatCannotBeRenderedStopsSpinningAndSaysWhy() async throws {
        let fixture = try CorruptImageFixture()
        let available = CGSize(width: 1000, height: 700)
        let host = NSHostingView(rootView: AnyView(
            SwappableHarness(box: PairBox(pair: Self.pair(fixture)), available: available,
                             probeCount: ProbeCount())))
        host.frame = CGRect(origin: .zero, size: available)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        func spinners(_ view: NSView) -> [NSProgressIndicator] {
            view.subviews.flatMap {
                [$0].compactMap { $0 as? NSProgressIndicator } + spinners($0)
            }
        }
        // The positive control: while the render is genuinely in flight, waiting is the right
        // answer and the spinner is there. If this never happens the test below proves nothing.
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
