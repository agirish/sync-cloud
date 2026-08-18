import Foundation
import Testing
@testable import SyncCloud

/// The crash-guard key, and the breadcrumb that reports whether it is armed.
///
/// **Neither had any coverage, and the key was written out twice ~630 lines apart** — once where
/// the registration domain turns the assert off, once where launch reads it back to say which state
/// the session is in. Both sites sit inside `if !isRunningTests`, so nothing exercised them, and a
/// typo in either would have made the diagnostic lie in the direction that costs the most: a
/// session reporting ARMED while in fact suppressed is exactly the question three investigations in
/// `docs/columns-layout-loop.md` needed answered.
///
/// The key is one constant now, so that drift is closed by construction. What is left to test is
/// the reading, which must mirror AppKit's own `objectForKey:`-then-`boolForKey:` order — that
/// order is the only reason the breadcrumb agrees with what AppKit actually does.
///
/// **Driven through a stub rather than a scratch suite, and the reason is a finding of its own.**
/// A `UserDefaults(suiteName:)` instance still searches the process-wide registration domain, and
/// this key is already present as `0` in this test host — measured — so the absent case simply
/// cannot be produced in-process. A scratch suite would have made `anUnregisteredKeyReadsAsArmed`
/// assert the opposite of its name and pass for the wrong reason.
@Suite struct DisplayCycleAssertTests {

    /// Answers exactly what it is told to, so each of the three states AppKit distinguishes can be
    /// presented on its own.
    private final class StubDefaults: UserDefaults, @unchecked Sendable {
        let stored: Bool?
        init(stored: Bool?) {
            self.stored = stored
            super.init(suiteName: nil)!
        }
        override func object(forKey defaultName: String) -> Any? {
            defaultName == DisplayCycleAssert.key ? stored : super.object(forKey: defaultName)
        }
        override func bool(forKey defaultName: String) -> Bool {
            defaultName == DisplayCycleAssert.key ? (stored ?? false) : super.bool(forKey: defaultName)
        }
    }

    /// **Absent means armed.** Under tests nothing is registered at all, deliberately, so CI keeps
    /// failing loudly if a fixture ever reproduces the runaway — the breadcrumb has to say ARMED
    /// there, not the opposite. This is the state a `boolForKey:`-only read cannot see, since an
    /// absent key reads `false` and would be reported as suppressed.
    @Test func anAbsentKeyReadsAsArmed() {
        #expect(DisplayCycleAssert.isArmed(in: StubDefaults(stored: nil)))
    }

    /// `false` — what a real launch registers — suppresses it.
    @Test func falseSuppressesTheAssert() {
        #expect(!DisplayCycleAssert.isArmed(in: StubDefaults(stored: false)))
    }

    /// And a diagnostic session gets the crash back by writing the key `true`, the documented escape
    /// hatch. This is the state an `objectForKey:`-only read cannot see, since a present key would
    /// be reported as suppressed whatever its value.
    @Test func anExplicitTrueArmsItAgain() {
        #expect(DisplayCycleAssert.isArmed(in: StubDefaults(stored: true)))
    }

    /// The three states really are three answers, which is what makes the order load-bearing rather
    /// than a style choice: either half of the expression on its own collapses two of them.
    @Test func theThreeStatesAreToldApart() {
        let armedAbsent = DisplayCycleAssert.isArmed(in: StubDefaults(stored: nil))
        let suppressed = DisplayCycleAssert.isArmed(in: StubDefaults(stored: false))
        let armedExplicit = DisplayCycleAssert.isArmed(in: StubDefaults(stored: true))
        #expect(armedAbsent != suppressed, "an absent key and an explicit false report the same state — a boolForKey:-only read")
        #expect(armedExplicit != suppressed, "an explicit true and an explicit false report the same state — an objectForKey:-only read")
    }

    /// The registration and the reading name the same key. They used to be two literals; this says
    /// the one that survived is still AppKit's spelling, because a constant both sites agree on is
    /// only worth having if it is the right string.
    @Test func theKeyIsAppKitsOwnSpelling() {
        #expect(DisplayCycleAssert.key == "NSWindowAssertWhenDisplayCycleLimitReached")
    }
}
