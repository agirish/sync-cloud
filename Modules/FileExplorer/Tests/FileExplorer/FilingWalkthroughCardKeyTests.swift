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
            onDecision: { recorder.decisions.append($0) },
            onCancel: { recorder.cancels += 1 })
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

    private func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { firstTextField(in: $0) }.first
    }
}
