import Testing
@testable import SyncCloud

/// How a result message leaves on its own — the capsule's flies into Activity; nothing else does.
@Suite struct ResultMessageExitTests {

    private func exit(_ home: ResultMessageHome, reduceMotion: Bool = false, activityIsOpen: Bool = false,
                      hasAnchors: Bool = true) -> ResultMessageExit {
        ResultMessageExit.exit(home: home, reduceMotion: reduceMotion, activityIsOpen: activityIsOpen,
                               hasAnchors: hasAnchors)
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

    @Test func activityAlreadyOpenUnderTheCapsuleClearsItInPlace() {
        #expect(exit(.toolbar, activityIsOpen: true) == .clear)
        #expect(exit(.toolbar, reduceMotion: true, activityIsOpen: true) == .clear)
    }
}
