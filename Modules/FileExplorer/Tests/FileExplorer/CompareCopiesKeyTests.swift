import AppKit
import Design
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The Compare Copies surface's keys, driven through a real window's responder chain.
///
/// **The one rule worth a whole suite: ⏎ never trashes.** The house rule is written down and
/// tested at the Restructure sheet — the safe act keeps the default, and landing a destructive one
/// is a deliberate click. The mockup this surface was built from put ⌘⏎ on the trash button; the
/// review reversed it, and this is what keeps it reversed.
///
/// The keys are `.onKeyPress` and not key equivalents, which is a correction to the plan rather
/// than a preference: an in-window overlay leaves the whole window mounted underneath it, so a
/// `.defaultAction` here would eat bare ⏎ typed into any field behind the scrim, on key-repeat.
/// `BareKeyEquivalentScanTests` enforces that; this suite pins that the replacement actually works.
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
            // The panes must not mount Quick Look here: a real preview spins up an extension
            // process per side, and this suite is about the responder chain.
            probe: { _ in .missing },
            hash: { _ in .hashed("a") })
    }

    private func host(_ view: some View) -> NSWindow {
        let size = CGSize(width: 1200, height: 800)
        let hostView = NSHostingView(rootView: AnyView(view.frame(width: size.width,
                                                                  height: size.height)))
        hostView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hostView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostView
        hostView.layoutSubtreeIfNeeded()
        return window
    }

    /// Waits for the surface's own deferred `FocusState` claim, so a green here also says the
    /// overlay really does take focus when it appears — without which every key below is dead.
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

    /// keyCode 76, U+0003 — and it always carries `.numericPad` and `.function`, which is why the
    /// guard is `isPlainKeystroke` and not `modifiers.isEmpty`.
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

    @Test func returnClosesAndTrashesNothing() async throws {
        let recorder = Recorder()
        let window = host(sheet(into: recorder))
        guard await waitForFocus(in: window) else { return }
        sendReturn(window)
        #expect(recorder.closes == 1)
        #expect(recorder.trashes.isEmpty, "⏎ destroyed one of the user's files")
    }

    /// The second keycap that says Enter. keyCode 76 sends U+0003, so a handler keyed on `.return`
    /// alone is silently deaf to it — on a surface whose whole job is one decision.
    @Test func theKeypadsEnterClosesToo() async throws {
        let recorder = Recorder()
        let window = host(sheet(into: recorder))
        guard await waitForFocus(in: window) else { return }
        sendKeypadEnter(window)
        #expect(recorder.closes == 1)
        #expect(recorder.trashes.isEmpty)
    }

    @Test func escapeCloses() async throws {
        let recorder = Recorder()
        let window = host(sheet(into: recorder))
        guard await waitForFocus(in: window) else { return }
        sendEscape(window)
        #expect(recorder.closes == 1)
    }

    /// A chord belongs to whoever owns it. ⌘⏎ was the mockup's trash shortcut; it must now do
    /// nothing here at all rather than quietly closing.
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

    /// **Caps Lock must not kill the arrows**, which `modifiers.isEmpty` would — it rides on every
    /// event while engaged. The arrows themselves also always carry `.numericPad`/`.function`.
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

    /// A stale surface has nothing to act on — the live group that would receive the flip is gone.
    /// The key must be `.ignored` rather than silently doing nothing, so whoever else wants it
    /// still sees it.
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

    // MARK: The Differences overlay, before its stat lands

    /// **esc, while the surface is still nothing but a spinner.**
    ///
    /// The pair view owns every key this surface answers and is not mounted until both sides have
    /// been statted — and that stat is off the main actor precisely because a dead SMB or unmounted
    /// cloud volume can block it indefinitely. So the one moment the reader most wants out was the
    /// one moment esc did nothing. The fix mounts a focusable placeholder carrying its own handler;
    /// this is what says that handler is reachable, focused, and wired to the close.
    ///
    /// The stat here never answers, which IS the state under test rather than a slow stand-in.
    @Test func escapeClosesTheDifferencesOverlayWhileTheStatIsStillBlocking() async throws {
        let recorder = Recorder()
        let difference = FileDifference(relativePath: "Reports/Q3.pdf",
                                        leftItemPath: "/L/Reports/Q3.pdf",
                                        rightItemPath: "/R/Reports/Q3.pdf",
                                        type: .differentDates, action: .copyToRight,
                                        description: "differs", enclosedItemCount: nil)
        // Built out here, not inside the closure: the closure is `@Sendable` and these come from a
        // main-actor helper. They are values, so capturing them is free.
        let left = copy("/L/Reports/Q3.pdf", keeper: true)
        let right = copy("/R/Reports/Q3.pdf")
        let pair = try #require(DifferencesPairCompare.pair(
            for: difference,
            paneNames: PaneProviderNames(leftName: "iCloud", rightName: "Dropbox")))
        let overlay = DifferencesPairCompareOverlay(
            pair: pair, hue: .blue,
            onClose: { recorder.closes += 1 },
            copies: { _ in
                try? await Task.sleep(nanoseconds: .max)   // a mount that will not answer
                return (left: left, right: right)          // never reached; the closure must type
            })
        let window = host(overlay)
        guard await waitForFocus(in: window) else { return }

        sendEscape(window)

        #expect(recorder.closes == 1, "esc did nothing while the surface waited on its stat")
    }
}
