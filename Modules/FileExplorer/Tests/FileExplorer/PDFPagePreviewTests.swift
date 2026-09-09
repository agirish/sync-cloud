import Testing
import Foundation
import UniformTypeIdentifiers
@testable import FileExplorer

/// The two rules behind the PDF preview: which files it draws, and how big a page comes out.
///
/// Both are pure, and both were defects in the shipped behaviour rather than gaps. Quick Look scales
/// a PDF page to the preview's WIDTH and lets the height overflow, so widening the preview showed
/// LESS of the page — measured, a letter page in an 820pt-wide, 560pt-tall preview rendered about
/// 1060pt tall, i.e. the top third and nothing else. The rendering itself can only be judged by eye,
/// but which renderer runs and what scale it picks are exactly the parts that would fail silently:
/// a page fitted to the wrong dimension still looks like a working preview.
@Suite struct PDFPagePreviewTests {

    // MARK: - Which renderer

    @Test func testAPDFIsDrawnByPDFKit() {
        #expect(PreviewRenderer.forType(.pdf) == .pdfPages)
    }

    /// Everything Quick Look already handles well stays with Quick Look. Images are the measured
    /// case — a 900×2400 PNG in a 500×560 preview came out whole, both ends visible — and text opens
    /// in a scrolling text view.
    @Test func testEveryOtherTypeStaysWithQuickLook() {
        for type: UTType in [.png, .jpeg, .plainText, .movie, .rtf, .zip] {
            #expect(PreviewRenderer.forType(type) == .quickLook, "\(type.identifier)")
        }
    }

    /// An unresolved type is Quick Look's, not PDFKit's. The fallback has to point at the renderer
    /// that can draw anything, because "we could not tell what this is" is not a reason to hand it to
    /// the one renderer that only understands one format.
    @Test func testAnUnknownTypeStaysWithQuickLook() {
        #expect(PreviewRenderer.forType(nil) == .quickLook)
    }

    // MARK: - The type a preview item carries

    @Test func testTheItemsTypeComesFromTheWalksIdentifier() {
        #expect(ColumnPreviewItem.type(uti: "com.adobe.pdf", path: "/x/report.pdf") == .pdf)
    }

    /// **The fallback is load-bearing, not decoration.** `FileNode.kind` is a resource-value read
    /// that a deferred column listing can skip, so a PDF can reach the preview with no type at all —
    /// and without this it would be drawn by the very renderer this change exists to replace.
    /// The second case is the one that reads like a trick and is not: `UTType("dyn.…")` SUCCEEDS.
    /// The system mints a placeholder type for an identifier it does not recognise instead of
    /// returning nil, so an unrecognised identifier has to be rejected explicitly or it shadows the
    /// extension that still knows what the file is.
    @Test func testTheItemsTypeFallsBackToTheExtension() {
        #expect(ColumnPreviewItem.type(uti: nil, path: "/x/report.pdf") == .pdf)
        #expect(UTType("dyn.ah62d4rv4ge8086dcta")?.isDynamic == true, "the premise: this resolves")
        #expect(ColumnPreviewItem.type(uti: "dyn.ah62d4rv4ge8086dcta", path: "/x/report.pdf") == .pdf)
    }

    /// A path with nothing to go on resolves to nothing, which `PreviewRenderer` reads as Quick
    /// Look's.
    @Test func testAnExtensionlessPathResolvesToNoType() {
        #expect(ColumnPreviewItem.type(uti: nil, path: "/x/README") == nil)
        #expect(PreviewRenderer.forType(ColumnPreviewItem.type(uti: nil, path: "/x/README"))
                == .quickLook)
    }

    // MARK: - How big the page comes out

    private let letter = CGSize(width: 612, height: 792)

    /// The defect, stated as arithmetic. In a preview far wider than it is tall, fitting on WIDTH
    /// would scale a letter page past the height and push most of it below the fold; the whole-page
    /// rule takes the height instead.
    @Test func testAWidePreviewFitsThePageOnHeight() {
        let view = CGSize(width: 820, height: 560)
        let scale = PDFPageFit.scale(pageSize: letter, viewSize: view)
        let fitsHeight: CGFloat = 560.0 / 792.0
        #expect(scale == fitsHeight)
        // The whole page is inside the view, which is the property that matters — both dimensions,
        // not just the one the scale was taken from.
        #expect(letter.height * scale <= view.height)
        #expect(letter.width * scale <= view.width)
        // And it is strictly smaller than fitting on width would have been — the regression guard.
        #expect(scale < view.width / letter.width)
    }

    /// The other side of the same rule: a narrow preview is width-bound, and the page still fits
    /// whole.
    @Test func testANarrowPreviewFitsThePageOnWidth() {
        let view = CGSize(width: 388, height: 560)
        let scale = PDFPageFit.scale(pageSize: letter, viewSize: view)
        let fitsWidth: CGFloat = 388.0 / 612.0
        #expect(scale == fitsWidth)
        #expect(letter.width * scale <= view.width)
        #expect(letter.height * scale <= view.height)
    }

    /// A small page is shown at its own size rather than blown up to fill the pane — a receipt or a
    /// business card rendered a metre tall is not "fitting the page".
    @Test func testASmallPageIsNeverEnlarged() {
        let card = CGSize(width: 252, height: 144)
        #expect(PDFPageFit.scale(pageSize: card, viewSize: CGSize(width: 900, height: 700)) == 1)
    }

    /// A view mid-layout has a zero dimension, and a scale of 0 makes PDFKit draw nothing at all —
    /// which reads as a preview that failed to load rather than one that has not been laid out yet.
    @Test func testAZeroSizedViewOrPageYieldsAUsableScale() {
        #expect(PDFPageFit.scale(pageSize: letter, viewSize: CGSize(width: 0, height: 560)) == 1)
        #expect(PDFPageFit.scale(pageSize: letter, viewSize: CGSize(width: 400, height: 0)) == 1)
        #expect(PDFPageFit.scale(pageSize: .zero, viewSize: CGSize(width: 400, height: 560)) == 1)
    }
}
