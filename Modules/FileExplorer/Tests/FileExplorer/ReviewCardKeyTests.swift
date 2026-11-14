import AppKit
import SwiftUI
import Testing
import Sync
@testable import FileExplorer

/// `ReviewCardView`'s ⏎-primary and ⌫-skip, the two keys that move or drop a row, through a real
/// window's responder chain (the harness of `FilingWalkthroughCardKeyTests`).
///
/// `onKeyPress` filters no modifiers on any overload, so without `press.isPlainKeystroke` ⌘⌫ and ⌥⌫
/// would skip the item, which no back-step can revisit. The single-key `onKeyPress(.return)` never
/// matches the keypad's Enter (U+0003, not U+000D), runs for ⌘⏎ and ⇧⏎, and fires on key-repeat
/// while `isActing` is still open, so ⏎ uses `keys: [.return, .keypadEnter], phases: .down` with
/// ⌫'s guard. ␣ and esc keep the single-key overload, unguarded: neither moves bytes.
@MainActor
@Suite(.serialized) struct ReviewCardKeyTests {

    /// What the card reported. A reference type: the closures escape into SwiftUI's update.
    private final class Recorder: @unchecked Sendable {
        var primaries = 0
        var skips = 0
        var exits = 0
    }

    private func makeCard(into recorder: Recorder, focusNudge: Int = 0) -> ReviewCardView? {
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
            focusNudge: focusNudge,
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
    /// A card mounted and holding focus, its actions counted into the recorder; nil (recorded)
    /// when focus never lands.
    private func focusedCard() async throws -> (Recorder, NSWindow)? {
        let recorder = Recorder()
        let subject = try #require(makeCard(into: recorder), "fixture queue produced no session")
        let (window, _) = host(subject)
        guard await waitForCardFocus(in: window) else { return nil }
        return (recorder, window)
    }

    private func waitForCardFocus(in window: NSWindow) async -> Bool {
        let (held, pumps) = await LayoutPumpWait.pump(window, upTo: 10) {
            window.firstResponder !== window && !(window.firstResponder is NSText)
        }
        if !held { Issue.record("the card never claimed focus (\(pumps) pumps)") }
        return held
    }

    private func sendDelete(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                            isARepeat: Bool = false) {
        send(window, keyCode: 51, characters: "\u{08}", modifiers: modifiers, isARepeat: isARepeat)
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

    /// The keypad's Enter is a different character: keyCode 76, `NSEnterCharacter` (U+0003), never
    /// U+000D, and like the arrows it always carries `.numericPad` and `.function`. `onKeyPress`
    /// gets it as `KeyEquivalent("\u{3}")` with modifiers rawValue 96 (the main row's ⏎ is "\r",
    /// rawValue 0), so a handler keyed on `.return` never sees it. Caller modifiers are unioned
    /// with the intrinsic pair, so `.command` here is the ⌘-keypad-Enter AppKit really delivers.
    private static let keypadEnterIntrinsicFlags: NSEvent.ModifierFlags = [.numericPad, .function]

    private func sendKeypadEnter(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                                 isARepeat: Bool = false) {
        send(window, keyCode: 76, characters: "\u{3}",
             modifiers: modifiers.union(Self.keypadEnterIntrinsicFlags), isARepeat: isARepeat)
    }

    // MARK: ⏎ — both keycaps

    /// Both Enter keys copy: the hint row advertises ⏎ for the primary action, and a full-size
    /// keyboard has two keycaps that say so.
    @Test func bothEnterKeysRunThePrimaryAction() async throws {
        guard case let (recorder, window)? = try await focusedCard() else { return }

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

    /// A held Enter copies one item, from either keycap. The primary is a real file copy and the
    /// `isActing` gate closes only once the host's async outcome lands, so auto-repeat could launch
    /// several copies of the row first; `.down`-only prevents that, as it does for ⌫.
    @Test func aHeldEnterCopiesExactlyOneItem() async throws {
        guard case let (recorder, window)? = try await focusedCard() else { return }

        sendReturn(window)
        for _ in 0..<3 { sendReturn(window, isARepeat: true) }
        #expect(recorder.primaries == 1,
                "a held ⏎ produced \(recorder.primaries) copies — auto-repeat is re-copying the row")

        for _ in 0..<3 { sendKeypadEnter(window, isARepeat: true) }
        #expect(recorder.primaries == 1,
                "a held keypad Enter produced \(recorder.primaries) copies in total — auto-repeat is re-copying the row")

        // Honesty control: fresh presses of both keycaps still arrive, so the readings above are
        // the phase filter working, not the harness dropping events.
        sendReturn(window)
        sendKeypadEnter(window)
        #expect(recorder.primaries == 3, "fresh presses stopped arriving: \(recorder.primaries)")
    }

    /// A modified Enter is not the primary action, from either keycap. ⌘⏎ and ⇧⏎ are
    /// "open"/"extend" chords across macOS and ⌥⏎ is "open in a new window": none is the plain
    /// keystroke the hint row advertises, and the primary moves real bytes. The guard must be
    /// `isPlainKeystroke` (⌘⌥⌃⇧ only): every keypad Enter carries `.numericPad` and `.function`,
    /// so `modifiers.isEmpty` would refuse the key outright.
    @Test func aModifiedEnterCopiesNothing() async throws {
        guard case let (recorder, window)? = try await focusedCard() else { return }

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
                a MODIFIED Enter ran the primary action (primaries: \(recorder.primaries)). \
                ⌘/⌥/⌃/⇧ + ⏎ are chords, and the primary copies a real file.
                """)

        // Caps Lock is a lock, not a chord: both keycaps must still copy while it is engaged.
        sendReturn(window, modifiers: .capsLock)
        sendKeypadEnter(window, modifiers: .capsLock)
        #expect(recorder.primaries == 4, """
                Enter with Caps Lock engaged copied nothing (primaries: \(recorder.primaries)). \
                `.capsLock` rides on every event while the lock is engaged.
                """)
        #expect(recorder.skips == 0)
        #expect(recorder.exits == 0)
    }

    /// A modified ⌫ is not a skip. The positive control (plain ⌫ skips) keeps the modified readings
    /// from passing against a card that never wired its handler.
    @Test func aModifiedDeleteSkipsNothing() async throws {
        guard case let (recorder, window)? = try await focusedCard() else { return }

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

    /// → doesn't skip here, though the Rules walkthrough takes it: in Compare → means "to the right
    /// pane" (⌘→ copies there), and a skip can't be taken back. The plain ⌫ afterwards keeps the
    /// arrow's silence from passing against a card that never got focus.
    @Test func rightArrowDoesNotSkip() async throws {
        guard case let (recorder, window)? = try await focusedCard() else { return }

        let arrow: NSEvent.ModifierFlags = [.function, .numericPad]
        send(window, keyCode: 124, characters: "\u{F703}", modifiers: arrow)
        send(window, keyCode: 124, characters: "\u{F703}", modifiers: arrow.union(.option))
        #expect(recorder.skips == 0, "a → skipped an item (skips: \(recorder.skips))")
        sendDelete(window)
        #expect(recorder.skips == 1, "plain ⌫ did not skip — the → reading above is vacuous")
        #expect(recorder.primaries == 0)
        #expect(recorder.exits == 0)
    }

    /// Caps Lock is not a chord. `.capsLock` rides on every event while the lock is engaged (it
    /// arrives as `EventModifiers` rawValue 1), so a `press.modifiers.isEmpty` guard would silently
    /// take ⌫-skip away from anyone who left it on. Only ⌘⌥⌃⇧ may refuse the skip.
    @Test func capsLockDoesNotDisableTheSkipKey() async throws {
        guard case let (recorder, window)? = try await focusedCard() else { return }

        sendDelete(window, modifiers: .capsLock)
        #expect(recorder.skips == 1, """
                ⌫ with Caps Lock engaged skipped nothing (skips: \(recorder.skips)). Caps Lock is \
                a lock, not a chord — it must not disarm the key the hint row advertises.
                """)
        #expect(recorder.primaries == 0)
        #expect(recorder.exits == 0)
    }

    /// The held-key rule the handler's `.down`-only phases promise, proven here rather than assumed
    /// from the walkthrough card's twin: a held ⌫ skips exactly one row.
    @Test func aHeldDeleteSkipsExactlyOneRow() async throws {
        guard case let (recorder, window)? = try await focusedCard() else { return }

        sendDelete(window)
        for _ in 0..<3 { sendDelete(window, isARepeat: true) }
        #expect(recorder.skips == 1,
                "a held ⌫ produced \(recorder.skips) skips — auto-repeat is mass-skipping the queue")

        // Honesty control: fresh presses still arrive, so the single skip above is the phase
        // filter working, not the harness dropping events after the first.
        for _ in 0..<3 { sendDelete(window) }
        #expect(recorder.skips == 4, "fresh presses stopped arriving: \(recorder.skips)")
    }

    // MARK: The premise the `focused` guard rests on

    /// The probe's focus targets: the handler's own view, and two of its descendants.
    private enum ProbeSpot: Hashable { case anchor, button, plainFocusable }

    /// What the probe below saw. A reference type: the closures escape into SwiftUI's update.
    private final class ProbeRecorder: @unchecked Sendable {
        /// One entry per press the ancestor handler received: what `focused` read inside it.
        var ancestorSawAnchorFocused: [Bool] = []
        /// Every `@FocusState` transition the probe observed, so a "focus never moved" run is
        /// distinguishable from "focus moved and the handler fired anyway".
        var focusMoves: [ProbeSpot?] = []
        /// The seam that moves focus. A `@FocusState` can't be written from outside the view, and
        /// driving it through `onChange(of:)` on a plain captured `var` doesn't work: the view never
        /// re-renders, so the change is never observed.
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
                // A real `Button`, like the cards' Skip / Preview / Verify, and a plain focusable
                // view beside it: the two ways a descendant can hold focus.
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

    /// `.onKeyPress` fires for a key delivered anywhere in its subtree, even while a descendant
    /// holds focus and the handler's own `focused` reads false.
    ///
    /// This is the premise `ReviewCardView`'s and `FilingWalkthroughCard`'s `guard … focused` rests
    /// on. In the app, Full Keyboard Access is what makes a `Button` focusable, and `NSApp` is nil
    /// in this test process (so `isFullKeyboardAccessEnabled` can't be read or set); driving the
    /// `@FocusState` directly reproduces the state FKA would, which is what the guard keys on.
    ///
    /// Both descendant kinds are pressed: a `Button` and a plain `.focusable()` view are different
    /// focus citizens on macOS, and only one is what FKA promotes. Every other test here and in
    /// `FilingWalkthroughCardKeyTests` runs with the card itself focused, where the term is a no-op.
    @Test func anAncestorHandlerStillFiresForAKeyAimedAtAFocusedDescendant() async {
        let recorder = ProbeRecorder()
        let (window, hostView) = host(AncestorHandlerProbe(recorder: recorder))
        guard await waitForCardFocus(in: window) else { return }

        // Positive control: with the anchor focused the handler runs and sees `focused` true.
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

    /// Both decision cards guard their byte-moving keys on `focused`, in the same words.
    ///
    /// The behavioural half is above; this pins it to the two real handlers. It can't be
    /// behavioural on the shipped cards: their `@FocusState` is private and no descendant carries a
    /// `.focused()` binding a test could write. `ReviewCardView` and `FilingWalkthroughCard` are
    /// twins whose handlers can silently drift apart, so a structural check holds them together.
    ///
    /// Byte-moving keys only. esc is ungated on both cards (cancelling from a focused button is
    /// what esc means there anyway), and ␣ (Quick Look) moves nothing.
    @Test func bothDecisionCardsGuardTheirByteMovingKeysOnFocus() throws {
        /// The `guard` line that opens the handler introduced by `marker`.
        func guardLine(_ file: String, after marker: String) throws -> String {
            let text = try SourceText.fileExplorer(file)
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
            ("AutomationsLens.swift", ".onKeyPress(keys: [.rightArrow, .delete], phases: .down)", "→ and ⌫ — an unrevisitable skip"),
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

    // MARK: Focus recovery

    /// The recovery that has to come with the `focused` guard, in the half this process can prove.
    ///
    /// With `focused` on ⏎ and ⌫, a card that has lost key focus has advertised keys that silently
    /// do nothing. The routes back are a click on the card body or on its own Quick Look / Verify
    /// buttons, all of which call `reclaimFocus()`: a `Task { @MainActor in focused = true }`, one
    /// turn later.
    ///
    /// The click isn't reachable here: a synthesized `leftMouseDown`/`leftMouseUp` through
    /// `window.sendEvent` doesn't drive SwiftUI's tap gesture in this headless host. So this drives
    /// the same deferred claim through `focusNudge` and pins the mechanism, that a deferred
    /// `focused = true` brings ⏎ back after focus moved away. The scan below pins that the three
    /// affordances call it.
    ///
    /// ⏎ is proved dead first, so a green can't come from focus never having left.
    @MainActor
    @Test func aDeferredFocusClaimTakesTheCardsKeysBackAfterFocusMovedAway() async throws {
        let recorder = Recorder()
        let card = try #require(makeCard(into: recorder))
        let (window, hostView) = host(card)
        defer { window.contentView = nil }
        guard await waitForCardFocus(in: window) else { return }

        // Focus off the card — what a click on one of its own buttons does under Full Keyboard
        // Access, staged here without needing FKA (which `NSApp` being nil makes unreadable).
        window.makeFirstResponder(window)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { false }
        sendReturn(window)
        #expect(recorder.primaries == 0,
                "PREMISE FAILED: ⏎ still ran the primary with focus off the card, so this test cannot see the recovery")

        // The same deferred claim `reclaimFocus()` makes, driven through the host's nudge.
        let bumped = try #require(makeCard(into: recorder, focusNudge: 1))
        hostView.rootView = AnyView(bumped.frame(width: hostView.frame.width,
                                                 height: hostView.frame.height))
        _ = await LayoutPumpWait.pump(window, upTo: 10) {
            window.firstResponder !== window && !(window.firstResponder is NSText)
        }

        sendReturn(window)
        #expect(recorder.primaries == 1,
                "a deferred focus claim did not give the card's keys back — ⏎ is still dead")
    }

    /// Every affordance on the card that can take key focus away from it calls `reclaimFocus()`.
    ///
    /// A source scan, so it sees whether the call is there, not whether it works; the test above
    /// carries the mechanism. Without the call, a Quick Look or a Verify leaves ⏎ and ⌫ dead with
    /// their keycaps still on screen.
    ///
    /// Anchored on the two buttons by name rather than a count of `reclaimFocus` calls: a count
    /// passes when a new focus-taking button is added without one.
    @Test func theCardsOwnAffordancesAllPutKeyFocusBack() throws {
        let source = try SourceText.fileExplorer("ReviewCardView.swift")
        // The card body: a click anywhere on it is the route a user tries first, and it needs the
        // filled hit area to be clickable at all — an unfilled shape is hit-tested only where
        // painted.
        #expect(source.contains(".contentShape(Rectangle())\n        .onTapGesture { reclaimFocus() }"),
                "the card body no longer takes focus back on a tap")
        // The two buttons that leave the item alone, so `.task(id: item.id)`'s claim never fires
        // for them. (File and Skip change the item, and that claim covers them.)
        for button in ["Quick Look", "Verify"] {
            let label = "Label(\"\(button)\""
            let idx = try #require(source.range(of: label)?.lowerBound,
                                   "the \(button) button is gone — re-aim this scan")
            let action = String(source[..<idx].suffix(600))
            #expect(action.contains("reclaimFocus()"),
                    "the \(button) button can take key focus and does not give it back")
        }
    }
}
