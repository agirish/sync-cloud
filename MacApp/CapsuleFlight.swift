import AppKit
import SwiftUI
import Design
import FileExplorer

/// **How a result message leaves when nobody undid or followed it** — its time ran out, or ✕.
///
/// A pane's or the workspace's message simply goes: it was where the reader was working, and they
/// saw it. The capsule's was shown while they worked elsewhere (Run Room CG), so it folds into its
/// ring and flies into the Activity button, where Recent keeps it — the ✕'s own tooltip already
/// promised "it stays in Activity". Pure, so each refusal is testable without a toolbar.
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

    static func exit(home: ResultMessageHome, reduceMotion: Bool, activityIsOpen: Bool,
                     hasAnchors: Bool) -> ResultMessageExit {
        guard home == .toolbar else { return .clear }
        // The popover hangs from the capsule and already lists the message in Recent; a ring flying
        // out from under it to the button that opened it says nothing the list does not. Its row
        // flashes instead.
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

    /// Both views' screen frames and the window they are in — or nil unless both are in the SAME
    /// window. **`view.window === host` is the overflow guard `CommandPaletteHost` measured:** an
    /// item folded behind the toolbar's chevron keeps its view out of the window, and converting
    /// it answers with the window's bottom-left corner at a plausible size, which would fly the ring
    /// to nowhere.
    func frames() -> (host: NSWindow, capsule: CGRect, activity: CGRect)? {
        guard let capsule, let activity, let host = capsule.window, activity.window === host else { return nil }
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

/// **The landing**, as the Activity button sees it: a count it animates on — and the message in the
/// air, whose problem dot waits for it (`ActivityCenter.dotHeldFor`).
@MainActor
final class CapsuleFlightLanding: ObservableObject {
    static let shared = CapsuleFlightLanding()
    @Published private(set) var arrivals = 0
    /// The message folding or flying now. Its banner is cleared before the ring lands, and that
    /// clearing must not release the dot early.
    private(set) var flying: UUID?

    func takeOff(_ id: UUID) { flying = id }

    /// Called off without landing: the message was replaced while it folded.
    func callOff(_ id: UUID) { if flying == id { flying = nil } }

    /// The message is in Activity: the button bumps, a held dot appears, and an open Activity's
    /// row for it flashes.
    func arrived(_ id: UUID, in center: ActivityCenter = .shared) {
        if flying == id { flying = nil }
        arrivals &+= 1
        center.releaseDot()
        center.flashRow(for: id)
    }
}

/// Draws a flight over the window, in a panel of its own.
///
/// **A panel, because the window cannot draw over its toolbar.** The capsule and the Activity
/// button are toolbar items, and the window's SwiftUI content sits below the toolbar; a child
/// window rides above all of it. Inert to the mouse, never key, gone when the ring lands — the
/// same panel shape the Go-to list uses (`CommandPalettePanelController`).
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
        // Its own window, so the main window's root accent does not reach it (DS4).
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
