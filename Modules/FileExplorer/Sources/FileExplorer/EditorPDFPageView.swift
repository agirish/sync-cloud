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
        if overlay.superview != nil { installOverlay() }
    }

    // MARK: Find's highlights

    /// The find's matches, drawn over the pages — see ``EditorPDFFindOverlay``.
    var highlights: EditorPDFHighlights {
        get { overlay.highlights }
        set {
            guard newValue != overlay.highlights else { return }
            overlay.highlights = newValue
            if !newValue.isEmpty || overlay.superview != nil { installOverlay() }
        }
    }

    private let overlay = EditorPDFFindOverlay()
    private weak var watchedClip: NSClipView?
    private var watchesScale = false

    /// Puts the overlay on top, the size of the view, and redraws it as the pages scroll. Kept on
    /// top on every layout: PDFKit adds views of its own when a document arrives.
    private func installOverlay() {
        overlay.reader = self
        if subviews.last !== overlay {
            overlay.removeFromSuperview()
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        if let clip = subviews.lazy.compactMap({ $0 as? NSScrollView }).first?.contentView, clip !== watchedClip {
            if let watchedClip {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: watchedClip)
            }
            watchedClip = clip
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(pagesMoved(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }
        // A zoom resizes the pages without necessarily moving the clip's bounds, and a page turn
        // can swap which pages are drawn: both redraw the highlights where the pages now are.
        if !watchesScale {
            watchesScale = true
            for name in [Notification.Name.PDFViewScaleChanged, .PDFViewVisiblePagesChanged] {
                NotificationCenter.default.addObserver(self, selector: #selector(pagesMoved(_:)), name: name, object: self)
            }
        }
        overlay.needsDisplay = true
    }

    @objc private func pagesMoved(_ note: Notification) {
        if !overlay.highlights.isEmpty { overlay.needsDisplay = true }
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

    /// Esc in the pages — the find bar's, when it is up (``EditorPDFReader``). `true` when it
    /// closed something.
    var onEscape: (() -> Bool)?
    static let escapeKeyCode: UInt16 = 53

    /// ⌥← and ⌥→ turn a page, as Edit's keys rather than the panes': with Edit on screen the
    /// reader has the workspace to itself. Esc closes the find bar from the pages too, as it does
    /// from its field — a press with nothing to close goes on as before.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == Self.escapeKeyCode, flags.isEmpty, onEscape?() == true { return }
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

/// **The find's matches over the reader's pages, from geometry alone.**
///
/// The rects arrive from the lane in page space (``EditorPDFFind``) and are mapped here with
/// `PDFView.convert(_:from:)` — no `PDFSelection` is built on the reader's document, which would be
/// text work on the main thread. Every match is tinted; the current one more strongly. It takes no
/// clicks: they go through to the pages.
final class EditorPDFFindOverlay: NSView {
    weak var reader: PDFView?
    var highlights = EditorPDFHighlights.none {
        didSet { if highlights != oldValue { needsDisplay = true } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where `rect`, in page space on `page`, falls in this view.
    func place(_ rect: CGRect, on page: PDFPage) -> CGRect? {
        guard let reader else { return nil }
        return convert(reader.convert(rect, from: page), from: reader)
    }

    /// **The tint is light enough to read the text through.** The overlay sits ABOVE the pages —
    /// PDFKit draws them on layers of its own, so a multiply blend here would blend with nothing —
    /// and black text under the tint comes out darkened yellow. Measured 2026-10-17: at the 0.6 this
    /// shipped with, that text read at ~2.6:1 against its highlight; at ``currentAlpha`` it reads at
    /// ~5.9:1 (`theHighlightLeavesTheTextReadable`). The current match is told apart by an outline
    /// rather than by a darker fill.
    static let currentAlpha: CGFloat = 0.4
    static let otherAlpha: CGFloat = 0.25

    override func draw(_ dirtyRect: NSRect) {
        guard !highlights.isEmpty, let reader, let document = reader.document else { return }
        let base = NSColor.findHighlightColor
        for page in reader.visiblePages {
            let index = document.index(for: page)
            guard let found = highlights.pages[index] else { continue }
            for (ordinal, rects) in found.enumerated() {
                let isCurrent = highlights.current == EditorPDFHighlights.Spot(page: index, ordinal: ordinal)
                for rect in rects {
                    guard let placed = place(rect.insetBy(dx: -1, dy: -1), on: page),
                          placed.intersects(dirtyRect.insetBy(dx: -3, dy: -3)) else { continue }
                    base.withAlphaComponent(isCurrent ? Self.currentAlpha : Self.otherAlpha).setFill()
                    NSBezierPath(roundedRect: placed, xRadius: 2, yRadius: 2).fill()
                    if isCurrent {
                        NSColor.systemOrange.setStroke()
                        let ring = NSBezierPath(roundedRect: placed.insetBy(dx: -0.75, dy: -0.75), xRadius: 2.5, yRadius: 2.5)
                        ring.lineWidth = 1.5
                        ring.stroke()
                    }
                }
            }
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
    /// The find's matches, drawn over the pages.
    var highlights: EditorPDFHighlights = .none
    /// Esc in the pages: `true` when it closed something.
    var onEscape: (() -> Bool)?

    final class Coordinator: NSObject {
        let state: EditorPDFViewState
        weak var view: ReaderPDFView?
        var pageToken: Int?
        var scaleToken: Int?
        var revealToken: Int?
        var focusToken: Int?
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
        context.coordinator.focusToken = state.focusRequest
        state.reader = view
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
        let reveal = state.revealRequest.flatMap { $0.token != coordinator.revealToken ? $0 : nil }
        if let request = state.pageRequest, request.token != coordinator.pageToken,
           let document, let page = document.page(at: request.value) {
            coordinator.pageToken = request.token
            // **Not when a match on this page is to be shown in the same pass**: going to the page
            // scrolls to its top first, so stepping between two matches already on screen jumped
            // the view up and back down for nothing. The reveal goes to the page itself.
            if Self.goesToPageTop(page: request.value, reveal: reveal?.value) { view.go(to: page) }
        }
        if let request = reveal, let document, let page = document.page(at: request.value.pageIndex) {
            coordinator.revealToken = request.token
            // A margin round the match, so it is not drawn hard against the edge it scrolled to —
            // and no scroll at all for a match already in sight.
            let wanted = request.value.rect.insetBy(dx: -24, dy: -48)
            if !Self.isInSight(request.value.rect, on: page, in: view) { view.go(to: wanted, on: page) }
        }
        if state.focusRequest != coordinator.focusToken {
            coordinator.focusToken = state.focusRequest
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }
        view.onEscape = onEscape
        view.highlights = highlights
    }

    /// Whether a page ask scrolls to the page's top: not when a match on that same page is to be
    /// revealed in the same pass, which goes to the page itself.
    static func goesToPageTop(page: Int, reveal: EditorPDFReveal?) -> Bool {
        reveal?.pageIndex != page
    }

    /// Whether `rect`, in page space on `page`, is wholly on screen in `view` — a page on screen at
    /// all, and the rect inside the view's bounds.
    static func isInSight(_ rect: CGRect, on page: PDFPage, in view: PDFView) -> Bool {
        guard view.visiblePages.contains(page) else { return false }
        return view.bounds.contains(view.convert(rect, from: page))
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
        if coordinator.state.reader === view { coordinator.state.reader = nil }
        view.onEscape = nil
        view.highlights = .none
        // The model owns the document and releases it on close; the view lets go of it now.
        view.document = nil
    }
}
