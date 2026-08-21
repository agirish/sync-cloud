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
        let onDecision: (Bool) -> Void
        var body: some View {
            VStack {
                TextField("Search", text: .constant("inv"))
                FilingWalkthroughCard(
                    row: row, position: 1, total: 3, accent: .blue,
                    providerName: "iCloud", onQuickLook: nil, onReveal: nil,
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

    private func send(_ window: NSWindow, keyCode: UInt16, characters: String, isARepeat: Bool = false) {
        window.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: isARepeat, keyCode: keyCode)!)
    }

    private func sendReturn(_ window: NSWindow, isARepeat: Bool = false) {
        send(window, keyCode: 36, characters: "\r", isARepeat: isARepeat)
    }

    // MARK: The keys, with the card focused

    /// ⏎ files, → skips, esc cancels — through the focus the card acquired for itself.
    @Test func theFocusedCardReceivesItsThreeKeys() async {
        let recorder = Recorder()
        let (window, _) = host(card(into: recorder))
        guard await waitForCardFocus(in: window) else { return }

        sendReturn(window)
        send(window, keyCode: 124, characters: "\u{F703}")   // →
        send(window, keyCode: 53, characters: "\u{1B}")      // esc
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

    // MARK: The keys, with a text field focused

    /// **The bug, as a test.** With key focus in a text field — the lens header's search, the
    /// Settings overlay — ⏎ and → belong to the field. The shipped `.keyboardShortcut`s were
    /// window-level key equivalents, consulted before the first responder, so this exact
    /// keystroke moved the current file on disk.
    @Test func aTextFieldElsewhereKeepsItsReturnAndArrow() async throws {
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
        send(window, keyCode: 124, characters: "\u{F703}")   // →
        #expect(recorder.decisions == [true], """
                typing in the text field reached the walkthrough card: \(recorder.decisions). \
                A ⏎ meant for the field just filed a real file (or a → silently skipped one, with \
                no back-step) — the exact defect the window-level `.keyboardShortcut`s shipped.
                """)
        #expect(recorder.cancels == 0)
    }

    // MARK: The recovery hatch

    /// **The focus-recovery hatch, as far as this harness can take it.** In the app the sequence
    /// is: type in the lens header's search field (which lives OUTSIDE the lens body and stays
    /// mounted through the walkthrough), then click "File N…" or the card's File/Skip. On macOS a
    /// click on a plain button does NOT dislodge the field's editor — an NSTextView — from first
    /// responder, and the card's passive `.task(id:)` claim rightly declines to take focus from a
    /// text view, so without the host-driven `focusNudge` hatch ⏎/→/esc stay dead for the whole
    /// walkthrough.
    ///
    /// **What this harness cannot reproduce is the decline itself.** The passive guard reads
    /// `NSApp.keyWindow`, and this window is never ordered in and can never be key, so the guard
    /// never engages under `swift test` — the "field editor blocks the passive claim" state is
    /// unreachable offscreen, and a test of it would pass vacuously against any code. What it CAN
    /// pin is the hatch's whole contract, against a real responder chain: with an NSTextField's
    /// editor genuinely holding first responder, one nudge bump — what the host sends for every
    /// File/Skip decision — must take key focus back from the editor and land it on the card,
    /// proven the only non-vacuous way: ⏎ reaching the card's handler again.
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
}
