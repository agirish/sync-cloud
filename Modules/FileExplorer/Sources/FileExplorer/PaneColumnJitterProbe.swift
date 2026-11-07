import AppKit
import Events
import SwiftUI

/// The opt-in switch for the pane's frame-rate diagnostics: the column travel trace, and the
/// per-click `[tap]`/`[sel]`/`[render]` stamps.
///
/// Off by default, which matters: these lines come per frame of scrolling and per click, a
/// few hundred lines for a few seconds of scrolling. `LogFileWriter` caps the log at 5 MB and keeps
/// only its newest part, so scroll noise would evict the sync runs, errors and scan results the log
/// exists to preserve.
///
/// What stays ungated describes a decision rather than a frame: `[click]`, `[columns]`, `[crumb]`,
/// `[deselect]`. They are rare, actionable, and what the next report will need.
@MainActor
enum PaneScrollTrace {
    /// `defaults write com.abhishekgirish.SyncCloud paneScrollTraceEnabled -bool YES` to turn the
    /// trace on for a diagnostic session.
    static let defaultsKey = "paneScrollTraceEnabled"

    /// Read once, so a per-frame log site costs a Bool rather than a `UserDefaults` lookup. Tests
    /// set it directly to drive the emission they assert on.
    static var isEnabled = UserDefaults.standard.bool(forKey: defaultsKey)
}

/// Watches one column's list: logs its vertical travel, and pulls it home when it parks
/// stretched in overscroll.
///
/// **A list can park in vertical overscroll**: a gesture that starts diagonal is claimed by one
/// scroll view of the nested pair, its deltas reach the other without phase, and the rubber band
/// stretches and never hears the release, then snaps back late. The same lost-phase problem
/// `PaneColumnsOverscrollReturn` treats on the stack's horizontal axis.
///
/// The same treatment, with the same constants: any bounds movement re-arms the quiescence timer,
/// and a list found resting out of its legal range past the tolerance is animated home. A healthy
/// native bounce keeps moving until it settles in range, so it is never touched, and the tolerance
/// leaves sub-point parking alone so the watchdog can't pull in a loop.
///
/// The travel log (one coalesced line per column per 250ms of movement) and the pulls log behind
/// `PaneScrollTrace`, so the next report can be read straight off the file.
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

    final class ProbeView: BoundedResolveView {
        var label = "?"
        private weak var observedClip: NSClipView?
        private var observer: NSObjectProtocol?
        /// Test seams: instrumentation that silently never fires would report a healthy pane, so
        /// the mounted test scrolls a column and asserts a line was actually emitted.
        private(set) var linesLogged = 0
        var resolvedClip: NSClipView? { observedClip }

        /// How long the pull home takes. Injectable for the reason `docs/flaky-tests.md` gives in
        /// "The machine decides the verdict — throttled CoreAnimation", as the stack watchdog's
        /// `PaneColumnsOverscrollReturn.WatchdogView.pullDuration` is: the pull is an implicit
        /// CoreAnimation animation in an offscreen, never-key test window, and when CoreAnimation
        /// is starved (display asleep, Low Power Mode, a full parallel run) it never advances, so a
        /// test waiting for home times out and reports the start state.
        ///
        /// Zero means no animation at all, not a very fast one: a zero-duration group still defers
        /// through CoreAnimation and can be starved the same way.
        ///
        /// The default is pinned by `theListPullHomeShipsAnimated`: with every test mount injecting
        /// zero, nothing else reads the shipped value, and a drift to zero would silently delete
        /// the bounce.
        var pullDuration: TimeInterval = ProbeView.defaultPullDuration

        /// What the app ships: long enough to read as a bounce, short enough not to feel like a
        /// correction. The same number the stack watchdog ships.
        static let defaultPullDuration: TimeInterval = 0.25

        /// The window's travel so far. Extremes, not endpoints: a quick bob down and back inside
        /// one window has identical endpoints, and the bob is what's being hunted.
        private var windowMin: CGFloat?
        private var windowMax: CGFloat?
        private var windowStart: CGFloat?
        private var pendingFlush: DispatchWorkItem?
        /// Coalesces the quiescence re-arm: one timer per rest window, not a `DispatchWorkItem` per
        /// bounds change, which matters with one probe per open column. See `QuiescenceTimer`.
        /// `Self.quiescence` is `BoundedResolveView`'s, the interval the stack's watchdog uses too.
        private lazy var pullCheck = QuiescenceTimer(quiescence: Self.quiescence)
        private static let coalesce: TimeInterval = 0.25

        override func windowDidExit() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            observedClip = nil
            pendingFlush?.cancel()
            pendingFlush = nil
            pullCheck.cancel()
        }

        override func resolvePass() {
            guard window != nil else { return }
            if let observedClip, observedClip.window === window, observer != nil { return }
            guard spendSearchBudget() else { return }
            // A List's `.background` sits beside the list's scroll view, not inside it, so an
            // ancestor walk never enters it. `PaneListResolver` resolves by frame, because in a
            // column stack the lists are siblings and tree position can't tell them apart.
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

        /// Re-arms the quiescence timer, as the stack's watchdog does: while the list is moving (a
        /// drag, momentum, a working native spring) the check never runs; it fires only at rest.
        private func scheduleReturn() {
            pullCheck.noteActivity { [weak self] in self?.returnHomeIfParked() }
        }

        private func returnHomeIfParked() {
            guard let clip = observedClip else { return }
            let origin = clip.bounds.origin
            // `legalOrigin` and `tolerance` are `BoundedResolveView`'s, alongside `quiescence`,
            // shared with the stack's watchdog through the base.
            let home = Self.legalOrigin(for: origin, clip: clip)
            guard max(abs(home.x - origin.x), abs(home.y - origin.y)) >= Self.tolerance else { return }
            // Gated like the travel log: a pull is rare when healthy, but in a correction loop it
            // fires per frame and would evict the 1000-entry buffer's real context.
            // `paneScrollTraceEnabled` is the switch that shows it.
            if PaneScrollTrace.isEnabled {
                Logger.shared.debug(String(
                    format: "[col] %@ pull (%.2f, %.2f) → (%.2f, %.2f)",
                    label, origin.x, origin.y, home.x, home.y))
            }
            if pullDuration > 0 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = pullDuration
                    context.allowsImplicitAnimation = true
                    clip.setBoundsOrigin(home)
                }
            } else {
                // Straight to the answer, with no animation to be starved of ticks.
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
            // Only genuine travel is worth a line, and a window that ended where it began but moved
            // in between is the bob being hunted, so range decides.
            guard max(high, start, now) - min(low, start, now) >= 0.5 else { return }
            // Checked after the window is measured and before anything is written, so the sampling
            // (and the `defer` that rolls the window forward) is the same whether or not the trace
            // is on.
            guard PaneScrollTrace.isEnabled else { return }
            linesLogged += 1
            Logger.shared.debug(String(
                format: "[col] %@ y %.1f → %.1f (range %.1f…%.1f)", label, start, now, low, high))
        }
    }
}
