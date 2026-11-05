import Foundation
import Testing
@testable import SyncCloud

/// The AutoFill guard that keeps ⌘K from hanging the app — see ``AutoFillHeuristics``.
///
/// Only the spelling and the registration can be tested in-process: AppKit caches its read of each
/// key on first use, so the effect on `NSAutoFillHeuristicController` can only be seen in the
/// running app.
@Suite struct AutoFillHeuristicsTests {

    /// AppKit's own spelling, as read by the block `-[NSAutoFillHeuristicController
    /// _showPasswordAutoFillIfNecessaryForView:withCompletionHandler:]` schedules. A typo here
    /// would register a key nothing reads.
    @Test func theKeyIsAppKitsOwnSpelling() {
        #expect(AutoFillHeuristics.key == "NSAutoFillHeuristicsEnabled")
    }

    /// Registering turns it off. AppKit reads `objectForKey:` first, so the key must be present: an
    /// absent key reads as on.
    @Test func registeringTurnsItOff() {
        let defaults = ScratchDefaults("AutoFillOff")
        AutoFillHeuristics.registerOff(in: defaults)
        #expect(defaults.object(forKey: AutoFillHeuristics.key) as? Bool == false)
        #expect(AutoFillHeuristics.isOff(in: defaults))
    }

    /// An explicit `true` written by hand is the escape hatch, and the breadcrumb must say ON for it.
    @Test func anExplicitTrueReadsAsOn() {
        let defaults = ScratchDefaults("AutoFillTrue")
        AutoFillHeuristics.registerOff(in: defaults)
        defaults.set(true, forKey: AutoFillHeuristics.key)
        #expect(!AutoFillHeuristics.isOff(in: defaults))
    }
}
