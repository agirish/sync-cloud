import AppKit
import Events
import SwiftUI

/// Watches one column's list: logs its vertical travel, and pulls it home when it parks
/// stretched in overscroll.
///
/// This began as pure instrumentation for the jitter report ("the first column moves up and
/// down"), and what it recorded closed the case: `[col] right col0 y 0.0 → -17.5` followed
/// six hundred milliseconds later by `-17.5 → 0.0`. The list itself was PARKING in vertical
/// overscroll and snapping back on some later event — the same lost-gesture-phase disease
/// `PaneColumnsOverscrollReturn` treats on the stack's horizontal axis, on the lists' vertical
/// one. A gesture that starts diagonal is claimed by one scroll view of the nested pair and its
/// deltas reach the other without phase, so the rubber band stretches and never hears the
/// release. Parked stretch, late snap: the reported jitter, and — parked low — the original
/// "scroll brings down content lower".
///
/// So the same treatment applies, with the same constants: any bounds movement re-arms the
/// quiescence timer; a list found RESTING out of its legal range past the tolerance is animated
/// home. A healthy native bounce keeps its bounds moving until it settles in range, so the
/// watchdog never interferes with it, and the tolerance keeps sub-point pixel parking sacred —
/// the lesson of the stack watchdog's 18,000-pull night.
///
/// The travel log stays: it is one coalesced line per column per 250ms of actual movement, it is
/// what caught this, and the pulls log too — so the next report reads straight off the file.
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
        private var pendingReturn: DispatchWorkItem?
        private static let coalesce: TimeInterval = 0.25

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                observer = nil
                observedClip = nil
                pendingFlush?.cancel()
                pendingFlush = nil
                pendingReturn?.cancel()
                pendingReturn = nil
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
            // A list can already be parked stretched when the probe attaches (view-mode switch,
            // column reopened); give it its first check without waiting for a bounds change.
            scheduleReturn()
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
            scheduleReturn()
        }

        /// Re-arms the quiescence timer, exactly as the stack's watchdog does: while the list is
        /// genuinely moving — a drag, momentum, a native spring that works — the check never
        /// runs. It fires only once the list has come to rest.
        private func scheduleReturn() {
            pendingReturn?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.returnHomeIfParked() }
            pendingReturn = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + PaneColumnsOverscrollReturn.WatchdogView.quiescence,
                execute: work)
        }

        private func returnHomeIfParked() {
            guard let clip = observedClip else { return }
            let origin = clip.bounds.origin
            let home = PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(for: origin, clip: clip)
            let tolerance = PaneColumnsOverscrollReturn.WatchdogView.tolerance
            guard max(abs(home.x - origin.x), abs(home.y - origin.y)) >= tolerance else { return }
            Logger.shared.debug(String(
                format: "[col] %@ pull (%.2f, %.2f) → (%.2f, %.2f)",
                label, origin.x, origin.y, home.x, home.y))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                clip.setBoundsOrigin(home)
            }
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
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
