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
    @Test func everyModesDigitRoundTrips() {
        for mode in ComparePairMode.allCases {
            #expect(ComparePairMode.forDigit(mode.digit) == mode)
        }
        #expect(ComparePairMode.forDigit(0) == nil)
        #expect(ComparePairMode.forDigit(5) == nil)
    }

    /// A kind with no raster gets exactly one mode, and the surface then draws no segmented
    /// control at all — a one-segment picker is a control that cannot be used.
    @Test func onlyRasterKindsGetTheFullModeSet() {
        #expect(ComparePairMode.available(for: .pdf).count == 4)
        #expect(ComparePairMode.available(for: .image).count == 4)
        #expect(ComparePairMode.available(for: .text) == [.sideBySide])
        #expect(ComparePairMode.available(for: .other) == [.sideBySide])
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
        let deadline = Date().addingTimeInterval(3)
        func views(_ v: NSView) -> [PDFView] {
            v.subviews.flatMap { [$0].compactMap { $0 as? PDFView } + views($0) }
        }
        while Date() < deadline {
            window.layoutIfNeeded()
            if views(host).allSatisfy({ $0.document != nil }), views(host).count == 2 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let pdfs = views(host)
        #expect(pdfs.count == 2, "expected two PDF panes, found \(pdfs.count)")
        #expect(pdfs.allSatisfy { $0.document?.pageCount == 2 },
                "a document did not open: \(pdfs.map { $0.document?.pageCount ?? -1 })")
        for pane in pdfs {
            #expect(pane.frame.width > 300, "a pane laid out at \(pane.frame.width)pt")
            #expect(pane.frame.height > 400)
        }
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
}
