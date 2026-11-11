import AppKit
import SwiftUI

/// Which wheel events over Info the column stack gets too.
///
/// Info is drawn over the column stack, not inside its scroll view, so AppKit sends a swipe that
/// starts over Info to Info's own (vertical) scroll view alone: a sideways swipe there would move
/// nothing, a missed scroll in what looks like one more column. So every event of a gesture that
/// starts over Info also goes to the stack. Info keeps its own vertical scrolling; the stack, which
/// scrolls only sideways, takes the horizontal part. A vertical swipe can't nudge the stack: the
/// stack's axis lock (`WheelGestureTracker`) holds it, since the gesture starts within its bounds.
///
/// A gesture is claimed by where its first event lands (`.mayBegin` or `.began`) and keeps that
/// answer through its momentum, wherever the pointer drifts, as AppKit routes the gesture. A plain
/// wheel's events carry no phase, so each is its own gesture. Pure, so the rule is tested without
/// synthesizing `NSEvent`s.
struct PaneInfoWheelRouting {
    private(set) var claimed = false

    mutating func forwards(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, overInfo: Bool) -> Bool {
        if phase.isEmpty && momentumPhase.isEmpty {
            claimed = false
            return overInfo
        }
        if phase.contains(.mayBegin) || phase.contains(.began) {
            claimed = overInfo
        }
        let answer = claimed
        if momentumPhase.contains(.ended) || phase.contains(.cancelled) {
            claimed = false
        }
        return answer
    }

    /// Whether a point is over Info as it is seen: inside Info's frame and inside the stack's
    /// scroll view, which Info is masked to. Info scrolled past the stack's edge still has its
    /// frame there, over the next pane, and a swipe in that pane is that pane's. All in window
    /// coordinates; no stack, no claim.
    static func isOverInfo(_ point: NSPoint, info: NSRect, stack: NSRect?) -> Bool {
        guard let stack else { return false }
        return info.contains(point) && stack.contains(point)
    }
}

public extension View {
    /// Hands every wheel gesture that starts over this view (Info as a column) to the column
    /// stack too (`PaneInfoWheelRouting`). Nothing where the pane has no stack.
    func forwardsWheelGesturesToColumns(_ slot: PaneInfoSlot) -> some View {
        background(PaneInfoWheelForwarder(slot: slot))
    }
}

/// Watches the app's wheel events while Info is on screen, and passes those `PaneInfoWheelRouting`
/// claims to the stack's scroll view. Never a hit-test target: it only listens.
struct PaneInfoWheelForwarder: NSViewRepresentable {
    let slot: PaneInfoSlot

    func makeNSView(context: Context) -> ForwarderView {
        let view = ForwarderView()
        view.slot = slot
        return view
    }

    func updateNSView(_ view: ForwarderView, context: Context) {
        view.slot = slot
    }

    static func dismantleNSView(_ view: ForwarderView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class ForwarderView: NSView {
        weak var slot: PaneInfoSlot?
        private var monitor: Any?
        private var routing = PaneInfoWheelRouting()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopMonitoring() } else { startMonitoring() }
        }

        private func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window else { return }
            let scroller = slot?.stackScroller.flatMap { $0.window === window ? $0 : nil }
            let overInfo = PaneInfoWheelRouting.isOverInfo(event.locationInWindow, info: convert(bounds, to: nil),
                                                           stack: scroller.map { $0.convert($0.bounds, to: nil) })
            guard routing.forwards(phase: event.phase, momentumPhase: event.momentumPhase, overInfo: overInfo),
                  let stack = scroller else { return }
            stack.scrollWheel(with: event)
        }
    }
}

/// Finds the column stack's scroll view from inside it and gives it to Info's slot
/// (`PaneInfoSlot.stackScroller`). Mounted in the room the stack keeps for Info.
struct PaneInfoStackProbe: NSViewRepresentable {
    let slot: PaneInfoSlot

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.slot = slot
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.slot = slot
        view.resolve()
    }

    final class ProbeView: NSView {
        weak var slot: PaneInfoSlot?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolve()
        }

        override func layout() {
            super.layout()
            resolve()
        }

        func resolve() {
            guard window != nil, let slot else { return }
            let scroller = PaneColumnsOverscrollReturn.WatchdogView.findStackScrollView(from: self)
            if slot.stackScroller !== scroller { slot.stackScroller = scroller }
        }
    }
}
