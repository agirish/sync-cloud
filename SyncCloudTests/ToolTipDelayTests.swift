import AppKit
import Foundation
import ObjectiveC
import Testing
@testable import SyncCloud

/// The app-wide tooltip delay — see ``ToolTipDelay``.
@Suite struct ToolTipDelayTests {

    /// AppKit's own spelling. A typo registers a key nothing reads, and every tooltip keeps
    /// AppKit's 1.5 s.
    @Test func theKeyIsAppKitsOwnSpelling() {
        #expect(ToolTipDelay.key == "NSInitialToolTipDelay")
        #expect(ToolTipDelay.milliseconds == 300)
    }

    /// Registration, not a write: a value set by hand (`defaults write … NSInitialToolTipDelay`)
    /// still wins. No "starts unset" precondition — the registration domain is process-wide, so a
    /// scratch suite in this host already sees the 300 the app registered at launch.
    @Test func aWrittenValueOverridesTheRegistration() {
        let defaults = ScratchDefaults("ToolTipDelay")
        ToolTipDelay.register(in: defaults)
        #expect(defaults.integer(forKey: ToolTipDelay.key) == 300)
        defaults.set(800, forKey: ToolTipDelay.key)
        #expect(defaults.integer(forKey: ToolTipDelay.key) == 800)
    }

    /// **The outcome, not the registration.** The test host is SyncCloud.app, so `App.init` has run
    /// and AppKit's tooltip manager in this process is the one the app's views use. Its delay is
    /// read when it is created, so a registration that landed too late would leave 1.5 here while
    /// the two tests above stay green.
    @Test @MainActor func appKitsTooltipManagerUsesIt() throws {
        let manager: AnyClass = try #require(NSClassFromString("NSToolTipManager"), "AppKit renamed its tooltip manager")
        let shared = try #require((manager as AnyObject)
            .perform(NSSelectorFromString("sharedToolTipManager"))?.takeUnretainedValue())
        let ivar = try #require(class_getInstanceVariable(manager, "_toolTipDelay"),
                                "AppKit renamed the delay it reads — re-measure (see ToolTipDelay)")
        let seconds = Unmanaged.passUnretained(shared).toOpaque()
            .advanced(by: ivar_getOffset(ivar)).load(as: Double.self)
        #expect(abs(seconds - 0.3) < 0.0001, "tooltips wait \(seconds) s, not 0.3 s")
    }
}
