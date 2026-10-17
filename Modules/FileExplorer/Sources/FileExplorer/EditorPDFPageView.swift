import AppKit
import PDFKit
import SwiftUI

/// Edit's page view: the column preview's `FitPagePDFView`, grown the reader's controls — Page,
/// Width and Actual, zoom, and ⌥← / ⌥→ for pages.
///
/// **Refitted on a size change, not on every layout pass**, for `FitPagePDFView`'s reason: a pass
/// runs for a scroll or a first-responder change, and re-imposing the fit on each one would undo a
/// zoom the reader had just made. Resize the window and the page fits again; zoom, and it stays
/// zoomed until a fit is picked. With no fit (`nil`, after a zoom) nothing is refitted at all.
final class ReaderPDFView: PDFView {
    /// The fit to hold, or `nil` once the reader has zoomed by hand.
    var fit: EditorPDFFit? = .page {
        didSet { if fit != oldValue { fittedSize = nil; needsLayout = true } }
    }
    private var fittedSize: CGSize?

    /// Refit on the next layout even if the size has not changed — for a new document, whose page
    /// is a different question from the view's.
    func invalidateFit() { fittedSize = nil }

    /// The page-break margin PDFKit leaves either side of a page, which a width fit keeps clear.
    var sideMargin: CGFloat { displaysPageBreaks ? max(pageBreakMargins.left, pageBreakMargins.right) : 0 }

    override func layout() {
        super.layout()
        clearInheritedBackground()
        refit()
    }

    /// Applies ``fit`` when the size has moved since it was last applied.
    func refit() {
        guard let fit, bounds.size != fittedSize, bounds.width > 0, bounds.height > 0,
              let page = currentPage ?? document?.page(at: 0)
        else { return }
        fittedSize = bounds.size
        let pageSize = page.bounds(for: displayBox).size
        scaleFactor = EditorPDFFit.scale(fit, pageSize: pageSize, viewSize: bounds.size, margin: sideMargin)
    }

    /// ⌥← and ⌥→ turn a page, as Edit's keys rather than the panes': with Edit on screen the
    /// reader has the workspace to itself.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.option, .numericPad, .function] || flags == .option {
            switch event.specialKey {
            case .leftArrow?:
                if canGoToPreviousPage { goToPreviousPage(nil) }
                return
            case .rightArrow?:
                if canGoToNextPage { goToNextPage(nil) }
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    /// See `FitPagePDFView.clearInheritedBackground` — both writes are needed, for the same reason.
    func clearInheritedBackground() {
        backgroundColor = .clear
        for case let scroll as NSScrollView in subviews where scroll.drawsBackground {
            scroll.drawsBackground = false
        }
    }
}

/// The open PDF's pages, in Edit's document card.
///
/// **The document arrives already parsed**, through `PDFKitSerialAccess`, from ``EditorPDFDocument``
/// — this view never opens one. It reports where the reader is to ``EditorPDFViewState`` and takes
/// its fit, zoom and page asks from there.
struct EditorPDFPageView: NSViewRepresentable {
    let document: PDFDocument?
    @ObservedObject var state: EditorPDFViewState

    final class Coordinator: NSObject {
        let state: EditorPDFViewState
        weak var view: ReaderPDFView?
        var pageToken: Int?
        var scaleToken: Int?
        init(state: EditorPDFViewState) { self.state = state }

        @MainActor @objc func pageChanged(_ note: Notification) {
            guard let view, let page = view.currentPage, let document = view.document else { return }
            let index = document.index(for: page)
            if state.currentPage != index { state.currentPage = index }
        }

        @MainActor @objc func scaleChanged(_ note: Notification) {
            guard let view else { return }
            if abs(state.scale - view.scaleFactor) > 0.0001 { state.scale = view.scaleFactor }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.displayDirection = .vertical
        view.minScaleFactor = EditorPDFViewState.minScale
        view.maxScaleFactor = EditorPDFViewState.maxScale
        view.clearInheritedBackground()
        context.coordinator.view = view
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)),
                                               name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scaleChanged(_:)),
                                               name: .PDFViewScaleChanged, object: view)
        update(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: ReaderPDFView, context: Context) {
        update(view, coordinator: context.coordinator)
    }

    private func update(_ view: ReaderPDFView, coordinator: Coordinator) {
        if view.document !== document {
            view.document = document
            view.invalidateFit()
            view.needsLayout = true
            // A reload asks for its page in the same pass; the pages must be laid out to go to one.
            if document != nil {
                view.layoutDocumentView()
                Self.takeFocusIfUnclaimed(view)
            }
        }
        view.fit = state.fit
        if let request = state.scaleRequest, request.token != coordinator.scaleToken {
            coordinator.scaleToken = request.token
            view.scaleFactor = request.value
        }
        if let request = state.pageRequest, request.token != coordinator.pageToken,
           let document, let page = document.page(at: request.value) {
            coordinator.pageToken = request.token
            view.go(to: page)
        }
    }

    /// **The pages take the keyboard only when nothing else has it**, so ⌥← / ⌥→ and Space work
    /// straight after ⌘O — but a click in Edit's open pane keeps the pane's focus, where the arrow
    /// keys walk the list (and open each file they land on).
    static func takeFocusIfUnclaimed(_ view: ReaderPDFView) {
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            if window.firstResponder == nil || window.firstResponder === window {
                window.makeFirstResponder(view)
            }
        }
    }

    static func dismantleNSView(_ view: ReaderPDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        // The model owns the document and releases it on close; the view lets go of it now.
        view.document = nil
    }
}
