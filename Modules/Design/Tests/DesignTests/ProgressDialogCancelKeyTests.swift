import AppKit
import SwiftUI
import Testing
@testable import Design

/// **⌘. cancels the progress dialog, and Esc does not.**
///
/// Before this the dialog had no key at all: a 7,000-item copy could be stopped only with the
/// mouse. The chord is ⌘. — the Mac's cancel-operation chord — and NOT Esc, because the dialog is
/// an overlay with the whole window live under it, where Esc clears a pane's selection; a habitual
/// Esc must not abort the copy. So both directions are pinned: the chord fires, and the role key
/// a sheet's Cancel would carry does not.
///
/// Driven through a real window's key-equivalent pass, which is where a SwiftUI
/// `.keyboardShortcut` lives — a `Button` is not an `NSControl` and cannot be pressed from here
/// any other way. `AppChordTests` pins what the chord renders; this pins that it is wired.
@MainActor
@Suite(.serialized) struct ProgressDialogCancelKeyTests {

    private func host(_ progress: Progress) async throws -> NSWindow {
        try await host(AnyView(ProgressDialog(progress: progress)))
    }

    private func host(_ root: AnyView) async throws -> NSWindow {
        let hostView = NSHostingView(rootView: root)
        hostView.frame = CGRect(x: 0, y: 0, width: 400, height: 220)
        let window = NSWindow(contentRect: hostView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostView
        for _ in 0..<10 {
            hostView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
        return window
    }

    /// `ignoring` defaults to `characters`; the two differ for a shifted chord — see ⇧⌘. below.
    private func key(_ window: NSWindow, keyCode: UInt16, characters: String, ignoring: String? = nil,
                     modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
            isARepeat: false, keyCode: keyCode))
    }

    private func cancellable() -> Progress {
        let progress = Progress(totalUnitCount: 7363)
        progress.localizedDescription = "Copying 7,363 Items"
        progress.isCancellable = true
        progress.completedUnitCount = 3336
        return progress
    }

    @Test func commandPeriodPressesCancel() async throws {
        let progress = cancellable()
        let window = try await host(progress)
        defer { window.close() }
        // keyCode 47 is the period key.
        let commandPeriod = try key(window, keyCode: 47, characters: ".", modifiers: .command)
        #expect(window.performKeyEquivalent(with: commandPeriod), "⌘. was not claimed by the dialog")
        #expect(progress.isCancelled, "⌘. did not cancel the operation")
    }

    /// A click counter a SwiftUI button can write from inside a hosted view.
    private final class Presses { var count = 0 }

    /// **⌘. over a window with an Esc button reaches the dialog, and only the dialog.** AppKit
    /// treats ⌘. as Esc (`cancelOperation:`), so a `.cancelAction` button under the overlay —
    /// Settings' close, a sheet's Cancel — is the other claimant. Pressing it there would close
    /// whatever lies under the copy and leave the copy running. Both stacking orders, since which
    /// view the key pass meets first is the whole question.
    ///
    /// Measured 2026-10-24: with the dialog's own chord removed, neither the key-equivalent pass
    /// nor the window's keyDown carried ⌘. to the hosted `.cancelAction` button, so the second
    /// half has never been seen red here — it holds the line should AppKit or SwiftUI start
    /// mapping ⌘. onto Esc buttons. The first half goes red with the chord removed.
    @Test(arguments: [true, false])
    func commandPeriodCancelsTheDialogNotAnEscButtonUnderIt(dialogOnTop: Bool) async throws {
        let progress = cancellable()
        let presses = Presses()
        let escButton = Button("Close") { presses.count += 1 }.keyboardShortcut(.cancelAction)
        let dialog = ProgressDialog(progress: progress)
        let root = dialogOnTop
            ? AnyView(ZStack { escButton; dialog })
            : AnyView(ZStack { dialog; escButton })
        let window = try await host(root)
        defer { window.close() }

        // The control: Esc alone does reach the button, so the fixture can see a press.
        let escape = try key(window, keyCode: 53, characters: "\u{1b}", modifiers: [])
        _ = window.performKeyEquivalent(with: escape)
        try #require(presses.count == 1, "Esc did not press the .cancelAction button — this fixture sees nothing")
        try #require(!progress.isCancelled, "Esc cancelled the operation")

        // As NSApplication delivers it: the key-equivalent pass, then — only if nothing claimed
        // it — the window's keyDown, where AppKit turns ⌘. into `cancelOperation:`.
        let commandPeriod = try key(window, keyCode: 47, characters: ".", modifiers: .command)
        if !window.performKeyEquivalent(with: commandPeriod) { window.sendEvent(commandPeriod) }
        #expect(progress.isCancelled, "⌘. did not cancel the operation with an Esc button under the dialog")
        #expect(presses.count == 1, "⌘. also pressed the Esc button under the dialog")
    }

    /// **The count is grouped for the reader's locale**, like the title above it. The locale is
    /// pinned so the separator is a fact of the test; a cached formatter with no locale ignored
    /// it. Clamped to the total, as the bar is.
    @Test func theCountIsGroupedForTheLocale() {
        #expect(ProgressDialog.formattedCount(completed: 3336, total: 7363, locale: Locale(identifier: "en_US"))
                == "3,336 of 7,363")
        #expect(ProgressDialog.formattedCount(completed: 3336, total: 7363, locale: Locale(identifier: "de_DE"))
                == "3.336 of 7.363")
        #expect(ProgressDialog.formattedCount(completed: 7400, total: 7363, locale: Locale(identifier: "en_US"))
                == "7,363 of 7,363")
    }

    /// **The Cancel button's key comes from `AppChord.cancelOperation`, whole.** The key pass above
    /// cannot see a ⇧ slip in the binding: measured 2026-10-23, a button bound to ⇧⌘. still claims a
    /// plain ⌘. event — SwiftUI's match is lenient about ⇧ on a punctuation key — so the test above
    /// stays green over it. The chord's own modifiers are pinned by `AppChordTests` (its display,
    /// and `noTwoChordsCollide` against ⇧⌘. `hiddenFiles`); this pins that the button reads them.
    @Test func theCancelButtonIsBoundToTheRegisteredChord() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Design/ProgressDialog.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read ProgressDialog.swift — this check would be vacuous")
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.components(separatedBy: ".keyboardShortcut(").count == 2,
                "the dialog should register exactly one key equivalent")
        #expect(code.contains(
            ".keyboardShortcut(AppChord.cancelOperation.key, modifiers: AppChord.cancelOperation.modifiers)"),
            "Cancel's key equivalent is no longer read from AppChord.cancelOperation")
    }

    /// Esc is the key a sheet's Cancel takes (`.cancelAction`), so it is the binding a later
    /// "consistency" fix would reach for. And ⇧⌘. is the hidden-files toggle — the neighbour a
    /// modifier slip would land on — which must flip the filter, not stop the copy.
    @Test func neitherEscNorShiftCommandPeriodCancels() async throws {
        let progress = cancellable()
        let window = try await host(progress)
        defer { window.close() }
        let escape = try key(window, keyCode: 53, characters: "\u{1b}", modifiers: [])
        _ = window.performKeyEquivalent(with: escape)
        window.sendEvent(escape)
        #expect(!progress.isCancelled, "Esc cancelled the operation — it belongs to the window under the dialog")

        // ⇧⌘. spelled as the keyboard spells it: `characters` ".", `charactersIgnoringModifiers` ">"
        // — measured 2026-10-23 by converting a CGEvent for key 47 with ⇧⌘ on this Mac's layout.
        let shiftCommandPeriod = try key(window, keyCode: 47, characters: ".", ignoring: ">",
                                         modifiers: [.shift, .command])
        _ = window.performKeyEquivalent(with: shiftCommandPeriod)
        #expect(!progress.isCancelled, "⇧⌘. cancelled the operation — it is the hidden-files toggle")
    }
}
