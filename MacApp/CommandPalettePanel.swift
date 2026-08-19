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

/// The panel class, which exists for one overridden line — and as of §7 that line reads the other
/// way round.
///
/// A borderless `NSPanel` refuses key by default. While the palette carried its own field, refusing
/// key was the bug this file was written to fix: the field could not hold the caret. Now the field
/// is in the toolbar of the host window, so the polarity inverts — **the panel must refuse key, or
/// taking it would pull the caret out of the field the user is typing into.** Measured before it
/// was built (ROADMAP_V4 §7, spike 2): with the panel non-key the host stays key, first responder
/// stays the field editor, typed characters keep landing, and the list's selection fill draws
/// identically, because the highlight is this app's own `fill(accent)` rather than an AppKit
/// emphasized selection.
final class CommandPaletteWindow: NSPanel {
    override var canBecomeKey: Bool { false }
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
    /// Where the toolbar field is, in the panel's own SwiftUI coordinate space. Published rather
    /// than passed once, because the panel spans the host window and the field moves with every
    /// resize — a list anchored to where the field *was* is a list beside the field.
    @Published var fieldFrame: CGRect = .zero

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
    /// The live presentation's state, so the toolbar field can drive it — the field is outside this
    /// panel now, and everything it does (typing, ↑ ↓, ↩) has to reach the list somehow.
    private(set) var state: CommandPaletteState?
    /// Where the field is, asked again whenever the window moves.
    private var anchor: (() -> CGRect?)?
    /// Running a route dismisses first; held so ↩ from the field takes exactly the same path a
    /// click on a row does.
    private var runRoute: ((PaletteRoute) -> Void)?

    var isPresented: Bool { panel != nil }

    // MARK: Driven from the toolbar field

    /// What the user typed. Goes through `setQuery` so the selection moves with the list.
    func setQuery(_ query: String) { state?.setQuery(query) }

    /// ↑ / ↓ from the field editor.
    func move(by step: Int) {
        guard let state else { return }
        state.selection = PaletteSelection.moved(from: state.selection, by: step, in: state.rows)
    }

    /// ↩ from the field editor — **through the same pure rule a click takes**, never by reading the
    /// row here.
    func runSelection() {
        guard let state, let route = PaletteSelection.chosen(at: state.selection, in: state.rows)
        else { return }
        runRoute?(route)
    }

    /// Re-reads where the field is and hands it to the panel's content in ITS coordinate space:
    /// AppKit measures from the bottom left of the screen, SwiftUI from the top left of the panel.
    /// One translation, in one place, so nothing downstream has to know which convention it holds.
    /// - Parameter retriesLeft: the field is a SwiftUI toolbar item that mounts a turn or two
    ///   after the flag that opens it, so the first look routinely finds nothing. Retried on the
    ///   main queue rather than measured once, and the panel draws nothing until this succeeds.
    private func refreshAnchor(retriesLeft: Int = 6) {
        guard let panel, let state else { return }
        guard let screenRect = anchor?(), screenRect.width > 0 else {
            guard retriesLeft > 0 else {
                // Said out loud: a palette with no anchor is an empty window over the app, and it
                // has no other trace.
                Logger.shared.warning("[palette] the Go to field never appeared — the list has nothing to hang from")
                return
            }
            DispatchQueue.main.async { [weak self] in self?.refreshAnchor(retriesLeft: retriesLeft - 1) }
            return
        }
        let bottomLeft = panel.convertPoint(fromScreen: screenRect.origin)
        state.fieldFrame = CGRect(x: bottomLeft.x,
                                  y: panel.frame.height - (bottomLeft.y + screenRect.height),
                                  width: screenRect.width, height: screenRect.height)
    }

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
                 anchor: @escaping () -> CGRect?,
                 onRun: @escaping (PaletteRoute) -> Void,
                 onDismiss: @escaping () -> Void) {
        dismiss()
        self.onDismiss = onDismiss
        self.state = state
        self.anchor = anchor
        self.runRoute = { [weak self] route in
            self?.dismiss()
            onRun(route)
        }

        let content = CommandPalettePanelContent(
            state: state, accent: accent, glassLevel: glassLevel,
            onRun: { [weak self] route in
                // Dismiss FIRST, so the routing that follows lands on a window whose toolbar field
                // has already collapsed — a route that changes workspace underneath an open field
                // leaves the user typing at a list that is about to be replaced.
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
        // **The `hidesOnDeactivate = true` that used to sit here never did anything, and the reason
        // is the line order.** It was described as "a second belt for the case `didResignKey`
        // already covers (the app being deactivated) … the one case this cannot be tested for", and
        // measured inside a running app-target suite the panel read `hidesOnDeactivate == false`
        // right after `present` returned. **`addChildWindow` clears the flag**, and the assignment
        // came before it:
        //
        //     set true                  → true
        //     addChildWindow            → false      <- here
        //     makeKeyAndOrderFront      → false
        //     (set AFTER addChildWindow → true)
        //
        // So it was inert for as long as it was written down. It is deleted rather than moved below
        // the `addChildWindow`, because **the case it was for is covered, and that is now measured
        // too**: deactivating the app with the palette up (`NSApp.deactivate()`) gives
        // `children=0, isPresented=false` and exactly one dismissal through `onDismiss` — the panel
        // resigns key and the observer below closes it outright, which is strictly better than
        // hiding it. A belt that hides a window already being dismissed buys nothing, and a comment
        // promising a safety net that is not there is worse than having no net.
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentView = NSHostingView(rootView: AnyView(content))

        // A child window rides the host: it moves, resizes and orders with it, so the scrim cannot
        // come adrift of the window it is dimming.
        host.addChildWindow(panel, ordered: .above)
        // `orderFront`, never `makeKeyAndOrderFront`: the host keeps key so its toolbar field keeps
        // the caret. `addChildWindow` already orders it above; this is the explicit half.
        panel.orderFront(nil)
        self.panel = panel
        refreshAnchor()

        // **Logged because two rounds of this were guesswork.** Whether the panel takes key decides
        // whether its field holds the caret, and it cannot be observed from a test host.
        //
        // `isActive` is logged beside `isKeyWindow` because a `.nonactivatingPanel` takes key only
        // while its app is active, so `key=false` alone says nothing: `paletteOnLaunchArmed` raises
        // the palette when discovery finishes, which can be a very long time after launch. The
        // `[load] left #1 walked … in N` field in `~/sync-cloud.log` is **mixed-unit**: of 202
        // readings, 77 are in ms (68.6–938.2) and 125 in s (1.07–9891.41, the longest a single
        // outlier). So the palette can arm a fraction of a second in, or hours in, long after the
        // user has moved to another app. Without `active=` the two readings that matter, "the panel
        // refused key" and "SyncCloud was in the background", are the same line.
        //
        // (Three earlier versions of this sentence were wrong. Two read `tail -5` of that grep
        // instead of all of it — "minutes" was called invented when the log supports it, then
        // "10.5–15.4 s cold" replaced it. The third read the whole field and then sorted it as if
        // it had one unit, dropping 38% of the readings and putting the floor 16× too high.
        // **Read the whole field, and check its units before quoting a range.**)
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
        //
        // **Observed on the HOST now, not on the panel.** The panel cannot become key any more, so
        // it can never resign it either: an observer on the panel would be a dismissal path that
        // silently never fires. The host resigning key is the same event it always was — another
        // window, or another app, taking over.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            hostFrameObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: host, queue: .main) { [weak self, weak panel, weak host] _ in
                    guard let panel, let host else { return }
                    MainActor.assumeIsolated {
                        panel.setFrame(host.frame, display: true)
                        // The field moved with the window; re-anchor rather than leave the list
                        // beside it.
                        self?.refreshAnchor()
                    }
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
        // **No ⌘K monitor any more, and its absence is the fix rather than an omission.** While the
        // panel took key, the menu item could not fire — it reads a `@FocusedValue` published by
        // the window underneath — so a local monitor was the only path left, and it made ⌘K *close*
        // the palette. The host keeps key now, so the menu item works throughout, and ⌘K on an open
        // field means what it means in every other search field on the Mac: select what is there so
        // the next keystroke replaces it. Decided 2026-08-18; `closesThePalette` retired with it.
    }

    /// Installs a local monitor and tracks its token, so `dismiss()` has one bag to drain.
    ///
    /// **The `if let` is about the bag's element type, not about a failed install.** Both monitor
    /// factories are declared `nullable id` (`NSEvent.h`) and the header documents no failure mode
    /// for either, so a nil return is not a case anyone can point to — but the API is typed `Any?`,
    /// and an `Any?` appended straight to an `[Any]` bag becomes an element of type
    /// `Optional<Any>`. A `nil` one bridges to `NSNull`, and `NSEvent.removeMonitor` on that traps
    /// with `-[NSNull invalidate]: unrecognized selector sent to instance` — measured, in
    /// `+[NSEvent removeMonitor:]`. Unwrapping first is what keeps the bag drainable.
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
    /// **Probably not redundant with the resign-key observer, and the difference is the mask.** A
    /// left-click in one of those windows makes it key, so the observer would have covered it and
    /// this monitor merely gets there first — synchronously during dispatch, where the observer is
    /// registered `queue: .main` and lands a turn later. A **right- or middle-click is believed not
    /// to change the key window**, which would make this monitor the only thing that dismisses for
    /// two of its three masks.
    ///
    /// **That belief is UNVERIFIED — no test, no log line, and `event.window` has never been
    /// recorded.** It is nonetheless the stated reason this monitor is not deletable, so settle it
    /// before deleting: log `event.window` *and* `NSApp.keyWindow` here for one session and
    /// right-click another window.
    ///
    /// A local monitor also does not see events consumed by nested tracking loops. That much is
    /// documented — `NSEvent.h`, on `+addLocal`: "your handler will not be called for events that
    /// are consumed by nested event-tracking loops such as control tracking, menu tracking, or
    /// window dragging". What follows for the palette — that it stays up over a pulled-down menu —
    /// is inferred from it and has not been observed here.
    ///
    /// `nil` is a click this app cannot attribute to a window of its own; treating it as outside is
    /// the safe direction, since the alternative is a palette that survives a click it cannot see.
    static func clickDismissesThePalette(clickedWindow: NSWindow?, palette: NSWindow) -> Bool {
        clickedWindow !== palette
    }

    /// Idempotent, because six different things call it and two of them can race — esc arriving
    /// as the panel is already resigning key, say.
    func dismiss() {
        state = nil
        anchor = nil
        runRoute = nil
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
        GoToResultsPanel(
            rows: state.rows,
            query: state.query,
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
            accent: accent,
            glassLevel: glassLevel,
            fieldFrame: state.fieldFrame,
            onRun: onRun,
            onClose: onClose)
    }
}
