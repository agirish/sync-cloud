import Testing
@testable import FileExplorer

/// Pins `AutomationToggleEchoGuard` (C12): `AutomationRuleCard` mirrors `rule.enabled` into local
/// `@State`, and before the guard an EXTERNAL write to `rule.enabled` (import, bulk toggle, undo)
/// round-tripped through the mirror's `onChange` into `onToggle` → `setAutomationRule` — a model
/// write the user never made. The guard must swallow exactly those echoes while letting genuine
/// gestures through, in both directions.
///
/// The mutating calls are hoisted into locals because `#expect` captures its expression in a
/// non-mutating closure.
struct AutomationToggleEchoGuardTests {

    // MARK: - Genuine gestures go through, both directions

    @Test func aUserFlipOffIsForwarded() {
        var echoGuard = AutomationToggleEchoGuard(enabled: true)

        let forwarded = echoGuard.shouldForwardSwitchChange(to: false)

        #expect(forwarded)
    }

    @Test func aUserFlipOnIsForwarded() {
        var echoGuard = AutomationToggleEchoGuard(enabled: false)

        let forwarded = echoGuard.shouldForwardSwitchChange(to: true)

        #expect(forwarded)
    }

    /// Flip off, model confirms, flip back on: the second gesture must not be eaten by the first
    /// one's bookkeeping. (This is the trace that breaks a naive "remember the last user value"
    /// implementation.)
    @Test func consecutiveOpposingGesturesAreBothForwarded() {
        var echoGuard = AutomationToggleEchoGuard(enabled: true)

        let firstForwarded = echoGuard.shouldForwardSwitchChange(to: false)
        // The model write comes back as rule.enabled == false; the mirror already shows false,
        // so no resync (and no echo) happens.
        let resynced = echoGuard.shouldResyncMirror(to: false, mirror: false)
        let secondForwarded = echoGuard.shouldForwardSwitchChange(to: true)

        #expect(firstForwarded)
        #expect(!resynced)
        #expect(secondForwarded)
    }

    // MARK: - External writes are mirrored, not echoed

    @Test func anExternalDisableResyncsTheMirrorAndSwallowsTheEcho() {
        var echoGuard = AutomationToggleEchoGuard(enabled: true)

        // rule.enabled flips to false under the card (bulk toggle / undo / import).
        let resynced = echoGuard.shouldResyncMirror(to: false, mirror: true)
        // The resync writes isEnabled = false, whose onChange asks about the echo: suppressed.
        let echoForwarded = echoGuard.shouldForwardSwitchChange(to: false)

        #expect(resynced)
        #expect(!echoForwarded)
    }

    @Test func anExternalEnableResyncsTheMirrorAndSwallowsTheEcho() {
        var echoGuard = AutomationToggleEchoGuard(enabled: false)

        let resynced = echoGuard.shouldResyncMirror(to: true, mirror: false)
        let echoForwarded = echoGuard.shouldForwardSwitchChange(to: true)

        #expect(resynced)
        #expect(!echoForwarded)
    }

    /// After an external write settles, the very next user gesture is genuine again.
    @Test func aGestureAfterAnExternalWriteIsForwarded() {
        var echoGuard = AutomationToggleEchoGuard(enabled: true)

        let resynced = echoGuard.shouldResyncMirror(to: false, mirror: true)
        let echoForwarded = echoGuard.shouldForwardSwitchChange(to: false)  // the echo
        let gestureForwarded = echoGuard.shouldForwardSwitchChange(to: true)  // the user, back on

        #expect(resynced)
        #expect(!echoForwarded)
        #expect(gestureForwarded)
    }

    /// An external write matching the mirror needs no resync at all — most importantly the model's
    /// own confirmation of a gesture the guard just forwarded.
    @Test func aModelWriteMatchingTheMirrorIsANoOp() {
        var echoGuard = AutomationToggleEchoGuard(enabled: true)

        let forwarded = echoGuard.shouldForwardSwitchChange(to: false)
        let resynced = echoGuard.shouldResyncMirror(to: false, mirror: false)

        #expect(forwarded)
        #expect(!resynced)
    }
}
