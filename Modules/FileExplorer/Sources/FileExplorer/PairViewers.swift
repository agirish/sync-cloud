import AppKit
import PDFKit
import SwiftUI
import Sync

// MARK: - The reentrancy latch

/// The one guard every synchronised pair needs: while a change is being mirrored to the other
/// side, that side's own notification must not mirror it back.
///
/// **A `Bool` set and cleared around the mirror, not a comparison of values.** Comparing values
/// ("only mirror if they differ") looks equivalent and is not: the two views quantise scroll
/// offsets and magnification differently, so A → B → A' lands a hair off A, which differs again,
/// and the pair walks. The latch stops the loop at one hop regardless of what the far side rounds
/// to.
///
/// A class, and deliberately not `@State`: the notification handlers are AppKit closures that
/// outlive a SwiftUI update, and a value type captured by them would be a copy.
final class SyncLatch {
    private var mirroring = false

    /// Runs `body` with the latch held, unless it is already held — in which case this is the
    /// echo, and it does nothing. Returns whether it ran.
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
/// **This is what phase 1 could not do.** `QLPreviewView` exposes no scroll or zoom API at all —
/// the app sets exactly three properties on it and by design knows nothing about formats — so
/// synchronised Quick Look panes are not merely unbuilt, they are unbuildable. A typed viewer has
/// the document, the page and the scroll view, which is why sync arrives with typed viewers and
/// not before.
///
/// **Documents are opened through `PDFKitSerialAccess`, never on the main actor.** `PDFDocument(url:)`
/// parses, PDFKit's parsing is not thread-safe, and `run` would be `queue.sync` from the main
/// thread — the whole window waiting behind a running scan's extractions.
struct PDFPairView: NSViewRepresentable {

    let leftPath: String
    let rightPath: String
    /// The page both sides show, clamped per side by ``PagePairing``.
    let page: Int
    let pairing: PagePairing
    /// Suspends mirroring while held — ⌥ lets one pane be scrolled on its own.
    let syncSuspended: Bool
    /// The page the reader has scrolled onto, reported back so the strip and the pixel modes
    /// follow. Only ever called with a page the surface is not already on.
    var onPageChange: (Int) -> Void = { _ in }

    final class Coordinator: NSObject {
        let latch = SyncLatch()
        var observers: [NSObjectProtocol] = []
        var left: PDFView?
        var right: PDFView?
        var syncSuspended = false
        /// The paths the loaded documents came from, so `updateNSView` reloads only on a real
        /// change — re-opening the same document on every ancestor render is a parse per redraw.
        var loaded: (left: String, right: String)?
        /// Whether the SCROLL observers are registered. They cannot be registered at construction
        /// (see `wireScroll`), and registering them twice would mirror every scroll twice.
        var scrollWired = false
        /// Just the scroll observers, so a re-wire after a path change can drop the previous
        /// pair's without disturbing the zoom ones, which are registered once for the view's life.
        ///
        /// **Disjoint from ``observers``, not a subset of it, and maintained only through
        /// ``replaceScrollObservers(_:)``.** A token held in both lists survives the re-wire in the
        /// other one: this list is cleared and `observers` goes on holding a token already removed
        /// from the centre, for the life of the view and growing by two per pair opened.
        private(set) var scrollObservers: [NSObjectProtocol] = []

        /// Swaps this pair's scroll observers in and the previous pair's out, in one step.
        ///
        /// **One step, because two was the bug.** The `PDFView`s are reused across a path change,
        /// so their clip views can be the very same objects — a second registration on one clip
        /// mirrors every scroll twice, and the latch hiding that in effect is exactly what let it
        /// go unnoticed as a leak in fact.
        func replaceScrollObservers(_ make: () -> [NSObjectProtocol]) {
            for observer in scrollObservers { NotificationCenter.default.removeObserver(observer) }
            scrollObservers = make()
        }
        /// The page each side should be showing, as of the most recent `updateNSView`.
        ///
        /// **Read by the load completion rather than captured at its start**, because a page turn
        /// during the open is otherwise dropped on the floor: `go` bails while `document` is still
        /// nil, and the load then goes to the index it captured before the turn. The strip pointed
        /// at page 12 and the panes sat on page 1 until the next turn — most likely exactly when
        /// the lane is busy behind a scan, which is when the open is slow enough to click through.
        var requestedPages: (left: Int, right: Int) = (0, 0)
        /// The surface's page as of the last update, so a report can be suppressed when it merely
        /// echoes a page the surface itself just asked for.
        var surfacePage = 0
        /// True while THIS view is driving its own page — setting a document, or going to the page
        /// the surface asked for.
        ///
        /// **A value check alone did not hold, and the reason is the document assignment.** Setting
        /// `document` puts the view on page 1 and posts, which is a page the surface never asked
        /// for: the handler took it as a reader's move, reported it, and recorded it — so the `go`
        /// that followed a moment later no longer matched what was recorded and was reported too.
        /// A surface opened on page 2 was told twice that the reader had gone somewhere.
        var drivingPage = false
        /// Re-read on every update rather than captured once: a SwiftUI view is a fresh value on
        /// every render, and an observer holding the FIRST one would be calling into a closure
        /// whose captured state stopped moving.
        var onPageChange: (Int) -> Void = { _ in }

        deinit {
            // Both lists, because they are disjoint: `observers` holds the ones registered once
            // for the view's life, `scrollObservers` the ones a path change re-registers. Keeping
            // a scroll observer in both was the shape this started as, and it meant the re-wire
            // could drop it from one list and leave it in the other — a token already removed from
            // the centre, retained for the life of the view and growing by two per pair opened.
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
        // Only the zoom half can be wired now — see `wireScroll`. The page observers go here too:
        // like the scale notification, `PDFViewPageChanged` is posted BY the view, which exists.
        wireZoom(context.coordinator)
        wirePageReporting(context.coordinator)
        return split
    }

    private func makePDFView() -> PDFView {
        let view = PDFView()
        view.autoScales = true
        // **Continuous, so that scrolling is a thing this surface can do at all.**
        //
        // This was `.singlePage`, on the reasoning that the strip and ⇞/⇟ are the navigation and a
        // continuous scroll would put the two sides on different pages with nothing saying so.
        // Measured, that reasoning cost more than it bought: `autoScales` fits the page to the
        // pane, so at the size the overlay actually opens a US Letter page lays out at 792.0pt
        // inside a 792.0pt clip view — the content fits to the pixel and a scroll gesture is
        // clamped to nothing. Both panes sat dead under the reader's fingers, which reads as
        // "these do not scroll together" and is really "neither one scrolls".
        //
        // The objection it was built on no longer holds either: the two sides are mirrored now
        // (`wireScroll`, fixed after it was found registering nothing), so a scroll moves both, and
        // `onPageChange` walks the strip along with them rather than leaving it pointing elsewhere.
        view.displayMode = .singlePageContinuous
        // Page breaks earn their space once pages flow past each other: without them a two-page
        // document scrolls as one unbroken column and the reader cannot see where one page ends.
        view.displaysPageBreaks = true
        view.backgroundColor = .textBackgroundColor
        return view
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        let coordinator = context.coordinator
        coordinator.syncSuspended = syncSuspended
        coordinator.onPageChange = onPageChange
        coordinator.surfacePage = page
        // Recorded FIRST, and on every update: a turn arriving while the documents are still
        // opening reaches the panes only through this, since the `go` below has nothing to act on
        // yet. See `Coordinator.requestedPages`.
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
            // The page as it stands NOW, not as it stood when this open was queued — a turn during
            // the open reaches the view only here.
            go(view, to: coordinator.requestedPages[keyPath: side])
            coordinator.drivingPage = false
            // **HERE, not in `makeNSView`.** A `PDFView` with no document has no `documentView`,
            // so it has no scroll view and no clip view to observe — the observers registered at
            // construction found nil and silently registered nothing, and the panes then scrolled
            // independently while every other part of the sync looked correct. This is the moment
            // both halves exist.
            wireScroll(coordinator)
        }
    }

    /// A `PDFDocument` crossing back from the lane. `@unchecked` for the same reason
    /// ``SendableImage`` is: PDFKit's types carry no conformance, and this one is created inside
    /// the lane and handed to exactly one view.
    private struct SendableDocument: @unchecked Sendable {
        let document: PDFDocument
        init(_ document: PDFDocument) { self.document = document }
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
    /// Page changes are NOT mirrored: the page is owned by the surface (the strip, ⇞/⇟), and a
    /// viewer that also pushed page changes at its twin would fight the surface's own state for
    /// which page is current. Scroll and zoom have no such owner, so they are mirrored.
    private func wireZoom(_ coordinator: Coordinator) {
        guard let left = coordinator.left, let right = coordinator.right else { return }
        for (source, target) in [(left, right), (right, left)] {
            let zoom = NotificationCenter.default.addObserver(
                forName: .PDFViewScaleChanged, object: source, queue: .main
            ) { [weak coordinator, weak target, weak source] _ in
                guard let coordinator, let target, let source,
                      !coordinator.syncSuspended else { return }
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
    /// **The page is still owned by the surface — this reports, it does not decide.** Continuous
    /// scrolling means the reader can move the document without ever touching the strip or ⇞/⇟,
    /// and a strip left pointing at page 1 while page 4 is on screen would be describing a
    /// different document than the one being read; worse, the pixel modes would be diffing a page
    /// nobody is looking at. So each view says which page it landed on and the surface decides.
    ///
    /// **Both sides report, and the echo is suppressed by value, not by a latch.** The surface
    /// setting a page moves both views, each of which posts — so the guard is that a report equal
    /// to what the surface already asked for is not a report at all. That also collapses the second
    /// side's notification when a mirrored scroll carries it onto the same page.
    ///
    /// **⌥ silences the report, and that is not the same guard as the scroll mirror's.** While ⌥ is
    /// held the two viewers stop mirroring so one pane can be moved alone — but a report is not a
    /// mirror, it is a message to the surface, and the surface owns the page for BOTH panes. So a
    /// ⌥-held scroll that crossed a page boundary reported it, the surface set its page, and the
    /// next update drove the other pane there: the one thing ⌥ exists to prevent, arriving by the
    /// long way round. Nothing said so, because the scroll offsets really had stopped mirroring —
    /// only whole pages jumped. Released, the surface's page drives both panes back into step,
    /// which is what ⌥ being held-and-released means.
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
    /// **Called from the document load, and this is the correction that matters.** A `PDFView`
    /// with no document has no `documentView`, hence no enclosing scroll view and no clip view to
    /// observe — so registering these in `makeNSView` registered nothing at all, silently, while
    /// the zoom half worked and made the pair look synchronised. Idempotent, because both sides'
    /// loads call it and only the second one can succeed.
    @MainActor
    private func wireScroll(_ coordinator: Coordinator) {
        guard !coordinator.scrollWired,
              let left = coordinator.left, let right = coordinator.right,
              let leftClip = left.documentView?.enclosingScrollView?.contentView,
              let rightClip = right.documentView?.enclosingScrollView?.contentView else { return }
        coordinator.scrollWired = true
        // The previous pair's observers go as this pair's arrive — see `replaceScrollObservers`.
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

    func updateNSView(_ split: NSSplitView, context: Context) {
        context.coordinator.syncSuspended = syncSuspended
        let images = [left, right]
        for (index, scroll) in context.coordinator.scrollViews.enumerated() {
            guard let imageView = scroll.documentView as? NSImageView else { continue }
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
