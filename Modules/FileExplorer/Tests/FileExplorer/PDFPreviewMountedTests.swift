import AppKit
import PDFKit
import Quartz
import SwiftUI
import Sync
import Testing
import UniformTypeIdentifiers
@testable import FileExplorer

/// The PDF preview as the pane actually mounts it — the half `PDFPagePreviewTests` cannot see.
///
/// Those tests pin the rules. These pin that the rules are wired to a real view: that a PDF reaches
/// PDFKit and everything else still reaches Quick Look, that the page laid out is a WHOLE page, and
/// that the document under it can be scrolled. Every number below is read off laid-out AppKit views,
/// never from the constants that produced them — which matters most for the scroll, because "there
/// is a scroll view" and "it has somewhere to scroll to" are different claims and only the second is
/// the complaint this change answers.
@MainActor
@Suite struct PDFPreviewMountedTests {

    /// A real multi-page PDF and a real image, because both renderers read the file.
    private final class Fixture {
        let root: String
        let pdf: String
        let png: String
        /// US Letter, the shape the fit rule is most often asked about.
        static let pageSize = CGSize(width: 612, height: 792)
        static let pageCount = 5

        init() throws {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("PDFPreviewMounted-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            root = dir.path

            let doc = PDFDocument()
            for index in 0..<Self.pageCount {
                let image = NSImage(size: Self.pageSize)
                image.lockFocus()
                NSColor.white.setFill()
                NSRect(origin: .zero, size: Self.pageSize).fill()
                ("Page \(index + 1)" as NSString).draw(
                    at: NSPoint(x: 40, y: 700),
                    withAttributes: [.font: NSFont.boldSystemFont(ofSize: 44)])
                image.unlockFocus()
                if let page = PDFPage(image: image) { doc.insert(page, at: index) }
            }
            pdf = dir.appendingPathComponent("report.pdf").path
            doc.write(toFile: pdf)

            let art = NSImage(size: NSSize(width: 200, height: 200))
            art.lockFocus()
            NSColor.systemGreen.setFill()
            NSRect(x: 0, y: 0, width: 200, height: 200).fill()
            art.unlockFocus()
            let rep = NSBitmapImageRep(data: art.tiffRepresentation!)!
            png = dir.appendingPathComponent("art.png").path
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: png))
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }
    }

    private func item(_ path: String, uti: String?) -> ColumnPreviewItem {
        ColumnPreviewItem(row: PaneRow(
            side: .left, version: 1,
            node: FileNode(id: path, name: (path as NSString).lastPathComponent,
                           isDirectory: false, fileSize: 1, kind: uti),
            children: nil))
    }

    /// Mounts the preview column itself, so what is measured is the pane's own choice of renderer
    /// rather than a view this test picked.
    private func mount(_ item: ColumnPreviewItem, width: CGFloat, height: CGFloat)
    -> (window: NSWindow, host: NSView) {
        let host = NSHostingView(rootView: ColumnPreviewColumn(
            item: item,
            paneToken: PaneToken(isLeft: true, isSingleSource: true),
            isAwaitingDownload: false,
            downloadChannel: NotificationCenter()))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        return (window, host)
    }

    private func descendants(of view: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ v: NSView) { found.append(v); v.subviews.forEach(walk) }
        walk(view)
        return found
    }

    private func pdfView(in view: NSView) -> FitPagePDFView? {
        descendants(of: view).compactMap { $0 as? FitPagePDFView }.first
    }

    private func quickLookViews(in view: NSView) -> [QLPreviewView] {
        descendants(of: view).compactMap { $0 as? QLPreviewView }
    }

    /// Waits for a condition on the shared pumping loop — the preview is held back by
    /// `previewSettleDelay`, and what it waits on arrives on main-actor turns rather than on a clock.
    private func wait(_ window: NSWindow, upTo seconds: Double,
                      for condition: () -> Bool) async -> (held: Bool, pumps: Int) {
        await LayoutPumpWait.pump(window, upTo: seconds, until: condition)
    }

    /// A PDF is drawn by PDFKit, in this process — which is the whole point, because the Quick Look
    /// path renders in an `NSRemoteView` whose scrolling and scale belong to the extension.
    @Test func testAPDFIsMountedInPDFKitAndNotInQuickLook() async throws {
        let fixture = try Fixture()
        let mounted = mount(item(fixture.pdf, uti: UTType.pdf.identifier), width: 820, height: 700)
        let settled = await wait(mounted.window, upTo: 10) { pdfView(in: mounted.host) != nil }
        try #require(settled.held, "no PDF view after \(settled.pumps) layout passes")
        #expect(quickLookViews(in: mounted.host).isEmpty,
                "the file reached Quick Look as well — both renderers are mounted")
    }

    /// And everything else still is not. The image is the measured case: Quick Look already shows a
    /// whole image, so moving it would be a change with nothing to gain.
    @Test func testAnImageStillGoesToQuickLook() async throws {
        let fixture = try Fixture()
        let mounted = mount(item(fixture.png, uti: UTType.png.identifier), width: 820, height: 700)
        let settled = await wait(mounted.window, upTo: 10) { !quickLookViews(in: mounted.host).isEmpty }
        try #require(settled.held, "no Quick Look view after \(settled.pumps) layout passes")
        #expect(pdfView(in: mounted.host) == nil)
    }

    /// **The defect, measured on the laid-out view.** In a preview far wider than it is tall, the page
    /// must still be whole: Quick Look fitted it to the width and rendered a letter page about 1060pt
    /// tall inside 560pt, showing the top third.
    ///
    /// The assertion is on the page's size in the view's own coordinates, which is what the reader
    /// sees — not on `scaleFactor`, which is the input to it.
    @Test func testAWidePreviewShowsAWholePage() async throws {
        let fixture = try Fixture()
        let mounted = mount(item(fixture.pdf, uti: UTType.pdf.identifier), width: 820, height: 700)
        let settled = await wait(mounted.window, upTo: 10) {
            (pdfView(in: mounted.host)?.scaleFactor ?? 0) > 0 && pdfView(in: mounted.host)?.document != nil
        }
        try #require(settled.held, "the PDF never laid out (\(settled.pumps) passes)")
        let view = try #require(pdfView(in: mounted.host))

        let drawn = CGSize(width: Fixture.pageSize.width * view.scaleFactor,
                           height: Fixture.pageSize.height * view.scaleFactor)
        #expect(drawn.height <= view.bounds.height,
                "the page is \(drawn.height)pt tall in a \(view.bounds.height)pt view — it is cut off")
        #expect(drawn.width <= view.bounds.width)
        // Height-bound at this shape, which is exactly where fitting on width goes wrong.
        #expect(drawn.height > view.bounds.height - 1)
    }

    /// The same page in a narrow preview: whole again, and width-bound this time. Both shapes,
    /// because a rule that fitted only one of them would look correct in whichever the author tried.
    @Test func testANarrowPreviewShowsAWholePage() async throws {
        let fixture = try Fixture()
        let mounted = mount(item(fixture.pdf, uti: UTType.pdf.identifier), width: 420, height: 900)
        let settled = await wait(mounted.window, upTo: 10) {
            (pdfView(in: mounted.host)?.scaleFactor ?? 0) > 0 && pdfView(in: mounted.host)?.document != nil
        }
        try #require(settled.held, "the PDF never laid out (\(settled.pumps) passes)")
        let view = try #require(pdfView(in: mounted.host))

        let drawn = CGSize(width: Fixture.pageSize.width * view.scaleFactor,
                           height: Fixture.pageSize.height * view.scaleFactor)
        #expect(drawn.width <= view.bounds.width,
                "the page is \(drawn.width)pt wide in a \(view.bounds.width)pt view")
        #expect(drawn.height <= view.bounds.height)
    }

    /// **Nothing paints a slab behind the page.** The preview sits on the pane's own surface, and a
    /// PDF that brought its own white rectangle was the one file type that did not blend into it —
    /// in dark mode that rectangle would be the brightest thing in the window.
    ///
    /// Both halves are asserted because turning off only one leaves the slab: `backgroundColor`
    /// governs the view, and PDFKit's own enclosing scroll view draws the area around the page
    /// independently and comes up white.
    @Test func testThePageSitsOnThePanesSurfaceRatherThanAWhiteSlab() async throws {
        let fixture = try Fixture()
        let mounted = mount(item(fixture.pdf, uti: UTType.pdf.identifier), width: 820, height: 700)
        let settled = await wait(mounted.window, upTo: 10) { pdfView(in: mounted.host) != nil }
        try #require(settled.held, "no PDF view after \(settled.pumps) layout passes")
        let view = try #require(pdfView(in: mounted.host))

        #expect(view.backgroundColor.alphaComponent == 0,
                "the PDF view paints its own background")
        let scroll = try #require(descendants(of: view).compactMap { $0 as? NSScrollView }.first)
        #expect(scroll.drawsBackground == false,
                "PDFKit's scroll view still fills the area around the page")
    }

    /// **There is somewhere to scroll to, and it is the rest of the document.** The complaint this
    /// answers is not "the scroll bar is missing" but "scrolling gets me nothing", so the assertion
    /// is that the scrolling content is taller than what is on screen by about the four pages that
    /// are off it — a single-page display mode would pass a mere "a scroll view exists" check.
    @Test func testTheWholeDocumentIsScrollable() async throws {
        let fixture = try Fixture()
        let mounted = mount(item(fixture.pdf, uti: UTType.pdf.identifier), width: 820, height: 700)
        let settled = await wait(mounted.window, upTo: 10) {
            (pdfView(in: mounted.host)?.scaleFactor ?? 0) > 0 && pdfView(in: mounted.host)?.document != nil
        }
        try #require(settled.held, "the PDF never laid out (\(settled.pumps) passes)")
        let view = try #require(pdfView(in: mounted.host))
        #expect(view.displayMode == .singlePageContinuous,
                "a paged mode scrolls within one page — the document is not reachable")

        let scroll = try #require(descendants(of: view).compactMap { $0 as? NSScrollView }.first)
        let content = try #require(scroll.documentView).frame.height
        let visible = scroll.documentVisibleRect.height
        #expect(content > visible * 2,
                "the document is \(content)pt against a \(visible)pt viewport — \(Fixture.pageCount) pages should be far more")

        // And it really moves. Scroll toward the ORIGIN rather than the end: a PDF's pages are laid
        // out bottom-up in an unflipped scroll view, so the viewport opens at the top of the document
        // and therefore at the scroller's MAXIMUM. Asking it to go further down is a no-op, and a
        // test written that way fails on a scroll view that works perfectly.
        let before = scroll.documentVisibleRect.origin.y
        #expect(before > visible, "the viewport did not open at the top of the document")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.documentVisibleRect.origin.y < before - 1,
                "the clip view did not move — there is a scroll view but nothing scrolls")
    }
}
