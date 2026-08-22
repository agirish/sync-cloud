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

    // MARK: The premise the `focused` guard rests on

    /// A focus target that is unambiguously a DESCENDANT of the handler's own view.
    private enum ProbeSpot: Hashable { case anchor, button, plainFocusable }

    /// What the probe below saw. A reference type: the closures escape into SwiftUI's update.
    private final class ProbeRecorder: @unchecked Sendable {
        /// One entry per press the ancestor handler received: what `focused` read inside it.
        var ancestorSawAnchorFocused: [Bool] = []
        /// Every `@FocusState` transition the probe observed, so a "focus never moved" run is
        /// distinguishable from "focus moved and the handler fired anyway".
        var focusMoves: [ProbeSpot?] = []
        /// The seam that moves focus. A `@FocusState` cannot be written from outside the view,
        /// and driving it through an `onChange(of:)` on a plain captured `var` does NOT work —
        /// the view never re-renders, so the change is never observed. That was the first cut of
        /// this probe and it reported a false negative: focus stayed on the anchor throughout.
        var setFocus: ((ProbeSpot?) -> Void)?
    }

    /// The minimum shape both decision cards have: a `.focusable()` ancestor carrying the
    /// `.onKeyPress` handler, with focusable descendants inside it.
    private struct AncestorHandlerProbe: View {
        let recorder: ProbeRecorder
        @FocusState private var spot: ProbeSpot?

        var body: some View {
            VStack {
                Text("the card")
                // A real `Button`, like the cards' Skip / Preview / Verify, and a plain
                // focusable view beside it — the two ways a descendant can hold focus.
                Button("Skip") {}
                    .focusable(true)
                    .focused($spot, equals: .button)
                Text("plain focusable")
                    .focusable(true)
                    .focused($spot, equals: .plainFocusable)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($spot, equals: .anchor)
            .onKeyPress(keys: [.return], phases: .down) { _ in
                recorder.ancestorSawAnchorFocused.append(spot == .anchor)
                return .handled
            }
            .onAppear {
                recorder.setFocus = { spot = $0 }
                Task { @MainActor in spot = .anchor }
            }
            .onChange(of: spot) { _, new in recorder.focusMoves.append(new) }
        }
    }

    /// **`.onKeyPress` fires for a key delivered anywhere in its SUBTREE — including while a
    /// DESCENDANT holds focus and the handler's own `focused` reads false.**
    ///
    /// This is the premise `ReviewCardView`'s and `FilingWalkthroughCard`'s `guard … focused`
    /// rests on, and until 2026-08-21 it was asserted rather than measured: the walkthrough's
    /// comment called it "UNVERIFIABLE under `swift test`", and on that reading the guard looked
    /// like complexity on a false premise — which is exactly why `ReviewCardView` shipped without
    /// it while its twin had it. It is verifiable. Only the ROUTE is not: in the app Full Keyboard
    /// Access is what makes a `Button` focusable, and `NSApp` is **nil** in this test process
    /// (measured — so `isFullKeyboardAccessEnabled` cannot even be read, let alone set). Driving
    /// the `@FocusState` directly reproduces the state FKA would produce, which is what the guard
    /// actually keys on.
    ///
    /// Both descendant kinds are pressed, because a `Button` and a plain `.focusable()` view are
    /// different focus citizens on macOS and only one of them is what FKA promotes.
    ///
    /// Without this, the two cards' `focused` terms have no test that says what they buy: every
    /// other test in this suite and in `FilingWalkthroughCardKeyTests` runs with the card itself
    /// focused, where the term is a no-op.
    @Test func anAncestorHandlerStillFiresForAKeyAimedAtAFocusedDescendant() async {
        let recorder = ProbeRecorder()
        let (window, hostView) = host(AncestorHandlerProbe(recorder: recorder))
        guard await waitForCardFocus(in: window) else { return }

        // The positive control: with the ANCHOR focused the handler runs and sees `focused` true.
        sendReturn(window)
        #expect(recorder.ancestorSawAnchorFocused == [true], """
                the anchor never received ⏎ (\(recorder.ancestorSawAnchorFocused)) — the readings \
                below would be measuring a dead harness rather than focus.
                """)

        for descendant in [ProbeSpot.button, .plainFocusable] {
            recorder.setFocus?(descendant)
            hostView.layoutSubtreeIfNeeded()
            _ = await LayoutPumpWait.pump(window, upTo: 0.2) { false }
            let before = recorder.ancestorSawAnchorFocused.count
            sendReturn(window)
            // Non-vacuity: focus really left the anchor. A run where the `@FocusState` write did
            // not take would otherwise read as "the guard is unnecessary".
            #expect(recorder.focusMoves.contains(descendant), """
                    focus never moved to \(descendant) (moves: \(recorder.focusMoves)) — this \
                    press was still aimed at the anchor, so it proves nothing.
                    """)
            #expect(recorder.ancestorSawAnchorFocused.count == before + 1, """
                    the ancestor handler did NOT fire for a ⏎ aimed at a focused \(descendant). \
                    If SwiftUI has started scoping `.onKeyPress` to the exact focused view, the \
                    two cards' `focused` guards are dead code and this test should say so.
                    """)
            #expect(recorder.ancestorSawAnchorFocused.last == false, """
                    the handler fired with `focused` reading TRUE while \(descendant) held focus \
                    — the guard cannot tell the two states apart, so it protects nothing.
                    """)
        }
    }

    /// **Both decision cards guard their byte-moving keys on `focused`, and they say so in the
    /// same words.**
    ///
    /// The behavioural half is above; this is the half that pins it to the two real handlers.
    /// It cannot be behavioural on the shipped cards: their `@FocusState` is private and none of
    /// their descendants carries a `.focused()` binding a test could write, so there is no way to
    /// put the real card into the descendant-focused state from out here. A structural check is
    /// what is left — and this file's own history is the argument for having one: `ReviewCardView`
    /// and `FilingWalkthroughCard` are twins whose handlers have now diverged twice (the modifier
    /// filter, then this), each time silently, each time on the card that moves bytes.
    ///
    /// Byte-moving keys only. esc is deliberately ungated on both cards — cancelling from a
    /// focused button is what esc means there anyway — and ␣ (Quick Look) moves nothing.
    @Test func bothDecisionCardsGuardTheirByteMovingKeysOnFocus() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/FileExplorer
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/FileExplorer
            .appendingPathComponent("Sources/FileExplorer")

        /// The `guard` line that opens the handler introduced by `marker`.
        func guardLine(_ file: String, after marker: String) throws -> String {
            let text = try #require(
                try? String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8),
                "cannot read \(file) — this check would be vacuous")
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let start = try #require(lines.firstIndex { $0.contains(marker) }, """
                        \(file) no longer contains `\(marker)` — the handler was renamed, \
                        respelled or removed, and this check stopped reading anything.
                        """)
            let body = try #require(lines[(start + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                                    "\(file): nothing follows \(marker)")
            return body.trimmingCharacters(in: .whitespaces)
        }

        let expected = "guard press.isPlainKeystroke, focused else { return .ignored }"
        let handlers = [
            ("ReviewCardView.swift", ".onKeyPress(keys: [.return, .keypadEnter], phases: .down)", "⏎ — the primary copy/move"),
            ("ReviewCardView.swift", ".onKeyPress(keys: [.delete], phases: .down)", "⌫ — an unrevisitable skip"),
            ("AutomationsLens.swift", ".onKeyPress(keys: [.return, .keypadEnter], phases: .down)", "⏎ — files a real file"),
            ("AutomationsLens.swift", ".onKeyPress(keys: [.rightArrow], phases: .down)", "→ — an unrevisitable skip"),
        ]
        for (file, marker, what) in handlers {
            #expect(try guardLine(file, after: marker) == expected, """
                    \(file)'s \(what) handler does not open with `\(expected)`. Both terms are \
                    load-bearing: `isPlainKeystroke` keeps ⌘⏎/⌥⌫ from deciding, and `focused` \
                    keeps a key aimed at a focused descendant button from deciding (see \
                    anAncestorHandlerStillFiresForAKeyAimedAtAFocusedDescendant). Dropping \
                    either one on either card moves bytes the keystroke did not ask for.
                    """)
        }
    }
}
