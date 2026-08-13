import AppKit
import Events
import SwiftUI

/// The opt-in switch for the pane's frame-rate diagnostics: the column travel trace, and the
/// per-click `[tap]`/`[sel]`/`[render]` stamps left over from the dead-click investigation.
///
/// **Off by default, and that is the load-bearing part.** These lines are emitted per frame of
/// scrolling and per click, not per thing the user did: the travel trace alone is one coalesced
/// line per column per 250ms of movement, so with three columns open in each pane a few seconds of
/// scrolling writes a few hundred lines describing nothing. That volume does not merely sit in the
/// file — `LogFileWriter` caps the log at 5 MB and trims it from the TAIL, so scroll noise evicts
/// the sync runs, errors and scan results the log exists to preserve. A user who scrolls for a
/// minute before hitting a real bug has thrown away the evidence of it.
///
/// What stays ungated is everything that describes a decision rather than a frame: `[click]`,
/// `[columns]`, `[crumb]`, `[deselect]`, and both watchdogs' `pull` lines. Those are rare,
/// actionable, and precisely what the next report will need — the travel trace earned its keep by
/// catching the park-and-snap `PaneColumnJitterProbe` now fixes, and it stays available for the
/// next one rather than being deleted.
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

    final class ProbeView: BoundedResolveView {
        var label = "?"
        private weak var observedClip: NSClipView?
        private var observer: NSObjectProtocol?
        /// Test seams: instrumentation that silently never fires would report a healthy pane, so
        /// the mounted test scrolls a column and asserts a line was actually emitted.
        private(set) var linesLogged = 0
        var resolvedClip: NSClipView? { observedClip }

        /// How long the pull home takes. Injectable for the reason `docs/flaky-tests.md`
        /// mechanism 1 gives, and for the reason the stack watchdog's identical seam gives: the
        /// pull is an implicit CoreAnimation animation, and the tests mount an offscreen,
        /// never-key window. When CoreAnimation is starved — display asleep, Low Power Mode, or
        /// simply a full parallel test run — that animation never advances, so
        /// `clip.bounds.origin` never reaches home and a test waiting on it burns its whole
        /// timeout and reports the START state. That is exactly what took
        /// `PaneColumnsOverscrollReturnCycleTests` red three times in one afternoon (22.8 s to
        /// give up against 1.4 s isolated, twice locally and once in CI) before
        /// `PaneColumnsOverscrollReturn.WatchdogView.pullDuration` was added; this file carried
        /// the same hardcoded 0.25 with no seam, so `PaneColumnListWatchdogTests` was the second,
        /// unmitigated copy of the hazard.
        ///
        /// Zero means "no animation at all", not "a very fast one" — a zero-duration group still
        /// defers through CoreAnimation and can be starved exactly the same way.
        ///
        /// **The default is pinned by a test** (`theListPullHomeShipsAnimated`), because once
        /// every mount in the suite injects zero, nothing reads the value the app actually ships
        /// and a default that drifted to zero would delete the bounce for real users in silence.
        var pullDuration: TimeInterval = ProbeView.defaultPullDuration

        /// What the app ships: long enough to read as a bounce, short enough not to feel like a
        /// correction. The same number the stack watchdog ships, for the same reason.
        static let defaultPullDuration: TimeInterval = 0.25

        /// The window's travel so far. Extremes, not endpoints: a quick bob down and back inside
        /// one window has identical endpoints, and the bob is precisely what's being hunted.
        private var windowMin: CGFloat?
        private var windowMax: CGFloat?
        private var windowStart: CGFloat?
        private var pendingFlush: DispatchWorkItem?
        /// Coalesces the quiescence re-arm — one timer per rest window instead of a fresh
        /// `DispatchWorkItem` per bounds-change notification. There is one of these probes per open
        /// column, so the old cost was multiplied by the whole stack. See `QuiescenceTimer`.
        /// `Self.quiescence` is the shared constant on `BoundedResolveView` — the same interval
        /// the stack's watchdog feeds its own timer.
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
            pullCheck.noteActivity { [weak self] in self?.returnHomeIfParked() }
        }

        private func returnHomeIfParked() {
            guard let clip = observedClip else { return }
            let origin = clip.bounds.origin
            // `legalOrigin` and `tolerance` are `BoundedResolveView`'s, alongside `quiescence`:
            // this probe used to reach across into `PaneColumnsOverscrollReturn.WatchdogView` for
            // all three, which is the coupling the shared base exists to remove.
            let home = Self.legalOrigin(for: origin, clip: clip)
            guard max(abs(home.x - origin.x), abs(home.y - origin.y)) >= Self.tolerance else { return }
            Logger.shared.debug(String(
                format: "[col] %@ pull (%.2f, %.2f) → (%.2f, %.2f)",
                label, origin.x, origin.y, home.x, home.y))
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
            // Only genuine travel is worth a line — and a window that ended where it began but
            // visited somewhere else in between is the bob being hunted, so range decides.
            guard max(high, start, now) - min(low, start, now) >= 0.5 else { return }
            // Checked AFTER the window has been measured and BEFORE anything is written, so the
            // sampling (and the `defer` above that rolls the window forward) behaves identically
            // whether or not anyone is listening. See `PaneScrollTrace`.
            guard PaneScrollTrace.isEnabled else { return }
            linesLogged += 1
            Logger.shared.debug(String(
                format: "[col] %@ y %.1f → %.1f (range %.1f…%.1f)", label, start, now, low, high))
        }
    }
}
