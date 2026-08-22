import AppKit
import SwiftUI
import Testing
import Sync
@testable import FileExplorer

/// The filing walkthrough card's keys, exercised through a real window's responder chain.
///
/// The card shipped its keys as window-level key equivalents (`.keyboardShortcut(.return,
/// modifiers: [])` / `(.rightArrow, modifiers: [])`), which are consulted BEFORE the first
/// responder — so a ⏎ typed into the lens header's search field moved the current file on disk,
/// and key equivalents fire on key-repeat, so a held ⏎ approved file after file.
/// `BareKeyEquivalentScanTests` bans that shape at source level; this suite is the behavioral
/// half: the replacement `.onKeyPress` handlers really receive the keys when the card holds
/// focus, do NOT receive them when a text field does, and do not auto-repeat.
///
/// Harness borrowed from `DifferencesTableBindingTests`: a borderless, never-ordered-in window,
/// events injected with `sendEvent`. Every negative assertion is paired in-test with a positive
/// from the same harness — a probe that cannot report presence cannot report absence either.
@MainActor
@Suite(.serialized) struct FilingWalkthroughCardKeyTests {

    private static func row(_ name: String) -> AutomationDryRunRow {
        AutomationDryRunRow(id: "/inbox/\(name)", fileName: name, ruleID: UUID(), ruleName: "Rule",
                            verdict: .wouldFile(destination: "Docs"),
                            destinationDir: URL(fileURLWithPath: "/root/Docs"),
                            destinationLabel: "Docs",
                            destinationAnchor: URL(fileURLWithPath: "/root"))
    }

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
    /// way `FilingWalkthroughCard` reads `AutomationsLens.filingFocusNudge`, so a test can play
    /// the host's `advanceFiling` bump from outside the hierarchy.
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
        let size = CGSize(width: 520, height: 480)
        let hostView = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        hostView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hostView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostView
        hostView.layoutSubtreeIfNeeded()
        return (window, hostView)
    }

    /// Waits for the card's own deferred `FocusState` claim to land — the same acquisition the
    /// app relies on when the walkthrough appears, not a `makeFirstResponder` shortcut past it.
    /// So a green here also says the card really does take focus on appearance.
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

    /// **Arrows always carry `.function` and `.numericPad`.** Not a stylistic choice — AppKit sets
    /// both on every arrow-key event (`NSEvent.ModifierFlags.numericPad`: "also set if any of the
    /// arrow keys are pressed"), so an arrow with `modifierFlags: []` is a shape the real
    /// keyboard cannot produce. This sender synthesized exactly that until 2026-08-21, and the
    /// blindness cost a shipped feature: the handlers guarded on `press.modifiers.isEmpty`, which
    /// is FALSE for every real →, so → skipped nothing in the app while this suite stayed green.
    /// The caller's `modifiers` are UNIONED with the intrinsic pair, so `.option` here means the
    /// ⌥→ AppKit would actually deliver.
    ///
    /// Measured through this same harness (`SwiftUI.EventModifiers` raw values, from a probe view
    /// on this window's responder chain): arrow flags `[]` → 0; `[.function, .numericPad]` → 96;
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

    // MARK: The keys, with the card focused

    /// ⏎ files, → skips, esc cancels — through the focus the card acquired for itself.
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

    /// **Key-repeat decides nothing.** ⏎ moves a real file and → skips one no back-step can
    /// revisit, so the handlers are `.down`-phase only — a held key must decide exactly ONE file.
    /// The window-level equivalents this replaced fired on every repeat, approving file after
    /// file under a held ⏎.
    @Test func aHeldKeyDecidesExactlyOneFile() async {
        let recorder = Recorder()
        let (window, _) = host(card(into: recorder))
        guard await waitForCardFocus(in: window) else { return }

        sendReturn(window)
        for _ in 0..<3 { sendReturn(window, isARepeat: true) }
        #expect(recorder.decisions == [true],
                "a held ⏎ produced \(recorder.decisions.count) decisions — auto-repeat is filing files")

        // The control that keeps the assertion honest: the same key sent as three fresh presses
        // is delivered three times, so the single decision above is the phase filter working —
        // not the harness dropping events after the first.
        for _ in 0..<3 { sendReturn(window) }
        #expect(recorder.decisions.count == 4, "fresh presses stopped arriving: \(recorder.decisions)")
    }

    /// **A modified key is not a decision.** ⌘⏎ / ⇧⏎ are "open"/"add to selection" chords all over
    /// macOS, and ⌥→ / ⌃→ are word-wise and Space-switch navigation — none of them is the plain
    /// keystroke the keycaps advertise, and ⏎ files a real file while → skips one no back-step can
    /// revisit. The `onKeyPress(keys:phases:)` overload does NOT filter modifiers the way the
    /// single-key `onKeyPress(.escape)` overload does, so the handlers must check
    /// `press.modifiers` themselves — the first cut of this card did not, which was a regression:
    /// the `.keyboardShortcut(…, modifiers: [])` equivalents it replaced matched unmodified keys
    /// only.
    @Test func aModifiedKeyDecidesNothing() async {
        let recorder = Recorder()
        let (window, _) = host(card(into: recorder))
        guard await waitForCardFocus(in: window) else { return }

        // The positive control first: an unmodified ⏎ really reaches the handler, so the
        // no-decision readings below measure the modifier filter, not a dead harness.
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

    /// The held-key rule, for → specifically: it has its own handler, so the ⏎ repeat test says
    /// nothing about it — → could regress to `[.down, .repeat]` with that test green. A held →
    /// must skip exactly ONE file (skips are unrevisitable; there is no back-step).
    @Test func aHeldArrowSkipsExactlyOneFile() async {
        let recorder = Recorder()
        let (window, _) = host(card(into: recorder))
        guard await waitForCardFocus(in: window) else { return }

        sendRightArrow(window)
        for _ in 0..<3 { sendRightArrow(window, isARepeat: true) }
        #expect(recorder.decisions == [false],
                "a held → produced \(recorder.decisions.count) decisions — auto-repeat is skipping files")

        // Same honesty control as the ⏎ test: fresh presses still arrive, so the single decision
        // above is the phase filter, not the harness dropping events.
        for _ in 0..<3 { sendRightArrow(window) }
        #expect(recorder.decisions.count == 4, "fresh presses stopped arriving: \(recorder.decisions)")
    }

    /// …and for esc: a held esc must cancel ONCE. Cancel tears the walkthrough down, so in the app
    /// a second delivery lands on nothing — but the handler's contract should not depend on that,
    /// and the two decision handlers are `.down`-only for the same reason.
    @Test func aHeldEscCancelsExactlyOnce() async {
        let recorder = Recorder()
        let (window, _) = host(card(into: recorder))
        guard await waitForCardFocus(in: window) else { return }

        sendEscape(window)
        for _ in 0..<3 { sendEscape(window, isARepeat: true) }
        #expect(recorder.cancels == 1,
                "a held esc cancelled \(recorder.cancels) times — the handler is not .down-only")

        for _ in 0..<3 { sendEscape(window) }
        #expect(recorder.cancels == 4, "fresh presses stopped arriving: \(recorder.cancels)")
    }

    /// **Caps Lock is not a chord.** `.capsLock` is present on EVERY event while the lock is
    /// engaged, so a guard written as `press.modifiers.isEmpty` kills ⏎, → and esc outright for
    /// anyone who left it on — the card goes fully dead with no way to tell why. Measured on this
    /// harness: `return` with `[.capsLock]` arrives as `EventModifiers` rawValue 1, `isEmpty ==
    /// false`. Only the four INTENT modifiers (⌘⌥⌃⇧) may refuse a decision.
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

    /// **The bug, as a test.** With key focus in a text field — the lens header's search, the
    /// Settings overlay — ⏎, → and esc belong to the field. The shipped `.keyboardShortcut`s were
    /// window-level key equivalents, consulted before the first responder, so this exact
    /// keystroke moved the current file on disk. esc is in the volley for the same reason: the
    /// Cancel button once carried `.keyboardShortcut(.cancelAction)` — bare esc at window level —
    /// and an esc typed to clear the field would have discarded the walkthrough's approvals.
    ///
    /// Honest scope, measured by mutation: re-adding `.cancelAction` to Cancel leaves this test
    /// GREEN — window-level equivalents never fire in this never-key window, so what the esc
    /// volley pins is the `.onKeyPress` handlers honouring focus. The `.cancelAction` shape
    /// itself is banned statically, by `BareKeyEquivalentScanTests.
    /// noLensFileRegistersAnyKeyEquivalentAtAll` (proven red under that same mutation).
    @Test func aTextFieldElsewhereKeepsItsReturnArrowAndEsc() async throws {
        let recorder = Recorder()
        let (window, hostView) = host(VStack {
            TextField("Search", text: .constant("inv"))
            card(into: recorder)
        })
        // Let the card claim focus first — the positive half, proving this hosting CAN deliver
        // keys to the card at all. Without it an empty `decisions` below would also be the
        // signature of a card that never wired its handlers.
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

    /// **The focus-recovery hatch, as far as this harness can take it.** In the app the sequence
    /// is: type in the lens header's search field (which lives OUTSIDE the lens body and stays
    /// mounted through the walkthrough), then click "File N…" or the card's File/Skip. On macOS a
    /// click on a plain button does NOT dislodge the field's editor — an NSTextView — from first
    /// responder, and the card has no passive per-row focus claim to fall back on (deliberately:
    /// every advance arrives with a nudge bump, so a guarded per-row claim beside the unconditional
    /// `onChange` one would be dead code — see the comment at the card's `.onAppear`), so without
    /// the host-driven `focusNudge` hatch ⏎/→/esc stay dead for the whole walkthrough.
    ///
    /// What this pins is the hatch's whole contract, against a real responder chain: with an
    /// NSTextField's editor genuinely holding first responder, one nudge bump — what the host
    /// sends for every File/Skip decision and every Preview/Reveal inspection — must take key
    /// focus back from the editor and land it on the card, proven the only non-vacuous way: ⏎
    /// reaching the card's handler again.
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

        // The host's half of the hatch: bump the nudge, exactly what `advanceFiling` does for
        // every decision. The card must claim key focus back from the field editor.
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

    /// The wrap's whole contract: the nudge bump comes FIRST, exactly once, and the inner gesture
    /// still runs with the same path. Order matters — the bump is the focus recovery, and running
    /// the gesture without it is the pre-fix behaviour where only a File/Skip brought ⏎/→/esc back.
    @Test func recoveringFocusBumpsTheNudgeBeforeRunningTheGesture() {
        var calls: [String] = []
        let wrapped = FilingWalkthroughCard.recoveringFocus(
            via: { calls.append("bump") },
            { calls.append("open \($0)") })
        wrapped?("/inbox/a.pdf")
        #expect(calls == ["bump", "open /inbox/a.pdf"],
                "expected the nudge bump first, then the gesture — got \(calls)")
    }

    /// **A Preview does not cost a decision.** Pre-fix, the ONLY gesture that recovered key focus
    /// was an irreversible File/Skip (`advanceFiling` was the only nudge-bumper): a user who
    /// clicked into the header's search field had to spend a file or an unrevisitable skip to get
    /// ⏎/→/esc back. Now the non-destructive Preview/Reveal do it too, through the same wrapper
    /// the lens installs.
    ///
    /// The card's buttons cannot be clicked under `swift test` (see
    /// `PaneBackgroundDeselectMountedTests.testSyntheticClicksCannotDriveThisHarness` — this
    /// window can never be key), so the test fires the exact closure the Preview button's action
    /// would: the wrapped gesture, built with `recoveringFocus` the way
    /// `AutomationsLens.filingReviewState` builds it, bumping the same host state the card reads.
    /// The reclaim is then proven the only non-vacuous way — ⏎ reaching the card's handler again.
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

        // The Preview gesture — NOT a decision.
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

    /// The lens really installs the wrapper on both inspection gestures. Source-level, because
    /// `filingReviewState` is private view glue inside `AutomationsLens` and hosting the whole
    /// lens needs a live `FileSyncManager` — and the buttons could not be clicked anyway (above).
    /// Deliberately pinned to the exact spelling: if the wiring is renamed, rename it here, and
    /// keep the bump-inside-`recoveringFocus` shape while doing it.
    @Test func theLensWiresBothInspectionGesturesThroughTheRecovery() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Modules/FileExplorer/Tests/FileExplorer
            .deletingLastPathComponent()   // …/Modules/FileExplorer/Tests
            .deletingLastPathComponent()   // …/Modules/FileExplorer
            .appendingPathComponent("Sources/FileExplorer/AutomationsLens.swift")
        let text = try #require(try? String(contentsOf: source, encoding: .utf8),
                                "cannot read \(source.path) — is the file gone or renamed?")
        #expect(text.contains("onQuickLook: FilingWalkthroughCard.recoveringFocus(via: { filingFocusNudge += 1 }, onQuickLook)"),
                "the lens no longer wires Preview through recoveringFocus — clicking Preview stops recovering key focus")
        #expect(text.contains("onReveal: FilingWalkthroughCard.recoveringFocus(via: { filingFocusNudge += 1 }, onReveal)"),
                "the lens no longer wires Reveal through recoveringFocus — clicking Reveal stops recovering key focus")
    }
}
