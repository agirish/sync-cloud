import AppKit
import SwiftUI

// MARK: - Shortcut reveal
//
// Hold ⌥ alone for `ShortcutRevealMachine.holdDuration` and every control with a keyboard shortcut
// grows a keycap badge;
// release it and they vanish. This file is the ONE place that decides whether the reveal is on —
// `ShortcutKeycap` is the one place that decides what a badge looks like. Same shape as
// `HoverAffordanceStyle`: one choke point per affordance, so a change lands everywhere at once.
//
// **Why ⌥ and not ⌘.** ⌘ appears *inside* most of the hints it would be revealing (⌘R, ⌘F, ⌘→),
// and it is the app's move modifier (`ModifierTracker.isMoveModifier` is ⇧-or-⌘) — a ⌘ trigger
// would flash badges through ⌘Z and ⌘-click and collide with the Copy→Move retitle. ⌥'s existing
// in-app meanings are all read at *click* time (⌥-click acts on both panes; ⌥-click a disclosure
// triangle collapses all), which a passive hold does not disturb.
//
// **Accepted, not a defect.** With ⌥ down, pressing ⌘R sends ⌥⌘R, which does not match the ⌘R key
// equivalent — so a shortcut cannot be fired *through* the reveal. This is a look-release-press
// flow, the same one iPadOS's ⌘-hold uses, and it is deliberate: making shortcuts fire through the
// reveal would mean swallowing ⌥ out of chords the user may legitimately want. Do not "fix" it.

/// The modifier keys the reveal reasons about, as a plain value type — so the state machine below
/// can be driven and tested without AppKit or an event loop in the picture.
public struct ShortcutRevealModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let option = ShortcutRevealModifiers(rawValue: 1 << 0)
    public static let command = ShortcutRevealModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutRevealModifiers(rawValue: 1 << 2)
    public static let control = ShortcutRevealModifiers(rawValue: 1 << 3)

    /// Reads the four chord modifiers out of an AppKit flag set.
    ///
    /// Caps Lock and Fn are deliberately dropped rather than treated as "an additional modifier".
    /// Caps Lock is a *latched* state: left on, it would make the `[.option]`-alone test below
    /// unsatisfiable and the reveal simply would not exist for that user. Fn rides along with the
    /// arrow keys and the function row rather than describing anything the user chose to hold.
    public init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: ShortcutRevealModifiers = []
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self = modifiers
    }
}

/// The hold rule, as a pure state machine over an injected clock.
///
/// The duration is ``holdDuration``, and is deliberately named nowhere else in prose: this line and
/// the file header above both still said "700 ms" a release after the constant became 0.2 — a
/// number `theHoldDurationIsWhatTheInterfacePromises` had been pinning the whole time.
///
/// Every transition is a function of (current phase, event, instant) — nothing here reads the
/// wall clock, schedules anything, or touches AppKit, so the whole interaction is assertable in
/// a unit test with `Date`s the test picks. `ShortcutRevealTracker` is the only thing that turns
/// real events and a real timer into calls on this.
public struct ShortcutRevealMachine: Equatable, Sendable {

    /// How long ⌥ must be held **alone** before the keycaps appear.
    ///
    /// Deliberately short — the reveal should feel like the window answering, not like a wait you
    /// have to learn the length of. It is not zero because the ⌥ that *begins* an ⌥-click or an
    /// ⌥-typed character is itself a brief ⌥-alone hold, and at zero every one of those would
    /// flash the badges up for a frame before the click or keystroke cancelled them.
    ///
    /// So this is the only thing separating "looking" from "about to do something with ⌥", and it
    /// buys that separation with the shortest delay that still reads as deliberate. Shorter is a
    /// legitimate taste call; the cost is paid in flicker during ⌥-click, not in correctness —
    /// every cancel rule holds at any duration. One constant, pinned by
    /// `ShortcutRevealMachineTests.theHoldDurationIsWhatTheInterfacePromises`; every other test
    /// derives its timings from it so changing this number cannot quietly invalidate them.
    public static let holdDuration: TimeInterval = 0.2

    public enum Phase: Equatable, Sendable {
        /// Nothing is held that could become a reveal.
        case idle
        /// ⌥ is down alone; the keycaps appear when `deadline` passes.
        case arming(deadline: Date)
        /// The keycaps are showing.
        case revealed
        /// This hold is disqualified — a key, a click, or a second modifier arrived — but ⌥ may
        /// still be down. Only releasing ⌥ returns it to `idle`.
        ///
        /// Load-bearing, not bookkeeping. Without it the cancel rules would merely *defer* the
        /// reveal: ⌥-typing `ø` and keeping ⌥ down would re-arm on the next `flagsChanged` and
        /// flash badges a moment after the user stopped typing, and pressing ⌥⌘ then releasing only
        /// ⌘ would open a reveal nobody asked for.
        case blocked
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    /// The one thing the view layer reads.
    public var isRevealActive: Bool { phase == .revealed }

    /// When a pending arm fires, for the driver to schedule against. `nil` unless arming.
    public var pendingDeadline: Date? {
        guard case .arming(let deadline) = phase else { return nil }
        return deadline
    }

    /// A `flagsChanged` — the only event that can *start* a reveal.
    public mutating func modifiersChanged(to modifiers: ShortcutRevealModifiers, at now: Date) {
        guard modifiers.contains(.option) else {
            // ⌥ up. Always a dismissal, and the only way out of `blocked`.
            phase = .idle
            return
        }
        guard modifiers == .option else {
            // A second modifier joined ⌥. Disqualifies the hold whether it arrived during the
            // arming window or after the keycaps were already up.
            phase = .blocked
            return
        }
        switch phase {
        case .idle:
            phase = .arming(deadline: now.addingTimeInterval(Self.holdDuration))
        case .arming, .revealed, .blocked:
            // ⌥-alone was already true. A repeat `flagsChanged` must not restart the clock, and a
            // blocked hold must not un-block by dropping back to ⌥ alone.
            break
        }
    }

    /// Any key going down while ⌥ is held — an ⌥-typed character, an ⌥⇥, a chord the user means.
    public mutating func keyDown() { disqualify() }

    /// Any mouse button going down while ⌥ is held — ⌥-click acts on both panes, and must not
    /// have been preceded by a flash of badges.
    public mutating func mouseDown() { disqualify() }

    /// The driver calls this when the scheduled deadline arrives.
    ///
    /// Re-checks the deadline rather than trusting the timer, which is what makes a *stale* fire
    /// harmless: a cancel-then-re-arm leaves a later deadline in place, so the old timer's call
    /// lands with `now < deadline` and is ignored. No token bookkeeping needed.
    public mutating func deadlineElapsed(at now: Date) {
        guard case .arming(let deadline) = phase, now >= deadline else { return }
        phase = .revealed
    }

    /// Hard reset, for when the app stops receiving events at all (it resigned active).
    ///
    /// A *local* event monitor never sees the ⌥-up that happens in another app, so ⌥-⇥-ing away
    /// mid-reveal would otherwise leave the keycaps up forever, over a window that isn't even
    /// frontmost.
    public mutating func reset() { phase = .idle }

    private mutating func disqualify() {
        // `.idle` means ⌥ isn't down: an ordinary keystroke or click, nothing to cancel.
        guard phase != .idle else { return }
        phase = .blocked
    }
}

// MARK: - Driver

/// Turns real AppKit events into `ShortcutRevealMachine` transitions and publishes the one Bool
/// the view layer reads. Install one per window at the root and inject it with
/// `.shortcutRevealSource(_:)`.
///
/// A sibling of `ModifierTracker` (FileExplorer), not a replacement: that one answers "is the
/// move modifier held" for the transfer buttons, is scoped to the view that owns it, and watches
/// ⇧/⌘. This one is app-wide, watches ⌥, and needs the key and mouse streams too.
@MainActor
public final class ShortcutRevealTracker: ObservableObject {

    /// True while the keycaps should be showing.
    @Published public private(set) var isActive = false

    private var machine = ShortcutRevealMachine()
    /// `nonisolated(unsafe)` for the same reason as `ModifierTracker.monitor`: the tokens are
    /// opaque `Any`, and only the nonisolated `deinit` reads them — to hand them straight back to
    /// the main actor. Written once in `init`, never mutated afterwards.
    nonisolated(unsafe) private var monitors: [Any] = []
    private var deadline: Task<Void, Never>?
    /// The wait most recently handed to the deadline timer; nil once a hold is cancelled.
    ///
    /// Deliberately NOT cleared when a deadline actually fires — "last scheduled" is what it says
    /// and what the tests read. Only a cancel nils it, because a cancel is the case where a
    /// leftover value would describe a timer that no longer exists.
    ///
    /// Test observability, and it earns its keep: the whole job of `rescheduleDeadline` is that a
    /// repeat `flagsChanged` — which a held ⌥ produces a stream of — SHORTENS the remaining wait
    /// rather than restarting it. Restarting it would push the reveal permanently out of reach on
    /// a real keyboard, and that bug is completely invisible from `isActive`, which eventually
    /// goes true either way. A test written against `isActive` alone passed against it.
    private(set) var lastScheduledInterval: TimeInterval?
    nonisolated(unsafe) private var resignObserver: NSObjectProtocol?
    private let now: @MainActor () -> Date

    /// - Parameter now: the clock, injectable so a test can drive the driver as well as the
    ///   machine. `@MainActor` so a test can back it with main-actor state it advances by hand.
    public init(now: @escaping @MainActor () -> Date = Date.init) {
        self.now = now

        // Local monitors only: the reveal is about *this* app's controls, and a global monitor
        // would need Accessibility permission to watch the whole system's keystrokes — a
        // spectacularly disproportionate ask for a hint overlay.
        add(matching: .flagsChanged) { [weak self] event in
            self?.noteModifiersChanged(to: ShortcutRevealModifiers(event.modifierFlags))
        }
        add(matching: .keyDown) { [weak self] _ in self?.noteKeyDown() }
        add(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.noteMouseDown()
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteResignedActive() }
        }
    }

    // MARK: The transitions the monitors drive
    //
    // Internal rather than private, and each a one-liner over the machine, purely so the tests can
    // reach them: driving this class through real `NSEvent`s would mean synthesising events and
    // running an app event loop, which is not something a `swift test` process has. Without this
    // seam the entire driver — deadline scheduling, the `isActive` write, resign-active — is
    // untested, and a break there means the feature never appears while every machine test still
    // passes.

    func noteModifiersChanged(to modifiers: ShortcutRevealModifiers) {
        machine.modifiersChanged(to: modifiers, at: now())
        rescheduleDeadline()
        publish()
    }

    func noteKeyDown() {
        machine.keyDown()
        rescheduleDeadline()
        publish()
    }

    func noteMouseDown() {
        machine.mouseDown()
        rescheduleDeadline()
        publish()
    }

    func noteResignedActive() {
        machine.reset()
        rescheduleDeadline()
        publish()
    }

    private func add(matching mask: NSEvent.EventTypeMask,
                     handle: @escaping @MainActor (NSEvent) -> Void) {
        // The event is always returned unchanged: this observes the stream, it never consumes
        // from it. Swallowing a keyDown here would break every shortcut in the app.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { handle(event) }
            return event
        }
        if let monitor { monitors.append(monitor) }
    }

    /// Boxes the opaque monitor tokens so the nonisolated deinit can hand them to a MainActor
    /// task — same reason as `ModifierTracker`: `removeMonitor` is main-thread-only and `deinit`
    /// guarantees nothing about where it runs.
    private struct MonitorBox: @unchecked Sendable { let values: [Any] }

    deinit {
        deadline?.cancel()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        if !monitors.isEmpty {
            let box = MonitorBox(values: monitors)
            Task { @MainActor in box.values.forEach(NSEvent.removeMonitor) }
        }
    }

    /// Keeps exactly one timer alive for the machine's current arm, and none when it isn't armed.
    private func rescheduleDeadline() {
        deadline?.cancel()
        deadline = nil
        guard let fireAt = machine.pendingDeadline else {
            lastScheduledInterval = nil
            return
        }
        let interval = fireAt.timeIntervalSince(now())
        lastScheduledInterval = interval
        deadline = Task { @MainActor [weak self] in
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            // Re-reads the clock rather than assuming the sleep was exact; the machine checks the
            // deadline again anyway, so an early wake-up is a no-op rather than an early reveal.
            self.machine.deadlineElapsed(at: self.now())
            self.publish()
        }
    }

    private func publish() {
        if isActive != machine.isRevealActive { isActive = machine.isRevealActive }
    }
}

// MARK: - Environment

private struct ShortcutRevealActiveKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// True while the ⌥-hold reveal is showing keycaps. `false` in any tree without a
    /// `.shortcutRevealSource(_:)` above it — including every preview and snapshot test, which is
    /// why the resting appearance is the one you get for free.
    var shortcutRevealActive: Bool {
        get { self[ShortcutRevealActiveKey.self] }
        set { self[ShortcutRevealActiveKey.self] = newValue }
    }
}

public extension View {
    /// Publishes `tracker`'s state to every `.shortcutKeycap(_:)` below this point. One per
    /// window, at the root.
    func shortcutRevealSource(_ tracker: ShortcutRevealTracker) -> some View {
        modifier(ShortcutRevealSourceModifier(tracker: tracker))
    }
}

private struct ShortcutRevealSourceModifier: ViewModifier {
    @ObservedObject var tracker: ShortcutRevealTracker

    func body(content: Content) -> some View {
        content.environment(\.shortcutRevealActive, tracker.isActive)
    }
}
