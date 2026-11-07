import Testing
@testable import FileExplorer

/// Pins `AutomationToggleEchoGuard`: `AutomationRuleCard` mirrors `rule.enabled` into local
/// `@State`, and without the guard an external write to `rule.enabled` (import, bulk toggle, undo)
/// would round-trip through the mirror's `onChange` into `onToggle` → `setAutomationRule`, a model
/// write the user never made. The guard must swallow exactly those echoes while letting genuine
/// gestures through, in both directions.
///
/// The mutating calls are hoisted into locals because `#expect` captures its expression in a
/// non-mutating closure.
struct AutomationToggleEchoGuardTests {

    // MARK: - Genuine gestures go through, both directions

    @Test func aUserFlipOnIsForwarded() {
        var echoGuard = AutomationToggleEchoGuard(enabled: false)

        let forwarded = echoGuard.shouldForwardSwitchChange(to: true)

        #expect(forwarded)
    }

    /// Flip off, model confirms, flip back on: the second gesture must not be eaten by the first
    /// one's bookkeeping, as it would be by a naive "remember the last user value" guard.
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
}
