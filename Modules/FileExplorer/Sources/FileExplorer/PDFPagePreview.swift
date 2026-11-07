import AppKit
import Events
import os
import PDFKit
import SwiftUI
import Sync
import UniformTypeIdentifiers

/// Which renderer draws a previewable file.
///
/// A rule rather than a branch inside the view, because it is a policy about file types and the
/// view it decides is a hosted AppKit view no test can read the intent out of.
///
/// Quick Look is the default: it scales images to fit, scrolls text, gives video controls, and
/// needs no format knowledge here. PDFs are the exception: Quick Look fits a page to the preview's
/// width and lets the height overflow, so a wider preview shows less of the page, and its remote
/// view can't scroll to the rest. PDFKit renders in-process, so the fit and scrolling are ours
/// (`FitPagePDFView`). Other paged formats are drawn by their own Quick Look extensions, and this
/// app has no renderer to switch them to.
enum PreviewRenderer: Equatable, Sendable {
    /// PDFKit, fitted to the page and scrolling through the document.
    case pdfPages
    /// Quick Look.
    case quickLook

    /// `conforms(to:)` rather than `== .pdf`, so a format that declares itself a kind of PDF is
    /// drawn as one. No system type does today (Illustrator's doesn't), so no test pins this half.
    ///
    /// An unresolved type goes to Quick Look, the renderer that can draw anything, not to the one
    /// that understands a single format.
    static func forType(_ type: UTType?) -> PreviewRenderer {
        guard let type, type.conforms(to: .pdf) else { return .quickLook }
        return .pdfPages
    }
}

/// How a PDF page is sized inside the preview.
///
/// Pure so the sizing can be asserted without a rendered document.
enum PDFPageFit {
    /// The scale at which a whole page fits, both dimensions inside the view.
    ///
    /// The tighter of the two ratios decides, so the page is always wholly visible and the slack
    /// falls the other way as margins; fitting on width alone overflows a short pane.
    ///
    /// Capped at 1 so a small page is never blown up past its natural size. A view mid-layout (a
    /// dimension still 0) gets 1, never a scale of 0, which PDFKit treats as "draw nothing".
    static func scale(pageSize: CGSize, viewSize: CGSize) -> CGFloat {
        guard pageSize.width > 0, pageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return 1 }
        return min(1, min(viewSize.width / pageSize.width, viewSize.height / pageSize.height))
    }
}

/// A `PDFView` that keeps a whole page in view as the pane is resized.
///
/// `autoScales` is off: in a continuous display mode PDFKit fits the width, the behaviour being
/// replaced. The scale comes from `PDFPageFit.scale` instead.
///
/// Refitted on a size change, not every layout pass: a pass also runs for a scroll or a focus
/// change, and refitting then would undo a zoom the reader just made with ⌘+ or a pinch.
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
    /// `backgroundColor = .clear` alone isn't enough: PDFKit's own enclosing `NSScrollView` draws
    /// the area around the page, white, and would leave the PDF in a bright rectangle (the
    /// brightest thing in a dark window). Both are turned off.
    ///
    /// Applied from `layout()`, not once at construction, because the scroll view is PDFKit's: it
    /// may not exist yet when the view is created, and PDFKit may reset the flag on a document
    /// change. Both writes are idempotent, so re-asserting them per pass is cheap.
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
/// The page arrives from `PDFKitSerialAccess` a moment after the view mounts (longer while a scan
/// holds the lane), and an empty `PDFView` paints nothing, so `placeholder` stands behind the view
/// until the page lands, and stays, with the outcome to caption, if it never does.
///
/// The outcome is this mount's own `@State`, and the column mounts a fresh preview per selection,
/// so a result can't outlive its file: walking A → B → A, the second A shows the placeholder while
/// it loads rather than inheriting the first A's `.opened` and a blank pane.
struct PDFPagePreview<Placeholder: View>: View {
    let url: URL
    /// What stands behind the page: given nil while the open is in flight, and the outcome when it
    /// failed. Not shown once the page is in, since it would show around the page's edges.
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
/// `.singlePageContinuous` so a scroll walks the document rather than stopping at the end of page
/// one, with page breaks drawn so the boundary between pages is visible. The scrollers are
/// `PDFView`'s own, in this process, unlike Quick Look's `NSRemoteView`.
///
/// **Never open the document on the main actor**; it goes through `PDFKitSerialAccess`, as in
/// `PDFPairView`. `PDFDocument(url:)` parses, so a large PDF inline stalls the main thread per
/// selection, and PDFKit parsing isn't thread-safe: an open beside the lane could overlap a scan's
/// extraction. So the view mounts empty and the page arrives when the lane has parsed it.
struct PDFPageView: NSViewRepresentable {
    let url: URL
    /// Told how each open concluded, on the main actor, once the view holds the result. Never told
    /// about an open that was superseded or outlived its view.
    ///
    /// No default: a defaulted no-op would let a dropped argument compile, and the placeholder
    /// would never leave.
    let onOutcome: (URL, PDFOpenOutcome) -> Void

    /// What the view has asked the lane for, so a load that comes back can be checked against it.
    @MainActor
    final class Coordinator {
        /// The URL most recently requested, for `updateNSView`'s guard.
        var requested: URL?
        /// The open in flight. Latest request wins: a newer request or the view's dismantle
        /// withdraws it, and a withdrawn open is neither started nor assigned, so a slow open of
        /// the previous file can't land under the current file's name.
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
        // The pane paints its own surface behind this; see `clearInheritedBackground` for why one
        // line here is not enough.
        view.clearInheritedBackground()
        context.coordinator.onOutcome = onOutcome
        load(url, into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: FitPagePDFView, context: Context) {
        context.coordinator.onOutcome = onOutcome
        // Guarded as `QuickLookPreview.updateNSView` is: this runs on every ancestor re-render, and
        // re-reading a document rebuilds every page and loses the reader's scroll position.
        //
        // Against the requested URL, not `view.document?.documentURL`: while a load is in the lane,
        // or for a file that fails to open, there is no document, and every re-render would queue
        // a fresh parse.
        guard context.coordinator.requested != url else { return }
        // A different file's document comes down now, not when the new one lands: the old page
        // under the new name, even briefly, is a wrong preview, and this frees its descriptor
        // sooner. The column never takes this path (it mounts a preview per selection), but the
        // update must be right whoever calls it.
        view.document = nil
        load(url, into: view, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ view: FitPagePDFView, coordinator: Coordinator) {
        // A `PDFDocument` holds the file open; dropping it keeps a preview walk from leaving a
        // descriptor per file. Withdrawing the open stops one still in the lane from handing a
        // document back, or from being parsed at all if its turn hasn't come.
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
                // Not parsed once withdrawn: a walk through a folder during a scan queues an open
                // per file, and parsing them all would delay the file being looked at.
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
            // Only a document with something to show: a locked one draws nothing and would hold the
            // file open for no reason.
            view.document = outcome == .opened ? opened?.document : nil
            // `layout()` fits only on a size change. A view that has never had a page has no fit to
            // keep, but one that showed another file's page still holds that page's fit.
            view.invalidateFit()
            view.needsLayout = true
            Self.log(outcome, url: url, waited: waited, parsing: parsing)
            coordinator.onOutcome(url, outcome)
        }
    }

    /// The trace reports the wait for the lane, the cost this design adds. A failure is a warning,
    /// because a preview that stays on its icon is otherwise unexplained.
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
/// A class with its own lock rather than state on the coordinator because the lane reads it, off
/// the main actor, to decide whether to parse at all.
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

    /// How many of the column preview's opens the lane has skipped because they were withdrawn
    /// first, for the life of the process. Test instrumentation, like
    /// `PDFKitSerialAccess.peakConcurrentParses`: a skipped parse has no other outside signature.
    /// Never reset, for that counter's reason.
    ///
    /// **Only the column preview may count here.** `PDFPreviewMountedTests` asserts it does not
    /// move across a held lane, so another reader counting here would break that test when run
    /// alongside. A new reader that withdraws opens counts them on itself, as
    /// `EditorPDFDocument.skippedOpens` does.
    static var skippedOpens: Int { skips.withLock { $0 } }
    static func noteSkipped() { skips.withLock { $0 += 1 } }
}
