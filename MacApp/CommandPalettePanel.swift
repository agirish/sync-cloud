import SwiftUI
import AppKit
import Design
import Events
import FileExplorer

// MARK: - Why the palette is a window and not an overlay
//
// It shipped as an `.overlay` on the window's content, like Settings and Help, and it did not work:
// **clicks and keystrokes went straight through it to the panes underneath.** The app's own log
// caught it — `[click] left pane selected 1 item(s)` and a run of `[columns] left pane depth …`
// lines are stamped *while the palette was open*, so a click meant to dismiss it was selecting
// files, and the characters meant for its field were landing in the pane's search field and walking
// it from hit to hit (which is why a different file kept appearing in Quick Look).
//
// The cause is AppKit interop, not layout. The file panes are `NSViewRepresentable`s — real
// `NSTableView`s in the hosting view's subview tree — and a SwiftUI overlay *drawn* above them is
// not reliably *hit* above them. Settings and Help have the same shape and get away with it because
// they are dismissed with a button or esc; a palette is dismissed by clicking away and driven
// entirely by the keyboard, so it needs both of the things the overlay could not give it.
//
// A real window settles all of it by construction:
//
// - **Keyboard.** The panel becomes key, so its field is the first responder and the pane's field
//   cannot be. No focus race, no `@FocusState` write to lose.
// - **Clicking away.** Anything else clicked — the content, the toolbar, the title bar, another
//   app — makes some other window key, and resigning key dismisses. One rule covers every surface,
//   including the title bar, which no in-window scrim could ever have covered.
// - **The scrim still belongs to the palette.** The panel is sized to the host window and is
//   transparent, so `CommandPaletteView` draws exactly what it drew before: dimmed backdrop, card
//   floating near the top. Nothing about the look changes.

/// The panel class, which exists for one overridden line.
///
/// A borderless `NSPanel` refuses key by default, and a palette that cannot become key is the bug
/// this file was written to fix.
final class CommandPaletteWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Never main: the document window stays the app's main window underneath, so the menu bar and
    /// the window title keep describing the app rather than a transient palette.
    override var canBecomeMain: Bool { false }
}

/// The palette's own state while it is up: what has been typed, and which row is lit.
///
/// **The index is snapshotted when the palette opens and never re-read.** That is not a shortcut —
/// re-indexing between a key and its character is the disk-walk-in-a-view-body mistake one layer
/// over, and the answer to "what folders exist" cannot honestly change inside one palette session.
@MainActor
final class CommandPaletteState: ObservableObject {
    @Published private(set) var query: String = ""
    @Published var selection: Int?

    let index: PaletteIndex

    init(index: PaletteIndex) {
        self.index = index
        self.selection = PaletteSelection.initialIndex(in: PaletteRouter.rows(query: "", index: index))
    }

    var rows: [PaletteRow] { PaletteRouter.rows(query: query, index: index) }

    /// Typing moves the selection with the list rather than leaving it where it was: an index into
    /// the PREVIOUS results names a different row after a keystroke, so ↩ would run something the
    /// user never looked at.
    func setQuery(_ newValue: String) {
        query = newValue
        selection = PaletteSelection.initialIndex(in: rows)
    }
}

/// Presents and dismisses the palette panel. Owned by `ContentView` so it outlives a body pass.
@MainActor
final class CommandPalettePanelController: ObservableObject {

    private var panel: CommandPaletteWindow?
    private var resignObserver: NSObjectProtocol?
    private var hostFrameObservers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var onDismiss: (() -> Void)?

    var isPresented: Bool { panel != nil }

    /// Raises the palette over `host`.
    ///
    /// - Parameter onDismiss: called for every way it can close — resigning key, esc, the scrim,
    ///   running a route, or ⌘K again — so the caller has exactly one place to put "it is closed
    ///   now". A second path that skipped this is how a chord-suspension flag gets stuck on.
    func present(over host: NSWindow,
                 state: CommandPaletteState,
                 accent: Color,
                 glassLevel: GlassLevel,
                 onRun: @escaping (PaletteRoute) -> Void,
                 onDismiss: @escaping () -> Void) {
        dismiss()
        self.onDismiss = onDismiss

        let content = CommandPalettePanelContent(
            state: state, accent: accent, glassLevel: glassLevel,
            onRun: { [weak self] route in
                // Dismiss FIRST, so the routing that follows lands on a window that is already
                // key again — a route that changes workspace while the panel still holds key
                // leaves the app focused on a window that is about to close.
                self?.dismiss()
                onRun(route)
            },
            onClose: { [weak self] in self?.dismiss() })

        let panel = CommandPaletteWindow(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        // A second belt for the case `didResignKey` already covers (the app being deactivated), and
        // kept because that one case is the only one this cannot be tested for: a panel left
        // floating over another app would be the worst version of the bug this file fixes.
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentView = NSHostingView(rootView: AnyView(content))

        // A child window rides the host: it moves, resizes and orders with it, so the scrim cannot
        // come adrift of the window it is dimming.
        host.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        // **Logged because two rounds of this were guesswork.** Whether the panel takes key decides
        // whether its field holds the caret, and it cannot be observed from a test host — so the
        // one place the answer exists on a real machine is here. The host's other child windows are
        // logged with it: a window with a toolbar keeps its title bar in one, which is why covering
        // the host's frame does not cover the title bar.
        Logger.shared.debug("[palette] panel key=\(panel.isKeyWindow) frame=\(panel.frame) "
            + "host children=\((host.childWindows ?? []).map { String(describing: type(of: $0)) })")

        // **Resigning key IS the click-away rule.** Not a scrim tap: the scrim is inside this
        // panel and could only ever catch clicks within the host's own bounds, which is what left
        // the title bar undismissable. Anything that takes key — the content, the toolbar, the
        // title bar, another app — closes the palette.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            hostFrameObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: host, queue: .main) { [weak panel, weak host] _ in
                    guard let panel, let host else { return }
                    MainActor.assumeIsolated { panel.setFrame(host.frame, display: true) }
                })
        }
        // ⌘K has to keep working while the panel is key, and it cannot come from the menu item:
        // that reads a `@FocusedValue` published by the window underneath, which is no longer key.
        // A local monitor is the only path left, and it is scoped to the panel's lifetime.
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak panel] event in
                guard let self, let panel, self.isPresented,
                      Self.clickDismissesThePalette(clickedWindow: event.window, palette: panel)
                else { return event }
                // The event is RETURNED, never swallowed: the click that dismisses the palette is
                // also the click the user meant for the toolbar button or the title bar under it,
                // and eating it would trade one broken gesture for another.
                self.dismiss()
                return event
            }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPresented,
                  Self.closesThePalette(modifiers: event.modifierFlags,
                                        charactersIgnoringModifiers: event.charactersIgnoringModifiers)
            else { return event }
            self.dismiss()
            return nil
        }
    }

    /// Whether a mouse-down **outside the palette** should dismiss it.
    ///
    /// **This is the click-away rule, and it is a rule about which WINDOW was clicked — not about
    /// layering, and not about key state.** Two mechanisms were tried before it and both were
    /// reported broken from the running app: the scrim inside this panel, and resigning key.
    ///
    /// **Why they failed for title-bar clicks was never established, and this comment says so
    /// rather than inventing one.** A first draft asserted that a window with a toolbar keeps its
    /// title bar in a separate window ordered above the panel — plausible, and false. The panel now
    /// logs what it can see when it is raised, and on the real window that reads:
    ///
    ///     [palette] panel key=true frame=(0.0, 87.0, 1710.0, 986.0) host children=["CommandPaletteWindow"]
    ///
    /// One child window, which is this panel; a frame that is the host's whole frame and therefore
    /// *does* span the title bar; and key genuinely taken. Every premise of that explanation is
    /// contradicted by its own diagnostic. Part of the region is now accounted for by something
    /// else entirely — the card's `.contentShape` sat outside its 96pt top padding, so the strip
    /// directly above the card swallowed clicks (fixed separately) — and the rest is not.
    ///
    /// That is exactly why the rule below is the one worth having: **it does not depend on knowing.**
    ///
    /// A local mouse monitor sees every click destined for this app before it is dispatched, and
    /// the window it names settles the question with no geometry and no ordering: **anything but
    /// the palette itself dismisses.** A click *on* the palette is left alone — the scrim's own tap
    /// handles the dimmed area, and the card has to keep working.
    ///
    /// `nil` is a click this app cannot attribute to a window of its own; treating it as outside is
    /// the safe direction, since the alternative is a palette that survives a click it cannot see.
    static func clickDismissesThePalette(clickedWindow: NSWindow?, palette: NSWindow) -> Bool {
        clickedWindow !== palette
    }

    /// Whether a key-down is the palette's own chord.
    ///
    /// **Only the four modifiers a chord is made of are compared.** The obvious form —
    /// `modifierFlags.intersection(.deviceIndependentFlagsMask) == .command` — is what this
    /// replaced, and it is wrong for anyone typing with **Caps Lock on**: that mask includes
    /// `.capsLock` (and `.function`, and `.numericPad`), so the intersection came back as
    /// `[.command, .capsLock]`, matched nothing, and ⌘K silently stopped closing the palette it had
    /// opened. Exactly the class of bug this whole surface keeps producing — a chord that works
    /// until some unrelated key state is different.
    ///
    /// Static and pure so the rule can be asserted without an `NSEvent`, which cannot be
    /// synthesised in a test.
    static func closesThePalette(modifiers: NSEvent.ModifierFlags,
                                 charactersIgnoringModifiers: String?) -> Bool {
        let chordModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard modifiers.intersection(chordModifiers) == .command else { return false }
        // Caps Lock also changes the character, so the comparison folds case as well as flags.
        return charactersIgnoringModifiers?.lowercased() == String(AppChord.commandPalette.key.character)
    }

    /// Idempotent, because five different things call it and two of them can race — esc arriving
    /// as the panel is already resigning key, say.
    func dismiss() {
        for monitor in [keyMonitor, clickMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        clickMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        hostFrameObservers.forEach(NotificationCenter.default.removeObserver)
        hostFrameObservers = []
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
        }
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }
}

/// The panel's root view: the palette, fed from the state object the controller owns.
private struct CommandPalettePanelContent: View {
    @ObservedObject var state: CommandPaletteState
    let accent: Color
    let glassLevel: GlassLevel
    let onRun: (PaletteRoute) -> Void
    let onClose: () -> Void

    var body: some View {
        CommandPaletteView(
            rows: state.rows,
            query: Binding(get: { state.query }, set: { state.setQuery($0) }),
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
            accent: accent,
            glassLevel: glassLevel,
            onRun: onRun,
            onClose: onClose)
    }
}
