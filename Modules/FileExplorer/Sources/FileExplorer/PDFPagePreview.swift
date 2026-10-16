import AppKit
import PDFKit
import SwiftUI
import Sync
import UniformTypeIdentifiers

/// Which renderer draws a previewable file.
///
/// A rule rather than a branch inside the view, because the answer is a policy about file types and
/// the view it decides is a hosted AppKit view that no test can read the intent out of.
///
/// **Quick Look is still the default and stays the default.** It is the same renderer the Quick Look
/// panel uses, and for everything measured it does the right thing: an image is scaled so the whole
/// image is visible, text opens in a scrolling text view, video gets its own controls, and none of
/// that requires this app to know anything about those formats.
///
/// PDFs are the exception, and it is a measured one. Quick Look scales a PDF page to fit the preview's
/// WIDTH and lets the height overflow, so the wider the preview the more zoomed-in the page: at 388pt
/// a letter page fitted almost exactly, and at 820pt the same page rendered ~1060pt tall in a 560pt
/// view, showing the top third and nothing else. That is the wrong way round — widening a preview
/// should show you more of a page, not less — and the remote view offers no way to reach the rest.
/// PDFKit renders in-process, so the fit and the scrolling are ours to set; see `FitPagePDFView`.
///
/// Only PDFs, deliberately. Other paged formats (Pages, Word, Keynote) are drawn by their own Quick
/// Look extensions, out of process, and this app has no renderer for them to switch to.
enum PreviewRenderer: Equatable, Sendable {
    /// PDFKit, fitted to the page and scrolling through the document.
    case pdfPages
    /// Quick Look, as before.
    case quickLook

    /// `conforms(to:)` rather than `== .pdf`, so a format that declares itself a kind of PDF is drawn
    /// as one. No system type currently conforms to `public.pdf` other than itself — Illustrator's
    /// does not, checked — so there is nothing to pin this half with, and it is stated here rather
    /// than left as an unexplained looser test.
    ///
    /// An unresolved type is Quick Look's. The fallback has to name the renderer that can draw
    /// anything: "we could not tell what this is" is not a reason to hand a file to the one renderer
    /// that understands a single format.
    static func forType(_ type: UTType?) -> PreviewRenderer {
        guard let type, type.conforms(to: .pdf) else { return .quickLook }
        return .pdfPages
    }
}

/// How a PDF page is sized inside the preview.
///
/// Pure so the sizing can be asserted without a rendered document — the interesting cases are the two
/// the bug was about, and neither is convenient to stage in a view.
enum PDFPageFit {
    /// The scale at which a whole page fits, both dimensions inside the view.
    ///
    /// The `min` of the two ratios is the entire rule: fitting on width alone is what Quick Look does
    /// and what leaves a letter page overflowing a short pane by several hundred points. Whichever
    /// dimension is tighter decides, so the page is always wholly visible and the slack falls in the
    /// other direction as margins.
    ///
    /// Capped at 1 so a small page is never blown up past its natural size — a business-card PDF in a
    /// wide pane should not be rendered a metre tall — and floored above zero so a view mid-layout
    /// (either dimension still 0) cannot produce a scale of 0, which PDFKit treats as a request to
    /// draw nothing at all.
    static func scale(pageSize: CGSize, viewSize: CGSize) -> CGFloat {
        guard pageSize.width > 0, pageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return 1 }
        return min(1, min(viewSize.width / pageSize.width, viewSize.height / pageSize.height))
    }
}

/// A `PDFView` that keeps a whole page in view as the pane is resized.
///
/// `autoScales` is deliberately off. PDFKit's own auto-scaling fits the WIDTH in a continuous display
/// mode, which is precisely the behaviour being replaced — so the scale is set here instead, from
/// `PDFPageFit.scale`.
///
/// **Refitted on a size change, not on every layout pass.** A pass runs for reasons that are nothing
/// to do with the pane's size — a scroll, a first responder change — and re-imposing the fit on each
/// one would undo a zoom the reader had just made with ⌘+ or a pinch. Tracking the size the fit was
/// last computed for keeps the two apart: resize the pane and the page fits again, zoom in and it
/// stays zoomed until you do.
final class FitPagePDFView: PDFView {
    private var fittedSize: CGSize?

    /// Refit on the next layout even if the size has not changed — for a newly assigned document,
    /// whose page size is a different question from the view's.
    func invalidateFit() { fittedSize = nil }

    override func layout() {
        super.layout()
        clearInheritedBackground()
        guard bounds.size != fittedSize, bounds.width > 0, bounds.height > 0,
              let page = currentPage ?? document?.page(at: 0)
        else { return }
        fittedSize = bounds.size
        let pageSize = page.bounds(for: displayBox).size
        scaleFactor = PDFPageFit.scale(pageSize: pageSize, viewSize: bounds.size)
    }

    /// Stops the view painting a slab behind the page, so the pane's own surface shows around it.
    ///
    /// **`backgroundColor = .clear` alone does not do it.** The area around a page is drawn by
    /// PDFKit's own enclosing `NSScrollView`, which draws its background independently and comes up
    /// white — so a PDF sat in a bright rectangle while every other preview blended into the pane,
    /// and in dark mode that rectangle would be the brightest thing in the window. Both have to be
    /// turned off: this one for the area the page does not cover, `backgroundColor` for the view
    /// itself.
    ///
    /// Applied from `layout()` rather than once at construction because the scroll view is PDFKit's,
    /// not ours: it is not necessarily present when the view is created, and it is not this code's
    /// to assume PDFKit leaves the flag alone across a document change. Both writes are idempotent
    /// and neither invalidates anything, so re-asserting them per pass costs a comparison.
    func clearInheritedBackground() {
        backgroundColor = .clear
        for case let scroll as NSScrollView in subviews where scroll.drawsBackground {
            scroll.drawsBackground = false
        }
    }
}

/// A PDF in the preview pane: the whole page, scrolling through the document.
///
/// `.singlePageContinuous` is what makes a scroll walk the document rather than stop at the end of
/// page one, and it is the mode the reader is asking for when they scroll a preview at all. Page
/// breaks are drawn so the boundary between two pages is visible rather than being an unexplained
/// seam.
///
/// The scrollers are `PDFView`'s own, in this process, which is the other half of what this fixes:
/// the Quick Look path renders in an `NSRemoteView` whose scrolling is the extension's business and
/// not reachable from here.
///
/// **The document is opened through `PDFKitSerialAccess`, never on the main actor** — the same rule
/// as `PDFPairView`, for the same two reasons. `PDFDocument(url:)` parses, and a large PDF parsed
/// inline is a main-thread stall per selection. And PDFKit's parsing is not thread-safe: a preview
/// opened beside the lane could overlap a duplicate scan's or a document survey's extraction, which
/// is the overlap the lane's 4.5–6.3% measurement is about. So the view mounts empty and the page
/// arrives when the lane has parsed it.
struct PDFPagePreview: NSViewRepresentable {
    let url: URL

    /// What the view has asked the lane for, so a load that comes back can be checked against it.
    @MainActor
    final class Coordinator {
        /// The URL most recently requested. **Latest request wins**: a load that finishes for any
        /// other URL is dropped, never assigned — otherwise a slow open of the previous file could
        /// land after the current one and put the wrong document under the current file's name.
        var requested: URL?
        /// Set by `dismantleNSView`, so a load still in the lane when the view goes does nothing.
        var isDismantled = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FitPagePDFView {
        let view = FitPagePDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.displayDirection = .vertical
        // The pane paints its own surface behind this — see `clearInheritedBackground`, which is
        // where the rest of that happens and why one line here is not enough.
        view.clearInheritedBackground()
        load(url, into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: FitPagePDFView, context: Context) {
        // Guarded for the reason `QuickLookPreview.updateNSView` is: this runs on every ancestor
        // re-render, and re-reading a document rebuilds every page and throws away the reader's
        // scroll position.
        //
        // **Against the REQUESTED url, not `view.document?.documentURL`.** While a load is in the
        // lane the view has no document, so the document's URL would read as "not this one" on
        // every re-render and queue a fresh parse each time — and the same for a file that fails
        // to open, which never gets a document at all.
        guard context.coordinator.requested != url else { return }
        load(url, into: view, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ view: FitPagePDFView, coordinator: Coordinator) {
        // A `PDFDocument` holds the file open; dropping it with the view keeps a preview walk from
        // leaving one descriptor per file behind. The flag stops a load still in the lane from
        // handing one straight back.
        coordinator.isDismantled = true
        view.document = nil
    }

    /// Opens `url` in the lane and hands the document to `view` — if it is still the one wanted.
    @MainActor
    private func load(_ url: URL, into view: FitPagePDFView, coordinator: Coordinator) {
        // A different file's document comes down now rather than when the new one lands: a page
        // from the previous selection sitting under the new file's name, even briefly, is a wrong
        // preview, and it releases that file's descriptor sooner.
        if coordinator.requested != nil { view.document = nil }
        coordinator.requested = url
        Task { @MainActor [weak view] in
            let opened = await PDFKitSerialAccess.perform {
                PDFDocument(url: url).map(SendableDocument.init)
            }
            guard let view, !coordinator.isDismantled, coordinator.requested == url else { return }
            view.document = opened?.document
            // The document arrives after the first layout pass, so the fit computed then was for no
            // page at all — and `layout()` refits only on a size change unless told otherwise.
            view.invalidateFit()
            view.needsLayout = true
        }
    }
}
