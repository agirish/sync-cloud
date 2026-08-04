import AppKit
import Testing
@testable import Design

/// The 700 ms ⌥-hold rule, driven directly with a clock the test picks.
///
/// Every one of these is a real interaction someone performs in the app — ⌥-clicking a breadcrumb
/// to move both panes, ⌥-typing a `ø` into a rename field, ⌥⇥-ing away mid-look. The reveal is
/// only allowed to exist because it stays out of all of them, so the cancel rules get more tests
/// here than the happy path does.
@Suite struct ShortcutRevealMachineTests {

    /// A fixed instant. Pinned rather than `Date()` per house style: every deadline below is
    /// arithmetic on this, so nothing depends on how long the test itself takes to run.
    private static let t0 = Date(timeIntervalSinceReferenceDate: 780_000_000)

    private func armed(at start: Date = t0) -> ShortcutRevealMachine {
        var machine = ShortcutRevealMachine()
        machine.modifiersChanged(to: .option, at: start)
        return machine
    }

    /// The whole feature in four lines: ⌥ down alone, wait, keycaps.
    @Test func holdingOptionAloneRevealsAfterTheHoldDuration() {
        var machine = armed()
        #expect(machine.phase == .arming(deadline: Self.t0.addingTimeInterval(0.7)))
        #expect(!machine.isRevealActive)

        machine.deadlineElapsed(at: Self.t0.addingTimeInterval(ShortcutRevealMachine.holdDuration))
        #expect(machine.isRevealActive)
    }

    /// A tap is not a hold. This is the assertion that keeps the reveal off the screen during the
    /// ⌥ that merely *begins* an ⌥-click, which is over in a fraction of the window.
    @Test func anOptionTapShorterThanTheHoldRevealsNothing() {
        var machine = armed()
        // Released at 300 ms...
        machine.modifiersChanged(to: [], at: Self.t0.addingTimeInterval(0.3))
        #expect(machine.phase == .idle)

        // ...and the timer that was already in flight for the original deadline must not fire.
        machine.deadlineElapsed(at: Self.t0.addingTimeInterval(0.7))
        #expect(!machine.isRevealActive)
    }

    /// Fires only at the deadline, not merely because a timer called.
    @Test func anEarlyDeadlineCallDoesNotReveal() {
        var machine = armed()
        machine.deadlineElapsed(at: Self.t0.addingTimeInterval(0.699))
        #expect(!machine.isRevealActive)
        machine.deadlineElapsed(at: Self.t0.addingTimeInterval(0.7))
        #expect(machine.isRevealActive)
    }

    // MARK: Cancel rules — during the arming window

    @Test func aKeyDownDuringArmingCancels() {
        var machine = armed()
        machine.keyDown()
        machine.deadlineElapsed(at: Self.t0.addingTimeInterval(0.7))
        #expect(!machine.isRevealActive)
    }

    @Test func aMouseDownDuringArmingCancels() {
        var machine = armed()
        machine.mouseDown()
        machine.deadlineElapsed(at: Self.t0.addingTimeInterval(0.7))
        #expect(!machine.isRevealActive)
    }

    @Test(arguments: [ShortcutRevealModifiers.command, .shift, .control])
    func aSecondModifierDuringArmingCancels(extra: ShortcutRevealModifiers) {
        var machine = armed()
        machine.modifiersChanged(to: [.option, extra], at: Self.t0.addingTimeInterval(0.1))
        machine.deadlineElapsed(at: Self.t0.addingTimeInterval(0.7))
        #expect(!machine.isRevealActive)
    }

    // MARK: Cancel rules — after the keycaps are up

    private func revealed() -> ShortcutRevealMachine {
        var machine = armed()
        machine.deadlineElapsed(at: Self.t0.addingTimeInterval(0.7))
        #expect(machine.isRevealActive, "fixture failed to reveal")
        return machine
    }

    @Test func releasingOptionDismisses() {
        var machine = revealed()
        machine.modifiersChanged(to: [], at: Self.t0.addingTimeInterval(2))
        #expect(!machine.isRevealActive)
        #expect(machine.phase == .idle)
    }

    @Test func aKeyDownAfterTheRevealDismisses() {
        var machine = revealed()
        machine.keyDown()
        #expect(!machine.isRevealActive)
    }

    @Test func aMouseDownAfterTheRevealDismisses() {
        var machine = revealed()
        machine.mouseDown()
        #expect(!machine.isRevealActive)
    }

    @Test func aSecondModifierAfterTheRevealDismisses() {
        var machine = revealed()
        machine.modifiersChanged(to: [.option, .command], at: Self.t0.addingTimeInterval(1))
        #expect(!machine.isRevealActive)
    }

    // MARK: The `blocked` phase — cancels must not merely defer

    /// ⌥-typing a character (`⌥o` → `ø`) with ⌥ still down. A cancel that only reset the clock
    /// would light the badges up 700 ms after the user stopped typing, over the field they are
    /// typing into. Nothing re-arms until ⌥ is released.
    @Test func typingWithOptionHeldStaysBlockedUntilOptionIsReleased() {
        var machine = armed()
        machine.keyDown()
        #expect(machine.phase == .blocked)

        // A repeat flagsChanged still reporting ⌥-alone — which AppKit does send — must not re-arm.
        machine.modifiersChanged(to: .option, at: Self.t0.addingTimeInterval(0.2))
        #expect(machine.phase == .blocked)
        machine.deadlineElapsed(at: Self.t0.addingTimeInterval(5))
        #expect(!machine.isRevealActive)

        // Releasing ⌥ is the only way out.
        machine.modifiersChanged(to: [], at: Self.t0.addingTimeInterval(0.4))
        #expect(machine.phase == .idle)
    }

    /// ⌥⌘ pressed together, then ⌘ let go while ⌥ stays down. The user is mid-chord, not looking
    /// for hints — dropping back to ⌥-alone must not open a reveal.
    @Test func releasingTheSecondModifierDoesNotReArmWhileOptionIsStillDown() {
        var machine = ShortcutRevealMachine()
        machine.modifiersChanged(to: [.option, .command], at: Self.t0)
        machine.modifiersChanged(to: .option, at: Self.t0.addingTimeInterval(0.1))
        #expect(machine.phase == .blocked)
        machine.deadlineElapsed(at: Self.t0.addingTimeInterval(5))
        #expect(!machine.isRevealActive)
    }

    /// ⌥-click, which is `act on both panes` at three separate call sites. Holding ⌥ after the
    /// click — which is what actually happens, the finger stays down — must stay quiet.
    @Test func optionClickThenKeepingOptionDownRevealsNothing() {
        var machine = armed()
        machine.mouseDown()
        machine.modifiersChanged(to: .option, at: Self.t0.addingTimeInterval(0.05))
        machine.deadlineElapsed(at: Self.t0.addingTimeInterval(10))
        #expect(!machine.isRevealActive)
    }

    // MARK: Clock hygiene

    /// A held ⌥ produces a stream of `flagsChanged`, not one event. If each restarted the clock the
    /// reveal would never arrive.
    @Test func repeatedOptionAloneEventsDoNotRestartTheClock() {
        var machine = armed()
        machine.modifiersChanged(to: .option, at: Self.t0.addingTimeInterval(0.5))
        #expect(machine.phase == .arming(deadline: Self.t0.addingTimeInterval(0.7)),
                "the second event moved the deadline")
        machine.deadlineElapsed(at: Self.t0.addingTimeInterval(0.7))
        #expect(machine.isRevealActive)
    }

    /// Release, re-press, and the FIRST hold's timer fires late. It must not reveal on the second
    /// hold's behalf — the second hold has its own, later deadline and has not earned it yet.
    @Test func aStaleTimerFromAnEarlierHoldDoesNotReveal() {
        var machine = armed()
        machine.modifiersChanged(to: [], at: Self.t0.addingTimeInterval(0.2))
        machine.modifiersChanged(to: .option, at: Self.t0.addingTimeInterval(0.5))

        // The abandoned first timer, arriving at its own deadline.
        machine.deadlineElapsed(at: Self.t0.addingTimeInterval(0.7))
        #expect(!machine.isRevealActive, "a stale timer revealed on the new hold's behalf")

        // The live one, at the second hold's deadline.
        machine.deadlineElapsed(at: Self.t0.addingTimeInterval(1.2))
        #expect(machine.isRevealActive)
    }

    /// ⌥⇥ away mid-look. A *local* monitor never sees the ⌥-up that happens in the other app, so
    /// without the reset the keycaps would stay lit over a window that isn't even frontmost.
    @Test func resigningActiveDismisses() {
        var machine = revealed()
        machine.reset()
        #expect(!machine.isRevealActive)
        #expect(machine.phase == .idle)
    }

    // MARK: Flag translation

    /// Caps Lock latched on would otherwise make "⌥ alone" unsatisfiable, and the feature would
    /// silently not exist for anyone who leaves it on. Fn is set by the arrow keys rather than
    /// chosen. Neither is a modifier the user is holding, so neither reaches the machine.
    @Test func capsLockAndFunctionAreNotModifiers() {
        #expect(ShortcutRevealModifiers([.option, .capsLock]) == .option)
        #expect(ShortcutRevealModifiers([.option, .function]) == .option)

        var machine = ShortcutRevealMachine()
        machine.modifiersChanged(to: ShortcutRevealModifiers([.option, .capsLock]), at: Self.t0)
        machine.deadlineElapsed(at: Self.t0.addingTimeInterval(0.7))
        #expect(machine.isRevealActive, "Caps Lock suppressed the reveal")
    }

    @Test func theFourChordModifiersAreTranslated() {
        #expect(ShortcutRevealModifiers([]) == [])
        #expect(ShortcutRevealModifiers([.option, .command, .shift, .control])
                == [.option, .command, .shift, .control])
        #expect(!ShortcutRevealModifiers(NSEvent.ModifierFlags.command).contains(.option))
    }
}
