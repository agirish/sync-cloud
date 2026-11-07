import AppKit
import CoreGraphics
import Foundation
import PDFKit
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The modes, the page pairing, and the render half of the visual compare.
@Suite struct ComparePairViewingTests {

    // MARK: Modes

    /// A mode's digit and its place among the offered modes are one fact; writing the mapping
    /// twice lets a keyboard hint and its key disagree.
    @Test func everyModesDigitRoundTripsWithinWhatIsOffered() {
        for kind in PairContentKind.allCases {
            let offered = ComparePairMode.available(for: kind)
            for mode in offered {
                let digit = try? #require(mode.digit(in: offered))
                #expect(ComparePairMode.forDigit(digit ?? 0, in: offered) == mode, "\(kind)")
            }
            #expect(ComparePairMode.forDigit(0, in: offered) == nil)
            #expect(ComparePairMode.forDigit(offered.count + 1, in: offered) == nil)
        }
    }

    /// The digit is a position in what is offered, not in the declaration. A text pair's `2` must
    /// reach its Diff segment, the fourth case declared; `allCases` would reach one not on screen.
    @Test func aTextPairsSecondDigitReachesItsSecondSegment() {
        let offered = ComparePairMode.available(for: .text)
        #expect(ComparePairMode.forDigit(2, in: offered) == .textDiff)
        #expect(ComparePairMode.forDigit(2, in: ComparePairMode.available(for: .pdf)) == .swipe)
        #expect(ComparePairMode.forDigit(2, in: ComparePairMode.available(for: .other)) == nil)
    }

    /// A kind with neither a raster nor lines gets exactly one mode, and then no segmented control
    /// at all: a one-segment picker can't be used.
    @Test func eachKindOffersTheModesItCanActuallyDraw() {
        #expect(ComparePairMode.available(for: .pdf).count == 4)
        #expect(ComparePairMode.available(for: .image).count == 4)
        #expect(ComparePairMode.available(for: .text) == [.sideBySide, .textDiff])
        #expect(ComparePairMode.available(for: .other) == [.sideBySide])
        // The pixel modes are never offered where there is no raster to compare.
        for kind in [PairContentKind.text, .other] {
            #expect(!ComparePairMode.available(for: kind).contains(.difference), "\(kind)")
        }
    }

    /// Difference always carries its caveat: two scans of one sheet glow everywhere from scanner
    /// noise, and an untold reader takes the glow for content.
    @Test func differenceIsTheModeThatOwesACaveat() {
        #expect(ComparePairMode.difference.caveat?.contains("pixel level") == true)
        for mode in ComparePairMode.allCases where mode != .difference {
            #expect(mode.caveat == nil, "\(mode) carries a caveat it does not need")
        }
    }

    // MARK: Pairing

    @Test func equalLengthsPairStraightThrough() {
        let pairing = PagePairing(leftPages: 5, rightPages: 5)
        #expect(pairing.stripLength == 5)
        #expect(!pairing.lengthsDiffer)
        #expect(pairing.lengthNote == nil)
        for index in 0..<5 {
            #expect(pairing.leftIndex(at: index) == index)
            #expect(pairing.rightIndex(at: index) == index)
            #expect(pairing.isComparable(at: index))
        }
    }

    /// 6 against 5: the strip is six long and the short side pins at its last page. Truncating to
    /// five would hide the page only one document has, and a blank pane past the end reads as a
    /// failed render.
    @Test func theShorterSidePinsAtItsLastPageAndSaysSo() throws {
        let pairing = PagePairing(leftPages: 6, rightPages: 5)
        #expect(pairing.stripLength == 6)
        #expect(pairing.leftIndex(at: 5) == 5)
        #expect(pairing.rightIndex(at: 5) == 4, "the short side did not pin at its last page")
        #expect(pairing.rightIsPinned(at: 5))
        #expect(!pairing.leftIsPinned(at: 5))
        let note = try #require(pairing.lengthNote)
        #expect(note.contains("6 pages"))
        #expect(note.contains("5"))
    }

    /// A pinned position is not a comparison: it sets a page against a different page, so its dot
    /// says one-sided, never "same" or "changed".
    @Test func aPinnedPositionIsNotComparable() {
        let pairing = PagePairing(leftPages: 6, rightPages: 5)
        #expect(pairing.isComparable(at: 4))
        #expect(!pairing.isComparable(at: 5))
    }

    @Test func aDocumentThatWouldNotOpenHasNoStrip() {
        let pairing = PagePairing(leftPages: 0, rightPages: 0)
        #expect(pairing.stripLength == 0)
        #expect(!pairing.isComparable(at: 0))
    }

    @Test func aSinglePagePairIsSingular() throws {
        let note = try #require(PagePairing(leftPages: 1, rightPages: 3).lengthNote)
        #expect(note.contains("1 page on the left"))
        #expect(!note.contains("1 pages"))
    }

    // MARK: Page state

    /// Pending is its own state. A strip showing "same" while the comparison is still queued would
    /// make a claim nobody checked, beside a button that trashes a file.
    @Test func pendingIsNotSame() {
        #expect(PageDiffState.pending != .same)
        #expect(!PageDiffState.pending.isResolved)
        #expect(PageDiffState.same.isResolved)
    }

    /// A raster that couldn't be built is `unrenderable`, never `same`, for the reason
    /// `BitmapDiff.compare` returns nil rather than a zero result.
    @Test func anUnbuiltRasterIsNotAMatch() {
        #expect(PageDiffState.from(nil) == .unrenderable)
        #expect(PageDiffState.from(BitmapDiffResult(changedFraction: 0, changedRects: [],
                                                    sizesDiffer: false)) == .same)
        #expect(PageDiffState.from(BitmapDiffResult(changedFraction: 0.2, changedRects: [],
                                                    sizesDiffer: false)) == .changed(fraction: 0.2))
    }

    /// A pending page draws no dot, not a grey one. A grey dot reads as "checked, unremarkable"
    /// rather than "not checked"; the page number alone is the honest resting state.
    @Test func onlyAResolvedPageGetsADot() {
        #expect(PageDiffState.pending.dot == nil)
        #expect(PageDiffState.same.dot == .same)
        #expect(PageDiffState.changed(fraction: 0.2).dot == .changed)
        #expect(PageDiffState.oneSided.dot == .oneSided)
        #expect(PageDiffState.unrenderable.dot == .unrenderable)
    }

    /// Every resolved state has a dot and the pending one does not, asserted as a pair so a new
    /// state can't be added with neither.
    @Test func aDotExistsForExactlyTheResolvedStates() {
        let states: [PageDiffState] = [.pending, .same, .changed(fraction: 0.5), .oneSided,
                                       .unrenderable]
        for state in states {
            #expect((state.dot != nil) == state.isResolved, "\(state)")
        }
    }

    // MARK: Nothing to draw — waiting, or never

    /// A spinner means "wait", so a side whose raster can't be built (a corrupt JPEG, an encrypted
    /// PDF) gets a message instead, matching the strip's `.unrenderable`.
    @Test func aFailedSideIsToldAboutRatherThanWaitedFor() {
        let outcome = PairRenderOutcome.failed(left: true, right: false)
        #expect(outcome.fallback(for: .left, name: "scan.jpg")
                == .message("“scan.jpg” could not be rendered."))
        #expect(outcome.fallback(for: .right, name: "scan copy.jpg") == .spinner,
                "the side that rendered fine must not be captioned as broken")
    }

    /// While a render is in flight the spinner is right; removing it would be a different wrong
    /// answer.
    @Test func aRenderInFlightStillWaits() {
        for outcome in [PairRenderOutcome.rendering, .ready] {
            #expect(outcome.fallback(for: .left, name: "a.png") == .spinner, "\(outcome)")
            #expect(outcome.fallback(for: .right, name: "b.png") == .spinner, "\(outcome)")
            #expect(outcome.differenceMessage(leftName: "a.png", rightName: "b.png") == nil,
                    "\(outcome)")
            #expect(!outcome.didFail, "\(outcome)")
        }
    }

    /// A comparison needs both sides, so one unrenderable side ends it, and the difference view
    /// names that side rather than leaving a black field to read as "no differences".
    @Test func theDifferenceViewNamesTheSideThatEndedTheComparison() {
        #expect(PairRenderOutcome.failed(left: true, right: false)
                    .differenceMessage(leftName: "a.png", rightName: "b.png")
                == "“a.png” could not be rendered, so there is nothing to compare.")
        #expect(PairRenderOutcome.failed(left: false, right: true)
                    .differenceMessage(leftName: "a.png", rightName: "b.png")
                == "“b.png” could not be rendered, so there is nothing to compare.")
        #expect(PairRenderOutcome.failed(left: true, right: true)
                    .differenceMessage(leftName: "a.png", rightName: "b.png")
                == "Neither copy could be rendered, so there is nothing to compare.")
    }

    @Test func onlyAFailedOutcomeReportsAFailedSide() {
        #expect(PairRenderOutcome.failed(left: true, right: false).failed(.left))
        #expect(!PairRenderOutcome.failed(left: true, right: false).failed(.right))
        #expect(!PairRenderOutcome.ready.failed(.left))
        #expect(!PairRenderOutcome.rendering.failed(.right))
        #expect(PairRenderOutcome.failed(left: false, right: true).didFail)
    }

    // MARK: The renderer, on real documents

    private final class PDFFixture {
        let dir: URL
        let onePage: String
        let twoPage: String
        let twoPageEdited: String

        init() throws {
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ComparePairViewingTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            onePage = try Self.write(pages: ["Hello"], to: dir.appendingPathComponent("one.pdf"))
            twoPage = try Self.write(pages: ["Hello", "World"],
                                     to: dir.appendingPathComponent("two.pdf"))
            twoPageEdited = try Self.write(pages: ["Hello", "Changed"],
                                           to: dir.appendingPathComponent("two-edited.pdf"))
        }
        deinit { try? FileManager.default.removeItem(at: dir) }

        /// A real multi-page PDF built through PDFKit: the renderer opens documents, so a
        /// fabricated path would answer nil and the cases below would pass vacuously.
        private static func write(pages: [String], to url: URL) throws -> String {
            let document = PDFDocument()
            for (index, text) in pages.enumerated() {
                let size = CGSize(width: 300, height: 200)
                let image = NSImage(size: size)
                image.lockFocus()
                NSColor.white.setFill()
                NSRect(origin: .zero, size: size).fill()
                (text as NSString).draw(
                    at: NSPoint(x: 20, y: 100),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 48),
                                     .foregroundColor: NSColor.black])
                image.unlockFocus()
                let page = try #require(PDFPage(image: image))
                document.insert(page, at: index)
            }
            #expect(document.write(to: url))
            return url.path
        }
    }

    @Test func pageCountReadsTheDocument() async throws {
        let fixture = try PDFFixture()
        #expect(await PagePairRaster.pageCount(path: fixture.onePage) == 1)
        #expect(await PagePairRaster.pageCount(path: fixture.twoPage) == 2)
        #expect(await PagePairRaster.pageCount(path: "/nope/missing.pdf") == nil)
    }

    /// The render is bounded by the long edge asked for, so a 300-page document costs one bounded
    /// page at a time and never a full-resolution raster.
    @Test func aRenderedPageIsBoundedByItsLongEdge() async throws {
        let fixture = try PDFFixture()
        let image = try #require(await PagePairRaster.render(path: fixture.onePage, page: 0,
                                                             longEdge: 400))
        #expect(max(image.width, image.height) == 400)
        #expect(min(image.width, image.height) > 1)
    }

    @Test func aPageIndexPastTheEndRendersNothing() async throws {
        let fixture = try PDFFixture()
        #expect(await PagePairRaster.render(path: fixture.onePage, page: 5, longEdge: 200) == nil)
        #expect(await PagePairRaster.render(path: fixture.onePage, page: -1, longEdge: 200) == nil)
    }

    /// End to end: two documents with the same page 1 and a different page 2 diff as
    /// same-then-changed. Fails if the render, the normalisation or the loop is wrong.
    @Test func twoRealPagesDiffAsSameThenChanged() async throws {
        let fixture = try PDFFixture()
        func diff(page: Int) async throws -> BitmapDiffResult {
            let a = try #require(await PagePairRaster.render(path: fixture.twoPage, page: page,
                                                             longEdge: 400))
            let b = try #require(await PagePairRaster.render(path: fixture.twoPageEdited,
                                                             page: page, longEdge: 400))
            return try #require(BitmapDiff.compare(a.cgImage, b.cgImage))
        }
        #expect(try await diff(page: 0).isIdentical, "page 1 is the same on both and read as changed")
        let second = try await diff(page: 1)
        #expect(!second.isIdentical, "page 2 differs on both and read as identical")
        #expect(!second.changedRects.isEmpty)
    }

    /// The PDFKit lane holds: a compare render and another reader together never put two parses
    /// in flight. `peakConcurrentParses` above 1 means a second lane exists somewhere.
    @Test func theSerialLaneStillHoldsWithACompareRunning() async throws {
        let fixture = try PDFFixture()
        // Paths, not the fixture: the fixture is a class, and sharing it across concurrent tasks
        // is a data race the compiler refuses.
        let render = fixture.twoPage
        let count = fixture.twoPageEdited
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = await PagePairRaster.render(path: render, page: 0, longEdge: 200)
                }
                group.addTask { _ = await PagePairRaster.pageCount(path: count) }
            }
        }
        #expect(PDFKitSerialAccess.peakConcurrentParses <= 1,
                "two PDFKit parses ran at once — peak \(PDFKitSerialAccess.peakConcurrentParses)")
    }

    // MARK: The typed viewer, mounted

    /// Both documents open and both panes get width. Read back from the views, because `PDFView`
    /// draws through a layer `cacheDisplay(in:to:)` doesn't capture, so a mounted pair
    /// photographs as two empty boxes whether it works or not.
    @MainActor
    @Test func theTypedPdfPairOpensBothDocumentsAndSplitsTheSpace() async throws {
        let fixture = try PDFFixture()
        let view = PDFPairView(leftPath: fixture.twoPage, rightPath: fixture.twoPageEdited,
                               page: 0, pairing: PagePairing(leftPages: 2, rightPages: 2),
                               syncSuspended: false)
        let host = NSHostingView(rootView: AnyView(view.frame(width: 800, height: 500)))
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func views(_ v: NSView) -> [PDFView] {
            v.subviews.flatMap { [$0].compactMap { $0 as? PDFView } + views($0) }
        }
        // `LayoutPumpWait`, not a wall-clock deadline: the documents arrive on main-actor turns,
        // and under load seconds buy few of them ("Fixed pumps and fixed sleeps",
        // `docs/flaky-tests.md`).
        let (held, pumps) = await LayoutPumpWait.pump(window, upTo: 5) {
            let found = views(host)
            return found.count == 2 && found.allSatisfy { $0.document != nil }
        }
        let pdfs = views(host)
        #expect(held, "the pair never finished loading (\(pumps) pumps, \(pdfs.count) panes)")
        #expect(pdfs.count == 2, "expected two PDF panes, found \(pdfs.count)")
        #expect(pdfs.allSatisfy { $0.document?.pageCount == 2 },
                "a document did not open: \(pdfs.map { $0.document?.pageCount ?? -1 })")
        for pane in pdfs {
            #expect(pane.frame.width > 300, "a pane laid out at \(pane.frame.width)pt")
            #expect(pane.frame.height > 400)
        }
    }

    /// Scrolling one pane moves the other. A `PDFView` has no clip view until its document loads,
    /// so observers registered in `makeNSView` would register nothing, while zoom sync still made
    /// the pair look synchronised. Only a real scroll shows it.
    @MainActor
    @Test func scrollingOnePaneMovesTheOther() async throws {
        let fixture = try PDFFixture()
        let view = PDFPairView(leftPath: fixture.twoPage, rightPath: fixture.twoPageEdited,
                               page: 0, pairing: PagePairing(leftPages: 2, rightPages: 2),
                               syncSuspended: false)
        let host = NSHostingView(rootView: AnyView(view.frame(width: 400, height: 200)))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func views(_ v: NSView) -> [PDFView] {
            v.subviews.flatMap { [$0].compactMap { $0 as? PDFView } + views($0) }
        }
        func clips() -> [NSClipView] {
            views(host).compactMap { $0.documentView?.enclosingScrollView?.contentView }
        }
        // Wait for the clip views, not just the documents: the observer needs the clip view, and
        // it doesn't exist at construction.
        let (held, pumps) = await LayoutPumpWait.pump(window, upTo: 5) { clips().count == 2 }
        try #require(held, "the panes never got scroll views (\(pumps) pumps)")
        let pair = clips()
        let target = CGPoint(x: 0, y: 40)
        pair[0].scroll(to: target)
        pair[0].enclosingScrollView?.reflectScrolledClipView(pair[0])
        // The mirror runs on the main queue from a notification; give it turns to arrive.
        let (mirrored, mirrorPumps) = await LayoutPumpWait.pump(window, upTo: 3) {
            abs(pair[1].bounds.origin.y - pair[0].bounds.origin.y) < 0.5
        }
        #expect(mirrored, """
                the right pane sat at \(pair[1].bounds.origin.y) while the left moved to \
                \(pair[0].bounds.origin.y) (\(mirrorPumps) pumps) — the scroll observers were \
                never registered
                """)
    }

    // MARK: The reentrancy latch

    /// What a value comparison can't give: two views quantise scroll offsets differently, so
    /// A → B → A′ lands a hair off A and the pair walks. The latch stops the echo at one hop.
    @Test func theLatchStopsAnEchoAtOneHop() {
        let latch = SyncLatch()
        var hops = 0
        func mirror(depth: Int) {
            latch.mirror {
                hops += 1
                if depth < 5 { mirror(depth: depth + 1) }   // the echo trying to come back
            }
        }
        mirror(depth: 0)
        #expect(hops == 1, "the mirror re-entered \(hops) times")
    }

    /// …and it re-arms: a latch that stayed closed would freeze the pair after its first scroll.
    @Test func theLatchReArmsAfterEachMirror() {
        let latch = SyncLatch()
        var hops = 0
        for _ in 0..<3 { latch.mirror { hops += 1 } }
        #expect(hops == 3)
        #expect(!latch.isMirroring)
    }

    // MARK: The zoom has to survive a mode switch

    final class ZoomReports: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [CGFloat] = []
        func record(_ zoom: CGFloat) { lock.lock(); seen.append(zoom); lock.unlock() }
        var zooms: [CGFloat] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    /// The mode switch as the surface performs it: leaving side by side removes the representable
    /// and coming back builds a fresh one, which a test that only mounts can't see.
    private struct ModeSwitchHarness: View {
        let left: String
        let right: String
        let syncSuspended: Bool
        @ObservedObject var box: ZoomBox
        var body: some View {
            Group {
                if box.showingPair {
                    PDFPairView(leftPath: left, rightPath: right, page: 0,
                                pairing: PagePairing(leftPages: 3, rightPages: 3),
                                syncSuspended: syncSuspended,
                                zoom: box.zoom,
                                onZoomChange: { box.zoom = $0 })
                } else {
                    Color.clear      // stands in for a pixel mode
                }
            }
            .frame(width: 1000, height: 430)
        }
    }

    @MainActor
    final class ZoomBox: ObservableObject {
        @Published var showingPair = true
        /// What the surface remembers, also recorded so a test can assert that a report happened.
        @Published var zoom: CGFloat? { didSet { if let zoom { reports.record(zoom) } } }
        let reports = ZoomReports()
    }

    @MainActor
    private func mountSwitchable(_ fixture: LetterFixture, box: ZoomBox,
                                 syncSuspended: Bool = false)
        -> (NSHostingView<AnyView>, NSWindow) {
        let host = NSHostingView(rootView: AnyView(
            ModeSwitchHarness(left: fixture.left, right: fixture.right,
                              syncSuspended: syncSuspended, box: box)))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 430)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    @MainActor
    private func loadedPanes(_ host: NSHostingView<AnyView>, _ window: NSWindow) async throws -> [PDFView] {
        // Paced by the PDFKit lane the two opens queue in, not by seconds: in a full package run
        // that lane can be busy for minutes. See `LaneWait`.
        let (loaded, pumps) = await LaneWait.pump(window) {
            pdfViews(host).count == 2 && pdfViews(host).allSatisfy { $0.document != nil }
        }
        try #require(loaded, "the pair never loaded (\(pumps) lane passes)")
        return pdfViews(host)
    }

    /// The reader's round trip: zoom in, press `2`–`4` for a pixel mode, press `1` to come back.
    /// The fresh mount's `autoScales` would refit and lose the zoom; like the page, it lives on
    /// the surface.
    @MainActor
    @Test func theReadersZoomSurvivesLeavingAndReenteringSideBySide() async throws {
        let fixture = try LetterFixture()
        let box = ZoomBox()
        let (host, window) = mountSwitchable(fixture, box: box)
        let panes = try await loadedPanes(host, window)

        let fitted = panes[0].scaleFactor
        let chosen = fitted * 2.5
        panes[0].scaleFactor = chosen
        _ = await LayoutPumpWait.pump(window, upTo: 2) { false }

        box.showingPair = false                                   // 2–4: the pair unmounts
        let (told, tellPumps) = await LayoutPumpWait.pump(window, upTo: 5) {
            box.zoom.map { abs($0 - chosen) < 0.001 } ?? false
        }
        try #require(told, """
                     leaving side by side reported \(box.zoom.map(String.init) ?? "nothing") \
                     after \(tellPumps) pumps, not the reader's \(chosen)
                     """)

        box.showingPair = true                                    // 1: a fresh pair is built
        let back = try await loadedPanes(host, window)
        let (restored, pumps) = await LayoutPumpWait.pump(window, upTo: 5) {
            back.allSatisfy { abs($0.scaleFactor - chosen) < 0.001 }
        }
        #expect(restored, """
                came back at \(back.map(\.scaleFactor)) rather than \(chosen) after \(pumps) \
                pumps — the reader is at fit (\(fitted)) again
                """)
        #expect(abs(fitted - chosen) > 0.001, "positive control: the fit and the choice differ")
    }

    /// A fresh static mount (one `updateNSView`, nothing republishing) applies the zoom it was
    /// given. Applied inline in the load completion, the zoom is overwritten: PDFKit does its own
    /// initial fit at the next layout, so the pane comes up at the fit with `autoScales` false.
    /// The round-trip test can't catch this: its harness publishes, and a later pass re-applies.
    @MainActor
    @Test func aFreshStaticMountAppliesTheZoomItWasGiven() async throws {
        let fixture = try LetterFixture()
        // The fit this pane chooses on its own, so the assertion cannot pass by naming it.
        let box = ZoomBox()
        let (fitHost, fitWindow) = mountSwitchable(fixture, box: box)
        let fitted = try await loadedPanes(fitHost, fitWindow)[0].scaleFactor
        let remembered = fitted * 2.5

        let view = PDFPairView(leftPath: fixture.left, rightPath: fixture.right, page: 0,
                               pairing: PagePairing(leftPages: 3, rightPages: 3),
                               syncSuspended: false, zoom: remembered)
        let host = NSHostingView(rootView: AnyView(view.frame(width: 1000, height: 430)))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 430)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let panes = try await loadedPanes(host, window)
        let (applied, pumps) = await LayoutPumpWait.pump(window, upTo: 5) {
            panes.allSatisfy { abs($0.scaleFactor - remembered) < 0.001 }
        }
        #expect(applied, """
                opened at \(panes.map(\.scaleFactor)) rather than the remembered \(remembered) \
                after \(pumps) pumps — the fit overwrote it and the reader is back at \(fitted)
                """)
    }

    /// A pair the reader never zoomed keeps fitting itself. PDFKit posts its own initial fit, and
    /// the mirror turns the far pane's `autoScales` off; reporting that fit as a choice would pin
    /// every later mount at one window's fit.
    @MainActor
    @Test func anUntouchedPairReportsNoZoomAndKeepsFitting() async throws {
        let fixture = try LetterFixture()
        let box = ZoomBox()
        let (host, window) = mountSwitchable(fixture, box: box)
        let panes = try await loadedPanes(host, window)
        // Not `panes.allSatisfy`: the mirror turns one pane's `autoScales` off during load, and
        // which one depends on load order. That is why the report reads `fittedScale`, not the flag.
        try #require(panes.contains { $0.autoScales }, "premise: a pane is still fitting itself")

        box.showingPair = false
        _ = await LayoutPumpWait.pump(window, upTo: 5) { box.zoom != nil }
        #expect(box.zoom == nil,
                "the fit was recorded as a choice (\(box.reports.zooms)) — every later mount is pinned to it")

        box.showingPair = true
        let back = try await loadedPanes(host, window)
        #expect(back.contains { $0.autoScales }, "the fresh pair stopped fitting itself")
    }

    /// ⌥ silences the zoom report, as it does the page report: with ⌥ held the panes are apart, and
    /// a stored zoom would reach both panes on the next mount, which ⌥ exists to prevent.
    @MainActor
    @Test func aZoomSetWhileOptionIsHeldIsNotRecorded() async throws {
        let fixture = try LetterFixture()
        let box = ZoomBox()
        let (host, window) = mountSwitchable(fixture, box: box, syncSuspended: true)
        let panes = try await loadedPanes(host, window)

        panes[0].scaleFactor = panes[0].scaleFactor * 2.5
        _ = await LayoutPumpWait.pump(window, upTo: 2) { false }
        box.showingPair = false

        // Pumped as long as the round-trip test needs to see a report, so this is a waited-out
        // absence, not a race won by being quick.
        let (recorded, pumps) = await LayoutPumpWait.pump(window, upTo: 5) { box.zoom != nil }
        #expect(!recorded, """
                \(box.reports.zooms) recorded after \(pumps) pumps with ⌥ held — the next mount \
                applies it to both panes, which is what ⌥ forbids
                """)
    }

    // MARK: Scrolling, at the size the reader actually gets

    /// US Letter pages, at the pane size the overlay really opens, so the fixture can't make the
    /// answer come out favourable.
    private final class LetterFixture {
        let dir: URL
        let left: String
        let right: String
        init() throws {
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("LetterPair-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            left = try Self.write(dir.appendingPathComponent("a.pdf"))
            right = try Self.write(dir.appendingPathComponent("b.pdf"))
        }
        deinit { try? FileManager.default.removeItem(at: dir) }

        private static func write(_ url: URL) throws -> String {
            let document = PDFDocument()
            for index in 0..<3 {
                let size = CGSize(width: 612, height: 792)
                let image = NSImage(size: size)
                image.lockFocus()
                NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
                ("page \(index + 1)" as NSString).draw(
                    at: NSPoint(x: 40, y: 700),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 48)])
                image.unlockFocus()
                document.insert(try #require(PDFPage(image: image)), at: index)
            }
            #expect(document.write(to: url))
            return url.path
        }
    }

    @MainActor
    private func mountLetterPair(_ fixture: LetterFixture, pageReports: PageReports? = nil,
                                 syncSuspended: Bool = false)
        -> (NSHostingView<AnyView>, NSWindow) {
        let view = PDFPairView(leftPath: fixture.left, rightPath: fixture.right, page: 0,
                               pairing: PagePairing(leftPages: 3, rightPages: 3),
                               syncSuspended: syncSuspended,
                               onPageChange: { [pageReports] in pageReports?.record($0) })
        let host = NSHostingView(rootView: AnyView(view.frame(width: 1000, height: 430)))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 430)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    final class PageReports: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Int] = []
        func record(_ page: Int) { lock.lock(); seen.append(page); lock.unlock() }
        var pages: [Int] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    private func pdfViews(_ view: NSView) -> [PDFView] {
        view.subviews.flatMap { [$0].compactMap { $0 as? PDFView } + pdfViews($0) }
    }

    /// At the real pane size there is something to scroll. `autoScales` fits the page to the
    /// pane, so under `.singlePage` the document exactly fills the clip view and no scroll moves
    /// either pane. Continuous display gives a scroll somewhere to go.
    @MainActor
    @Test func atTheRealPaneSizeThereIsSomethingToScroll() async throws {
        let fixture = try LetterFixture()
        let (host, window) = mountLetterPair(fixture)
        // Paced by the PDFKit lane, not by seconds; see `LaneWait`.
        let (loaded, pumps) = await LaneWait.pump(window) {
            pdfViews(host).count == 2 && pdfViews(host).allSatisfy { $0.document != nil }
        }
        try #require(loaded, "the pair never loaded (\(pumps) lane passes)")
        for pane in pdfViews(host) {
            let documentHeight = try #require(pane.documentView?.frame.height)
            let clipHeight = try #require(pane.documentView?.enclosingScrollView?.contentView.bounds.height)
            #expect(documentHeight > clipHeight + 1, """
                    a pane laid out \(documentHeight)pt of document inside a \(clipHeight)pt clip \
                    view — the content fits, so a scroll gesture has nowhere to go
                    """)
        }
    }

    /// A page the reader lands on is reported to the surface, so the strip and pixel modes follow
    /// the panes.
    ///
    /// The move uses `go(to:)`, not a scroll: setting a clip view's bounds doesn't make `PDFView`
    /// recompute its current page. This pins everything after the page changes (notification,
    /// value guard, surface); PDFKit updating `currentPage` on scroll is the one link no test here
    /// can drive.
    @MainActor
    @Test func aPageTheReaderLandsOnIsReportedToTheSurface() async throws {
        let fixture = try LetterFixture()
        let reports = PageReports()
        let (host, window) = mountLetterPair(fixture, pageReports: reports)
        let (loaded, passes) = await LaneWait.pump(window) {
            pdfViews(host).count == 2 && pdfViews(host).allSatisfy { $0.document != nil }
        }
        try #require(loaded, "the pair never loaded (\(passes) lane passes)")
        try #require(reports.pages.isEmpty,
                     "a page was reported before anything moved: \(reports.pages)")

        let pane = pdfViews(host)[0]
        let document = try #require(pane.document)
        pane.go(to: try #require(document.page(at: 1)))

        let (reported, pumps) = await LayoutPumpWait.pump(window, upTo: 5) {
            reports.pages.contains(1)
        }
        #expect(reported, """
                landing on page 2 reported \(reports.pages) (\(pumps) pumps) — the strip would \
                still be pointing at page 1
                """)
    }

    /// ⌥ silences the page report, not only the scroll mirror. With ⌥ held one pane moves alone,
    /// as the Help book promises; but the surface owns the page for both panes, so a report would
    /// make its next update drive the other pane to the same page.
    @MainActor
    @Test func aPageLandedOnWhileOptionIsHeldIsNotReported() async throws {
        let fixture = try LetterFixture()
        let reports = PageReports()
        let (host, window) = mountLetterPair(fixture, pageReports: reports, syncSuspended: true)
        let (loaded, passes) = await LaneWait.pump(window) {
            pdfViews(host).count == 2 && pdfViews(host).allSatisfy { $0.document != nil }
        }
        try #require(loaded, "the pair never loaded (\(passes) lane passes)")

        let pane = pdfViews(host)[0]
        let document = try #require(pane.document)
        pane.go(to: try #require(document.page(at: 1)))

        // Pumped as long as the positive control above needs to see a report, so this is a
        // waited-out absence, not a race won by being quick.
        let (reported, pumps) = await LayoutPumpWait.pump(window, upTo: 5) {
            reports.pages.contains(1)
        }
        #expect(!reported, """
                page 2 was reported after \(pumps) pumps with ⌥ held \(reports.pages) — the \
                surface will drive the other pane there, which is what ⌥ forbids
                """)
    }

    /// The echo stops: both views post when the page changes, so a report repeating what the
    /// surface asked for must not come back, or the strip and panes push each other in a loop.
    @MainActor
    @Test func aPageTheSurfaceAskedForIsNotReportedBack() async throws {
        let fixture = try LetterFixture()
        let reports = PageReports()
        let view = PDFPairView(leftPath: fixture.left, rightPath: fixture.right, page: 1,
                               pairing: PagePairing(leftPages: 3, rightPages: 3),
                               syncSuspended: false,
                               onPageChange: { reports.record($0) })
        let host = NSHostingView(rootView: AnyView(view.frame(width: 1000, height: 430)))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 430)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let (loaded, passes) = await LaneWait.pump(window) {
            pdfViews(host).count == 2 && pdfViews(host).allSatisfy { $0.document != nil }
        }
        try #require(loaded, "the pair never loaded (\(passes) lane passes)")
        // Give every notification the surface's own move produces time to arrive.
        _ = await LayoutPumpWait.pump(window, upTo: 3) { false }
        #expect(reports.pages.filter { $0 == 1 }.isEmpty, """
                the surface's own page came back as a report (\(reports.pages)) — that is the echo \
                the value guard exists to stop
                """)
    }

    // MARK: A page turned while the documents are still opening

    /// Holds the page the way the surface does, so the test can turn it under a mounted pair.
    private final class PageBox: ObservableObject {
        @Published var page: Int
        init(page: Int) { self.page = page }
    }

    private struct PagingHarness: View {
        @ObservedObject var box: PageBox
        let left: String
        let right: String

        var body: some View {
            PDFPairView(leftPath: left, rightPath: right, page: box.page,
                        pairing: PagePairing(leftPages: 2, rightPages: 2), syncSuspended: false)
                .frame(width: 800, height: 500)
        }
    }

    /// A page turned while the documents open is not lost. `go` bails while `document` is nil, so
    /// a load that used the index captured when it was queued would leave both panes on the old
    /// page. The window is widest when a scan holds the PDFKit lane and the strip is clickable.
    ///
    /// The turn is made before any await, and the require checks no document has arrived: a turn
    /// after the load would take the ordinary `go` path and prove nothing.
    @MainActor
    @Test func aPageTurnedWhileTheDocumentsOpenIsNotLost() async throws {
        let fixture = try PDFFixture()
        let box = PageBox(page: 0)
        let host = NSHostingView(rootView: AnyView(
            PagingHarness(box: box, left: fixture.twoPage, right: fixture.twoPageEdited)))
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        func panes(_ v: NSView) -> [PDFView] {
            v.subviews.flatMap { [$0].compactMap { $0 as? PDFView } + panes($0) }
        }
        // Both halves matter: `allSatisfy` is vacuously true on an empty array, so the count is
        // asserted too.
        try #require(panes(host).count == 2 && panes(host).allSatisfy { $0.document == nil },
                     "a document arrived before the turn — this would test the ordinary path")

        box.page = 1
        host.layoutSubtreeIfNeeded()

        let (loaded, pumps) = await LayoutPumpWait.pump(window, upTo: 5) {
            let found = panes(host)
            return found.count == 2 && found.allSatisfy { $0.document != nil }
        }
        try #require(loaded, "the pair never finished loading (\(pumps) pumps)")

        let (turned, turnPumps) = await LayoutPumpWait.pump(window, upTo: 3) {
            panes(host).allSatisfy { pane in
                guard let document = pane.document, let current = pane.currentPage else {
                    return false
                }
                return document.index(for: current) == 1
            }
        }
        let landed = panes(host).map { pane -> Int in
            guard let document = pane.document, let current = pane.currentPage else { return -1 }
            return document.index(for: current)
        }
        #expect(turned, """
                the panes landed on \(landed) after a turn to page 2 (\(turnPumps) pumps) — the \
                load went to the index it captured before the turn
                """)
    }
}

// MARK: - The scroll observers a path change replaces

/// Re-wiring the scroll sync must retire the previous pair's observers as it registers this pair's.
///
/// The `PDFView`s are reused across a path change, so their clip views can be the same objects and
/// a second registration mirrors every scroll twice. The latch hides the duplicate, so only the
/// registration count shows it.
///
/// Driven on a bare `Coordinator` against real `NotificationCenter` observers, to measure the
/// bookkeeping rather than a PDF pair's rendering.
@Suite struct PDFPairScrollObserverTests {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static let name = Notification.Name("SyncCloudTestScroll")

    private func observer(_ subject: AnyObject, _ counter: Counter) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: Self.name, object: subject,
                                               queue: nil) { _ in counter.bump() }
    }

    @Test func rewiringRetiresThePreviousPairsObservers() {
        let coordinator = PDFPairView.Coordinator()
        let clip = NSObject()
        let first = Counter(), second = Counter()

        coordinator.replaceScrollObservers { [observer(clip, first), observer(clip, second)] }
        NotificationCenter.default.post(name: Self.name, object: clip)
        #expect(first.count == 1 && second.count == 1, "the first wiring never took")

        let third = Counter()
        coordinator.replaceScrollObservers { [observer(clip, third)] }
        NotificationCenter.default.post(name: Self.name, object: clip)

        #expect(third.count == 1, "the new observer is not registered")
        #expect(first.count == 1 && second.count == 1, """
                the previous pair's observers still fire (\(first.count), \(second.count)) — every \
                scroll is mirrored once per pair ever opened
                """)
        #expect(coordinator.scrollObservers.count == 1,
                "\(coordinator.scrollObservers.count) tokens retained for one wiring")

        coordinator.replaceScrollObservers { [] }
    }

    /// The lifetime list is disjoint from the scroll list, checked by identity: a scroll observer in
    /// `observers` would be removed from the centre by a re-wire yet retained for the view's life.
    @Test func aScrollObserverIsNotAlsoHeldInTheLifetimeList() {
        let coordinator = PDFPairView.Coordinator()
        let clip = NSObject()
        coordinator.replaceScrollObservers { [observer(clip, Counter())] }
        let scroll = coordinator.scrollObservers
        #expect(!scroll.isEmpty, "positive control: there is a token to look for")
        for token in scroll {
            #expect(!coordinator.observers.contains { $0 === token },
                    "a scroll observer is in both lists — the re-wire will strand it in one")
        }
        coordinator.replaceScrollObservers { [] }
    }
}
