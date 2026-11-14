import AppKit
import Testing
import FileExplorer
import Sync
@testable import SyncCloud

/// How a result message leaves on its own — the capsule's flies into Activity; nothing else does.
@Suite struct ResultMessageExitTests {

    /// `(home, mirrored in the capsule, Reduce Motion, Activity open, both anchors laid out)`.
    typealias Ending = (home: ResultMessageHome, mirrored: Bool, reduce: Bool, open: Bool, anchors: Bool,
                        exit: ResultMessageExit)

    @Test(arguments: [
        // A run's ending a pane shows and the capsule mirrors goes into Activity from the capsule,
        // by the capsule's own rules.
        (.pane(isLeft: true), true, false, false, true, .fly),
        (.workspace, true, false, false, true, .fly),
        (.pane(isLeft: true), true, true, false, true, .landInActivity),
        (.pane(isLeft: true), true, false, false, false, .landInActivity),
        (.pane(isLeft: true), true, false, true, true, .flashInActivity),
        // The capsule's own message flies into Activity.
        (.toolbar, false, false, false, true, .fly),
        // A pane's or the workspace's message just goes; not even a glow, the reader was on it.
        (.pane(isLeft: true), false, false, false, true, .clear),
        (.pane(isLeft: false), false, false, false, true, .clear),
        (.workspace, false, false, false, true, .clear),
        (.workspace, false, true, false, true, .clear),
        // Reduce Motion lands it without the flight.
        (.toolbar, false, true, false, true, .landInActivity),
        // No flight without both ends: Activity folded behind the chevron, or the item not laid out.
        (.toolbar, false, false, false, false, .landInActivity),
        // Activity already open under the capsule flashes its row instead.
        (.toolbar, false, false, true, true, .flashInActivity),
        (.toolbar, false, true, true, true, .flashInActivity),
        // A pane's message is not in the popover's way.
        (.workspace, false, false, true, true, .clear),
    ] as [Ending])
    func aMessageLeavesByItsHomesRules(_ ending: Ending) {
        #expect(ResultMessageExit.exit(home: ending.home, mirroredInCapsule: ending.mirrored,
                                       reduceMotion: ending.reduce, activityIsOpen: ending.open,
                                       hasAnchors: ending.anchors) == ending.exit)
    }

    /// The landing releases a held dot and flashes the message's row; calling a flight off does
    /// neither, and leaves no message in the air.
    @MainActor
    @Test func landingReleasesTheDotAndFlashesTheRow() {
        let center = ActivityCenter()
        let landing = CapsuleFlightLanding()
        let warning = OperationBanner.warning("Moved 2 of 3 items to the Trash", log: .warn)
        center.record(warning, finishedRun: nil, seen: false, dotWaits: true)

        landing.takeOff(warning.id)
        landing.callOff(UUID())
        #expect(landing.flying == warning.id, "calling off another message's flight grounded this one")
        #expect(!center.showsDot)

        landing.arrived(warning.id, in: center)
        #expect(landing.flying == nil)
        #expect(landing.arrivals == 1)
        #expect(center.showsDot)
        #expect(center.flashedRow == warning.id)
    }

    /// The message in the air keeps its dot when its banner clears for the flight; a problem
    /// cleared in place while another message flies shows its dot at once, and that other message's
    /// landing leaves a problem still in the capsule holding its own.
    @MainActor
    @Test func eachHeldDotWaitsOnlyForItsOwnMessage() {
        let center = ActivityCenter()
        let landing = CapsuleFlightLanding()
        let flying = OperationBanner.warning("Moved 2 of 3 items to the Trash", log: .warn)
        center.record(flying, finishedRun: nil, seen: false, dotWaits: true)
        landing.takeOff(flying.id)
        landing.messageLeft(flying.id, in: center)
        #expect(!center.showsDot, "the dot showed as the banner cleared for the flight, before the landing")
        landing.arrived(flying.id, in: center)
        #expect(center.showsDot)

        // A success in the air while a problem arrives in the capsule: its landing is not the
        // problem's.
        let quiet = ActivityCenter()
        let done = OperationBanner.success("Moved “Untitled.md” to the Trash")
        let problem = OperationBanner.warning("Skipped 2 items", log: .warn)
        quiet.record(done, finishedRun: nil, seen: true)
        landing.takeOff(done.id)
        quiet.record(problem, finishedRun: nil, seen: false, dotWaits: true)
        landing.arrived(done.id, in: quiet)
        #expect(!quiet.showsDot, "another message's landing showed the dot of a problem still in the capsule")

        // The problem undone in place while yet another message is in the air.
        landing.takeOff(UUID())
        landing.messageLeft(problem.id, in: quiet)
        #expect(quiet.showsDot, "a problem cleared in place while another message flew lost its dot")
    }

    /// A problem replaced while it folds never takes off, so calling its flight off shows its dot.
    @MainActor
    @Test func callingOffAFlightShowsItsHeldDot() {
        let center = ActivityCenter()
        let landing = CapsuleFlightLanding()
        let warning = OperationBanner.warning("Moved 2 of 3 items to the Trash", log: .warn)
        center.record(warning, finishedRun: nil, seen: false, dotWaits: true)
        landing.takeOff(warning.id)
        landing.messageLeft(warning.id, in: center)
        #expect(!center.showsDot)
        landing.callOff(warning.id, in: center)
        #expect(landing.flying == nil)
        #expect(center.showsDot, "a flight called off during its fold left its problem with no dot")
    }

    /// The flight's two ends must both be in one window that is on screen. A window closed or
    /// minimized under a message gives none, or the panel would order it back in.
    @MainActor
    @Test func anchorsNeedBothEndsInOneWindowOnScreen() {
        func window(at origin: CGPoint) -> NSWindow {
            let window = NSWindow(contentRect: CGRect(origin: origin, size: CGSize(width: 900, height: 60)),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // Buried under everything, never over his screen (FileExplorer's `BuriedWindow`).
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
            return window
        }
        let screen = CommandPalettePanelTests.displayBounds()
        let host = window(at: CGPoint(x: screen.minX + 40, y: screen.minY + 40))
        defer { host.orderOut(nil) }
        let capsule = NSView(frame: CGRect(x: 300, y: 10, width: 200, height: 30))
        let activity = NSView(frame: CGRect(x: 840, y: 10, width: 30, height: 30))
        host.contentView?.addSubview(capsule)
        host.contentView?.addSubview(activity)
        let anchors = CapsuleFlightAnchors()
        anchors.capsule = capsule
        anchors.activity = activity

        #expect(anchors.frames() == nil, "a window that is not on screen gave the flight its ends")
        host.orderBack(nil)
        let ends = anchors.frames()
        #expect(ends?.host === host)
        #expect(ends?.capsule.width == 200 && ends?.activity.minX == host.frame.minX + 840)

        // Folded behind the toolbar's chevron: out of the window.
        activity.removeFromSuperview()
        #expect(anchors.frames() == nil)
        host.contentView?.addSubview(activity)
        #expect(anchors.frames() != nil)

        host.orderOut(nil)
        #expect(anchors.frames() == nil, "a window ordered out gave the flight its ends")
    }
}
