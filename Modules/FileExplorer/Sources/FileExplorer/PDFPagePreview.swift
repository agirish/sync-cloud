import AppKit
import Events
import os
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

/// What became of a preview's open, reported to whoever mounted it.
enum PDFOpenOutcome: Equatable, Sendable {
    /// The document is in the view.
    case opened
    /// PDFKit could not read it, or it has no pages: damaged, not really a PDF, or gone between the
    /// column's probe and the parse.
    case unreadable
    /// It opened, but shows nothing until a password is given — which a preview never asks for.
    case locked
}

/// A PDF in the preview pane, with something to look at until the page is there.
///
/// The page arrives from `PDFKitSerialAccess` a moment after the view mounts — longer while a scan
/// is extracting text in the same lane — and an empty `PDFView` paints nothing at all, so without
/// this the pane went blank between the column's icon and the page. `placeholder` stands behind the
/// view until the page lands, and stays, with the outcome to caption, if it never does.
///
/// **The outcome is this mount's own `@State`.** The column mounts a fresh preview per selection, so
/// a result can never outlive the file it was for: walk A → B → A and the second A starts with no
/// outcome, showing the placeholder while it loads, rather than inheriting the first A's `.opened`
/// and leaving a blank pane until the parse lands.
struct PDFPagePreview<Placeholder: View>: View {
    let url: URL
    /// What stands behind the page: given nil while the open is in flight, and the outcome when it
    /// failed. Not shown at all once the page is in — the page does not cover the whole view, so a
    /// placeholder left behind it would show around its edges.
    @ViewBuilder let placeholder: (PDFOpenOutcome?) -> Placeholder

    @State private var outcome: PDFOpenOutcome?

    var body: some View {
        PDFPageView(url: url) { _, concluded in outcome = concluded }
            .background {
                if outcome != .opened { placeholder(outcome) }
            }
    }
}

/// The PDF itself: the whole page, scrolling through the document.
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
struct PDFPageView: NSViewRepresentable {
    let url: URL
    /// Told how each open concluded, on the main actor, once the view holds the result. Never told
    /// about an open that was superseded or outlived its view.
    ///
    /// No default, for the reason `ColumnPreviewColumn.onOpenInEditor` has none: a defaulted no-op
    /// is a deleted argument that compiles, and a placeholder that then never leaves.
    let onOutcome: (URL, PDFOpenOutcome) -> Void

    /// What the view has asked the lane for, so a load that comes back can be checked against it.
    @MainActor
    final class Coordinator {
        /// The URL most recently requested, for `updateNSView`'s guard.
        var requested: URL?
        /// The open in flight. **Latest request wins**: a newer request or the view's dismantle
        /// withdraws it, and a withdrawn open is neither started by the lane nor assigned if it was
        /// already running — otherwise a slow open of the previous file could land after the current
        /// one and put the wrong document under the current file's name.
        var pending: PDFOpenTicket?
        /// The latest `onOutcome`, refreshed on every update so an open reports to the current one.
        var onOutcome: (URL, PDFOpenOutcome) -> Void = { _, _ in }
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
        context.coordinator.onOutcome = onOutcome
        load(url, into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: FitPagePDFView, context: Context) {
        context.coordinator.onOutcome = onOutcome
        // Guarded for the reason `QuickLookPreview.updateNSView` is: this runs on every ancestor
        // re-render, and re-reading a document rebuilds every page and throws away the reader's
        // scroll position.
        //
        // **Against the REQUESTED url, not `view.document?.documentURL`.** While a load is in the
        // lane the view has no document, so the document's URL would read as "not this one" on
        // every re-render and queue a fresh parse each time — and the same for a file that fails
        // to open, which never gets a document at all.
        guard context.coordinator.requested != url else { return }
        // A different file's document comes down now rather than when the new one lands: a page
        // from the previous file sitting under the new file's name, even briefly, is a wrong
        // preview, and it releases that file's descriptor sooner. (The column never takes this
        // path — it mounts a fresh preview per selection — but a representable owes its update a
        // right answer whoever calls it.)
        view.document = nil
        load(url, into: view, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ view: FitPagePDFView, coordinator: Coordinator) {
        // A `PDFDocument` holds the file open; dropping it with the view keeps a preview walk from
        // leaving one descriptor per file behind. Withdrawing the open stops one still in the lane
        // from handing a document straight back — or from being parsed at all, if its turn has not
        // come.
        coordinator.pending?.withdraw()
        view.document = nil
    }

    /// Opens `url` in the lane and hands the document to `view` — if it is still the one wanted.
    @MainActor
    private func load(_ url: URL, into view: FitPagePDFView, coordinator: Coordinator) {
        coordinator.pending?.withdraw()
        let ticket = PDFOpenTicket()
        coordinator.pending = ticket
        coordinator.requested = url
        let queued = ContinuousClock.now
        Task { @MainActor [weak view] in
            let lane = await PDFKitSerialAccess.perform { () -> PDFOpenTicket.Result in
                // **Not parsed at all once withdrawn.** Each selection mounts its own preview, so a
                // walk through a folder during a scan leaves one queued open per file it settled on;
                // parsing them would put every abandoned file ahead of the one being looked at.
                guard ticket.isWanted else { PDFOpenTicket.noteSkipped(); return .skipped }
                let started = ContinuousClock.now
                let document = PDFDocument(url: url).map(SendableDocument.init)
                return .parsed(document, waited: started - queued, parsing: .now - started)
            }
            guard case let .parsed(opened, waited, parsing) = lane,
                  let view, ticket.isWanted else { return }
            let outcome: PDFOpenOutcome
            switch opened?.document {
            case let document? where document.isLocked: outcome = .locked
            case let document? where document.pageCount > 0: outcome = .opened
            default: outcome = .unreadable
            }
            // Only a document there is something to show of — a locked one draws nothing, and holds
            // the file open for no reason.
            view.document = outcome == .opened ? opened?.document : nil
            // `layout()` fits only on a size change. A view that has never had a page has no fit to
            // keep, but one that showed another file's page still holds that page's fit.
            view.invalidateFit()
            view.needsLayout = true
            Self.log(outcome, url: url, waited: waited, parsing: parsing)
            coordinator.onOutcome(url, outcome)
        }
    }

    /// The cost this design adds is the wait for the lane, so it is what the trace reports; a failure
    /// is a warning, because a preview that stays on its icon is otherwise unexplained.
    private static func log(_ outcome: PDFOpenOutcome, url: URL, waited: Duration, parsing: Duration) {
        func ms(_ d: Duration) -> Int { Int(d / .milliseconds(1)) }
        switch outcome {
        case .opened:
            Logger.shared.debug("[preview] PDF \(url.path) opened — waited \(ms(waited)) ms for the PDFKit lane, parsed in \(ms(parsing)) ms")
        case .locked:
            Logger.shared.info("[preview] PDF \(url.path) is password-protected — showing its icon")
        case .unreadable:
            Logger.shared.warning("[preview] PDF \(url.path) could not be opened — damaged, empty or not a PDF; showing its icon")
        }
    }
}

/// One open, withdrawable until the lane is done with it.
///
/// A class with its own lock rather than state on the coordinator because the lane reads it, off the
/// main actor, to decide whether to parse at all.
final class PDFOpenTicket: Sendable {
    /// What the lane did with an open.
    enum Result: Sendable {
        /// Withdrawn before its turn came; nothing was parsed.
        case skipped
        /// Parsed — `nil` when PDFKit could not read the file — with the time spent queued behind
        /// other PDFKit work and the time the parse itself took.
        case parsed(SendableDocument?, waited: Duration, parsing: Duration)
    }

    private let wanted = OSAllocatedUnfairLock(initialState: true)

    var isWanted: Bool { wanted.withLock { $0 } }
    func withdraw() { wanted.withLock { $0 = false } }

    private static let skips = OSAllocatedUnfairLock(initialState: 0)

    /// How many of the COLUMN PREVIEW's opens the lane has skipped because they were withdrawn
    /// first, for the life of the process. Test instrumentation, like
    /// `PDFKitSerialAccess.peakConcurrentParses`: a skipped parse has no other outside signature.
    /// Never reset, for that counter's reason.
    ///
    /// **The preview's alone.** `PDFPreviewMountedTests` asserts it does NOT move across a held
    /// lane, so any other reader counting here breaks that test whenever it runs alongside. Edit's
    /// reader did, from 1a until 2026-10-17, and its tests withdraw opens on purpose: the first CI
    /// run with it on main went red on exactly that assertion. A new reader that withdraws opens
    /// counts them on itself, as `EditorPDFDocument.skippedOpens` does.
    static var skippedOpens: Int { skips.withLock { $0 } }
    static func noteSkipped() { skips.withLock { $0 += 1 } }
}
