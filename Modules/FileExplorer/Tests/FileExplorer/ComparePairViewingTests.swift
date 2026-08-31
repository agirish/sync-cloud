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

    /// The digit and the declaration order are ONE fact. Writing the mapping twice is how a
    /// keyboard hint and the key it advertises start disagreeing.
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

    /// **The digit is a position in what is OFFERED, not in the declaration.** A text pair offers
    /// two modes, so `2` there must reach its Diff segment — which is the fourth case declared. A
    /// digit derived from `allCases` would reach a segment that is not on screen.
    @Test func aTextPairsSecondDigitReachesItsSecondSegment() {
        let offered = ComparePairMode.available(for: .text)
        #expect(ComparePairMode.forDigit(2, in: offered) == .textDiff)
        #expect(ComparePairMode.forDigit(2, in: ComparePairMode.available(for: .pdf)) == .swipe)
        #expect(ComparePairMode.forDigit(2, in: ComparePairMode.available(for: .other)) == nil)
    }

    /// A kind with neither a raster nor lines gets exactly one mode, and the surface then draws no
    /// segmented control at all — a one-segment picker is a control that cannot be used.
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

    /// **Difference always carries its caveat.** Two scans of the same sheet of paper glow
    /// everywhere from scanner noise; a reader who has not been told reads the glow as content.
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

    /// **6 against 5: the strip is six long and the short side pins at its last page.** Truncating
    /// to five would hide the page that exists on one document only — which for a versions pair is
    /// the most interesting thing about it — and a blank pane past the end reads as a failed
    /// render rather than as the end of the document.
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

    /// **A pinned position is not a comparison.** It measures a page against a different page, so
    /// a strip dot there must not claim "same" or "changed" — it says one-sided instead.
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

    /// A pending dot is its own state. A strip that rendered "same" while the comparison was still
    /// queued behind a scan would be making a claim nobody checked, on a surface whose next button
    /// trashes a file.
    @Test func pendingIsNotSame() {
        #expect(PageDiffState.pending != .same)
        #expect(!PageDiffState.pending.isResolved)
        #expect(PageDiffState.same.isResolved)
    }

    /// A raster that could not be built is `unrenderable`, never `same`. Those two must not be the
    /// same answer here for the same reason `BitmapDiff.compare` returns nil rather than a
    /// zero result.
    @Test func anUnbuiltRasterIsNotAMatch() {
        #expect(PageDiffState.from(nil) == .unrenderable)
        #expect(PageDiffState.from(BitmapDiffResult(changedFraction: 0, changedRects: [],
                                                    sizesDiffer: false)) == .same)
        #expect(PageDiffState.from(BitmapDiffResult(changedFraction: 0.2, changedRects: [],
                                                    sizesDiffer: false)) == .changed(fraction: 0.2))
    }

    /// **A pending page draws NO dot, and that is the rule rather than a shade of grey.** A grey
    /// dot under every page is what the strip showed in side-by-side mode, where no comparison is
    /// run at all — markers that mean nothing, which read as "checked, and unremarkable" rather
    /// than as "not checked". The number alone is the honest resting state.
    @Test func onlyAResolvedPageGetsADot() {
        #expect(PageDiffState.pending.dot == nil)
        #expect(PageDiffState.same.dot == .same)
        #expect(PageDiffState.changed(fraction: 0.2).dot == .changed)
        #expect(PageDiffState.oneSided.dot == .oneSided)
        #expect(PageDiffState.unrenderable.dot == .unrenderable)
    }

    /// Every resolved state has a dot and the pending one does not — asserted as a pair, so a new
    /// state cannot be added with neither.
    @Test func aDotExistsForExactlyTheResolvedStates() {
        let states: [PageDiffState] = [.pending, .same, .changed(fraction: 0.5), .oneSided,
                                       .unrenderable]
        for state in states {
            #expect((state.dot != nil) == state.isResolved, "\(state)")
        }
    }

    // MARK: Nothing to draw — waiting, or never

    /// **A spinner means "wait", and it was shown for pages that were never going to arrive.** A
    /// raster that cannot be built — a corrupt JPEG, an encrypted PDF — left the pixel modes
    /// spinning for the life of the surface while the page strip a few points below had already
    /// resolved the same page to `.unrenderable`.
    @Test func aFailedSideIsToldAboutRatherThanWaitedFor() {
        let outcome = PairRenderOutcome.failed(left: true, right: false)
        #expect(outcome.fallback(for: .left, name: "scan.jpg")
                == .message("“scan.jpg” could not be rendered."))
        #expect(outcome.fallback(for: .right, name: "scan copy.jpg") == .spinner,
                "the side that rendered fine must not be captioned as broken")
    }

    /// While a render is genuinely in flight, the spinner is right — that is the state it was built
    /// for, and removing it would replace one wrong answer with another.
    @Test func aRenderInFlightStillWaits() {
        for outcome in [PairRenderOutcome.rendering, .ready] {
            #expect(outcome.fallback(for: .left, name: "a.png") == .spinner, "\(outcome)")
            #expect(outcome.fallback(for: .right, name: "b.png") == .spinner, "\(outcome)")
            #expect(outcome.differenceMessage(leftName: "a.png", rightName: "b.png") == nil,
                    "\(outcome)")
            #expect(!outcome.didFail, "\(outcome)")
        }
    }

    /// A comparison needs both sides, so one unrenderable side ends it — and the difference view
    /// says which one, rather than leaving an empty black field to be read as "no differences".
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

        /// A real multi-page PDF built through PDFKit — the renderer opens documents, so a
        /// fabricated path would answer nil and every case below would pass vacuously.
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

    /// **The end-to-end claim.** Two documents whose page 1 is the same and whose page 2 differs
    /// must diff as same-then-changed — the whole point of the page strip, and the one assertion
    /// that fails if the render, the normalisation or the loop is wrong anywhere.
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

    /// **The lane holds.** A compare render and another PDFKit reader running together must never
    /// put two parses in flight: `peakConcurrentParses` is 0 or 1 for the life of the process on a
    /// serial lane, and anything above 1 means a second lane exists somewhere.
    @Test func theSerialLaneStillHoldsWithACompareRunning() async throws {
        let fixture = try PDFFixture()
        // Paths, not the fixture: the fixture is a class and holding it in six concurrent tasks
        // is a data race the compiler is right to refuse — its only job here is the files.
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

    /// **Both documents really open, and both panes really get width.** The pieces this asserts
    /// are the ones a screenshot cannot: `PDFView` renders through a layer that
    /// `cacheDisplay(in:to:)` does not capture, so a mounted pair photographs as two empty boxes
    /// whether it is working or not (measured while building this). Reading the views back is the
    /// only way to tell those two apart.
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
        // **`LayoutPumpWait`, not a wall-clock deadline.** The documents arrive on main-actor
        // turns, and under full-package congestion seconds buy very few of them — this test first
        // failed exactly that way, passing in isolation and giving up after 51 seconds in the
        // suite. `docs/flaky-tests.md`, mechanism 2.
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

    /// **Scrolling one pane moves the other — the half that was silently dead.** The scroll
    /// observers were registered in `makeNSView`, where a `PDFView` has no document and therefore
    /// no `documentView`, no scroll view and no clip view: `guard let … else { continue }` found
    /// nil and registered nothing, while the ZOOM half (posted by the view itself) worked and made
    /// the pair look synchronised. Nothing but driving a real scroll could see it.
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
        // Wait for the CLIP VIEWS, not just the documents: the clip view is what the observer
        // needs, and it is the thing that does not exist at construction.
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

    /// **The property a value comparison cannot give.** Two views quantise scroll offsets
    /// differently, so A → B → A′ lands a hair off A, differs again, and the pair walks. The latch
    /// stops the echo at one hop whatever the far side rounds to.
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

    /// …and it re-arms: a latch that stayed closed after one mirror would freeze the pair on its
    /// first scroll, which is the same bug with the sign flipped.
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

    /// The mode switch, in the shape the surface performs it: `panes` switches on the mode, so
    /// leaving side-by-side REMOVES the representable and coming back builds a fresh one. A test
    /// that only ever mounts cannot see anything this is about.
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
        /// What the surface remembers. Recorded rather than only stored, so a test can assert the
        /// report happened at all as well as what came back.
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
        let (loaded, pumps) = await LayoutPumpWait.pump(window, upTo: 5) {
            pdfViews(host).count == 2 && pdfViews(host).allSatisfy { $0.document != nil }
        }
        try #require(loaded, "the pair never loaded (\(pumps) pumps)")
        return pdfViews(host)
    }

    /// **The whole round trip, in the shape the reader performs it.**
    ///
    /// Zoom in to read a table, press `2`–`4` to check the pixel difference, press `1` to come
    /// back. Measured on the unfixed code: 2.01× in, 0.81× out — `autoScales` refits the fresh
    /// mount and the reader's place is gone. The page already survives this by living on the
    /// surface; the zoom is the other half of where they were.
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

    /// **A fresh mount that already carries a zoom applies it, with no further update passes.**
    ///
    /// The mount is static — one `updateNSView`, no observable object nudging it — which is the
    /// configuration that catches the timing. Applied inline in the load completion the zoom is
    /// overwritten: PDFKit performs its own initial fit when the view next lays out, which is after
    /// the assignment returns, and the pane comes up at the fit with `autoScales` already false.
    /// Measured that way at 0.806 against an asked-for 2.0.
    ///
    /// The round-trip test above does NOT catch this — its harness publishes, so a later update
    /// pass re-applies and hides the ordering. Two load completions landing at different moments
    /// hide it too. This is the shape with neither rescue.
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

    /// **A pair the reader never zoomed must keep fitting itself.**
    ///
    /// The notification route failed exactly here: PDFKit posts its own initial fit, the mirror
    /// turns the far pane's `autoScales` off carrying it, and the surface was handed 0.806 as
    /// though it had been chosen — which then pins every later mount at one window's fit.
    @MainActor
    @Test func anUntouchedPairReportsNoZoomAndKeepsFitting() async throws {
        let fixture = try LetterFixture()
        let box = ZoomBox()
        let (host, window) = mountSwitchable(fixture, box: box)
        let panes = try await loadedPanes(host, window)
        // NOT `panes.allSatisfy` — measured, the mirror turns ONE pane's `autoScales` off during
        // load, and which one depends on load ordering. That is exactly why the report is decided
        // by `fittedScale` rather than by the flag; asserting the flag here would be asserting the
        // coin toss.
        try #require(panes.contains { $0.autoScales }, "premise: a pane is still fitting itself")

        box.showingPair = false
        _ = await LayoutPumpWait.pump(window, upTo: 5) { box.zoom != nil }
        #expect(box.zoom == nil,
                "the fit was recorded as a choice (\(box.reports.zooms)) — every later mount is pinned to it")

        box.showingPair = true
        let back = try await loadedPanes(host, window)
        #expect(back.contains { $0.autoScales }, "the fresh pair stopped fitting itself")
    }

    /// **⌥ silences the zoom report, for the reason it silences the page report.**
    ///
    /// With ⌥ held the panes are deliberately apart and there is no single zoom to record; storing
    /// one would hand it to BOTH panes on the next mount, which is what ⌥ exists to prevent.
    @MainActor
    @Test func aZoomSetWhileOptionIsHeldIsNotRecorded() async throws {
        let fixture = try LetterFixture()
        let box = ZoomBox()
        let (host, window) = mountSwitchable(fixture, box: box, syncSuspended: true)
        let panes = try await loadedPanes(host, window)

        panes[0].scaleFactor = panes[0].scaleFactor * 2.5
        _ = await LayoutPumpWait.pump(window, upTo: 2) { false }
        box.showingPair = false

        // Pumped for as long as the round-trip test needs to SEE a report, so this is a waited-out
        // absence rather than a race won by being quick.
        let (recorded, pumps) = await LayoutPumpWait.pump(window, upTo: 5) { box.zoom != nil }
        #expect(!recorded, """
                \(box.reports.zooms) recorded after \(pumps) pumps with ⌥ held — the next mount \
                applies it to both panes, which is what ⌥ forbids
                """)
    }

    // MARK: Scrolling, at the size the reader actually gets

    /// A page-sized document at the pane size the overlay really opens, so the fixture cannot be
    /// the reason the answer comes out favourable: US Letter, the geometry of the pair that
    /// prompted this.
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

    /// **The measurement that named the defect, kept as the test for it.**
    ///
    /// `autoScales` fits the page to the pane, so under `.singlePage` a US Letter page laid out at
    /// 792.0pt inside a 792.0pt clip view: the content fit to the pixel and every scroll gesture
    /// was clamped to nothing. The panes were not failing to scroll TOGETHER — neither of them
    /// could scroll at all, which is what "the PDFs still don't scroll in unison" turned out to
    /// mean. Continuous display is what gives a scroll somewhere to go.
    @MainActor
    @Test func atTheRealPaneSizeThereIsSomethingToScroll() async throws {
        let fixture = try LetterFixture()
        let (host, window) = mountLetterPair(fixture)
        let (loaded, pumps) = await LayoutPumpWait.pump(window, upTo: 5) {
            pdfViews(host).count == 2 && pdfViews(host).allSatisfy { $0.document != nil }
        }
        try #require(loaded, "the pair never loaded (\(pumps) pumps)")
        for pane in pdfViews(host) {
            let documentHeight = try #require(pane.documentView?.frame.height)
            let clipHeight = try #require(pane.documentView?.enclosingScrollView?.contentView.bounds.height)
            #expect(documentHeight > clipHeight + 1, """
                    a pane laid out \(documentHeight)pt of document inside a \(clipHeight)pt clip \
                    view — the content fits, so a scroll gesture has nowhere to go
                    """)
        }
    }

    /// A page the reader lands on is reported to the surface, so the strip and the pixel modes
    /// follow the panes instead of describing the page they left behind.
    ///
    /// **The move is made with `go(to:)` rather than a wheel event, and that is a real limit worth
    /// stating.** Setting a clip view's bounds directly does not make `PDFView` recompute which
    /// page is current — that tracking is PDFKit's, driven by its own scroll handling — so a test
    /// scrolling the clip proves nothing about the reporting path. What this pins is everything
    /// after the view changes page: the notification reaching the observer, the value guard letting
    /// a genuine move through, and the surface hearing it. That PDFKit updates `currentPage` while
    /// a reader scrolls a continuous document is its documented behaviour, and the one link here
    /// that no test in this package can drive.
    @MainActor
    @Test func aPageTheReaderLandsOnIsReportedToTheSurface() async throws {
        let fixture = try LetterFixture()
        let reports = PageReports()
        let (host, window) = mountLetterPair(fixture, pageReports: reports)
        let (loaded, _) = await LayoutPumpWait.pump(window, upTo: 5) {
            pdfViews(host).count == 2 && pdfViews(host).allSatisfy { $0.document != nil }
        }
        try #require(loaded, "the pair never loaded")
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

    /// **⌥ has to silence the report, not only the scroll mirror.**
    ///
    /// While ⌥ is held the two viewers stop mirroring so one pane can be moved alone — the promise
    /// the Help book makes in those words. A report is not a mirror though: it is a message to the
    /// surface, and the surface owns the page for BOTH panes. So a ⌥-held scroll crossing a page
    /// boundary reported it, the surface set its page, and its next update drove the other pane
    /// there — the one thing ⌥ exists to prevent, arriving by the long way round. Invisible in
    /// review because the scroll offsets really had stopped mirroring; only whole pages jumped.
    @MainActor
    @Test func aPageLandedOnWhileOptionIsHeldIsNotReported() async throws {
        let fixture = try LetterFixture()
        let reports = PageReports()
        let (host, window) = mountLetterPair(fixture, pageReports: reports, syncSuspended: true)
        let (loaded, _) = await LayoutPumpWait.pump(window, upTo: 5) {
            pdfViews(host).count == 2 && pdfViews(host).allSatisfy { $0.document != nil }
        }
        try #require(loaded, "the pair never loaded")

        let pane = pdfViews(host)[0]
        let document = try #require(pane.document)
        pane.go(to: try #require(document.page(at: 1)))

        // Pumped for as long as the positive control above needs to SEE a report, so this is a
        // waited-out absence rather than a race won by being quick.
        let (reported, pumps) = await LayoutPumpWait.pump(window, upTo: 5) {
            reports.pages.contains(1)
        }
        #expect(!reported, """
                page 2 was reported after \(pumps) pumps with ⌥ held \(reports.pages) — the \
                surface will drive the other pane there, which is what ⌥ forbids
                """)
    }

    /// **The echo has to stop.** Both views post when the page changes, and the surface moving the
    /// page moves both — so a report that merely repeats what the surface asked for must not come
    /// back, or the strip and the panes push each other in a loop.
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
        let (loaded, _) = await LayoutPumpWait.pump(window, upTo: 5) {
            pdfViews(host).count == 2 && pdfViews(host).allSatisfy { $0.document != nil }
        }
        try #require(loaded, "the pair never loaded")
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

    /// **A page turn during the open used to be dropped on the floor.** The load captured the page
    /// index at the moment it was queued, and `go` — the only other way in — bails while
    /// `document` is still nil. So a turn arriving in between reached neither: the strip pointed
    /// at page 2 and both panes sat on page 1 until the next turn. The window is real, and it is
    /// widest exactly when the strip is most worth clicking: a scan holding the PDFKit lane makes
    /// the open slow while the strip is already interactive.
    ///
    /// The turn is made BEFORE any await, so no document can have arrived yet — the require below
    /// says so rather than assuming it, because a test that turned the page after the load would
    /// pass through the ordinary `go` path and prove nothing.
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
        // asserted with it — two panes exist, and neither has a document yet.
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
/// **The `PDFView`s are reused across a path change**, so their clip views can be the very same
/// objects: a second registration on one clip mirrors every scroll twice. The latch collapses the
/// duplicate, which is precisely why this was invisible — the effect was right and the registration
/// count grew by two per pair opened.
///
/// Driven on a bare `Coordinator` against real `NotificationCenter` observers, so it measures the
/// bookkeeping itself rather than a PDF pair's rendering.
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

    /// The lifetime list is disjoint from the scroll list, so a re-wire cannot strand a token in
    /// it. Asserted by identity: a scroll observer appearing in `observers` is a token the re-wire
    /// removes from the centre and the coordinator then retains for the life of the view.
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
