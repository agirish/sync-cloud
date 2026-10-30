import Foundation
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
}
