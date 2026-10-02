import Foundation
import Testing
@testable import SyncCloud

/// The AutoFill guard that keeps ⌘K from hanging the app — see ``AutoFillHeuristics``.
///
/// What can be tested in-process is the spelling and the registration: AppKit caches its own read
/// of each key on first use, so the effect on `NSAutoFillHeuristicController` itself was measured
/// in the running app, not here.
@Suite struct AutoFillHeuristicsTests {

    /// AppKit's own spelling, as read out of the block `-[NSAutoFillHeuristicController
    /// _showPasswordAutoFillIfNecessaryForView:withCompletionHandler:]` schedules. A constant is only
    /// worth having if it is the right string — a typo here registers a key nothing reads.
    @Test func theKeyIsAppKitsOwnSpelling() {
        #expect(AutoFillHeuristics.key == "NSAutoFillHeuristicsEnabled")
    }

    /// Registering turns it off, in the order AppKit reads it (`objectForKey:` first, so the key
    /// must be PRESENT — an absent key reads as on).
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
