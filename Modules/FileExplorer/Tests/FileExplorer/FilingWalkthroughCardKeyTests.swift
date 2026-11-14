import AppKit
import SwiftUI
import Testing
import Sync
@testable import FileExplorer

/// The filing walkthrough card's keys, through a real window's responder chain. Window-level key
/// equivalents are consulted before the first responder (a ⏎ typed into the search field would move
/// a file on disk) and fire on key-repeat; `BareKeyEquivalentScanTests` bans them at source level.
/// This is the behavioural half: the `.onKeyPress` handlers hear the keys when the card holds focus,
/// not when a text field does, and do not auto-repeat.
///
/// A borderless, never-ordered-in window, events injected with `sendEvent`. Every negative is paired
/// with a positive from the same harness: a probe that cannot report presence cannot report absence.
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

    /// Stand-in for the host's `filingFocusNudge` `@State`, so a test can play the host's
    /// `advanceFiling` bump from outside the hierarchy.
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

    /// Waits for the card's own deferred `FocusState` claim, not a `makeFirstResponder` shortcut, so
    /// a green also says the card takes focus on appearance.
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

    /// Arrows always carry `.function` and `.numericPad`: AppKit sets both on every arrow-key event,
    /// so an arrow with `modifierFlags: []` is a shape the real keyboard cannot produce, and a handler
    /// guarded on `press.modifiers.isEmpty` would pass such a test while skipping nothing for a real
    /// →. The caller's `modifiers` are unioned with the pair, so `.option` means a real ⌥→. Measured
    /// here as `EventModifiers` raw values: `[]` → 0, the pair → 96, with `.capsLock` → 97.
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

    /// The keypad's Enter is not a carriage return: keyCode 76, `NSEnterCharacter` (U+0003), and like
    /// the arrows it always carries `.numericPad` and `.function` (raw 96, measured here). `onKeyPress`
    /// receives it as `KeyEquivalent("\u{3}")`, so `keys: [.return]` never matches it; hence
    /// `KeyEquivalent.keypadEnter` in the handler's set rather than a monitor. The caller's
    /// `modifiers` are unioned with the pair, as in `sendRightArrow`.
    private static let keypadEnterIntrinsicFlags: NSEvent.ModifierFlags = [.numericPad, .function]

    private func sendKeypadEnter(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                                 isARepeat: Bool = false) {
        send(window, keyCode: 76, characters: "\u{3}",
             modifiers: modifiers.union(Self.keypadEnterIntrinsicFlags), isARepeat: isARepeat)
    }

    // MARK: The keypad's Enter is the same decision as the main row's

    /// The card hears the keypad's Enter too, but not a chord on it. It arrives with `.numericPad` and
    /// `.function` set, so the guard must be `isPlainKeystroke` (⌘⌥⌃⇧ only), not `modifiers.isEmpty`,
    /// which would refuse every keypad Enter. Caps Lock is in the volley for the same reason.
    @Test func aModifiedKeypadEnterDecidesNothing() async {
        let recorder = Recorder()
        let (window, _) = host(card(into: recorder))
        guard await waitForCardFocus(in: window) else { return }

        // Positive control: the plain keypad Enter reaches the handler, so the readings below
        // measure the modifier filter, not a dead key.
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

    /// A modified key is not a decision: ⌘⏎/⇧⏎ and ⌥→/⌃→ are chords, and ⏎ files a real file while →
    /// skips one no back-step can revisit. **No `onKeyPress` overload filters modifiers**, so the
    /// handlers must check `press.modifiers` themselves.
    ///
    /// Measured here: the single-key overload fires for ⏎ with any modifier and on key-repeat, and
    /// differs from `keys:phases:` only in not firing on `.up`. ⌘esc, ⌃esc and ⌘. never arrive:
    /// AppKit takes them as `cancelOperation:` ahead of the responder chain.
    @Test func aModifiedKeyDecidesNothing() async {
        let recorder = Recorder()
        let (window, _) = host(card(into: recorder))
        guard await waitForCardFocus(in: window) else { return }

        // Positive control: an unmodified ⏎ reaches the handler.
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

    /// ⌫ skips too, as in Compare's one-at-a-time review. Plain only, once per press, like →: ⌘⌫ and
    /// ⌥⌫ are text-editing chords, and a held ⌫ must not run through the queue.
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

    /// Key-repeat decides nothing: the handlers are `.down`-phase only, so a held key acts once. Each
    /// key is its own case because each is its own handler or key-set entry, where `.repeat` could be
    /// re-admitted unnoticed. Esc is included although in the app cancel tears the walkthrough down.
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

        // Control: fresh presses still arrive, so the single act above is the phase filter, not the
        // harness dropping events.
        for _ in 0..<3 { press(isARepeat: false) }
        #expect(acts() == 4, "fresh presses stopped arriving: \(recorder.decisions), \(recorder.cancels) cancels")
    }

    /// Caps Lock is not a chord. `.capsLock` rides on every event while engaged (measured: raw 1,
    /// `isEmpty == false`), so a `press.modifiers.isEmpty` guard would kill ⏎, → and esc for anyone
    /// who left it on. Only ⌘⌥⌃⇧ may refuse a decision.
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

    /// With key focus in a text field (the search, the Settings overlay), ⏎, → and esc belong to the
    /// field: a ⏎ would move the current file on disk, an esc would discard the approvals.
    ///
    /// Scope: window-level equivalents never fire in this never-key window, so re-adding
    /// `.cancelAction` to Cancel leaves this green; that shape is banned statically by
    /// `BareKeyEquivalentScanTests.noAlwaysMountedSurfaceRegistersAnyKeyEquivalentAtAll`.
    @Test func aTextFieldElsewhereKeepsItsReturnArrowAndEsc() async throws {
        let recorder = Recorder()
        let (window, hostView) = host(VStack {
            TextField("Search", text: .constant("inv"))
            card(into: recorder)
        })
        // The positive half: this hosting delivers keys to the card at all.
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

    /// The focus-recovery hatch. On macOS a click on a plain button does not dislodge a text field's
    /// editor from first responder, and the card has no per-row focus claim (see its `.onAppear`),
    /// so after typing in the search field ⏎/→/esc would stay dead without `focusNudge`.
    ///
    /// With the field editor holding first responder, one nudge bump (sent for every decision and
    /// every Preview/Reveal) must land key focus on the card, proven by ⏎ reaching its handler again.
    @Test func aFocusNudgeReclaimsFocusFromATextFieldEditor() async throws {
        let recorder = Recorder()
        let hostState = HostState()
        let (window, hostView) = host(NudgedHost(
            state: hostState, row: Self.row("a.pdf"),
            onDecision: { recorder.decisions.append($0) }))
        // The positive half: the reclaim below is measured by key delivery, not responder identity.
        guard await waitForCardFocus(in: window) else { return }
        sendReturn(window)
        try #require(recorder.decisions == [true],
                     "the card never received keys in this harness — the reclaim below would be vacuous")

        // Hand focus to the field; the window's field editor (an NSText) now holds first responder.
        let field = try #require(firstTextField(in: hostView), "no NSTextField in the hierarchy")
        try #require(window.makeFirstResponder(field), "the field refused first responder")
        sendReturn(window)
        try #require(recorder.decisions == [true],
                     "⏎ reached the card while the field held focus — the card never lost it, so the nudge would prove nothing")

        // The host's half: bump the nudge, as `advanceFiling` does for every decision.
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

    /// A nil inspection gesture stays nil, or wrapping would conjure Preview/Reveal buttons for a host
    /// that offers neither.
    @Test func recoveringFocusPreservesAnAbsentGesture() {
        #expect(FilingWalkthroughCard.recoveringFocus(via: {}, nil) == nil)
    }

    /// The nudge bump comes first, exactly once, and the inner gesture still runs with the same path.
    @Test func recoveringFocusBumpsTheNudgeBeforeRunningTheGesture() {
        var calls: [String] = []
        let wrapped = FilingWalkthroughCard.recoveringFocus(
            via: { calls.append("bump") },
            { calls.append("open \($0)") })
        wrapped?("/inbox/a.pdf")
        #expect(calls == ["bump", "open /inbox/a.pdf"],
                "expected the nudge bump first, then the gesture — got \(calls)")
    }

    /// Preview recovers key focus too, so getting ⏎/→/esc back does not cost a file or an
    /// unrevisitable skip. The buttons cannot be clicked under `swift test` (`docs/flaky-tests.md`,
    /// "When you fix one": this window can never be key), so this fires the closure the Preview
    /// button would, built with `recoveringFocus` as `AutomationsLens.filingReviewState` builds it.
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

    /// The lens installs the wrapper on both inspection gestures. Source-level: `filingReviewState` is
    /// private view glue, and the buttons cannot be clicked here. If the wiring is renamed, rename it
    /// here and keep the bump-inside-`recoveringFocus` shape.
    @Test func theLensWiresBothInspectionGesturesThroughTheRecovery() throws {
        let text = try SourceText.fileExplorer("AutomationsLens.swift")
        #expect(text.contains("onQuickLook: FilingWalkthroughCard.recoveringFocus(via: { filingFocusNudge += 1 }, onQuickLook)"),
                "the lens no longer wires Preview through recoveringFocus — clicking Preview stops recovering key focus")
        #expect(text.contains("onReveal: FilingWalkthroughCard.recoveringFocus(via: { filingFocusNudge += 1 }, onReveal)"),
                "the lens no longer wires Reveal through recoveringFocus — clicking Reveal stops recovering key focus")
    }
}

/// What the walkthrough card says to VoiceOver. As in `ReviewCardKeyHintSpeechTests`, the strings
/// are tested rather than the tree: with no assistive client under `swift test`, an assertion on the
/// accessibility tree would pass whatever the card announces.
@Suite struct FilingWalkthroughCardSpeechTests {

    /// The label names the file, the destination, and the position: all four facts, because a label
    /// that lost one still reads as a sentence.
    @Test func theCardLabelNamesTheFileTheDestinationAndThePosition() {
        let label = FilingWalkthroughCard.cardSpeech(
            fileName: "Invoice 2026-03.pdf", destination: "Documents/Finance", position: 2, total: 7)
        for fact in ["Invoice 2026-03.pdf", "Documents/Finance", "2", "7"] {
            #expect(label.contains(fact), "\(fact) is missing from: \(label)")
        }
    }

    /// A row with no `destinationLabel` says "its destination", as the card draws; an `Optional`
    /// interpolated straight into the string would announce "to nil".
    @Test func anUnresolvedDestinationFallsBackToWhatTheCardDraws() {
        let label = FilingWalkthroughCard.cardSpeech(
            fileName: "scan.pdf", destination: nil, position: 1, total: 1)
        #expect(label.contains("to its destination"), "got: \(label)")
        #expect(!label.contains("nil"), "the Optional leaked into the spoken label: \(label)")
    }

    /// Every key is named, as infinitives: a hint that conjugated would produce "Return copys".
    @Test func everyWalkthroughKeyIsNamed() {
        let hint = FilingWalkthroughCard.keyHintSpeech
        for key in ["Return", "Right Arrow", "Delete", "Escape"] {
            #expect(hint.contains(key), "\(key) is missing from: \(hint)")
        }
        #expect(hint.contains("Return to file"), "got: \(hint)")
    }

    /// The card installs both. Source-level, since the tree is unreadable here and the strings could
    /// otherwise be correct and unused.
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
