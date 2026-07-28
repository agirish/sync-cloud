import AppKit
import Events
import SwiftUI

/// Instrumentation for the open jitter report: "selecting folders in other columns makes the 1st
/// column move up and down".
///
/// The headless harness cannot reproduce it — driving the same `browsePath`/`selection` writes a
/// click commits leaves every column's frame, clip offset and the stack's offset pixel-still — so
/// whatever moves involves the live event stream. Rather than guess, each column logs its own
/// vertical scroll offset changes; the `[tap]`/`[sel]` lines already in the log give the clicks,
/// and correlating timestamps says which column moved, when, and by how much.
///
/// Coalesced to at most one line per column per 250ms, spanning from the position the excursion
/// started at to where it is now — a burst of 60Hz scroll callbacks folds into one line, so a
/// normal user scroll costs a handful of lines, not hundreds.
struct PaneColumnJitterProbe: NSViewRepresentable {
    /// Column position in the stack, for the log line.
    let depth: Int
    let isLeft: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.label = "\(isLeft ? "left" : "right") col\(depth)"
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.label = "\(isLeft ? "left" : "right") col\(depth)"
        view.rearm()
    }

    final class ProbeView: NSView {
        var label = "?"
        private weak var observedClip: NSClipView?
        private var observer: NSObjectProtocol?
        private var budget = 4
        /// Test seams: instrumentation that silently never fires would report a healthy pane, so
        /// the mounted test scrolls a column and asserts a line was actually emitted.
        private(set) var linesLogged = 0
        var resolvedClip: NSClipView? { observedClip }

        /// The window's travel so far. Extremes, not endpoints: a quick bob down and back inside
        /// one window has identical endpoints, and the bob is precisely what's being hunted.
        private var windowMin: CGFloat?
        private var windowMax: CGFloat?
        private var windowStart: CGFloat?
        private var pendingFlush: DispatchWorkItem?
        private static let coalesce: TimeInterval = 0.25

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                observer = nil
                observedClip = nil
                pendingFlush?.cancel()
                pendingFlush = nil
                return
            }
            rearm()
        }

        func rearm() {
            budget = 4
            DispatchQueue.main.async { [weak self] in self?.resolveAndObserve() }
        }

        override func layout() {
            super.layout()
            resolveAndObserve()
        }

        private func resolveAndObserve() {
            guard window != nil else { return }
            if let observedClip, observedClip.window === window, observer != nil { return }
            guard budget > 0 else { return }
            budget -= 1
            // A List's `.background` sits BESIDE the list's scroll view, not inside it, so an
            // ancestor walk never enters it. `PaneListResolver` does this resolution for every
            // background sibling that needs it — by frame, because in a column stack the lists are
            // siblings and tree position cannot tell them apart. This probe was resolving only the
            // first column before that changed, which is worth knowing when reading any jitter
            // sample taken before it.
            guard let table = PaneListResolver.table(matching: self),
                  let scroller = table.enclosingScrollView else { return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            let clip = scroller.contentView
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.recordSample() }
            }
            observedClip = clip
            windowStart = clip.bounds.origin.y
        }

        private func recordSample() {
            guard let clip = observedClip else { return }
            let y = clip.bounds.origin.y
            if windowStart == nil { windowStart = y }
            windowMin = min(windowMin ?? y, y)
            windowMax = max(windowMax ?? y, y)
            // Trailing flush: the burst's last notification still gets its window reported.
            if pendingFlush == nil {
                let work = DispatchWorkItem { [weak self] in self?.flushWindow() }
                pendingFlush = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesce, execute: work)
            }
        }

        private func flushWindow() {
            pendingFlush = nil
            defer {
                windowStart = observedClip?.bounds.origin.y
                windowMin = nil
                windowMax = nil
            }
            guard let clip = observedClip, let start = windowStart,
                  let low = windowMin, let high = windowMax else { return }
            let now = clip.bounds.origin.y
            // Only genuine travel is worth a line — and a window that ended where it began but
            // visited somewhere else in between is the bob being hunted, so range decides.
            guard max(high, start, now) - min(low, start, now) >= 0.5 else { return }
            linesLogged += 1
            Logger.shared.debug(String(
                format: "[col] %@ y %.1f → %.1f (range %.1f…%.1f)", label, start, now, low, high))
        }
    }
}
