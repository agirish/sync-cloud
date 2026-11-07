import Foundation
import Testing
@testable import SyncCloud

/// The crash-guard key, and the breadcrumb that reports whether it is armed.
///
/// The registration that turns the assert off and the launch breadcrumb both sit inside
/// `if !isRunningTests`, so nothing else exercises them. A breadcrumb that misreports ARMED versus
/// suppressed misleads exactly the question `docs/columns-layout-loop.md` needs answered. The key
/// is one constant; the reading must mirror AppKit's `objectForKey:`-then-`boolForKey:` order to
/// agree with what AppKit does.
///
/// Driven through a stub, not a scratch suite: a `UserDefaults(suiteName:)` still searches the
/// process-wide registration domain, where this key is already `0` in the test host, so the absent
/// case can't be produced in-process and `anAbsentKeyReadsAsArmed` would pass for the wrong reason.
@Suite struct DisplayCycleAssertTests {

    /// Answers exactly what it is told, so each of the three states AppKit distinguishes can be
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

    /// Absent means armed. Under tests nothing is registered, so CI fails loudly if a fixture
    /// reproduces the runaway, and the breadcrumb must say ARMED there. A `boolForKey:`-only read
    /// can't see this state: an absent key reads `false` and would be reported as suppressed.
    @Test func anAbsentKeyReadsAsArmed() {
        #expect(DisplayCycleAssert.isArmed(in: StubDefaults(stored: nil)))
    }

    /// `false`, what a real launch registers, suppresses it.
    @Test func falseSuppressesTheAssert() {
        #expect(!DisplayCycleAssert.isArmed(in: StubDefaults(stored: false)))
    }

    /// A diagnostic session gets the crash back by writing the key `true`, the documented escape
    /// hatch. An `objectForKey:`-only read can't see this state: a present key would be reported as
    /// suppressed whatever its value.
    @Test func anExplicitTrueArmsItAgain() {
        #expect(DisplayCycleAssert.isArmed(in: StubDefaults(stored: true)))
    }

    /// The one constant both sites use is AppKit's own spelling, since agreeing on the wrong string
    /// would be worthless.
    @Test func theKeyIsAppKitsOwnSpelling() {
        #expect(DisplayCycleAssert.key == "NSWindowAssertWhenDisplayCycleLimitReached")
    }
}
