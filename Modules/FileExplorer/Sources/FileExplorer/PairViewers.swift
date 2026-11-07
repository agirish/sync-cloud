import AppKit
import PDFKit
import SwiftUI
import Sync

// MARK: - The reentrancy latch

/// The one guard every synchronised pair needs: while a change is being mirrored to the other
/// side, that side's own notification must not mirror it back.
///
/// A `Bool` held around the mirror, not a comparison of values: the two views quantise scroll
/// offsets and magnification differently, so A → B → A' lands a hair off A, differs again, and the
/// pair walks. The latch stops the loop at one hop whatever the far side rounds to.
///
/// A class, not `@State`: the notification handlers are AppKit closures that outlive a SwiftUI
/// update, and a value type captured by them would be a copy.
final class SyncLatch {
    private var mirroring = false

    /// Runs `body` with the latch held, unless it is already held, in which case this is the echo
    /// and it does nothing. Returns whether it ran.
    @discardableResult
    func mirror(_ body: () -> Void) -> Bool {
        guard !mirroring else { return false }
        mirroring = true
        defer { mirroring = false }
        body()
        return true
    }

    var isMirroring: Bool { mirroring }
}

// MARK: - PDF pair

/// Two `PDFView`s showing the same page of two documents, kept in step.
///
/// `QLPreviewView` has no scroll or zoom API, so synchronised Quick Look panes can't be built; a
/// typed viewer owns the document, the page and the scroll view, so it can sync.
///
/// **Never open the documents on the main actor**; they go through `PDFKitSerialAccess`.
/// `PDFDocument(url:)` parses, PDFKit parsing isn't thread-safe, and `run` would be `queue.sync`
/// from the main thread, the whole window waiting behind a running scan's extractions.
struct PDFPairView: NSViewRepresentable {

    let leftPath: String
    let rightPath: String
    /// The page both sides show, clamped per side by ``PagePairing``.
    let page: Int
    let pairing: PagePairing
    /// Suspends mirroring while held: ⌥ lets one pane be scrolled on its own.
    let syncSuspended: Bool
    /// The page the reader has scrolled onto, reported back so the strip and the pixel modes
    /// follow. Only ever called with a page the surface is not already on.
    var onPageChange: (Int) -> Void = { _ in }
    /// The zoom the surface remembers, or nil to let `autoScales` fit the page.
    ///
    /// The surface holds it because this view doesn't survive a mode switch: `panes` switches on
    /// the mode, so `2`–`4` remove this representable and `1` builds a fresh one with `autoScales`
    /// back at fit. The page survives by the same route; the zoom is the other half of where the
    /// reader was.
    var zoom: CGFloat?
    /// The zoom the reader has set, reported back so the surface can hand it to the next mount.
    var onZoomChange: (CGFloat) -> Void = { _ in }

    final class Coordinator: NSObject {
        let latch = SyncLatch()
        var observers: [NSObjectProtocol] = []
        var left: PDFView?
        var right: PDFView?
        var syncSuspended = false
        /// The paths the loaded documents came from, so `updateNSView` reloads only on a real
        /// change rather than parsing on every ancestor render.
        var loaded: (left: String, right: String)?
        /// Whether the scroll observers are registered. They can't be at construction (see
        /// `wireScroll`), and registering them twice would mirror every scroll twice.
        var scrollWired = false
        /// Just the scroll observers, so a re-wire after a path change can drop the previous
        /// pair's without disturbing the zoom ones, which are registered once for the view's life.
        ///
        /// Disjoint from ``observers`` and maintained only through ``replaceScrollObservers(_:)``.
        /// A token in both lists would survive the re-wire in `observers`, already removed from the
        /// centre, growing by two per pair opened.
        private(set) var scrollObservers: [NSObjectProtocol] = []

        /// Swaps this pair's scroll observers in and the previous pair's out, in one step.
        ///
        /// One step, because the `PDFView`s are reused across a path change, so their clip views
        /// can be the same objects: a second registration on one clip mirrors every scroll twice,
        /// and the latch would hide that while the observers leak.
        func replaceScrollObservers(_ make: () -> [NSObjectProtocol]) {
            for observer in scrollObservers { NotificationCenter.default.removeObserver(observer) }
            scrollObservers = make()
        }
        /// The page each side should be showing, as of the most recent `updateNSView`.
        ///
        /// Read by the load completion, not captured at its start: `go` does nothing while
        /// `document` is nil, so a page turn during a slow open (the lane busy behind a scan)
        /// would otherwise be lost, the strip on page 12 and the panes on page 1.
        var requestedPages: (left: Int, right: Int) = (0, 0)
        /// The surface's page as of the last update, so a report can be suppressed when it merely
        /// echoes a page the surface itself just asked for.
        var surfacePage = 0
        /// True while this view is driving its own page: setting a document, or going to the page
        /// the surface asked for.
        ///
        /// A value check alone isn't enough: setting `document` puts the view on page 1 and posts,
        /// a page the surface never asked for. Taken as a reader's move, it would be reported, and
        /// so would the `go` that follows: two false moves for a surface opened on page 2.
        var drivingPage = false
        /// Re-read on every update rather than captured once: a SwiftUI view is a fresh value each
        /// render, and an observer holding the first one would call a closure with stale state.
        var onPageChange: (Int) -> Void = { _ in }
        var onZoomChange: (CGFloat) -> Void = { _ in }
        /// The zoom the surface remembers, as of the most recent update.
        var surfaceZoom: CGFloat?
        /// What "not zoomed" currently means: the scale a pane that is still auto-fitting has
        /// settled on.
        ///
        /// `autoScales` alone can't answer "did the reader zoom": during load the mirror copies one
        /// pane's fit to the other, turning that pane's `autoScales` off, and which pane that is
        /// depends on which load finished first. So this is a value kept current by whichever pane
        /// is still fitting, and resizing the card moves the baseline instead of reading as a zoom.
        var fittedScale: CGFloat?

        deinit {
            // Both lists, because they are disjoint: `observers` holds the ones registered once
            // for the view's life, `scrollObservers` the ones a path change re-registers.
            for observer in observers + scrollObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        let left = makePDFView(), right = makePDFView()
        context.coordinator.left = left
        context.coordinator.right = right
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        // Only the zoom half can be wired now (see `wireScroll`). The page observers go here too:
        // like the scale notification, `PDFViewPageChanged` is posted by the view, which exists.
        wireZoom(context.coordinator)
        wirePageReporting(context.coordinator)
        return split
    }

    /// Hands the reader's zoom back to the surface on the way out.
    ///
    /// At unmount, not from `PDFViewScaleChanged`: PDFKit posts its own initial fit through that
    /// notification, so a fit and a reader's zoom can't be told apart, and the mirror makes the far
    /// pane's echo of a fit look like a zoom too. Unmount is when the value is needed (this view
    /// doesn't survive a mode switch), and everything has settled by then.
    ///
    /// "Did the reader zoom" compares against ``Coordinator/fittedScale``, not the `autoScales`
    /// flag (see there). Skipped with ⌥ held: the panes are deliberately apart, with no one zoom.
    ///
    /// Reported on the next turn, because dismantle runs inside a view-graph update and the closure
    /// writes `@State`. Only the next mount reads it, so the delay costs nothing.
    static func dismantleNSView(_ nsView: NSSplitView, coordinator: Coordinator) {
        guard !coordinator.syncSuspended,
              let pane = coordinator.left, pane.document != nil,
              let fitted = coordinator.fittedScale,
              abs(pane.scaleFactor - fitted) > 0.001 else { return }
        let zoom = pane.scaleFactor
        let report = coordinator.onZoomChange
        DispatchQueue.main.async { report(zoom) }
    }

    private func makePDFView() -> PDFView {
        let view = PDFView()
        view.autoScales = true
        // Continuous, so the panes can scroll at all: in `.singlePage`, `autoScales` fits the page
        // to the pane exactly and a scroll gesture is clamped to nothing. The two sides are
        // mirrored (`wireScroll`), and `onPageChange` walks the strip along with them.
        view.displayMode = .singlePageContinuous
        // Page breaks, so a continuous document doesn't scroll as one unbroken column with no
        // sign of where a page ends.
        view.displaysPageBreaks = true
        view.backgroundColor = .textBackgroundColor
        return view
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        let coordinator = context.coordinator
        coordinator.syncSuspended = syncSuspended
        coordinator.onPageChange = onPageChange
        coordinator.onZoomChange = onZoomChange
        coordinator.surfacePage = page
        coordinator.surfaceZoom = zoom
        // Recorded first, on every update: a turn while the documents are still opening reaches
        // the panes only through this, since `go` has nothing to act on yet.
        coordinator.requestedPages = (pairing.leftIndex(at: page), pairing.rightIndex(at: page))
        if coordinator.loaded?.left != leftPath || coordinator.loaded?.right != rightPath {
            coordinator.loaded = (leftPath, rightPath)
            coordinator.scrollWired = false
            load(leftPath, into: coordinator.left, side: \.left, coordinator: coordinator)
            load(rightPath, into: coordinator.right, side: \.right, coordinator: coordinator)
        } else {
            coordinator.drivingPage = true
            go(coordinator.left, to: coordinator.requestedPages.left)
            go(coordinator.right, to: coordinator.requestedPages.right)
            coordinator.drivingPage = false
        }
    }

    /// Puts both panes at the zoom the surface remembers.
    ///
    /// With no remembered zoom (the ordinary first mount) nothing happens, and `autoScales` fits
    /// the page. Once a zoom has been chosen, `autoScales` goes off, so the next overlay resize
    /// doesn't re-fit and discard the reader's choice.
    ///
    /// Applied inline: PDFKit's initial fit does not overwrite it. If a fit ever wins that race,
    /// `aFreshStaticMountAppliesTheZoomItWasGiven` fails.
    @MainActor
    private func applyZoom(_ coordinator: Coordinator) {
        guard let zoom = coordinator.surfaceZoom else { return }
        for view in [coordinator.left, coordinator.right].compactMap({ $0 }) {
            guard view.document != nil, abs(view.scaleFactor - zoom) > 0.001 else { continue }
            view.autoScales = false
            view.scaleFactor = zoom
        }
    }

    private func load(_ path: String, into view: PDFView?,
                      side: KeyPath<(left: Int, right: Int), Int>,
                      coordinator: Coordinator) {
        guard let view else { return }
        Task { @MainActor in
            let document = await PDFKitSerialAccess.perform {
                PDFDocument(url: URL(fileURLWithPath: path)).map(SendableDocument.init)
            }
            coordinator.drivingPage = true
            view.document = document?.document
            // The page as it stands now, not when this open was queued: a turn during the open
            // reaches the view only here.
            go(view, to: coordinator.requestedPages[keyPath: side])
            coordinator.drivingPage = false
            // The remembered zoom, now there is a document; `autoScales` has just fitted this page
            // and would otherwise have the last word.
            applyZoom(coordinator)
            // Here, not in `makeNSView`: a `PDFView` with no document has no `documentView`, so no
            // clip view to observe, and registering earlier would silently register nothing.
            wireScroll(coordinator)
        }
    }

    @MainActor
    private func go(_ view: PDFView?, to index: Int) {
        guard let view, let document = view.document,
              index >= 0, index < document.pageCount,
              let target = document.page(at: index) else { return }
        guard view.currentPage != target else { return }
        view.go(to: target)
    }

    /// Mirrors magnification between the two views. Registrable at construction: the notification
    /// is posted by the `PDFView` itself, which exists from the moment it is made.
    ///
    /// Page changes are not mirrored: the surface owns the page (the strip, ⇞/⇟), and a viewer
    /// pushing pages at its twin would fight it. Scroll and zoom have no such owner.
    private func wireZoom(_ coordinator: Coordinator) {
        guard let left = coordinator.left, let right = coordinator.right else { return }
        for (source, target) in [(left, right), (right, left)] {
            let zoom = NotificationCenter.default.addObserver(
                forName: .PDFViewScaleChanged, object: source, queue: .main
            ) { [weak coordinator, weak target, weak source] _ in
                guard let coordinator, let target, let source else { return }
                // A pane still auto-fitting is reporting a fit, not a zoom. Recorded before the ⌥
                // guard, because a fit is a fit whether or not the panes are held apart.
                if source.autoScales { coordinator.fittedScale = source.scaleFactor }
                guard !coordinator.syncSuspended else { return }
                coordinator.latch.mirror {
                    guard abs(target.scaleFactor - source.scaleFactor) > 0.001 else { return }
                    target.scaleFactor = source.scaleFactor
                }
            }
            coordinator.observers.append(zoom)
        }
    }

    /// Reports the page the reader has scrolled onto, so the strip follows the panes.
    ///
    /// The surface still owns the page; this reports, it doesn't decide. A continuous scroll moves
    /// the document without touching the strip, and a strip left on page 1 with page 4 on screen
    /// would have the pixel modes diffing a page nobody is looking at.
    ///
    /// Both sides report, and the echo is suppressed by value: a report equal to the surface's own
    /// page is no report. That also collapses the second side's post after a mirrored scroll.
    ///
    /// ⌥ silences the report too, separately from the scroll mirror: the surface sets the page for
    /// both panes, so a ⌥-held scroll across a page boundary would drag the other pane there. On
    /// release the surface's page drives both panes back into step.
    private func wirePageReporting(_ coordinator: Coordinator) {
        for view in [coordinator.left, coordinator.right].compactMap({ $0 }) {
            let observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak coordinator, weak view] _ in
                guard let coordinator, let view,
                      !coordinator.drivingPage, !coordinator.syncSuspended,
                      let document = view.document, let current = view.currentPage else { return }
                let index = document.index(for: current)
                guard index >= 0, index != coordinator.surfacePage else { return }
                // Recorded before the call, so a synchronous re-entry from the surface's own
                // update cannot read the stale value and report the same page twice.
                coordinator.surfacePage = index
                coordinator.onPageChange(index)
            }
            coordinator.observers.append(observer)
        }
    }

    /// Mirrors scroll, once both sides have a document.
    ///
    /// **Call it from the document load, not `makeNSView`**: a `PDFView` with no document has no
    /// `documentView`, hence no clip view to observe, and registering earlier silently registers
    /// nothing while the zoom half makes the pair look synchronised. Idempotent, because both
    /// sides' loads call it and only the second can succeed.
    @MainActor
    private func wireScroll(_ coordinator: Coordinator) {
        guard !coordinator.scrollWired,
              let left = coordinator.left, let right = coordinator.right,
              let leftClip = left.documentView?.enclosingScrollView?.contentView,
              let rightClip = right.documentView?.enclosingScrollView?.contentView else { return }
        coordinator.scrollWired = true
        // The previous pair's observers go as this pair's arrive; see `replaceScrollObservers`.
        coordinator.replaceScrollObservers {
            [(leftClip, right), (rightClip, left)].map { sourceClip, target in
                sourceClip.postsBoundsChangedNotifications = true
                return NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: sourceClip, queue: .main
                ) { [weak coordinator, weak target, weak sourceClip] _ in
                    guard let coordinator, let target, let sourceClip,
                          !coordinator.syncSuspended else { return }
                    coordinator.latch.mirror {
                        guard let targetScroll = target.documentView?.enclosingScrollView else { return }
                        targetScroll.contentView.scroll(to: sourceClip.bounds.origin)
                        targetScroll.reflectScrolledClipView(targetScroll.contentView)
                    }
                }
            }
        }
    }
}

// MARK: - Image pair

/// Two images in scroll views, zoom- and scroll-synchronised.
///
/// The same latch and the same ⌥ suspension as the PDF pair. Images are decoded at a bounded size
/// by the caller (``PagePairRaster/renderImage(path:longEdge:)``): a 100-megapixel raw decodes to
/// ~400 MB at full resolution, and a compare needs a picture, not the pixels.
struct ImagePairView: NSViewRepresentable {

    let left: CGImage?
    let right: CGImage?
    let syncSuspended: Bool

    final class Coordinator: NSObject {
        let latch = SyncLatch()
        var observers: [NSObjectProtocol] = []
        var scrollViews: [NSScrollView] = []
        var syncSuspended = false
        /// The two rasters currently on screen, by identity — see `updateNSView`.
        var shown: [CGImage?] = [nil, nil]
        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        let a = makeScrollView(), b = makeScrollView()
        context.coordinator.scrollViews = [a, b]
        split.addArrangedSubview(a)
        split.addArrangedSubview(b)
        wire(context.coordinator)
        return split
    }

    private func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8
        scroll.backgroundColor = .textBackgroundColor
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        scroll.documentView = imageView
        return scroll
    }

    /// Assigns only what changed. `updateNSView` runs on every render above it (every manager
    /// publish, every pointer event of a divider drag), and reassigning an unchanged image resets
    /// the image view and its frame. `CGImage` is immutable, so identity is the whole question.
    func updateNSView(_ split: NSSplitView, context: Context) {
        context.coordinator.syncSuspended = syncSuspended
        let images = [left, right]
        for (index, scroll) in context.coordinator.scrollViews.enumerated() {
            guard let imageView = scroll.documentView as? NSImageView else { continue }
            guard context.coordinator.shown[index] !== images[index] else { continue }
            context.coordinator.shown[index] = images[index]
            if let image = images[index] {
                let size = CGSize(width: image.width, height: image.height)
                imageView.image = NSImage(cgImage: image, size: size)
                imageView.frame = CGRect(origin: .zero, size: size)
            } else {
                imageView.image = nil
            }
        }
    }

    private func wire(_ coordinator: Coordinator) {
        let views = coordinator.scrollViews
        guard views.count == 2 else { return }
        for (index, source) in views.enumerated() {
            let target = views[1 - index]
            source.contentView.postsBoundsChangedNotifications = true
            let observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: source.contentView, queue: .main
            ) { [weak coordinator, weak target, weak source] _ in
                guard let coordinator, let target, let source, !coordinator.syncSuspended else { return }
                coordinator.latch.mirror {
                    if abs(target.magnification - source.magnification) > 0.001 {
                        target.magnification = source.magnification
                    }
                    target.contentView.scroll(to: source.contentView.bounds.origin)
                    target.reflectScrolledClipView(target.contentView)
                }
            }
            coordinator.observers.append(observer)
        }
    }
}
