import AppKit
import Design
import PDFKit
import SwiftUI

/// Edit's page view: the column preview's `FitPagePDFView`, grown the reader's controls — the
/// layouts, Fit Page / Fit Width / Actual Size and the zoom, and ⌥← / ⌥→ for pages.
///
/// **Refitted on a size change, not on every layout pass**, for `FitPagePDFView`'s reason: a pass
/// runs for a scroll or a first-responder change, and re-imposing the fit on each one would undo a
/// zoom the reader had just made. Resize the window and the page fits again; zoom, and it stays
/// zoomed until a fit is picked. With no fit (`nil`, after a zoom) nothing is refitted at all.
///
/// **In a layout that shows one spread at a time, a new spread refits too** — Single Page and Two
/// Pages draw only what is on screen, so a cover shown on its own is fitted alone and the 2–3 after
/// it is fitted as a pair. The continuous layouts keep the size-only rule: there the spreads scroll
/// past, and refitting each one would change the scale under the reader mid-scroll.
final class ReaderPDFView: PDFView {
    /// The fit to hold, or `nil` once the reader has zoomed by hand.
    var fit: EditorPDFFit? = .page {
        didSet { if fit != oldValue { fittedKey = nil; needsLayout = true } }
    }
    /// What the fit was last applied for: the room it fitted into, and — in a one-spread-at-a-time
    /// layout — the spread's size.
    private var fittedKey: FitKey?
    private struct FitKey: Equatable {
        var viewSize: CGSize
        var spreadSize: CGSize?
    }

    /// **The room the floating pieces keep clear** (Phase 6a): 28pt above the first page, and the
    /// capsule's band on the edge it is docked to (``EditorPDFFloating/canvasInsets(place:capsule:)``).
    /// Set as the scroll view's content insets, so the pages still scroll under the glass but the
    /// first page starts below the band and the last one can scroll fully clear of it. A fit is
    /// measured on what is left, so Fit Page puts the whole page between the bands.
    var canvasInsets = NSEdgeInsetsZero {
        didSet {
            guard !NSEdgeInsetsEqual(canvasInsets, oldValue) else { return }
            fittedKey = nil
            needsLayout = true
        }
    }

    /// **What floats over the pages outside the bands** — the find card, and the capsule where it
    /// has slid to clear it — in the canvas's top-left space, as SwiftUI lays them out. The pages do
    /// not keep clear of these (opening the card must not move them); only "is a match in sight"
    /// asks, so a step to a match under the card scrolls it out.
    var coveredRects: [CGRect] = []

    /// The scroll view PDFKit keeps the pages in.
    var pagesScrollView: NSScrollView? { subviews.lazy.compactMap { $0 as? NSScrollView }.first }

    /// The view's size less ``canvasInsets`` — what a fit is measured on. (Not `fittingSize`, which
    /// is `NSView`'s own and means something else.)
    var fitRoom: CGSize {
        CGSize(width: max(bounds.width - canvasInsets.left - canvasInsets.right, 1),
               height: max(bounds.height - canvasInsets.top - canvasInsets.bottom, 1))
    }

    /// Puts ``canvasInsets`` on the scroll view — by hand, so AppKit's own safe-area adjustment
    /// does not overwrite them on the next layout. A page view that was never given any is left
    /// exactly as PDFKit set it up.
    private func applyCanvasInsets() {
        guard let scroll = pagesScrollView else { return }
        if scroll.automaticallyAdjustsContentInsets {
            guard !NSEdgeInsetsEqual(canvasInsets, NSEdgeInsetsZero) else { return }
            scroll.automaticallyAdjustsContentInsets = false
        }
        if !NSEdgeInsetsEqual(scroll.contentInsets, canvasInsets) { scroll.contentInsets = canvasInsets }
    }

    /// The scale the fit last set. A scale change away from it that the fit did not make is the
    /// reader's own — a pinch — and lets the fit go (``EditorPDFPageView/Coordinator``).
    private(set) var fittedScale: CGFloat?
    private(set) var isApplyingFit = false

    /// Refit on the next layout even if the size has not changed — for a new document, or a new
    /// layout, whose spread is a different question from the view's.
    func invalidateFit() { fittedKey = nil }

    /// The page-break margin PDFKit leaves either side of a page, which a width fit keeps clear.
    var sideMargin: CGFloat { displaysPageBreaks ? max(pageBreakMargins.left, pageBreakMargins.right) : 0 }

    /// **The gap between the two pages of a spread**, in page space: one page's right margin and
    /// the next one's left. Measured 2026-10-17 on macOS 27 — 8pt at scale 1 in Two Pages,
    /// Continuous, and 7pt in Two Pages; both scale with the zoom, as page space does.
    var spreadGap: CGFloat { displaysPageBreaks ? pageBreakMargins.left + pageBreakMargins.right : 0 }

    var layoutMode: EditorPDFLayout { EditorPDFLayout(displayMode) }

    override func layout() {
        super.layout()
        clearInheritedBackground()
        applyCanvasInsets()
        watchPageTurns()
        refit()
        if overlay.superview != nil || fillOverlay.superview != nil { installOverlay() }
    }

    // MARK: Fill & Sign

    /// Fill & Sign's items, drawn and handled over the pages — see ``EditorPDFFillOverlay``.
    let fillOverlay = EditorPDFFillOverlay()

    var fillSign: EditorPDFFillSign? {
        get { fillOverlay.fill }
        set {
            guard newValue !== fillOverlay.fill else { return }
            fillOverlay.reader = self
            fillOverlay.fill = newValue
            if newValue != nil || fillOverlay.superview != nil { installOverlay() }
        }
    }

    // MARK: Replace Text… (TE82)

    /// **Replace Text… on the pages' right-click menu, for the words selected** (``menu(for:)``) —
    /// Fill & Sign on, Replace chosen, those words picked. Greyed, with the reason as a line under
    /// it, where Replace would say no: the words cross a line, or the file or the page refuses it.
    static let replaceTitle = "Replace Text…"

    /// Replace Text… for `selection`, live or greyed with its reason under it — `nil` with no words
    /// selected or no pages to place on.
    @MainActor
    static func replaceItems(fill: EditorPDFFillSign, selection: PDFSelection, document: PDFDocument?) -> [NSMenuItem]? {
        guard fill.hasPages, !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let document, let page = selection.pages.first else { return nil }
        let index = document.index(for: page)
        let outcome: Result<EditorPDFReplacePick, EditorPDFReplaceRefusal>
        if fill.replaceRefusal != nil {
            outcome = .failure(.noText)     // the file's refusal is the one said; nothing to measure
        } else if let box = fill.box(index) {
            outcome = EditorPDFReplace.pick(selection, page: page, index: index, box: box, widgets: EditorPDFReplace.widgets(on: page))
        } else {
            outcome = .failure(.noText)
        }
        let reason: String?
        switch (fill.replaceRefusal, outcome) {
        // Short, the file's refusal and the page's alike: this is a menu row, which does not wrap
        // (PD14).
        case (_?, _): reason = fill.replaceMenuReason
        case (nil, .failure(let refusal)): reason = refusal.menuReason
        case (nil, .success): reason = nil
        }
        guard let reason else {
            guard case .success(let pick) = outcome else { return nil }
            return [EditorClosureMenuItem(title: replaceTitle) { fill.replace(pick) }]
        }
        // No action: the menu greys them both.
        return [NSMenuItem(title: replaceTitle, action: nil, keyEquivalent: ""),
                NSMenuItem(title: reason, action: nil, keyEquivalent: "")]
    }

    /// **While Fill & Sign is up, the keyboard goes to its overlay** whenever it would come here —
    /// the overlay answers ⌘Z with Fill & Sign's own stack, and hands every other key back.
    func handKeyboardToFill() {
        guard fillOverlay.isActive, fillOverlay.superview === self, let window,
              window.firstResponder === self else { return }
        window.makeFirstResponder(fillOverlay)
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
        fillOverlay.reader = self
        // The find's highlights, then Fill & Sign's items over them — both kept on top of
        // whatever PDFKit has added since. No Fill & Sign attached, no layer for it.
        let layers: [NSView] = fillOverlay.fill == nil ? [overlay] : [overlay, fillOverlay]
        if fillOverlay.fill == nil { fillOverlay.removeFromSuperview() }
        if Array(subviews.suffix(layers.count)) != layers {
            layers.forEach { $0.removeFromSuperview() }
            layers.forEach { addSubview($0, positioned: .above, relativeTo: nil) }
        }
        for layer in [overlay, fillOverlay] as [NSView] {
            layer.frame = bounds
            layer.autoresizingMask = [.width, .height]
        }
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
        fillOverlay.needsDisplay = true
    }

    @objc private func pagesMoved(_ note: Notification) {
        if !overlay.highlights.isEmpty { overlay.needsDisplay = true }
        if fillOverlay.isActive { fillOverlay.refresh() }
    }

    /// Applies ``fit`` when the size — or, one spread at a time, the spread — has moved since it
    /// was last applied.
    func refit() {
        guard let fit, bounds.width > 0, bounds.height > 0, let document, document.pageCount > 0 else { return }
        let anchor = currentPage.map { document.index(for: $0) } ?? 0
        let pages = Self.fittedSpread(around: anchor, pageCount: document.pageCount, layout: layoutMode,
                                      coverSeparately: displaysAsBook)
        let spread = EditorPDFFit.spreadSize(pages.compactMap { document.page(at: $0)?.bounds(for: displayBox).size },
                                             gap: spreadGap)
        let room = fitRoom
        let key = FitKey(viewSize: room, spreadSize: layoutMode.isContinuous ? nil : spread)
        guard key != fittedKey else { return }
        fittedKey = key
        let scale = EditorPDFFit.scale(fit, spreadSize: spread, viewSize: room, margin: sideMargin)
        fittedScale = scale
        isApplyingFit = true
        scaleFactor = scale
        isApplyingFit = false
    }

    /// **The pages a fit is measured on**: the spread around `page` — except in Two Pages,
    /// Continuous, where every row is drawn two pages wide whatever is on screen, so a page standing
    /// alone (the cover, or a last odd page) is fitted as the pair beside it would be. Fitting it
    /// alone there would draw the next row wider than the view.
    static func fittedSpread(around page: Int, pageCount: Int, layout: EditorPDFLayout,
                             coverSeparately: Bool) -> ClosedRange<Int> {
        func spread(_ page: Int) -> ClosedRange<Int> {
            EditorPDFLayout.spread(containing: page, pageCount: pageCount, twoUp: layout.isTwoUp,
                                   coverSeparately: coverSeparately)
        }
        let here = spread(page)
        guard layout == .twoPagesContinuous, here.count == 1 else { return here }
        for neighbour in [here.upperBound + 1, here.lowerBound - 1] where (0..<pageCount).contains(neighbour) {
            let pair = spread(neighbour)
            if pair.count == 2 { return pair }
        }
        return here
    }

    /// One spread at a time, a page turn can bring a spread of another size: lay out again, and
    /// ``refit()`` decides whether it changed.
    private var watchesPageTurns = false
    private func watchPageTurns() {
        guard !watchesPageTurns else { return }
        watchesPageTurns = true
        NotificationCenter.default.addObserver(self, selector: #selector(pageTurned(_:)), name: .PDFViewPageChanged, object: self)
    }

    @objc private func pageTurned(_ note: Notification) {
        if fit != nil, !layoutMode.isContinuous { needsLayout = true }
    }

    // MARK: Focus

    /// Told when ``holdsFocus`` changes — the page view hands it to `EditorPDFViewState.hasFocus`.
    var onFocusChange: ((Bool) -> Void)?
    /// **Whether the pages have the keyboard**: this view, or a view inside it, first responder in
    /// the key window. Watched rather than worked out from `becomeFirstResponder` alone, because
    /// a click in the pages can hand first responder to PDFKit's own view inside this one, and
    /// the window going to the background takes the keyboard without either view hearing of it.
    private(set) var holdsFocus = false
    private var responderWatch: NSKeyValueObservation?
    private var keyWatches: [NSObjectProtocol] = []

    static func holdsFocus(firstResponder: NSResponder?, isKeyWindow: Bool, in reader: NSView) -> Bool {
        guard isKeyWindow, let view = firstResponder as? NSView else { return false }
        return view === reader || view.isDescendant(of: reader)
    }

    func updateFocus() {
        let now = Self.holdsFocus(firstResponder: window?.firstResponder, isKeyWindow: window?.isKeyWindow == true,
                                  in: self)
        guard now != holdsFocus else { return }
        holdsFocus = now
        onFocusChange?(now)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        responderWatch = nil
        keyWatches.forEach(NotificationCenter.default.removeObserver)
        keyWatches = []
        if let window {
            responderWatch = window.observe(\.firstResponder) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateFocus() }
            }
            keyWatches = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateFocus() }
                }
            }
        }
        updateFocus()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        // The window names its new first responder only once this returns.
        DispatchQueue.main.async { [weak self] in
            self?.handKeyboardToFill()
            self?.updateFocus()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.updateFocus() }
        return resigned
    }

    /// Esc in the pages — the find bar's, when it is up (``EditorPDFReader``). `true` when it
    /// closed something.
    var onEscape: (() -> Bool)?
    static let escapeKeyCode: UInt16 = 53

    /// ⌥← and ⌥→ turn a page, as Edit's keys rather than the panes': with Edit on screen the
    /// reader has the workspace to itself. In a two-page layout PDFKit's own previous and next
    /// turn the whole spread (`theOptionArrowsTurnAWholeSpread`). Esc closes the find bar from the pages too, as it does
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

    /// **PDFKit's own right-click menu, less its view controls.** Automatically Resize, the zooms,
    /// Actual Size, the four display modes and the page turns changed the view behind the reader's
    /// state: a layout picked there snapped back at the next update while the capsule showed the
    /// other one, and Automatically Resize left PDFKit fitting on its own under the capsule's fit.
    /// The capsule and its zoom menu hold every one of them. Look Up, Translate, Search and Copy stay
    /// — and with words selected, Replace Text… (TE82) goes under them.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        Self.removeViewControls(from: menu)
        if let fill = fillSign, let selection = currentSelection,
           let items = Self.replaceItems(fill: fill, selection: selection, document: document) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            items.forEach(menu.addItem)
        }
        return menu.items.isEmpty ? nil : menu
    }

    /// The actions of PDFKit's menu items that drive the view itself — public and private names, as
    /// macOS 27's menu carries them. One a later PDFKit renames is left in, as it was before.
    static let viewControlActions: Set<String> = [
        "_setAutoSize:", "zoomIn:", "zoomOut:", "_setActualSize:", "_setSinglePage:", "_setSinglePageScrolling:",
        "_setDoublePage:", "_setDoublePageScrolling:", "goToNextPage:", "goToPreviousPage:",
    ]

    static func removeViewControls(from menu: NSMenu) {
        for item in menu.items.reversed() {
            if let action = item.action, viewControlActions.contains(NSStringFromSelector(action)) { menu.removeItem(item) }
        }
        // The separators that stood between the groups that went: none doubled, none at either end.
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousWasSeparator { menu.removeItem(item); continue }
            previousWasSeparator = item.isSeparatorItem
        }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }

    /// See `FitPagePDFView.clearInheritedBackground` — both writes are needed, for the same reason.
    func clearInheritedBackground() {
        backgroundColor = .clear
        for case let scroll as NSScrollView in subviews where scroll.drawsBackground {
            scroll.drawsBackground = false
        }
    }
}

/// **Edit ▸ Select All over the pages: the text of the page on screen** — the spread, in a
/// two-page layout — not the whole PDF (decided 2026-10-20). PDFKit reads every page's text on the
/// main thread to select a whole document: on a 1,200-page PDF ⌘A held the app for seconds and ⌘C
/// after it for tens of seconds, and that reading ran beside the lane's.
///
/// **Still on main, beside the lane** — one spread's text now, not 1,200 pages'. A selection the
/// reader makes in its mounted view is the view's own work, as its drawing is, and is outside
/// `PDFKitSerialAccess` the same way: routed through the lane, ⌘A would wait behind a duplicate
/// scan for minutes.
public enum EditorPDFReaderSelection {
    @MainActor
    public static func selectPagesOnScreen(in view: PDFView) {
        guard let document = view.document, let current = view.currentPage else { return }
        let index = document.index(for: current)
        guard index != NSNotFound else { return }
        let twoUp = view.displayMode == .twoUp || view.displayMode == .twoUpContinuous
        let spread = EditorPDFLayout.spread(containing: index, pageCount: document.pageCount, twoUp: twoUp,
                                            coverSeparately: view.displaysAsBook)
        var selection: PDFSelection?
        for page in spread.compactMap(document.page(at:)) {
            guard let text = page.selection(for: page.bounds(for: view.displayBox)) else { continue }
            if let selection { selection.add(text) } else { selection = text }
        }
        view.setCurrentSelection(selection, animate: false)
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
    /// Fill & Sign, drawn and handled over the pages.
    var fill: EditorPDFFillSign?
    /// Esc in the pages: `true` when it closed something.
    var onEscape: (() -> Bool)?
    /// The bands the floating pieces keep clear — see ``ReaderPDFView/canvasInsets``.
    var canvasInsets = NSEdgeInsetsZero
    /// What floats over the pages outside those bands — see ``ReaderPDFView/coveredRects``.
    var coveredRects: [CGRect] = []
    /// The app's accent, for Fill & Sign's rings and field washes (``EditorPDFFillOverlay/accent``).
    var accent: Color = LiquidGlassHue.stored().accentColor
    /// View ▸ Text Size, for the words Fill & Sign draws in AppKit — the retype hint's (PD4).
    @Environment(\.appFontScale) private var fontScale

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
            if Self.letsTheFitGo(fit: state.fit, view: view) { state.fit = nil }
        }

        /// **A scale the fit did not set is the reader's own** — a pinch — and the fit lets go, so
        /// the label says 137% rather than Fit Page, and a resize does not snap the page back.
        @MainActor static func letsTheFitGo(fit: EditorPDFFit?, view: ReaderPDFView) -> Bool {
            guard fit != nil, !view.isApplyingFit, let fitted = view.fittedScale else { return false }
            return abs(view.scaleFactor - fitted) > 0.0001
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.autoScales = false
        view.displayMode = state.layout.displayMode
        view.displaysAsBook = state.layout.displaysAsBook(coverSeparately: state.coverSeparately)
        view.displaysPageBreaks = true
        view.displayDirection = .vertical
        view.minScaleFactor = EditorPDFViewState.minScale
        view.maxScaleFactor = EditorPDFViewState.maxScale
        view.clearInheritedBackground()
        context.coordinator.view = view
        context.coordinator.focusToken = state.focusRequest
        state.reader = view
        view.onFocusChange = { [weak state, weak view] focused in
            guard let state, let view, state.reader === view else { return }
            if state.hasFocus != focused { state.hasFocus = focused }
        }
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
        view.fillOverlay.accent = NSColor(accent)
        view.fillOverlay.textScale = fontScale
        view.canvasInsets = canvasInsets
        view.coveredRects = coveredRects
        Self.applyLayout(state.layout, coverSeparately: state.coverSeparately, to: view)
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
            if request.value.atTop {
                Self.place(request.value.rect.origin, on: page, in: view)
            } else {
                Self.reveal(request.value.rect, on: page, in: view)
            }
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
        view.fillSign = fill
    }

    /// **A new layout keeps the reader where they were**: the page they were on is gone to again
    /// once the pages are laid out the new way, and the fit is measured afresh — a spread is not a
    /// page.
    static func applyLayout(_ layout: EditorPDFLayout, coverSeparately: Bool, to view: ReaderPDFView) {
        let book = layout.displaysAsBook(coverSeparately: coverSeparately)
        guard view.displayMode != layout.displayMode || view.displaysAsBook != book else { return }
        let page = view.currentPage
        view.displayMode = layout.displayMode
        view.displaysAsBook = book
        view.invalidateFit()
        view.needsLayout = true
        guard view.document != nil else { return }
        view.layoutDocumentView()
        if let page { view.go(to: page) }
    }

    /// Whether a page ask scrolls to the page's top: not when a match on that same page is to be
    /// revealed in the same pass, which goes to the page itself.
    static func goesToPageTop(page: Int, reveal: EditorPDFReveal?) -> Bool {
        reveal?.pageIndex != page
    }

    /// Whether `rect`, in page space on `page`, is wholly on screen in `view` — a page on screen at
    /// all, and the rect inside the view's bounds, clear of the bands the floating pieces keep
    /// (``clearRect(of:)``): a match under the capsule is not in sight.
    static func isInSight(_ rect: CGRect, on page: PDFPage, in view: PDFView) -> Bool {
        guard view.visiblePages.contains(page) else { return false }
        return isClear(view.convert(rect, from: page), in: view)
    }

    /// The floating pieces' rects in `view`'s own space — from the canvas's top-left space, as
    /// SwiftUI lays them out; a `PDFView` is not flipped.
    static func covered(in view: PDFView) -> [CGRect] {
        guard let reader = view as? ReaderPDFView else { return [] }
        return reader.coveredRects.map { covered in
            let y = view.isFlipped ? covered.minY : view.bounds.height - covered.maxY
            return CGRect(x: covered.minX, y: y, width: covered.width, height: covered.height)
        }
    }

    /// **Shows `rect` on `page`, clear of the bands and the floating pieces** — with a margin, so it
    /// is not drawn hard against the edge it scrolled to, and no scroll at all for a match already
    /// in sight.
    ///
    /// **PDFKit's `go(to:on:)` does nothing for a rect already on screen** (PDFView.h), so a match
    /// under Fill & Sign's palette in the middle of the canvas, or under a card pushed down from the
    /// top, stayed under it at every ⌘G. What is still covered after it is scrolled out by hand, the
    /// least distance up or down (``clearingShifts(of:clear:covered:)``).
    static func reveal(_ rect: CGRect, on page: PDFPage, in view: PDFView) {
        guard !isInSight(rect, on: page, in: view) else { return }
        view.go(to: rect.insetBy(dx: -24, dy: -48), on: page)
        guard !isInSight(rect, on: page, in: view), view.visiblePages.contains(page) else { return }
        scrollClear(rect, on: page, in: view)
    }

    /// **Brings `point` on `page` to the top of the view** — a bookmark's heading (TE187) — then
    /// out from under the top band or a piece floating there. Judged by where the page is drawn,
    /// not by `visiblePages`, which still names the pages of before straight after a jump.
    static func place(_ point: CGPoint, on page: PDFPage, in view: PDFView) {
        view.go(to: PDFDestination(page: page, at: point))
        scrollClear(CGRect(x: point.x, y: point.y - 1, width: 1, height: 1), on: page, in: view)
    }

    /// Whether `shown`, in `view`'s space, is inside the clear part of the canvas and under no
    /// floating piece.
    static func isClear(_ shown: CGRect, in view: PDFView) -> Bool {
        clearRect(of: view).contains(shown) && !covered(in: view).contains { $0.intersects(shown) }
    }

    /// **Scrolls `rect` out from under a band or a floating piece by hand**, the least distance up
    /// or down (``clearingShifts(of:clear:covered:)``) — nothing when it is clear already.
    static func scrollClear(_ rect: CGRect, on page: PDFPage, in view: PDFView) {
        let shown = view.convert(rect, from: page)
        guard !isClear(shown, in: view), let reader = view as? ReaderPDFView, let scroll = reader.pagesScrollView else { return }
        let clip = scroll.contentView
        let start = clip.bounds.origin
        // The least move first; one the pages cannot scroll that far for (the top of page 1) is
        // put back and the next tried.
        for shift in clearingShifts(of: shown, clear: clearRect(of: view), covered: covered(in: view)) where shift != 0 {
            // The clip-view point now under where the match should be drawn has to come to sit
            // under the match: the difference, in the clip view's own space, whatever its flip and
            // zoom.
            let now = clip.convert(shown.origin, from: view)
            let wanted = clip.convert(CGPoint(x: shown.minX, y: shown.minY + shift), from: view)
            var bounds = clip.bounds
            bounds.origin = CGPoint(x: start.x + now.x - wanted.x, y: start.y + now.y - wanted.y)
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
            if isClear(view.convert(rect, from: page), in: view) { return }
            clip.scroll(to: start)
            scroll.reflectScrolledClipView(clip)
        }
    }

    /// **How far up (+) or down (−) `shown` could move to sit inside `clear` and clear of every
    /// rect in `covered`**, the least distance first — empty when no vertical move does it. All in
    /// one unflipped space. The pieces float at the canvas's sides and ends, so a match under one
    /// comes out above or below it, 8pt clear.
    static func clearingShifts(of shown: CGRect, clear: CGRect, covered: [CGRect]) -> [CGFloat] {
        let margin: CGFloat = 8
        var candidates: [CGFloat] = [0, clear.maxY - margin - shown.maxY, clear.minY + margin - shown.minY]
        for piece in covered where piece.minX < shown.maxX && shown.minX < piece.maxX {
            candidates += [piece.maxY + margin - shown.minY, piece.minY - margin - shown.maxY]
        }
        return candidates
            .filter { shift in
                let moved = shown.offsetBy(dx: 0, dy: shift)
                return clear.contains(moved) && !covered.contains { $0.intersects(moved) }
            }
            .enumerated().sorted { (abs($0.element), $0.offset) < (abs($1.element), $1.offset) }.map(\.element)
    }

    /// `view`'s bounds less its ``ReaderPDFView/canvasInsets`` — a `PDFView` is not flipped, so the
    /// top band comes off the top of the rect, which is its `maxY`.
    static func clearRect(of view: PDFView) -> CGRect {
        guard let reader = view as? ReaderPDFView else { return view.bounds }
        let insets = reader.canvasInsets
        return CGRect(x: view.bounds.minX + insets.left,
                      y: view.bounds.minY + (view.isFlipped ? insets.top : insets.bottom),
                      width: max(view.bounds.width - insets.left - insets.right, 0),
                      height: max(view.bounds.height - insets.top - insets.bottom, 0))
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
        if coordinator.state.reader === view {
            coordinator.state.reader = nil
            coordinator.state.hasFocus = false
        }
        view.onFocusChange = nil
        view.onEscape = nil
        view.highlights = .none
        view.fillSign = nil
        // The model owns the document and releases it on close; the view lets go of it now.
        view.document = nil
    }
}
