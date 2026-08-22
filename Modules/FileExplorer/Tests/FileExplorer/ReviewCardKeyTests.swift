import AppKit
import SwiftUI
import Testing
import Sync
@testable import FileExplorer

/// `ReviewCardView`'s ⌫-skip, exercised through a real window's responder chain — the same
/// harness as `FilingWalkthroughCardKeyTests` (borrowed in turn from
/// `DifferencesTableBindingTests`).
///
/// Covers the two keys that move or drop a row: ⌫-skip and ⏎-primary.
///
/// `onKeyPress` does NOT filter modifiers for its handler, on ANY overload — so without an
/// explicit `press.isPlainKeystroke` check, ⌘⌫ (Finder's "delete immediately", and "delete to
/// start of line" in text land) and ⌥⌫ (delete word) SKIP the current item, which no back-step
/// can revisit. That is the same modifier-blindness `FilingWalkthroughCard`'s first `.onKeyPress`
/// cut shipped; this suite is the donor-file half of that fix.
///
/// **The ⏎ tests below were written red, and three separate defects made them so.** The card's ⏎
/// was the single-key `onKeyPress(.return)` overload, whose doc-comment reputation here (and in
/// `KeyPress.isPlainKeystroke`'s own doc) was "matches unmodified presses only" — asserted, never
/// measured. Measured on this harness it: (1) never matched the numeric keypad's Enter at all
/// (keyCode 76 sends U+0003, not U+000D), (2) ran the primary copy for ⌘⏎ and ⇧⏎, and (3) fired
/// on key-repeat — a held ⏎ produced FOUR `onPrimary` calls, and `isActing` closes only when the
/// host's async outcome lands. The handler is now the `keys: [.return, .keypadEnter], phases:
/// .down` form with the same guard ⌫ carries. Nothing here reads the single-key overload's
/// behaviour any more; the ␣ and esc handlers still use it and are still unguarded (neither moves
/// bytes).
@MainActor
@Suite(.serialized) struct ReviewCardKeyTests {

    /// What the card reported. A reference type: the closures escape into SwiftUI's update.
    private final class Recorder: @unchecked Sendable {
        var primaries = 0
        var skips = 0
        var exits = 0
    }

    private func makeCard(into recorder: Recorder) -> ReviewCardView? {
        let queue = [FileDifference(
            id: UUID(),
            relativePath: "Reports/Q3-summary.pdf",
            // Deliberately absent from disk, so the fact load resolves to placeholders and no
            // fixture files are needed.
            leftItemPath: "/nonexistent-left/Reports/Q3-summary.pdf",
            rightItemPath: "/nonexistent-right/Reports/Q3-summary.pdf",
            type: .missingOnRight,
            action: .copyToRight,
            description: "test"
        )]
        guard let session = ReviewSession(queue: queue, isMove: false, pathRootName: nil) else {
            return nil
        }
        return ReviewCardView(
            session: session,
            paneNames: PaneProviderNames(leftName: "iCloud", rightName: "Dropbox"),
            accent: .blue,
            fileManager: FileManager.default,
            onQuickLook: nil,
            isActing: false,
            focusNudge: 0,
            onPrimary: { _ in recorder.primaries += 1 },
            onSkip: { _ in recorder.skips += 1 },
            onVerdict: { _, _, _ in },
            onExit: { recorder.exits += 1 }
        )
    }

    // MARK: Harness (same shape as FilingWalkthroughCardKeyTests)

    private func host(_ view: some View) -> (NSWindow, NSHostingView<AnyView>) {
        let size = CGSize(width: 720, height: 480)
        let hostView = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        hostView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hostView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostView
        hostView.layoutSubtreeIfNeeded()
        return (window, hostView)
    }

    /// Waits for the card's own deferred `FocusState` claim — the acquisition the app relies on —
    /// so a green here also says the card really does take focus on appearance.
    private func waitForCardFocus(in window: NSWindow) async -> Bool {
        let (held, pumps) = await LayoutPumpWait.pump(window, upTo: 10) {
            window.firstResponder !== window && !(window.firstResponder is NSText)
        }
        if !held { Issue.record("the card never claimed focus (\(pumps) pumps)") }
        return held
    }

    private func sendDelete(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                            isARepeat: Bool = false) {
        window.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{08}", charactersIgnoringModifiers: "\u{08}",
            isARepeat: isARepeat, keyCode: 51)!)
    }

    private func send(_ window: NSWindow, keyCode: UInt16, characters: String,
                      modifiers: NSEvent.ModifierFlags = [], isARepeat: Bool = false) {
        window.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: isARepeat, keyCode: keyCode)!)
    }

    private func sendReturn(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                            isARepeat: Bool = false) {
        send(window, keyCode: 36, characters: "\r", modifiers: modifiers, isARepeat: isARepeat)
    }

    /// **The keypad's Enter is a different character.** keyCode 76, `NSEnterCharacter` (U+0003),
    /// never U+000D — and, like the arrows, it always carries `.numericPad` and `.function`.
    /// Measured on this harness through a probe view: the main row's ⏎ is delivered to
    /// `onKeyPress` as `KeyEquivalent("\r")` with `press.modifiers` rawValue 0; the keypad's is
    /// delivered as `KeyEquivalent("\u{3}")` with rawValue 96. A handler keyed on `.return`
    /// therefore never sees it. Caller modifiers are UNIONED with the intrinsic pair, so
    /// `.command` here is the ⌘-keypad-Enter AppKit would really deliver.
    private static let keypadEnterIntrinsicFlags: NSEvent.ModifierFlags = [.numericPad, .function]

    private func sendKeypadEnter(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                                 isARepeat: Bool = false) {
        send(window, keyCode: 76, characters: "\u{3}",
             modifiers: modifiers.union(Self.keypadEnterIntrinsicFlags), isARepeat: isARepeat)
    }

    // MARK: ⏎ — both keycaps

    /// **Both Enter keys copy.** The card's hint row advertises ⏎ for the primary action and a
    /// full-size keyboard has two keycaps that say so; before this, the keypad's did nothing at
    /// all, silently, on a card whose whole job is one decision per row.
    @Test func bothEnterKeysRunThePrimaryAction() async throws {
        let recorder = Recorder()
        let subject = try #require(makeCard(into: recorder), "fixture queue produced no session")
        let (window, _) = host(subject)
        guard await waitForCardFocus(in: window) else { return }

        sendReturn(window)
        try #require(recorder.primaries == 1,
                     "the main row's ⏎ never arrived — the keypad reading below would be vacuous")
        sendKeypadEnter(window)
        #expect(recorder.primaries == 2, """
                the numeric keypad's Enter (keyCode 76, U+0003) ran nothing (primaries: \
                \(recorder.primaries)). It must copy exactly like the main row's ⏎.
                """)
        #expect(recorder.skips == 0)
        #expect(recorder.exits == 0)
    }

    /// **A held Enter copies one item, from either keycap.** The primary is a real file copy; the
    /// `isActing` gate closes only once the host's async outcome lands, so auto-repeat at ~15
    /// events a second can launch several copies of the same row before it does. `.down`-only is
    /// what actually prevents that — the same rule ⌫ already carries.
    @Test func aHeldEnterCopiesExactlyOneItem() async throws {
        let recorder = Recorder()
        let subject = try #require(makeCard(into: recorder), "fixture queue produced no session")
        let (window, _) = host(subject)
        guard await waitForCardFocus(in: window) else { return }

        sendReturn(window)
        for _ in 0..<3 { sendReturn(window, isARepeat: true) }
        #expect(recorder.primaries == 1,
                "a held ⏎ produced \(recorder.primaries) copies — auto-repeat is re-copying the row")

        for _ in 0..<3 { sendKeypadEnter(window, isARepeat: true) }
        #expect(recorder.primaries == 1,
                "a held keypad Enter produced \(recorder.primaries) copies in total — auto-repeat is re-copying the row")

        // The honesty control: fresh presses of BOTH keycaps still arrive, so the readings above
        // are the phase filter working rather than the harness dropping events.
        sendReturn(window)
        sendKeypadEnter(window)
        #expect(recorder.primaries == 3, "fresh presses stopped arriving: \(recorder.primaries)")
    }

    /// **A modified Enter is not the primary action, from either keycap.** ⌘⏎ and ⇧⏎ are
    /// "open"/"extend" chords all over macOS and ⌥⏎ is "open in a new window" — none is the plain
    /// keystroke the hint row advertises, and the primary moves real bytes. The guard has to be
    /// `isPlainKeystroke` (⌘⌥⌃⇧ only): every keypad Enter arrives with `.numericPad` and
    /// `.function` set, so `modifiers.isEmpty` would refuse the key outright.
    @Test func aModifiedEnterCopiesNothing() async throws {
        let recorder = Recorder()
        let subject = try #require(makeCard(into: recorder), "fixture queue produced no session")
        let (window, _) = host(subject)
        guard await waitForCardFocus(in: window) else { return }

        // Positive control: both plain keycaps really reach the handler.
        sendReturn(window)
        sendKeypadEnter(window)
        try #require(recorder.primaries == 2,
                     "a plain Enter never arrived — the modified readings below would be vacuous")

        for modifier in [NSEvent.ModifierFlags.command, .option, .control, .shift] {
            sendReturn(window, modifiers: modifier)
            sendKeypadEnter(window, modifiers: modifier)
        }
        #expect(recorder.primaries == 2, """
                a MODIFIED Enter ran the primary action (primaries: \(recorder.primaries)).                 ⌘/⌥/⌃/⇧ + ⏎ are chords, and the primary copies a real file.
                """)

        // Caps Lock is a lock, not a chord: both keycaps must still copy while it is engaged.
        sendReturn(window, modifiers: .capsLock)
        sendKeypadEnter(window, modifiers: .capsLock)
        #expect(recorder.primaries == 4, """
                Enter with Caps Lock engaged copied nothing (primaries: \(recorder.primaries)).                 `.capsLock` rides on every event while the lock is engaged.
                """)
        #expect(recorder.skips == 0)
        #expect(recorder.exits == 0)
    }

    /// **A modified ⌫ is not a skip.** The positive control (plain ⌫ really skips) is what keeps
    /// the modified readings from passing against a card that never wired its handler.
    @Test func aModifiedDeleteSkipsNothing() async throws {
        let recorder = Recorder()
        let subject = try #require(makeCard(into: recorder), "fixture queue produced no session")
        let (window, _) = host(subject)
        guard await waitForCardFocus(in: window) else { return }

        sendDelete(window)
        try #require(recorder.skips == 1,
                     "plain ⌫ never arrived — the modified readings below would be vacuous")

        sendDelete(window, modifiers: .command)
        sendDelete(window, modifiers: .option)
        sendDelete(window, modifiers: .shift)
        #expect(recorder.skips == 1, """
                a MODIFIED ⌫ skipped an item (skips: \(recorder.skips)). ⌘⌫/⌥⌫/⇧⌫ are editing and \
                Finder chords, not the plain keystroke the hint row advertises — and a skipped row \
                cannot be revisited.
                """)
        #expect(recorder.primaries == 0)
        #expect(recorder.exits == 0)
    }

    /// **Caps Lock is not a chord.** `.capsLock` rides on EVERY event while the lock is engaged,
    /// so a guard written as `press.modifiers.isEmpty` takes ⌫-skip away entirely from anyone who
    /// left it on — silently, with the hint row still advertising the key. Measured on this
    /// harness: `delete` sent with `[.capsLock]` arrives as `SwiftUI.EventModifiers` rawValue 1,
    /// `isEmpty == false`. Only the four INTENT modifiers (⌘⌥⌃⇧) may refuse the skip.
    @Test func capsLockDoesNotDisableTheSkipKey() async throws {
        let recorder = Recorder()
        let subject = try #require(makeCard(into: recorder), "fixture queue produced no session")
        let (window, _) = host(subject)
        guard await waitForCardFocus(in: window) else { return }

        sendDelete(window, modifiers: .capsLock)
        #expect(recorder.skips == 1, """
                ⌫ with Caps Lock engaged skipped nothing (skips: \(recorder.skips)). Caps Lock is \
                a lock, not a chord — it must not disarm the key the hint row advertises.
                """)
        #expect(recorder.primaries == 0)
        #expect(recorder.exits == 0)
    }

    /// The held-key rule the handler's `.down`-only phases promise, proven here rather than
    /// assumed from the walkthrough card's twin: a held ⌫ skips exactly ONE row.
    @Test func aHeldDeleteSkipsExactlyOneRow() async throws {
        let recorder = Recorder()
        let subject = try #require(makeCard(into: recorder), "fixture queue produced no session")
        let (window, _) = host(subject)
        guard await waitForCardFocus(in: window) else { return }

        sendDelete(window)
        for _ in 0..<3 { sendDelete(window, isARepeat: true) }
        #expect(recorder.skips == 1,
                "a held ⌫ produced \(recorder.skips) skips — auto-repeat is mass-skipping the queue")

        // The honesty control: fresh presses still arrive, so the single skip above is the phase
        // filter working, not the harness dropping events after the first.
        for _ in 0..<3 { sendDelete(window) }
        #expect(recorder.skips == 4, "fresh presses stopped arriving: \(recorder.skips)")
    }
}
