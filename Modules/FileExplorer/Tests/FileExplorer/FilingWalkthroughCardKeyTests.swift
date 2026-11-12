import AppKit
import SwiftUI
import Testing
import Sync
@testable import FileExplorer

/// The filing walkthrough card's keys, exercised through a real window's responder chain.
///
/// Window-level key equivalents (`.keyboardShortcut(.return, modifiers: [])` and the like) are
/// consulted before the first responder, so a ⏎ typed into the lens header's search field would
/// move the current file on disk, and they fire on key-repeat, so a held ⏎ would approve file after
/// file. `BareKeyEquivalentScanTests` bans that shape at source level; this suite is the
/// behavioural half: the `.onKeyPress` handlers receive the keys when the card holds focus, do not
/// receive them when a text field does, and do not auto-repeat.
///
/// Harness borrowed from `DifferencesTableBindingTests`: a borderless, never-ordered-in window,
/// events injected with `sendEvent`. Every negative assertion is paired in-test with a positive
/// from the same harness: a probe that cannot report presence cannot report absence either.
@MainActor
@Suite(.serialized) struct FilingWalkthroughCardKeyTests {

    private static func row(_ name: String) -> AutomationDryRunRow { .walkFixture(name) }

    /// What the card reported. A reference type: the closures escape into SwiftUI's update.
    private final class Recorder: @unchecked Sendable {
        var decisions: [Bool] = []
        var cancels = 0
    }

    private func card(into recorder: Recorder) -> FilingWalkthroughCard {
        FilingWalkthroughCard(
            row: Self.row("a.pdf"), position: 1, total: 3, accent: .blue,
            providerName: "iCloud", onQuickLook: nil, onReveal: nil,
            focusNudge: 0,
            onDecision: { recorder.decisions.append($0) },
            onCancel: { recorder.cancels += 1 })
    }

    /// Test-mutable stand-in for the host's `@State`: `NudgedHost` reads its nudge from here the
    /// way `FilingWalkthroughCard` reads `AutomationsLens.filingFocusNudge`, so a test can play the
    /// host's `advanceFiling` bump from outside the hierarchy.
    @MainActor
    private final class HostState: ObservableObject {
        @Published var focusNudge = 0
    }

    /// The card next to a text field, wired the way `AutomationsLens.filingReviewState` wires it.
    private struct NudgedHost: View {
        @ObservedObject var state: HostState
        let row: AutomationDryRunRow
        var onQuickLook: ((String) -> Void)? = nil
        let onDecision: (Bool) -> Void
        var body: some View {
            VStack {
                TextField("Search", text: .constant("inv"))
                FilingWalkthroughCard(
                    row: row, position: 1, total: 3, accent: .blue,
                    providerName: "iCloud", onQuickLook: onQuickLook, onReveal: nil,
                    focusNudge: state.focusNudge,
                    onDecision: onDecision,
                    onCancel: {})
            }
        }
    }

    // MARK: Harness

    private func host(_ view: some View) -> (NSWindow, NSHostingView<AnyView>) {
        let (host, window) = HostedView.framed(view, size: CGSize(width: 520, height: 480))
        return (window, host)
    }

    /// Waits for the card's own deferred `FocusState` claim to land, the same acquisition the app
    /// relies on when the walkthrough appears, not a `makeFirstResponder` shortcut past it. So a
    /// green here also says the card takes focus on appearance.
    private func waitForCardFocus(in window: NSWindow) async -> Bool {
        let (held, pumps) = await LayoutPumpWait.pump(window, upTo: 10) {
            window.firstResponder !== window && !(window.firstResponder is NSText)
        }
        if !held { Issue.record("the card never claimed focus (\(pumps) pumps)") }
        return held
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

    /// Arrows always carry `.function` and `.numericPad`. AppKit sets both on every arrow-key event
    /// (`NSEvent.ModifierFlags.numericPad`: "also set if any of the arrow keys are pressed"), so an
    /// arrow with `modifierFlags: []` is a shape the real keyboard cannot produce, and a handler
    /// guarded on `press.modifiers.isEmpty` would pass such a test while skipping nothing for a
    /// real →. The caller's `modifiers` are unioned with the intrinsic pair, so `.option` here
    /// means the ⌥→ AppKit would actually deliver.
    ///
    /// Measured through this harness (`SwiftUI.EventModifiers` raw values, from a probe view on
    /// this window's responder chain): arrow flags `[]` → 0; `[.function, .numericPad]` → 96;
    /// `[.capsLock, .function, .numericPad]` → 97.
    private static let arrowIntrinsicFlags: NSEvent.ModifierFlags = [.function, .numericPad]

    private func sendRightArrow(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                                isARepeat: Bool = false) {
        send(window, keyCode: 124, characters: "\u{F703}",
             modifiers: modifiers.union(Self.arrowIntrinsicFlags), isARepeat: isARepeat)
    }

    private func sendEscape(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                            isARepeat: Bool = false) {
        send(window, keyCode: 53, characters: "\u{1B}", modifiers: modifiers, isARepeat: isARepeat)
    }

    /// The numeric keypad's Enter is not a carriage return. It is keyCode 76 and sends
    /// `NSEnterCharacter` (U+0003), not U+000D, and like the arrows it always carries `.numericPad`
    /// and `.function`. Measured through this harness (a probe view reporting what `onKeyPress`
    /// receives on this window's responder chain):
    ///
    /// | sent | delivered `press.key` | `press.characters` | `press.modifiers` raw |
    /// |---|---|---|---|
    /// | keyCode 36, `"\r"`, `[]` | `KeyEquivalent("\r")` | U+000D | 0 |
    /// | keyCode 76, `"\u{3}"`, `[.numericPad, .function]` | `KeyEquivalent("\u{3}")` | U+0003 | 96
    /// |
    ///
    /// So `keys: [.return]`, which matches on the delivered `KeyEquivalent`, never matches the
    /// keypad's Enter, while `keys: [KeyEquivalent("\u{3}")]` does. The event is delivered to
    /// `onKeyPress`; it is the key set that misses it. Hence `KeyEquivalent.keypadEnter` in the
    /// handler's set rather than a monitor.
    ///
    /// The caller's `modifiers` are unioned with the intrinsic pair, as in `sendRightArrow`, so
    /// `.command` here means the ⌘-keypad-Enter AppKit would actually deliver.
    private static let keypadEnterIntrinsicFlags: NSEvent.ModifierFlags = [.numericPad, .function]

    private func sendKeypadEnter(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                                 isARepeat: Bool = false) {
        send(window, keyCode: 76, characters: "\u{3}",
             modifiers: modifiers.union(Self.keypadEnterIntrinsicFlags), isARepeat: isARepeat)
    }

    // MARK: The keypad's Enter is the same decision as the main row's

    /// A full-size keyboard has two Enter keys, and the card must hear both. The keypad's Enter is
    /// the key a two-handed user filing a stack of documents presses; a card deaf to it would file
    /// nothing, silently, with its hint row advertising ⏎. Nothing on screen distinguishes the two
    /// keycaps, so that failure would look like a wedged card.
    @Test func theKeypadsEnterFilesLikeTheMainRowReturn() async {
        let recorder = Recorder()
        let (window, _) = host(card(into: recorder))
        guard await waitForCardFocus(in: window) else { return }

        sendKeypadEnter(window)
        #expect(recorder.decisions == [true], """
                the numeric keypad's Enter (keyCode 76, U+0003) filed nothing: \(recorder.decisions).                 It must file exactly like the main row's ⏎ — the keycaps mean the same thing.
                """)
        #expect(recorder.cancels == 0)
    }

    /// The modifier rule for the keypad's Enter: ⌘⏎/⇧⏎ are "open"/"extend" chords whichever keycap
    /// produced them, and this Enter arrives with `.numericPad` and `.function` already set, so the
    /// guard has to be `isPlainKeystroke` (⌘⌥⌃⇧ only) and not `modifiers.isEmpty`, which would
    /// refuse every keypad Enter. Caps Lock is in the volley for the same reason.
    @Test func aModifiedKeypadEnterDecidesNothing() async {
        let recorder = Recorder()
        let (window, _) = host(card(into: recorder))
        guard await waitForCardFocus(in: window) else { return }

        // Positive control first: the plain keypad Enter really reaches the handler, so the
        // no-decision readings below measure the modifier filter, not a dead key.
        sendKeypadEnter(window)
        #expect(recorder.decisions == [true],
                "plain keypad Enter never arrived — the readings below are vacuous")

        sendKeypadEnter(window, modifiers: .command)
        sendKeypadEnter(window, modifiers: .option)
        sendKeypadEnter(window, modifiers: .control)
        sendKeypadEnter(window, modifiers: .shift)
        #expect(recorder.decisions == [true], """
                a MODIFIED keypad Enter filed a file: \(recorder.decisions). ⌘/⌥/⌃/⇧ + Enter are \
                chords, not the plain keystroke the keycap advertises.
                """)

        // And Caps Lock, which is a lock and not a chord, must still file.
        sendKeypadEnter(window, modifiers: .capsLock)
        #expect(recorder.decisions == [true, true], """
                keypad Enter with Caps Lock engaged filed nothing: \(recorder.decisions).                 `.capsLock` rides on every event while the lock is engaged.
                """)
        #expect(recorder.cancels == 0)
    }

    // MARK: The keys, with the card focused

    /// ⏎ files, → skips, esc cancels, through the focus the card acquired for itself.
    @Test func theFocusedCardReceivesItsThreeKeys() async {
        let recorder = Recorder()
        let (window, _) = host(card(into: recorder))
        guard await waitForCardFocus(in: window) else { return }

        sendReturn(window)
        sendRightArrow(window)
        sendEscape(window)
        #expect(recorder.decisions == [true, false],
                "got \(recorder.decisions) — ⏎ must file and → must skip")
        #expect(recorder.cancels == 1, "esc did not cancel")
    }

    /// A modified key is not a decision. ⌘⏎ / ⇧⏎ are "open"/"add to selection" chords all over
    /// macOS, and ⌥→ / ⌃→ are word-wise and Space-switch navigation; none of them is the plain
    /// keystroke the keycaps advertise, and ⏎ files a real file while → skips one no back-step can
    /// revisit. **No `onKeyPress` overload filters modifiers**, neither `keys:phases:` nor the
    /// single-key `onKeyPress(_:)`, so the handlers must check `press.modifiers` themselves.
    ///
    /// Measured on this harness, the single-key overload fires for ⏎ with ⌘/⇧/⌥/⌃/caps-lock and on
    /// key-repeat too; the two overloads differ only in that the single-key one does not fire on
    /// `.up`. ⌘esc, ⌃esc and ⌘. never arrive at all: AppKit takes those as `cancelOperation:` ahead
    /// of the responder chain, so neither overload sees them. That is a per-key routing effect, not
    /// a property of an overload.
    @Test func aModifiedKeyDecidesNothing() async {
        let recorder = Recorder()
        let (window, _) = host(card(into: recorder))
        guard await waitForCardFocus(in: window) else { return }

        // The positive control first: an unmodified ⏎ reaches the handler, so the no-decision
        // readings below measure the modifier filter, not a dead harness.
        sendReturn(window)
        #expect(recorder.decisions == [true], "unmodified ⏎ never arrived — the readings below are vacuous")

        sendReturn(window, modifiers: .command)
        sendReturn(window, modifiers: .shift)
        sendRightArrow(window, modifiers: .option)
        sendRightArrow(window, modifiers: .control)
        #expect(recorder.decisions == [true], """
                a MODIFIED key decided a file: \(recorder.decisions). ⌘⏎/⇧⏎ must not file and \
                ⌥→/⌃→ must not skip — only the plain keystroke the keycap advertises decides.
                """)
        #expect(recorder.cancels == 0)
    }

    /// ⌫ skips too: Compare's one-at-a-time review skips on ⌫, so someone who learned that one
    /// presses it here. Plain only, once per press, like →: ⌘⌫ and ⌥⌫ are text-editing chords, and
    /// a held ⌫ must not run through the queue.
    @Test func deleteSkipsLikeTheArrow() async {
        let recorder = Recorder()
        let (window, _) = host(card(into: recorder))
        guard await waitForCardFocus(in: window) else { return }

        sendDelete(window)
        #expect(recorder.decisions == [false], "a plain ⌫ did not skip: \(recorder.decisions)")
        for _ in 0..<3 { sendDelete(window, isARepeat: true) }
        sendDelete(window, modifiers: .command)
        sendDelete(window, modifiers: .option)
        #expect(recorder.decisions == [false],
                "a held or modified ⌫ decided a file: \(recorder.decisions)")
        #expect(recorder.cancels == 0)
    }

    private func sendDelete(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                            isARepeat: Bool = false) {
        send(window, keyCode: 51, characters: "\u{08}", modifiers: modifiers, isARepeat: isARepeat)
    }

    enum HeldKey: CaseIterable, Sendable { case returnKey, keypadEnter, rightArrow, escape }

    /// Key-repeat decides nothing. ⏎ moves a real file and → skips one no back-step can revisit, so
    /// the handlers are `.down`-phase only: a held key must act exactly once. Each key is its own
    /// case because each is its own handler or its own entry in a key set, where a `.repeat` phase
    /// could be re-admitted unnoticed (→ regressing to `[.down, .repeat]` with ⏎'s case green). And
    /// esc: cancel tears the walkthrough down, so in the app a second delivery lands on nothing, but
    /// the handler's contract should not depend on that.
    @Test(arguments: HeldKey.allCases)
    func aHeldKeyActsExactlyOnce(_ key: HeldKey) async {
        let recorder = Recorder()
        let (window, _) = host(card(into: recorder))
        guard await waitForCardFocus(in: window) else { return }
        func press(isARepeat: Bool) {
            switch key {
            case .returnKey: sendReturn(window, isARepeat: isARepeat)
            case .keypadEnter: sendKeypadEnter(window, isARepeat: isARepeat)
            case .rightArrow: sendRightArrow(window, isARepeat: isARepeat)
            case .escape: sendEscape(window, isARepeat: isARepeat)
            }
        }
        func acts() -> Int { key == .escape ? recorder.cancels : recorder.decisions.count }

        press(isARepeat: false)
        for _ in 0..<3 { press(isARepeat: true) }
        #expect(acts() == 1, "a held \(key) acted \(acts()) times — auto-repeat is deciding files")
        if key != .escape {
            #expect(recorder.decisions == [key != .rightArrow], "got \(recorder.decisions)")
        }

        // The honesty control: fresh presses still arrive, so the single act above is the phase
        // filter, not the harness dropping events after the first.
        for _ in 0..<3 { press(isARepeat: false) }
        #expect(acts() == 4, "fresh presses stopped arriving: \(recorder.decisions), \(recorder.cancels) cancels")
    }

    /// Caps Lock is not a chord. `.capsLock` is present on every event while the lock is engaged,
    /// so a guard written as `press.modifiers.isEmpty` would kill ⏎, → and esc outright for anyone
    /// who left it on, with no way to tell why. Measured on this harness: `return` with
    /// `[.capsLock]` arrives as `EventModifiers` rawValue 1, `isEmpty == false`. Only the four
    /// intent modifiers (⌘⌥⌃⇧) may refuse a decision.
    @Test func capsLockDoesNotDisableTheCardsKeys() async {
        let recorder = Recorder()
        let (window, _) = host(card(into: recorder))
        guard await waitForCardFocus(in: window) else { return }

        sendReturn(window, modifiers: .capsLock)
        sendRightArrow(window, modifiers: .capsLock)
        #expect(recorder.decisions == [true, false], """
                got \(recorder.decisions) — with Caps Lock engaged ⏎ must still file and → must \
                still skip. Caps Lock rides on every event; it is a lock, not a chord.
                """)
        sendEscape(window, modifiers: .capsLock)
        #expect(recorder.cancels == 1, "esc with Caps Lock engaged did not cancel")
    }

    // MARK: The keys, with a text field focused

    /// With key focus in a text field (the lens header's search, the Settings overlay), ⏎, → and
    /// esc belong to the field. A window-level key equivalent is consulted before the first
    /// responder, so this exact keystroke would move the current file on disk. esc is in the volley
    /// for the same reason: a `.keyboardShortcut(.cancelAction)` on Cancel would be bare esc at
    /// window level, and an esc typed to clear the field would discard the walkthrough's approvals.
    ///
    /// Honest scope: re-adding `.cancelAction` to Cancel leaves this test green, because
    /// window-level equivalents never fire in this never-key window, so what the esc volley pins is
    /// the `.onKeyPress` handlers honouring focus. The `.cancelAction` shape itself is banned
    /// statically, by
    /// `BareKeyEquivalentScanTests.noAlwaysMountedSurfaceRegistersAnyKeyEquivalentAtAll`, which
    /// that mutation does turn red.
    @Test func aTextFieldElsewhereKeepsItsReturnArrowAndEsc() async throws {
        let recorder = Recorder()
        let (window, hostView) = host(VStack {
            TextField("Search", text: .constant("inv"))
            card(into: recorder)
        })
        // Let the card claim focus first, the positive half, proving this hosting can deliver keys
        // to the card at all. Without it an empty `decisions` below would also be the signature of
        // a card that never wired its handlers.
        guard await waitForCardFocus(in: window) else { return }
        sendReturn(window)
        try #require(recorder.decisions == [true],
                     "the card never received keys in this harness — the negative below would be vacuous")

        // Now hand focus to the field, the way clicking into it would.
        let field = try #require(firstTextField(in: hostView), "no NSTextField in the hierarchy")
        try #require(window.makeFirstResponder(field), "the field refused first responder")

        sendReturn(window)
        sendRightArrow(window)
        sendEscape(window)
        #expect(recorder.decisions == [true], """
                typing in the text field reached the walkthrough card: \(recorder.decisions). \
                A ⏎ meant for the field just filed a real file (or a → silently skipped one, with \
                no back-step) — the exact defect the window-level `.keyboardShortcut`s shipped.
                """)
        #expect(recorder.cancels == 0, """
                esc typed in the text field cancelled the walkthrough — the esc handler stopped \
                honouring focus, so an esc meant to clear the field discards the approvals.
                """)
    }

    // MARK: The recovery hatch

    /// The focus-recovery hatch, as far as this harness can take it. In the app: type in the lens
    /// header's search field (which lives outside the lens body and stays mounted through the
    /// walkthrough), then click "File N…" or the card's File/Skip. On macOS a click on a plain
    /// button does not dislodge the field's editor, an NSTextView, from first responder, and the
    /// card has no passive per-row focus claim to fall back on (deliberately: every advance arrives
    /// with a nudge bump, so a guarded per-row claim beside the unconditional `onChange` one would
    /// be dead code; see the comment at the card's `.onAppear`). So without the host-driven
    /// `focusNudge` hatch, ⏎/→/esc would stay dead for the whole walkthrough.
    ///
    /// What this pins is the hatch's whole contract against a real responder chain: with an
    /// NSTextField's editor holding first responder, one nudge bump (what the host sends for every
    /// File/Skip decision and every Preview/Reveal inspection) must take key focus back from the
    /// editor and land it on the card, proven the only non-vacuous way: ⏎ reaching the card's
    /// handler again.
    @Test func aFocusNudgeReclaimsFocusFromATextFieldEditor() async throws {
        let recorder = Recorder()
        let hostState = HostState()
        let (window, hostView) = host(NudgedHost(
            state: hostState, row: Self.row("a.pdf"),
            onDecision: { recorder.decisions.append($0) }))
        // The positive half first: this hosting really delivers keys to the focused card, so the
        // reclaim below is measured by key delivery rather than by responder identity alone.
        guard await waitForCardFocus(in: window) else { return }
        sendReturn(window)
        try #require(recorder.decisions == [true],
                     "the card never received keys in this harness — the reclaim below would be vacuous")

        // Hand focus to the field, the way clicking into the search field would. From here the
        // window's field editor (an NSText) is what actually holds first responder.
        let field = try #require(firstTextField(in: hostView), "no NSTextField in the hierarchy")
        try #require(window.makeFirstResponder(field), "the field refused first responder")
        sendReturn(window)
        try #require(recorder.decisions == [true],
                     "⏎ reached the card while the field held focus — the card never lost it, so the nudge would prove nothing")

        // The host's half of the hatch: bump the nudge, exactly what `advanceFiling` does for every
        // decision. The card must claim key focus back from the field editor.
        hostState.focusNudge += 1
        let (reclaimed, pumps) = await LayoutPumpWait.pump(window, upTo: 10) {
            window.firstResponder !== window && !(window.firstResponder is NSText)
        }
        #expect(reclaimed,
                "the nudge never took key focus back from the field editor (\(pumps) pumps)")
        sendReturn(window)
        #expect(recorder.decisions == [true, true],
                "focus left the field editor but ⏎ still didn't reach the card: \(recorder.decisions)")
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { firstTextField(in: $0) }.first
    }

    // MARK: Non-destructive gestures recover focus too

    /// `recoveringFocus` preserves the host's "closure absent hides the affordance" contract: a
    /// nil inspection gesture must stay nil, or wrapping would conjure Preview/Reveal buttons for
    /// a host that offers neither.
    @Test func recoveringFocusPreservesAnAbsentGesture() {
        #expect(FilingWalkthroughCard.recoveringFocus(via: {}, nil) == nil)
    }

    /// The wrap's whole contract: the nudge bump comes first, exactly once, and the inner gesture
    /// still runs with the same path. Order matters: the bump is the focus recovery, and without it
    /// only a File/Skip would bring ⏎/→/esc back.
    @Test func recoveringFocusBumpsTheNudgeBeforeRunningTheGesture() {
        var calls: [String] = []
        let wrapped = FilingWalkthroughCard.recoveringFocus(
            via: { calls.append("bump") },
            { calls.append("open \($0)") })
        wrapped?("/inbox/a.pdf")
        #expect(calls == ["bump", "open /inbox/a.pdf"],
                "expected the nudge bump first, then the gesture — got \(calls)")
    }

    /// A Preview does not cost a decision. If File/Skip were the only gestures that recovered key
    /// focus, a user who clicked into the header's search field would have to spend a file or an
    /// unrevisitable skip to get ⏎/→/esc back; the non-destructive Preview/Reveal recover it too,
    /// through the same wrapper the lens installs.
    ///
    /// The card's buttons cannot be clicked under `swift test` (see `docs/flaky-tests.md`, "When
    /// you fix one": this window can never be key), so the test fires the exact closure the Preview button's action would:
    /// the wrapped gesture, built with `recoveringFocus` the way
    /// `AutomationsLens.filingReviewState` builds it, bumping the same host state the card reads.
    /// The reclaim is proven the only non-vacuous way: ⏎ reaching the card's handler again.
    @Test func aPreviewGestureReclaimsFocusWithoutSpendingADecision() async throws {
        let recorder = Recorder()
        let hostState = HostState()
        var previewed: [String] = []
        let preview = FilingWalkthroughCard.recoveringFocus(
            via: { hostState.focusNudge += 1 },
            { previewed.append($0) })
        let (window, hostView) = host(NudgedHost(
            state: hostState, row: Self.row("a.pdf"),
            onQuickLook: preview,
            onDecision: { recorder.decisions.append($0) }))

        // Positive half: this hosting really delivers keys to the focused card.
        guard await waitForCardFocus(in: window) else { return }
        sendReturn(window)
        try #require(recorder.decisions == [true],
                     "the card never received keys in this harness — the reclaim below would be vacuous")

        // Hand focus to the field; ⏎ must stop reaching the card, or the reclaim proves nothing.
        let field = try #require(firstTextField(in: hostView), "no NSTextField in the hierarchy")
        try #require(window.makeFirstResponder(field), "the field refused first responder")
        sendReturn(window)
        try #require(recorder.decisions == [true],
                     "⏎ reached the card while the field held focus — the card never lost it")

        // The Preview gesture, not a decision.
        preview?("/inbox/a.pdf")
        #expect(previewed == ["/inbox/a.pdf"], "the inspection itself must still run")
        let (reclaimed, pumps) = await LayoutPumpWait.pump(window, upTo: 10) {
            window.firstResponder !== window && !(window.firstResponder is NSText)
        }
        #expect(reclaimed, "Preview never took key focus back from the field editor (\(pumps) pumps)")
        sendReturn(window)
        #expect(recorder.decisions == [true, true],
                "focus left the field editor but ⏎ still didn't reach the card: \(recorder.decisions)")
        #expect(recorder.decisions.count == 2, "the Preview gesture itself must not decide anything")
    }

    /// The lens installs the wrapper on both inspection gestures. Source-level, because
    /// `filingReviewState` is private view glue inside `AutomationsLens`, hosting the whole lens
    /// needs a live `FileSyncManager`, and the buttons could not be clicked anyway (above). Pinned
    /// to the exact spelling on purpose: if the wiring is renamed, rename it here, and keep the
    /// bump-inside-`recoveringFocus` shape.
    @Test func theLensWiresBothInspectionGesturesThroughTheRecovery() throws {
        let text = try SourceText.fileExplorer("AutomationsLens.swift")
        #expect(text.contains("onQuickLook: FilingWalkthroughCard.recoveringFocus(via: { filingFocusNudge += 1 }, onQuickLook)"),
                "the lens no longer wires Preview through recoveringFocus — clicking Preview stops recovering key focus")
        #expect(text.contains("onReveal: FilingWalkthroughCard.recoveringFocus(via: { filingFocusNudge += 1 }, onReveal)"),
                "the lens no longer wires Reveal through recoveringFocus — clicking Reveal stops recovering key focus")
    }
}

/// What the walkthrough card says to VoiceOver.
///
/// Same reasoning as `ReviewCardKeyHintSpeechTests`: it is the string that is tested rather than
/// the tree, because there is no assistive client under `swift test`, so an assertion on the
/// rendered accessibility tree would pass whatever the card announces. The strings are the only
/// place any of this is checkable, so a missing container label could otherwise go unnoticed with
/// every suite green.
@Suite struct FilingWalkthroughCardSpeechTests {

    /// The label answers the question the card asks: which file, where to, and where in the queue.
    /// All four facts, because a label that silently lost one still reads as a sentence.
    @Test func theCardLabelNamesTheFileTheDestinationAndThePosition() {
        let label = FilingWalkthroughCard.cardSpeech(
            fileName: "Invoice 2026-03.pdf", destination: "Documents/Finance", position: 2, total: 7)
        for fact in ["Invoice 2026-03.pdf", "Documents/Finance", "2", "7"] {
            #expect(label.contains(fact), "\(fact) is missing from: \(label)")
        }
    }

    /// A row with no resolved destination still says something. `destinationLabel` is optional on
    /// `AutomationDryRunRow` and the card draws "its destination" in that case, so the spoken label
    /// must not go silent, or trail off, where the visible one does not. An `Optional` interpolated
    /// straight into the string would announce "to nil" here.
    @Test func anUnresolvedDestinationFallsBackToWhatTheCardDraws() {
        let label = FilingWalkthroughCard.cardSpeech(
            fileName: "scan.pdf", destination: nil, position: 1, total: 1)
        #expect(label.contains("to its destination"), "got: \(label)")
        #expect(!label.contains("nil"), "the Optional leaked into the spoken label: \(label)")
    }

    /// All three keys are named, and as infinitives: a hint that conjugated would produce "Return
    /// copys", and nothing on screen would show it.
    @Test func everyWalkthroughKeyIsNamed() {
        let hint = FilingWalkthroughCard.keyHintSpeech
        for key in ["Return", "Right Arrow", "Delete", "Escape"] {
            #expect(hint.contains(key), "\(key) is missing from: \(hint)")
        }
        #expect(hint.contains("Return to file"), "got: \(hint)")
    }

    /// The card installs both, at the card level. Source-level for the same reason as
    /// `theLensWiresBothInspectionGesturesThroughTheRecovery` above: the tree is unreadable here,
    /// so without this the two strings could be correct and unused.
    @Test func theCardInstallsTheContainerLabelAndHint() throws {
        let text = try SourceText.fileExplorer("AutomationsLens.swift")
        // `.contain` specifically: `.combine` would fold the card's Skip/File/Cancel/Preview/Reveal
        // buttons into the label and take the controls away from VoiceOver entirely.
        #expect(text.contains(".accessibilityElement(children: .contain)\n        .accessibilityLabel(Self.cardSpeech("),
                "the walkthrough card no longer wraps itself in a containing accessibility element with cardSpeech as its label")
        #expect(text.contains(".accessibilityHint(Self.keyHintSpeech)"),
                "the walkthrough card no longer carries its unconditional key hint")
    }
}
