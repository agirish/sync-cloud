import AppKit
import SwiftUI
import Testing
@testable import Design

/// **⌘. stops the run in the toolbar's progress capsule, and Esc does not.**
///
/// The progress dialog it replaced had no key at first: a 7,000-item copy could be stopped only
/// with the mouse. The chord is ⌘. — the Mac's cancel-operation chord — and NOT Esc, because the
/// whole window is live around the capsule, where Esc clears a pane's selection; a habitual Esc
/// must not abort the copy. So both directions are pinned: the chord fires, and the role key a
/// sheet's Cancel would carry does not.
///
/// Driven through a real window's key-equivalent pass, which is where a SwiftUI
/// `.keyboardShortcut` lives — a `Button` is not an `NSControl` and cannot be pressed from here
/// any other way. `AppChordTests` pins what the chord renders; this pins that it is wired.
@MainActor
@Suite(.serialized) struct ProgressCapsuleCancelKeyTests {

    private func host(_ progress: Progress, style: ProgressCapsuleStyle = .full) async throws -> NSWindow {
        try await host(AnyView(capsule(progress, style: style)))
    }

    /// The capsule as `RunCapsuleHost` builds it for a file operation.
    private func capsule(_ progress: Progress, style: ProgressCapsuleStyle = .full) -> ProgressCapsule {
        ProgressCapsule(run: ProgressCapsuleRun(progress: progress), style: style,
                        onCancel: { progress.cancel() })
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
        progress.localizedDescription = "Copying 7,363 items"
        progress.isCancellable = true
        progress.completedUnitCount = 3336
        return progress
    }

    /// Both rungs: the ring keeps the stop button, and with it the chord (TE206).
    @Test(arguments: [ProgressCapsuleStyle.full, .ring])
    func commandPeriodPressesCancel(style: ProgressCapsuleStyle) async throws {
        let progress = cancellable()
        let window = try await host(progress, style: style)
        defer { window.close() }
        // keyCode 47 is the period key.
        let commandPeriod = try key(window, keyCode: 47, characters: ".", modifiers: .command)
        #expect(window.performKeyEquivalent(with: commandPeriod), "⌘. was not claimed by the capsule")
        #expect(progress.isCancelled, "⌘. did not cancel the operation")
    }

    /// A click counter a SwiftUI button can write from inside a hosted view.
    private final class Presses { var count = 0 }

    /// **⌘. over a window with an Esc button reaches the capsule, and only the capsule.** AppKit
    /// treats ⌘. as Esc (`cancelOperation:`), so a `.cancelAction` button elsewhere in the window —
    /// Settings' close, a sheet's Cancel — is the other claimant. Pressing it there would close
    /// whatever lies under the copy and leave the copy running. Both stacking orders, since which
    /// view the key pass meets first is the whole question.
    ///
    /// Measured 2026-10-24: with the dialog's own chord removed, neither the key-equivalent pass
    /// nor the window's keyDown carried ⌘. to the hosted `.cancelAction` button, so the second
    /// half has never been seen red here — it holds the line should AppKit or SwiftUI start
    /// mapping ⌘. onto Esc buttons. The first half goes red with the chord removed.
    @Test(arguments: [true, false])
    func commandPeriodCancelsTheCapsuleNotAnEscButtonBesideIt(dialogOnTop: Bool) async throws {
        let progress = cancellable()
        let presses = Presses()
        let escButton = Button("Close") { presses.count += 1 }.keyboardShortcut(.cancelAction)
        let dialog = capsule(progress)
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
        #expect(progress.isCancelled, "⌘. did not cancel the operation with an Esc button beside the capsule")
        #expect(presses.count == 1, "⌘. also pressed the Esc button beside the capsule")
    }

    /// **With two or more runs, ⌘. opens the list and stops nothing** (TE219, decision CJ). The
    /// capsule draws the newest run; a ✕ there would stop whichever run happened to be drawn, so
    /// the one key the capsule registers moves to the count button. Both rungs — the ring shows
    /// the count as a badge (TE225).
    @Test(arguments: [ProgressCapsuleStyle.full, .ring])
    func withSeveralRunsCommandPeriodOpensTheListInsteadOfStopping(style: ProgressCapsuleStyle) async throws {
        let progress = cancellable()
        let opened = Presses()
        let capsule = ProgressCapsule(run: ProgressCapsuleRun(progress: progress), style: style,
                                      othersRunning: ["Saving 6 files as PDF · 2 of 6"],
                                      onCancel: { progress.cancel() }, onShowRuns: { opened.count += 1 })
        #expect(capsule.trailing == .count(2))
        let window = try await host(AnyView(capsule))
        defer { window.close() }
        let commandPeriod = try key(window, keyCode: 47, characters: ".", modifiers: .command)
        #expect(window.performKeyEquivalent(with: commandPeriod), "⌘. was not claimed by the count button")
        #expect(opened.count == 1, "⌘. did not open the list of runs")
        #expect(!progress.isCancelled, "⌘. stopped the drawn run with another one going beside it")
    }

    /// **The list's ⌘. and Return stop the newest run, and only it** (decision CJ: the second ⌘.
    /// stops what the capsule drew). The older run's Stop is its own button — reached by a click,
    /// never by a key that names no run.
    enum ListKey: CaseIterable, Sendable { case commandPeriod, returnKey }

    @Test(arguments: ListKey.allCases)
    func theListsKeysStopTheNewestRunOnly(listKey: ListKey) async throws {
        let newest = cancellable(), older = cancellable()
        let list = ProgressCapsuleRunList(runs: [
            ProgressCapsuleListedRun(id: "merge", run: ProgressCapsuleRun(progress: newest), symbol: "doc.on.doc",
                                     startedAt: Date(), onCancel: { newest.cancel() }),
            ProgressCapsuleListedRun(id: "pdf", run: ProgressCapsuleRun(progress: older), symbol: "doc.richtext",
                                     startedAt: Date(timeIntervalSinceNow: -60), onCancel: { older.cancel() }),
        ])
        let window = try await host(AnyView(list))
        defer { window.close() }
        let press = listKey == .commandPeriod
            ? try key(window, keyCode: 47, characters: ".", modifiers: .command)
            : try key(window, keyCode: 36, characters: "\r", modifiers: [])
        if !window.performKeyEquivalent(with: press) { window.sendEvent(press) }
        #expect(newest.isCancelled, "the key did not stop the newest run")
        #expect(!older.isCancelled, "the key stopped the older run too")
    }

    /// **In the Activity window neither key stops a run**: it is opened to read, and Return there
    /// cancelled the newest run. Its Stops are clicked.
    @Test(arguments: ListKey.allCases)
    func theWindowsListTakesNoKeys(listKey: ListKey) async throws {
        let newest = cancellable()
        let list = ProgressCapsuleRunList(runs: [
            ProgressCapsuleListedRun(id: "merge", run: ProgressCapsuleRun(progress: newest), symbol: "doc.on.doc",
                                     startedAt: Date(), onCancel: { newest.cancel() }),
        ], fillsWidth: true, takesKeys: false)
        let window = try await host(AnyView(list))
        defer { window.close() }
        let press = listKey == .commandPeriod
            ? try key(window, keyCode: 47, characters: ".", modifiers: .command)
            : try key(window, keyCode: 36, characters: "\r", modifiers: [])
        if !window.performKeyEquivalent(with: press) { window.sendEvent(press) }
        #expect(!newest.isCancelled, "a key in the Activity window stopped the run")
    }

    /// **A message over a run keeps the run's count, and ⌘. still reaches the runs** (decision CU):
    /// the count, even of one, opens the list rather than stopping anything; and with no run left
    /// the message has a close button that takes no key.
    @Test func aMessageOverARunKeepsItsCount() async throws {
        let progress = cancellable()
        let opened = Presses(), closed = Presses()
        let message = ProgressCapsuleMessage(text: "Saved 4 compressed copies", weight: .success,
                                             onClose: { closed.count += 1 })
        let capsule = ProgressCapsule(run: ProgressCapsuleRun(progress: progress), style: .full,
                                      onCancel: { progress.cancel() }, onShowRuns: { opened.count += 1 },
                                      message: message)
        #expect(capsule.trailing == .count(1))
        let window = try await host(AnyView(capsule))
        defer { window.close() }
        let commandPeriod = try key(window, keyCode: 47, characters: ".", modifiers: .command)
        _ = window.performKeyEquivalent(with: commandPeriod)
        #expect(opened.count == 1, "⌘. over a message did not open the runs")
        #expect(!progress.isCancelled, "⌘. over a message stopped the run behind it")

        let alone = ProgressCapsule(run: .idle, style: .full, onCancel: nil, message: message)
        #expect(alone.trailing == .none, "a message with no run under it showed a count")
    }

    /// **The count is grouped for the reader's locale**, like the title above it. The locale is
    /// pinned so the separator is a fact of the test; a cached formatter with no locale ignored
    /// it. Clamped to the total, as the bar is.
    @Test func theCountIsGroupedForTheLocale() {
        #expect(ProgressCapsule.formattedCount(completed: 3336, total: 7363, locale: Locale(identifier: "en_US"))
                == "3,336 of 7,363")
        #expect(ProgressCapsule.formattedCount(completed: 3336, total: 7363, locale: Locale(identifier: "de_DE"))
                == "3.336 of 7.363")
        #expect(ProgressCapsule.formattedCount(completed: 7400, total: 7363, locale: Locale(identifier: "en_US"))
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
            .appendingPathComponent("Sources/Design/ProgressCapsule.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read ProgressCapsule.swift — this check would be vacuous")
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.components(separatedBy: ".keyboardShortcut(").count == 2,
                "the capsule should register exactly one key equivalent")
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
        #expect(!progress.isCancelled, "Esc cancelled the operation — it belongs to the window around the capsule")

        // ⇧⌘. spelled as the keyboard spells it: `characters` ".", `charactersIgnoringModifiers` ">"
        // — measured 2026-10-23 by converting a CGEvent for key 47 with ⇧⌘ on this Mac's layout.
        let shiftCommandPeriod = try key(window, keyCode: 47, characters: ".", ignoring: ">",
                                         modifiers: [.shift, .command])
        _ = window.performKeyEquivalent(with: shiftCommandPeriod)
        #expect(!progress.isCancelled, "⇧⌘. cancelled the operation — it is the hidden-files toggle")
    }
}
