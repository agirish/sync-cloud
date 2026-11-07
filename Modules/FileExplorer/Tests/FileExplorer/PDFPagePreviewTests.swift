import Testing
import Foundation
import UniformTypeIdentifiers
@testable import FileExplorer

/// The two rules behind the PDF preview: which files it draws, and how big a page comes out.
///
/// Quick Look scales a PDF page to the preview's width and lets the height overflow, so a wider
/// preview shows less of the page (a letter page in an 820×560pt preview renders about 1060pt
/// tall). The drawing can only be judged by eye, but which renderer runs and what scale it picks
/// would fail silently: a page fitted to the wrong dimension still looks like a working preview.
@Suite struct PDFPagePreviewTests {

    // MARK: - Which renderer

    @Test func testAPDFIsDrawnByPDFKit() {
        #expect(PreviewRenderer.forType(.pdf) == .pdfPages)
    }

    /// Everything Quick Look already handles well stays with it: images come out whole (a 900×2400
    /// PNG in a 500×560 preview shows both ends), and text opens in a scrolling text view.
    @Test func testEveryOtherTypeStaysWithQuickLook() {
        for type: UTType in [.png, .jpeg, .plainText, .movie, .rtf, .zip] {
            #expect(PreviewRenderer.forType(type) == .quickLook, "\(type.identifier)")
        }
    }

    /// An unresolved type is Quick Look's, not PDFKit's: the fallback must be the renderer that can
    /// draw anything, not the one that understands a single format.
    @Test func testAnUnknownTypeStaysWithQuickLook() {
        #expect(PreviewRenderer.forType(nil) == .quickLook)
    }

    // MARK: - The type a preview item carries

    @Test func testTheItemsTypeComesFromTheWalksIdentifier() {
        #expect(ColumnPreviewItem.type(uti: "com.adobe.pdf", path: "/x/report.pdf") == .pdf)
    }

    /// The extension fallback matters: `FileNode.kind` is a resource-value read a deferred column
    /// listing can skip, so a PDF can arrive with no type and would go to Quick Look. And
    /// `UTType("dyn.…")` succeeds: the system mints a placeholder type for an unknown identifier
    /// rather than returning nil, so it must be rejected explicitly or it shadows the extension.
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

    /// In a preview far wider than tall, fitting on width would scale a letter page past the height
    /// and push most of it below the fold; the whole-page rule takes the height instead.
    @Test func testAWidePreviewFitsThePageOnHeight() {
        let view = CGSize(width: 820, height: 560)
        let scale = PDFPageFit.scale(pageSize: letter, viewSize: view)
        let fitsHeight: CGFloat = 560.0 / 792.0
        #expect(scale == fitsHeight)
        // The whole page is inside the view, in both dimensions, not just the one the scale came
        // from.
        #expect(letter.height * scale <= view.height)
        #expect(letter.width * scale <= view.width)
        // And strictly smaller than fitting on width would be.
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

    /// A small page is shown at its own size rather than blown up to fill the pane: a receipt or a
    /// business card a metre tall is not "fitting the page".
    @Test func testASmallPageIsNeverEnlarged() {
        let card = CGSize(width: 252, height: 144)
        #expect(PDFPageFit.scale(pageSize: card, viewSize: CGSize(width: 900, height: 700)) == 1)
    }

    /// A view mid-layout has a zero dimension, and a scale of 0 makes PDFKit draw nothing, which
    /// reads as a preview that failed to load rather than one not laid out yet.
    @Test func testAZeroSizedViewOrPageYieldsAUsableScale() {
        #expect(PDFPageFit.scale(pageSize: letter, viewSize: CGSize(width: 0, height: 560)) == 1)
        #expect(PDFPageFit.scale(pageSize: letter, viewSize: CGSize(width: 400, height: 0)) == 1)
        #expect(PDFPageFit.scale(pageSize: .zero, viewSize: CGSize(width: 400, height: 560)) == 1)
    }

    // MARK: - What the icon says when there is no page

    /// The caption under a PDF preview's icon: silent while the page is a moment away, the reason
    /// once it is not coming, and nothing at all once it is shown.
    @Test func aPDFsCaptionNamesWhyThereIsNoPage() {
        #expect(ColumnPreviewColumn.pdfCaption(nil) == nil,
                "a caption while the page is still opening would flash on every selection")
        #expect(ColumnPreviewColumn.pdfCaption(.opened) == nil)
        #expect(ColumnPreviewColumn.pdfCaption(.unreadable) == "This PDF can’t be opened")
        #expect(ColumnPreviewColumn.pdfCaption(.locked) == "This PDF is password-protected")
    }
}
