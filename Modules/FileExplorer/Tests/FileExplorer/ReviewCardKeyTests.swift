import AppKit
import SwiftUI
import Testing
import Sync
@testable import FileExplorer

/// `ReviewCardView`'s ⌫-skip, exercised through a real window's responder chain — the same
/// harness as `FilingWalkthroughCardKeyTests` (borrowed in turn from
/// `DifferencesTableBindingTests`).
///
/// The card's other keys (⏎/␣/esc) use the single-key `onKeyPress(_:)` overload, which matches
/// unmodified presses only. ⌫ cannot: it needs `phases: .down` so a held ⌫ skips exactly one row,
/// and the `onKeyPress(keys:phases:)` overload does NOT filter modifiers — so without an explicit
/// `press.modifiers` check, ⌘⌫ (Finder's "delete immediately", and "delete to start of line" in
/// text land) and ⌥⌫ (delete word) SKIP the current item, which no back-step can revisit. That is
/// the same modifier-blindness `FilingWalkthroughCard`'s first `.onKeyPress` cut shipped; this
/// suite is the donor-file half of that fix.
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
