import AppKit
import Testing
import FileExplorer
import Sync
@testable import SyncCloud

/// How a result message leaves on its own — the capsule's flies into Activity; nothing else does.
@Suite struct ResultMessageExitTests {

    private func exit(_ home: ResultMessageHome, mirrored: Bool = false, reduceMotion: Bool = false,
                      activityIsOpen: Bool = false, hasAnchors: Bool = true) -> ResultMessageExit {
        ResultMessageExit.exit(home: home, mirroredInCapsule: mirrored, reduceMotion: reduceMotion,
                               activityIsOpen: activityIsOpen, hasAnchors: hasAnchors)
    }

    /// A run's ending a pane shows and the capsule mirrors goes into Activity from the capsule, by
    /// the capsule's own rules.
    @Test func aMirroredRunsEndingFliesFromTheCapsule() {
        #expect(exit(.pane(isLeft: true), mirrored: true) == .fly)
        #expect(exit(.workspace, mirrored: true) == .fly)
        #expect(exit(.pane(isLeft: true), mirrored: true, reduceMotion: true) == .landInActivity)
        #expect(exit(.pane(isLeft: true), mirrored: true, hasAnchors: false) == .landInActivity)
        #expect(exit(.pane(isLeft: true), mirrored: true, activityIsOpen: true) == .flashInActivity)
    }

    @Test func theCapsulesMessageFliesIntoActivity() {
        #expect(exit(.toolbar) == .fly)
    }

    @Test func aPanesOrTheWorkspacesMessageJustGoes() {
        #expect(exit(.pane(isLeft: true)) == .clear)
        #expect(exit(.pane(isLeft: false)) == .clear)
        #expect(exit(.workspace) == .clear)
        // Not even a glow: the reader was looking at it.
        #expect(exit(.workspace, reduceMotion: true) == .clear)
    }

    @Test func reduceMotionLandsItWithoutTheFlight() {
        #expect(exit(.toolbar, reduceMotion: true) == .landInActivity)
    }

    @Test func noFlightWithoutBothEndsInTheWindow() {
        // Activity folded behind the toolbar's chevron, or the capsule's item not laid out.
        #expect(exit(.toolbar, hasAnchors: false) == .landInActivity)
    }

    @Test func activityAlreadyOpenUnderTheCapsuleFlashesItsRowInstead() {
        #expect(exit(.toolbar, activityIsOpen: true) == .flashInActivity)
        #expect(exit(.toolbar, reduceMotion: true, activityIsOpen: true) == .flashInActivity)
        // A pane's message is not in the popover's way: it just goes.
        #expect(exit(.workspace, activityIsOpen: true) == .clear)
    }

    /// The landing releases a held dot and flashes the message's row; calling a flight off does
    /// neither, and leaves no message in the air.
    @MainActor
    @Test func landingReleasesTheDotAndFlashesTheRow() {
        let center = ActivityCenter()
        let landing = CapsuleFlightLanding()
        let warning = OperationBanner.warning("Moved 2 of 3 items to the Trash")
        center.record(warning, run: nil, finishedRun: nil, seen: false, dotWaits: true)

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
        let flying = OperationBanner.warning("Moved 2 of 3 items to the Trash")
        center.record(flying, run: nil, finishedRun: nil, seen: false, dotWaits: true)
        landing.takeOff(flying.id)
        landing.messageLeft(flying.id, in: center)
        #expect(!center.showsDot, "the dot showed as the banner cleared for the flight, before the landing")
        landing.arrived(flying.id, in: center)
        #expect(center.showsDot)

        // A success in the air while a problem arrives in the capsule: its landing is not the
        // problem's.
        let quiet = ActivityCenter()
        let done = OperationBanner.success("Moved “Untitled.md” to the Trash")
        let problem = OperationBanner.warning("Skipped 2 items")
        quiet.record(done, run: nil, finishedRun: nil, seen: true)
        landing.takeOff(done.id)
        quiet.record(problem, run: nil, finishedRun: nil, seen: false, dotWaits: true)
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
        let warning = OperationBanner.warning("Moved 2 of 3 items to the Trash")
        center.record(warning, run: nil, finishedRun: nil, seen: false, dotWaits: true)
        landing.takeOff(warning.id)
        landing.messageLeft(warning.id, in: center)
        #expect(!center.showsDot)
        landing.callOff(warning.id, in: center)
        #expect(landing.flying == nil)
        #expect(center.showsDot, "a flight called off during its fold left its problem with no dot")
    }

    /// **The flight's two ends**: both in one window that is on screen. A window closed or
    /// minimized under a message gives none — the panel would order it back in.
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
