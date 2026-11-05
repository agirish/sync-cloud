import AppKit
import SwiftUI
import Design
import FileExplorer

/// How a result message leaves when nobody undid or followed it: its time ran out, or ✕.
///
/// A click's result in a pane or the workspace simply goes, since the reader saw it where they
/// were working. A message the capsule shows, its own or one it mirrors from a pane, folds into its
/// ring and flies into the Activity button, where Recent keeps it, as the ✕'s tooltip promises.
/// Pure, so each refusal is testable without a toolbar.
enum ResultMessageExit: Equatable {
    /// Clear it where it is.
    case clear
    /// Clear it, and flash its row in the Activity popover that is open under the capsule.
    case flashInActivity
    /// Clear it, and the Activity button glows once: Reduce Motion's answer, and the answer when the
    /// flight has nowhere to start or land.
    case landInActivity
    /// Fold, fly, land.
    case fly

    static func exit(home: ResultMessageHome, mirroredInCapsule: Bool = false, reduceMotion: Bool,
                     activityIsOpen: Bool, hasAnchors: Bool) -> ResultMessageExit {
        guard home == .toolbar || mirroredInCapsule else { return .clear }
        // The open popover already lists the message in Recent, so a flight would say nothing the
        // list doesn't. Its row flashes instead.
        guard !activityIsOpen else { return .flashInActivity }
        guard !reduceMotion, hasAnchors else { return .landInActivity }
        return .fly
    }
}

/// The toolbar views a flight goes between: the capsule's item and the Activity button.
///
/// Registered by zero-size probes in each (`CapsuleFlightAnchor`), because both are SwiftUI hosted
/// in AppKit's toolbar and neither has a frame the window's content can read.
@MainActor
final class CapsuleFlightAnchors {
    static let shared = CapsuleFlightAnchors()

    weak var capsule: NSView?
    weak var activity: NSView?

    /// Both views' screen frames and their window, or nil unless both are in the same window and
    /// it is on screen. `view.window === host` is the overflow guard (as in `CommandPaletteHost`):
    /// an item folded behind the toolbar's chevron is out of the window, and converting it answers
    /// the window's bottom-left corner at a plausible size, flying the ring to nowhere.
    ///
    /// On screen, because ordering a child panel front orders its parent back in: a message timing
    /// out after its window was closed or minimized would bring the window back. Off screen, it
    /// lands in Activity without the flight. Not `isOnActiveSpace`, which a test host reads false
    /// for a window plainly on screen.
    func frames() -> (host: NSWindow, capsule: CGRect, activity: CGRect)? {
        guard let capsule, let activity, let host = capsule.window, activity.window === host,
              host.isVisible else { return nil }
        return (host, host.convertToScreen(capsule.convert(capsule.bounds, to: nil)),
                host.convertToScreen(activity.convert(activity.bounds, to: nil)))
    }
}

/// A probe that registers the view it backs as one end of the flight. Place it as a `.background`
/// so it takes the item's own bounds.
struct CapsuleFlightAnchor: NSViewRepresentable {
    enum End { case capsule, activity }
    let end: End

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        register(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { register(view) }

    private func register(_ view: NSView) {
        switch end {
        case .capsule: CapsuleFlightAnchors.shared.capsule = view
        case .activity: CapsuleFlightAnchors.shared.activity = view
        }
    }
}

/// The landing, as the Activity button sees it: a count it animates on, and the message in the
/// air, whose problem dot waits for it (`ActivityCenter.dotHeldFor`).
@MainActor
final class CapsuleFlightLanding: ObservableObject {
    static let shared = CapsuleFlightLanding()
    @Published private(set) var arrivals = 0
    /// The message folding or flying now. Its banner is cleared before the ring lands, and that
    /// clearing must not release the dot early.
    private(set) var flying: UUID?

    func takeOff(_ id: UUID) { flying = id }

    /// The message left the window's message — replaced, undone, followed or closed. Its held dot
    /// shows now, unless it is the one in the air, whose dot waits for the landing. A dot is held
    /// only for the message on screen or the one flying, so this and the landing release every hold.
    func messageLeft(_ id: UUID, in center: ActivityCenter = .shared) {
        if flying != id { center.releaseDot(heldFor: id) }
    }

    /// Called off without landing: the message was replaced or cleared while it folded, so its dot
    /// shows now.
    func callOff(_ id: UUID, in center: ActivityCenter = .shared) {
        if flying == id { flying = nil }
        center.releaseDot(heldFor: id)
    }

    /// The message is in Activity: the button bumps, its held dot appears, and an open Activity's
    /// row for it flashes.
    func arrived(_ id: UUID, in center: ActivityCenter = .shared) {
        if flying == id { flying = nil }
        arrivals &+= 1
        center.releaseDot(heldFor: id)
        center.flashRow(for: id)
    }
}

/// Draws a flight over the window, in a panel of its own.
///
/// A panel, because the window's SwiftUI content sits below the toolbar and can't draw over the
/// capsule or the Activity button; a child window rides above it all. Inert to the mouse, never
/// key, gone when the ring lands, like the Go-to list's panel (`CommandPalettePanelController`).
@MainActor
enum CapsuleFlight {
    static func fly(_ weight: ProgressCapsuleMessage.Weight, from capsule: CGRect, to activity: CGRect,
                    over host: NSWindow, landed: @escaping @MainActor () -> Void) {
        let frame = host.frame
        // Screen points (bottom-left origin) into the panel's SwiftUI space (top-left origin).
        func local(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX - frame.minX, y: frame.maxY - rect.midY) }

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        // Its own window, so the main window's root accent doesn't reach it.
        panel.contentView = NSHostingView(rootView: ProgressCapsuleFlightView(
            from: local(capsule), to: local(activity), weight: weight).nativeControlAccent())
        host.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(ProgressCapsuleFlight.travelDuration))
            host.removeChildWindow(panel)
            panel.orderOut(nil)
            landed()
        }
    }
}
