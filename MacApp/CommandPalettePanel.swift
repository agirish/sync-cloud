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
// - **Clicking away.** Split across three mechanisms, and it took four attempts to get here: the
//   panel spans the host's whole frame, so clicks over the host — content, toolbar band and title
//   bar alike — land on the panel's own scrim and are dismissed by its tap; a left-click in another
//   of this app's windows moves key, and resigning key dismisses; a right- or middle-click there
//   moves no key at all, and only the mouse monitor covers it. `clickDismissesThePalette` carries
//   the boundary, the corrections, and what is still unverified; read it before changing any half.
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
    /// One bag rather than a named property per monitor: nothing ever reads them apart, and the
    /// shape matches `hostFrameObservers` below it, so adding a monitor cannot leave `dismiss()`
    /// behind.
    private var eventMonitors: [Any] = []
    private var onDismiss: (() -> Void)?

    var isPresented: Bool { panel != nil }

    /// Raises the palette over `host`.
    ///
    /// - Parameter onDismiss: called for every way it can close — resigning key, a click in another
    ///   of this app's windows, esc, the scrim, running a route, or ⌘K again — so the caller has
    ///   exactly one place to put "it is closed now". A second path that skipped this is how a
    ///   chord-suspension flag gets stuck on.
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
        // whether its field holds the caret, and it cannot be observed from a test host.
        //
        // `isActive` is logged beside `isKeyWindow` because a `.nonactivatingPanel` takes key only
        // while its app is active, so `key=false` alone says nothing: `paletteOnLaunchArmed` raises
        // the palette when discovery finishes — a few seconds on his tree, ~10s on a cold cache —
        // which can land after the user has moved to another app. Without `active=` the two
        // readings that matter, "the panel refused key" and "SyncCloud was in the background", are
        // the same line.
        //
        // **`childWindows` answers a narrower question than it looks like it does.** It lists only
        // windows *parented* here, and the panel was parented nine lines up, so it is guaranteed to
        // contain the palette. It is not a list of what is on screen above this window: a window
        // merely *ordered* above is not a child, and AppKit attaches children of its own (sheets,
        // popovers). Read it as "what is parented here", never as "what is above the panel" — this
        // line has already been mis-read once as refuting a theory it cannot speak to.
        Logger.shared.debug("[palette] panel key=\(panel.isKeyWindow) active=\(NSApp.isActive) "
            + "frame=\(panel.frame) "
            + "host children=\((host.childWindows ?? []).map { String(describing: type(of: $0)) })")

        // **Resigning key covers a left-click in another window, and another app.** Not clicks over
        // the host's own frame — the panel spans that frame and hit-tests, so those land on the
        // panel, move no key, and fall to the scrim's own tap. And not a right- or middle-click
        // anywhere, which changes no key window at all; the mouse monitor below is the only thing
        // that covers those. See `clickDismissesThePalette` for the whole boundary and for which
        // parts of it are still unverified.
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
        // Clicks in another of this app's windows, dismissing before the event is dispatched rather
        // than after key has moved. **Not deletable as a duplicate of the resign observer: a right-
        // or middle-click moves no key, so for two of these three masks this is the only dismissal
        // path.** What it can and cannot reach — and what about that is still unverified — is
        // written out on `clickDismissesThePalette`.
        addMonitor(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // Compared against `self.panel`, not a captured one: the capture would name the panel
            // from *this* presentation, and a monitor outliving its presentation would then measure
            // a click against a window that is no longer on screen.
            guard let self, let panel = self.panel,
                  Self.clickDismissesThePalette(clickedWindow: event.window, palette: panel)
            else { return event }
            // The event is RETURNED, never swallowed: the click that dismisses the palette is also
            // the click the user meant for whatever is under it, and eating it would trade one
            // broken gesture for another.
            self.dismiss()
            return event
        }
        // ⌘K has to keep working while the panel is key, and it cannot come from the menu item:
        // that reads a `@FocusedValue` published by the window underneath, which is no longer key.
        // A local monitor is the only path left, and it is scoped to the panel's lifetime.
        addMonitor(matching: .keyDown) { [weak self] event in
            guard let self, self.isPresented,
                  Self.closesThePalette(modifiers: event.modifierFlags,
                                        charactersIgnoringModifiers: event.charactersIgnoringModifiers)
            else { return event }
            self.dismiss()
            return nil
        }
    }

    /// Installs a local monitor and tracks its token, so `dismiss()` has one bag to drain.
    ///
    /// **The `if let` is about the bag's element type, not about a failed install.** The local
    /// variant has no documented failure mode — it is `nullable` in the header only because it
    /// shares a declaration shape with the *global* variant, which really can fail on accessibility
    /// trust — but it is typed `Any?`, and an `Any?` appended straight to an `[Any]` bag becomes an
    /// element of type `Optional<Any>`. A `nil` one bridges to `NSNull`, and `NSEvent.removeMonitor`
    /// on that traps with `-[NSNull invalidate]: unrecognized selector`. Unwrapping first is what
    /// keeps the bag drainable.
    ///
    /// A failure to install would mean ⌘K silently stops closing the palette, on a surface whose
    /// whole reason for logging is that it is otherwise unobservable — so say so rather than
    /// dropping it.
    private func addMonitor(matching mask: NSEvent.EventTypeMask,
                            handler: @escaping (NSEvent) -> NSEvent?) {
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler) else {
            Logger.shared.warning("[palette] event monitor for mask \(mask.rawValue) was not installed — "
                + "the palette will not respond to those events")
            return
        }
        eventMonitors.append(monitor)
    }

    /// Whether a mouse-down **outside the palette** should dismiss it.
    ///
    /// **This is a rule about which WINDOW was clicked — not about layering, and not about key
    /// state.** A click *on* the palette is left alone, because the card has to keep working and
    /// the scrim's own tap already owns the dimmed area.
    ///
    /// ## What this does NOT cover, and the correction that matters
    ///
    /// **The title-bar bug this rule was written for is almost certainly not fixed by this rule, and
    /// reading it that way is how a fifth attempt at click-away gets started.** The panel is sized
    /// to the host's whole `frame` (nine lines above the monitor) and its scrim is a filled,
    /// hit-testing `Rectangle`, so every click over the host — title band and toolbar band included
    /// — should be attributed to *this panel*, making `clickedWindow === palette` and leaving the
    /// monitor to return the event untouched.
    ///
    /// **INFERRED, not observed, and the distinction is the whole lesson of this file.** What
    /// supports it: the panel's frame is the host's, and `399d0c04` fixed a *title-bar* symptom by
    /// reordering `.contentShape` on a SwiftUI view **inside this panel**, which can only work if
    /// the click landed on the panel. What would settle it: log `event.window` in the monitor for
    /// one session and click the title bar. **That has never been done, and `event.window` has
    /// never been logged.** Do it before building anything else on this paragraph.
    ///
    /// What actually restored dismissal above the card was that same `.contentShape` sitting
    /// outside its top padding, so a 620×96pt block swallowed the clicks; the strip is the scrim's
    /// again.
    ///
    /// So the reachable job of this rule is narrower than "anything outside": it is **another
    /// window of this app** — Keyboard Shortcuts, Activity Log and Sync History are real `Window`
    /// scenes (Settings and Help are in-window overlays and are *under* the panel, not other
    /// windows), plus an open/save panel.
    ///
    /// **It is not redundant with the resign-key observer, and the difference is the mask.** A
    /// left-click in one of those windows makes it key, so the observer would have covered it and
    /// this monitor merely gets there first — synchronously during dispatch, where the observer is
    /// registered `queue: .main` and lands a turn later. But a **right- or middle-click does not
    /// change the key window**, so for two of the three masks here this monitor is the *only* thing
    /// that dismisses. Do not delete it as a duplicate.
    ///
    /// A local monitor is also believed not to see events consumed by NSMenu tracking or by a
    /// window drag/resize tracking loop, so the palette may stay up over a pulled-down menu.
    /// **Unverified — neither the mechanism nor the behaviour has been observed here.** If you touch
    /// this, open a menu with the palette up and write down what happens.
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

    /// Idempotent, because six different things call it and two of them can race — esc arriving
    /// as the panel is already resigning key, say.
    func dismiss() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors = []
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
