import Testing
import AppKit
import SwiftUI
import Design
import FileExplorer
import Sync
@testable import SyncCloud

/// The palette panel's two load-bearing rules, **against real windows**.
///
/// Both of them were broken when the palette was an in-window overlay, and neither was a rule
/// anything could have tested then, because neither existed: an overlay has no key state and no
/// resign-key event. They are the whole reason the palette became a window.
///
/// - **It becomes key.** An overlay could not, so its text field never took first responder and the
///   characters went to the pane's search field instead — visible in `~/sync-cloud.log` as a run of
///   `[columns] left pane depth …` lines stamped while the palette was open.
/// - **Anything else taking key dismisses it.** The overlay's scrim could only ever catch clicks
///   inside the window's own content, and not even those: the panes are `NSViewRepresentable`s, so
///   clicks landed in the `NSTableView` underneath (`[click] left pane selected 1 item(s)`, again
///   while the palette was open). Resigning key covers the content, the toolbar, the title bar and
///   another app with one rule.
///
/// ## Where the boundary is, measured
///
/// **Real key transfer is not observable in this test host.** `makeKeyAndOrderFront` gives a window
/// key only while its *application* is active, and an `xcodebuild test` host is not — even after
/// `NSApp.activate(ignoringOtherApps:)`, `isKeyWindow` stayed false through a five-second poll. So
/// two tests here originally asserted `isKeyWindow` and were meaningless: they passed on the one
/// run where the host happened to be frontmost and failed the next, which is a test that answers
/// only when nobody is looking.
///
/// The split this suite settled on is the honest one. **AppKit's key machinery is not mine to
/// test**; what is mine is (1) the window class *permitting* key at all, which is the exact default
/// that was broken, and (2) what this controller does when key is lost, which is driven here by
/// posting the notification AppKit would post. Both mutations that matter — a panel that refuses
/// key, a resign handler that does nothing — are still killed by that pair.
///
/// `.serialized` because these order real windows in and out, which is process-wide state.
@MainActor
@Suite(.serialized) struct CommandPalettePanelTests {

    /// A host to hang the panel on. `.titled` so it can take key the way the real window does;
    /// ordered out and released at the end of each test rather than `close()`d — closing a titled
    /// window in a test host has ended runs with no verdict before.
    private func makeHost() -> NSWindow {
        let host = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 900, height: 600),
                            styleMask: [.titled, .closable, .resizable],
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.makeKeyAndOrderFront(nil)
        return host
    }

    private func teardown(_ host: NSWindow, _ controller: CommandPalettePanelController) {
        controller.dismiss()
        host.orderOut(nil)
    }

    private var index: PaletteIndex {
        PaletteIndex(providers: [PaletteProvider(id: "icloud", name: "iCloud",
                                                 isMounted: true, isCurrent: true)],
                     providerRoot: "/root", folders: ["Legal"], recentFolders: [],
                     people: [], registry: nil, isScanning: false, hasSurvey: false)
    }

    @discardableResult
    private func present(_ controller: CommandPalettePanelController, over host: NSWindow,
                         onRun: @escaping (PaletteRoute) -> Void = { _ in },
                         onDismiss: @escaping () -> Void = {}) -> CommandPaletteState {
        let state = CommandPaletteState(index: index)
        controller.present(over: host, state: state, accent: .blue, glassLevel: .frosted,
                           onRun: onRun, onDismiss: onDismiss)
        return state
    }

    /// The panel this app raises must be *able* to take key. A borderless `NSPanel` refuses by
    /// default, and refusing is the whole defect: no key window means no first responder means the
    /// keystrokes go somewhere else.
    @Test func theWindowClassCanBecomeKeyAtAll() {
        let panel = CommandPaletteWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10),
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        #expect(panel.canBecomeKey, "a borderless panel that cannot become key cannot hold a caret")
        // ...and never main, so the menu bar and window title keep describing the document window.
        #expect(!panel.canBecomeMain)
        panel.orderOut(nil)
    }

    @Test func presentingRaisesAPanelParentedToAndSizedWithTheHost() {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        present(controller, over: host)
        #expect(controller.isPresented)
        let panel = try? #require(host.childWindows?.compactMap { $0 as? CommandPaletteWindow }.first)
        #expect(panel != nil, "the panel is not a child of the host — it will not move or order with it")
        // Sized to the host, because the scrim is inside it and has to dim the whole window —
        // including the title bar, which is what makes clicking there dismiss.
        #expect(panel?.frame == host.frame)
        // Whether it *did* take key is AppKit's business and unobservable here; that it *may* is
        // this app's, and `theWindowClassCanBecomeKeyAtAll` holds it.
        #expect(panel?.canBecomeKey == true)
        teardown(host, controller)
    }

    /// **Click-away, expressed as the only rule that covers the title bar.**
    ///
    /// A click anywhere in the window — content, toolbar or title bar — makes the host key, which
    /// makes the panel resign it. Driven by posting the notification AppKit posts, because the
    /// transfer itself does not happen in a test host (see the suite's note): what is under test is
    /// this controller's reaction, not AppKit's delivery.
    @Test func resigningKeyDismissesThePalette() async throws {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        var dismissed = false
        present(controller, over: host, onDismiss: { dismissed = true })
        #expect(controller.isPresented)
        let panel = try #require(host.childWindows?.first, "no panel to resign key")

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        // Delivered on the main queue, so it lands on a later turn. Bounded, and it fails at the
        // deadline rather than passing on timeout.
        await waitUntil("the palette dismissed after resigning key") { !controller.isPresented }
        #expect(dismissed, "onDismiss did not fire, so the chord suspension stays stuck on")
        teardown(host, controller)
    }

    /// Every exit path runs `onDismiss` exactly once. Five things call `dismiss()` and two can
    /// race — esc arriving as the panel is already resigning key — so a second call must be inert
    /// rather than re-firing the callback that clears the chord suspension.
    @Test func dismissIsIdempotentAndFiresItsCallbackOnce() {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        var dismissals = 0
        present(controller, over: host, onDismiss: { dismissals += 1 })
        controller.dismiss()
        controller.dismiss()
        controller.dismiss()
        #expect(dismissals == 1, "onDismiss fired \(dismissals) times")
        #expect(!controller.isPresented)
        #expect(host.childWindows?.isEmpty != false, "the panel is still a child of the host after dismissal")
        teardown(host, controller)
    }

    /// Presenting twice replaces, and **the replaced presentation is told it is over.**
    ///
    /// The window count alone is not discriminating — dropping the `dismiss()` at the top of
    /// `present` still leaves one child, because the orphaned panel is released the moment the
    /// controller stops referencing it, and the count was the whole of this test's first version.
    /// What survives that mutation is the *callback*: without the clear-out the first
    /// presentation's `onDismiss` never fires, and the flag the chord suspension reads is left
    /// claiming a palette that is no longer on screen — every menu shortcut in the app dead until
    /// something else happens to clear it.
    @Test func presentingAgainReplacesAndRetiresTheOneItReplaced() {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        var firstRetired = false
        present(controller, over: host, onDismiss: { firstRetired = true })
        present(controller, over: host)
        #expect(firstRetired,
                "the replaced presentation was never told it ended — the chord suspension stays stuck on")
        #expect(host.childWindows?.count == 1,
                "presenting twice left \(host.childWindows?.count ?? 0) panels parented to the host")
        teardown(host, controller)
    }

    @Test func thePanelFollowsTheHostWhenItResizes() async {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        present(controller, over: host)
        host.setFrame(CGRect(x: 120, y: 140, width: 1200, height: 800), display: true)
        await waitUntil("the panel followed the host's new frame") {
            host.childWindows?.first?.frame == host.frame
        }
        #expect(host.childWindows?.first?.frame == host.frame,
                "the scrim came adrift of the window it is dimming")
        teardown(host, controller)
    }

    // MARK: ⌘K, while the panel holds the keyboard

    /// **The chord must survive Caps Lock.**
    ///
    /// While the panel is key the menu item cannot fire — it reads a `@FocusedValue` published by
    /// the window underneath — so ⌘K comes from a local event monitor, and the obvious way to write
    /// that test is wrong: `.deviceIndependentFlagsMask` includes `.capsLock`, `.function` and
    /// `.numericPad`, so comparing the whole intersection to `.command` made ⌘K stop closing the
    /// palette for anyone with Caps Lock on. Only the four modifiers a chord is made of count.
    @Test func theClosingChordIgnoresKeyStateThatIsNotPartOfAChord() {
        typealias C = CommandPalettePanelController
        #expect(C.closesThePalette(modifiers: [.command], charactersIgnoringModifiers: "k"))
        #expect(C.closesThePalette(modifiers: [.command, .capsLock], charactersIgnoringModifiers: "K"),
                "⌘K stopped closing the palette because Caps Lock was on")
        #expect(C.closesThePalette(modifiers: [.command, .function], charactersIgnoringModifiers: "k"))
        #expect(C.closesThePalette(modifiers: [.command, .numericPad], charactersIgnoringModifiers: "k"))
    }

    /// ...and it must not fire for a *different* chord, or the palette would swallow keys that
    /// belong to the app. A monitor that returns nil eats the event for everyone.
    @Test func theClosingChordIsOnlyTheChordItself() {
        typealias C = CommandPalettePanelController
        #expect(!C.closesThePalette(modifiers: [.command, .shift], charactersIgnoringModifiers: "k"))
        #expect(!C.closesThePalette(modifiers: [.command, .option], charactersIgnoringModifiers: "k"))
        #expect(!C.closesThePalette(modifiers: [.command, .control], charactersIgnoringModifiers: "k"))
        #expect(!C.closesThePalette(modifiers: [], charactersIgnoringModifiers: "k"),
                "a bare k closed the palette — every letter typed into the field would close it")
        #expect(!C.closesThePalette(modifiers: [.command], charactersIgnoringModifiers: "j"))
        #expect(!C.closesThePalette(modifiers: [.command], charactersIgnoringModifiers: nil))
    }

    /// The chord comes from `AppChord`, so the monitor and the menu item cannot come to disagree
    /// about which key opens and closes the palette.
    @Test func theClosingChordIsTheRegisteredOne() {
        #expect(!CommandPalettePanelController.closesThePalette(
            modifiers: [.command],
            charactersIgnoringModifiers: String(AppChord.commandPalette.key.character) + "x"))
        #expect(CommandPalettePanelController.closesThePalette(
            modifiers: [.command],
            charactersIgnoringModifiers: String(AppChord.commandPalette.key.character)))
    }

    // MARK: The state the panel owns

    @Test func typingMovesTheSelectionWithTheListRatherThanLeavingItBehind() {
        let state = CommandPaletteState(index: index)
        // Opens on the first choosable row of the empty-query landing.
        #expect(state.selection == PaletteSelection.initialIndex(in: state.rows))
        state.selection = 4
        state.setQuery("legal")
        #expect(state.rows.count > 0)
        #expect(state.selection == PaletteSelection.initialIndex(in: state.rows),
                "the selection is a stale index into the previous results — ↩ would run a row nobody looked at")
    }

    @Test func theIndexIsSnapshottedRatherThanReReadPerKeystroke() {
        // A palette that re-indexed between a key and its character would be walking the folder
        // profile inside a keystroke. The state takes the index once, at init.
        let state = CommandPaletteState(index: index)
        state.setQuery("legal")
        #expect(state.index.folders == ["Legal"])
    }
}
