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

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
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
        // Only the zoom half can be wired now — see `wireScroll`.
        wireZoom(context.coordinator)
        return split
    }

    private func makePDFView() -> PDFView {
        let view = PDFView()
        view.autoScales = true
        // One page at a time: the surface's page strip and ⇞/⇟ are the navigation, and a
        // continuous scroll would put the two sides on different pages with nothing saying so.
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.backgroundColor = .textBackgroundColor
        return view
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        let coordinator = context.coordinator
        coordinator.syncSuspended = syncSuspended
        if coordinator.loaded?.left != leftPath || coordinator.loaded?.right != rightPath {
            coordinator.loaded = (leftPath, rightPath)
            coordinator.scrollWired = false
            load(leftPath, into: coordinator.left, page: pairing.leftIndex(at: page),
                 coordinator: coordinator)
            load(rightPath, into: coordinator.right, page: pairing.rightIndex(at: page),
                 coordinator: coordinator)
        } else {
            go(coordinator.left, to: pairing.leftIndex(at: page))
            go(coordinator.right, to: pairing.rightIndex(at: page))
        }
    }

    private func load(_ path: String, into view: PDFView?, page index: Int,
                      coordinator: Coordinator) {
        guard let view else { return }
        Task { @MainActor in
            let document = await PDFKitSerialAccess.perform {
                PDFDocument(url: URL(fileURLWithPath: path)).map(SendableDocument.init)
            }
            view.document = document?.document
            go(view, to: index)
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
        for (sourceClip, target) in [(leftClip, right), (rightClip, left)] {
            sourceClip.postsBoundsChangedNotifications = true
            let observer = NotificationCenter.default.addObserver(
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
            coordinator.observers.append(observer)
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
