import AppKit
import Design
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The Compare Copies surface's keys, driven through a real window's responder chain. ⏎ never
/// trashes: the safe act keeps the default and a destructive one is a deliberate click. The keys
/// are `.onKeyPress`, not key equivalents: the window stays mounted under an in-window overlay, so
/// a `.defaultAction` would eat bare ⏎ typed into any field behind the scrim.
@MainActor
@Suite(.serialized) struct CompareCopiesKeyTests {

    private final class Recorder: @unchecked Sendable {
        var closes = 0
        var trashes: [String] = []
        var keeperPicks: [String] = []
    }

    private func copy(_ path: String, keeper: Bool = false) -> DuplicateCopy {
        DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                      size: 1000, itemCount: 1, modificationDate: Date(timeIntervalSince1970: 1),
                      uniqueItemCount: 0, depth: 1, isRecommendedKeeper: keeper)
    }

    private func sheet(into recorder: Recorder, isStale: Bool = false) -> CompareCopiesSheet {
        let keeper = copy("/root/a/x.txt", keeper: true)
        let other = copy("/root/b/x.txt")
        return CompareCopiesSheet(
            pair: DuplicateComparePair(keeper: keeper, other: other,
                                       matchType: .identical, groupName: "x.txt"),
            standing: isStale ? .noLiveGroup : .inPair(keeper.path),
            allowsKeeperChoice: true,
            protectedPaths: [],
            scanRoot: "/root",
            providerName: "Projects",
            hue: .blue,
            availableSize: CGSize(width: 1200, height: 800),
            onChooseKeeper: { recorder.keeperPicks.append($0) },
            onTrash: { c, _ in recorder.trashes.append(c.path) },
            onClose: { recorder.closes += 1 },
            // No Quick Look: a real preview spins up an extension process per side, and this
            // suite is about the responder chain.
            probe: { _ in .missing },
            hash: { _ in .hashed("a") })
    }

    private func host(_ view: some View) -> NSWindow {
        HostedView.framed(view, size: CGSize(width: 1200, height: 800)).window
    }

    /// Waits for the surface's deferred `FocusState` claim, so a green also says the overlay takes
    /// focus when it appears; without it every key below is dead.
    private func waitForFocus(in window: NSWindow) async -> Bool {
        let (held, pumps) = await LayoutPumpWait.pump(window, upTo: 10) {
            window.firstResponder !== window && !(window.firstResponder is NSText)
        }
        if !held { Issue.record("the surface never claimed focus (\(pumps) pumps)") }
        return held
    }

    private func send(_ window: NSWindow, keyCode: UInt16, characters: String,
                      modifiers: NSEvent.ModifierFlags = []) {
        window.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode)!)
    }

    private func sendReturn(_ w: NSWindow, modifiers: NSEvent.ModifierFlags = []) {
        send(w, keyCode: 36, characters: "\r", modifiers: modifiers)
    }

    /// keyCode 76, U+0003. It always carries `.numericPad` and `.function`, which is why the guard
    /// is `isPlainKeystroke`, not `modifiers.isEmpty`.
    private func sendKeypadEnter(_ w: NSWindow, modifiers: NSEvent.ModifierFlags = []) {
        send(w, keyCode: 76, characters: "\u{3}",
             modifiers: modifiers.union([.numericPad, .function]))
    }

    private func sendEscape(_ w: NSWindow) { send(w, keyCode: 53, characters: "\u{1b}") }
    private func sendLeft(_ w: NSWindow, modifiers: NSEvent.ModifierFlags = []) {
        send(w, keyCode: 123, characters: "\u{f702}",
             modifiers: modifiers.union([.numericPad, .function]))
    }
    private func sendRight(_ w: NSWindow, modifiers: NSEvent.ModifierFlags = []) {
        send(w, keyCode: 124, characters: "\u{f703}",
             modifiers: modifiers.union([.numericPad, .function]))
    }

    // MARK: ⏎ closes, and never trashes

    enum CloseKey: CaseIterable, Sendable { case returnKey, keypadEnter, escape }

    /// ⏎, the keypad's Enter and esc each close once, and none trashes. The keypad's Enter is
    /// keyCode 76, U+0003, so a handler keyed on `.return` alone is silently deaf to it.
    @Test(arguments: CloseKey.allCases)
    func aClosingKeyClosesAndTrashesNothing(_ key: CloseKey) async throws {
        let recorder = Recorder()
        let window = host(sheet(into: recorder))
        guard await waitForFocus(in: window) else { return }
        switch key {
        case .returnKey: sendReturn(window)
        case .keypadEnter: sendKeypadEnter(window)
        case .escape: sendEscape(window)
        }
        #expect(recorder.closes == 1)
        #expect(recorder.trashes.isEmpty, "\(key) destroyed one of the user's files")
    }

    /// A chord belongs to whoever owns it: ⌘⏎ does nothing here, not even close.
    @Test func aModifiedReturnIsIgnored() async throws {
        let recorder = Recorder()
        let window = host(sheet(into: recorder))
        guard await waitForFocus(in: window) else { return }
        sendReturn(window, modifiers: .command)
        sendKeypadEnter(window, modifiers: .command)
        #expect(recorder.closes == 0, "a chord was swallowed by the plain-⏎ handler")
        #expect(recorder.trashes.isEmpty)
    }

    // MARK: ←/→ pick the keeper

    /// The keeper opens on the left, so → is the flip and ← is a no-op that must not be swallowed.
    @Test func theArrowsPickTheKeeperFromTheKeyboard() async throws {
        let recorder = Recorder()
        let window = host(sheet(into: recorder))
        guard await waitForFocus(in: window) else { return }
        sendRight(window)
        #expect(recorder.keeperPicks == ["/root/b/x.txt"])
        sendLeft(window)
        #expect(recorder.keeperPicks == ["/root/b/x.txt"],
                "← re-picked the copy that is already the keeper")
    }

    /// Caps Lock must not kill the arrows, which `modifiers.isEmpty` would: it rides on every event
    /// while engaged. The arrows also always carry `.numericPad`/`.function`.
    @Test func capsLockDoesNotKillTheArrows() async throws {
        let recorder = Recorder()
        let window = host(sheet(into: recorder))
        guard await waitForFocus(in: window) else { return }
        sendRight(window, modifiers: .capsLock)
        #expect(recorder.keeperPicks == ["/root/b/x.txt"])
    }

    @Test func aModifiedArrowIsIgnored() async throws {
        let recorder = Recorder()
        let window = host(sheet(into: recorder))
        guard await waitForFocus(in: window) else { return }
        sendRight(window, modifiers: .command)
        #expect(recorder.keeperPicks.isEmpty)
    }

    /// A stale surface has no live group to flip, so the arrows are `.ignored` rather than
    /// swallowed, and whoever else wants them still sees them.
    @Test func aStaleSurfaceIgnoresTheKeeperArrows() async throws {
        let recorder = Recorder()
        let window = host(sheet(into: recorder, isStale: true))
        guard await waitForFocus(in: window) else { return }
        sendRight(window)
        #expect(recorder.keeperPicks.isEmpty)
        // …and closing still works, because that is not an act on the group.
        sendEscape(window)
        #expect(recorder.closes == 1)
    }
}
