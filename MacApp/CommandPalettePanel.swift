import SwiftUI
import AppKit
import Design
import Events
import FileExplorer

// MARK: - Why the palette is a window and not an overlay
//
// Not an `.overlay` on the window's content, like Settings and Help: clicks and keystrokes go
// straight through an overlay to the panes underneath. The file panes are `NSViewRepresentable`s
// (real `NSTableView`s in the hosting view's subview tree), and a SwiftUI overlay drawn above them
// is not reliably hit above them. Settings and Help get away with it because a button or esc
// dismisses them; a palette is dismissed by clicking away and driven entirely by the keyboard.
//
// A real window settles it by construction:
//
// - Keyboard. The field is in the host's toolbar, so the panel must refuse key, or taking it
//   would pull the caret out of the field being typed into. See `CommandPaletteWindow`; never
//   make `canBecomeKey` true.
// - Clicking away. The panel is sized to its list, not the host's frame (a host-sized panel
//   eats every click over the app). Click-away is the mouse monitor, which dismisses and returns
//   the event so the click also does what the user meant, plus the host resigning key for another
//   app or window. `clickDismissesThePalette` carries the boundary; read it before changing either.
// - No scrim and no dim. The panel is exactly its list (`GoToResultsPanel`), hung under the
//   toolbar field by `refreshAnchor`/`place`. A window you can see through is one you expect to
//   click.
//
//   Not everything outside the panel is "the window underneath": the toolbar's Go-to field is
//   part of the palette and lives in the host window. The palette's surface is two objects in two
//   windows; `clickDismissesThePalette` reconciles them.

/// The panel class, which exists for its overrides.
///
/// **The panel must refuse key**, or taking it would pull the caret out of the toolbar field the
/// user is typing into. Non-key, the host stays key, the field editor stays first responder, and
/// the list's selection still draws, because the highlight is this app's own `fill(accentFill)`
/// rather than an AppKit emphasized selection.
final class CommandPaletteWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    /// Never main: the document window stays the app's main window underneath, so the menu bar and
    /// the window title keep describing the app rather than a transient palette.
    override var canBecomeMain: Bool { false }
}

/// The palette's own state while it is up: what has been typed, and which row is lit.
///
/// The index is a snapshot taken when the palette opens and never re-read: re-indexing between
/// keystrokes would be a disk walk in a view body, and "what folders exist" does not change inside
/// one palette session.
@MainActor
final class CommandPaletteState: ObservableObject {
    @Published private(set) var query: String = ""
    @Published var selection: Int?
    /// How wide the list draws: the field's width. Published, not passed once, because the field's
    /// width changes with every window resize. Zero until the field is found; the panel draws
    /// nothing at that width.
    @Published var listWidth: CGFloat = 0

    let index: PaletteIndex
    /// What is at a typed path, for Go to Folder: the one thing the router cannot answer from the
    /// snapshot. Here rather than on the index because a closure is neither `Equatable` nor
    /// `Sendable` and the index is both.
    ///
    /// `nil` means no path rows, never a default answer. The app passes a real one, and
    /// `theHostGivesTheRouterARealPathProbe` says so.
    let pathProbe: PalettePathProbe?

    init(index: PaletteIndex, pathProbe: PalettePathProbe? = nil) {
        self.index = index
        self.pathProbe = pathProbe
        self.selection = PaletteSelection.initialIndex(in: PaletteRouter.rows(query: "", index: index))
    }

    /// The last path asked about and what was there: a one-entry memo. `rows` is read twice per
    /// change (by `setQuery` and by the SwiftUI body) and again on every arrow key, so without it a
    /// keystroke costs two `stat`s and an arrow key two more; with it, one and none. Caching a disk
    /// answer for one presentation is the rule the snapshotted index already follows.
    private var lastProbed: (path: String, kind: PathKind)?

    private func probeKind(_ path: String) -> PathKind {
        if let lastProbed, lastProbed.path == path { return lastProbed.kind }
        // `.missing` is unreachable: this is only reached through the closure below, which exists
        // only when `pathProbe` does.
        let kind = pathProbe?(path) ?? .missing
        lastProbed = (path, kind)
        return kind
    }

    /// The rows for the query they were ranked for. Ranking is the palette's whole cost (every
    /// surveyed folder scored, ~16 ms over 3,000), and `rows` is read twice per keystroke and on
    /// every ↑ ↓. The index is a snapshot and the probe has its own memo, so the query is the only
    /// input that can change.
    private var ranked: (query: String, rows: [PaletteRow])?
    /// How many times the rows were actually ranked. Test instrumentation, like
    /// `PDFKitSerialAccess.peakConcurrentParses`; nothing in the app reads it.
    private(set) var rankingRuns = 0

    var rows: [PaletteRow] {
        if let ranked, ranked.query == query { return ranked.rows }
        rankingRuns += 1
        let rows = PaletteRouter.rows(query: query, index: index,
                                      probe: pathProbe == nil ? nil : { [self] in probeKind($0) })
        ranked = (query, rows)
        return rows
    }

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
    /// One bag rather than a property per monitor, like `hostFrameObservers`, so adding a monitor
    /// cannot leave `dismiss()` behind.
    private var eventMonitors: [Any] = []
    private var onDismiss: (() -> Void)?
    /// The live presentation's state, so the toolbar field, which is outside this panel, can drive
    /// the list (typing, ↑ ↓, ↩).
    private(set) var state: CommandPaletteState?
    /// Where the field is, asked again whenever the window moves.
    private var anchor: (() -> CGRect?)?
    /// The window the palette hangs off, so placement can be clamped to it.
    private weak var host: NSWindow?
    /// The field's screen rect as last measured, and the content height as last reported. Placement
    /// needs both and they arrive from different directions, so each is kept and the panel is
    /// re-placed whenever either moves.
    private var fieldRect: CGRect?
    private var contentHeight: CGFloat = 0
    /// Running a route dismisses first; held so ↩ from the field takes exactly the same path a
    /// click on a row does.
    private var runRoute: ((PaletteRoute) -> Void)?

    var isPresented: Bool { panel != nil }

    /// One display frame between anchor attempts, and ~0.6s of them. See `refreshAnchor`.
    static let anchorRetryInterval: TimeInterval = 1.0 / 60.0
    static let anchorAttempts = 36

    // MARK: Driven from the toolbar field

    /// What the user typed. Goes through `setQuery` so the selection moves with the list.
    func setQuery(_ query: String) { state?.setQuery(query) }

    /// ↑ / ↓ from the field editor.
    func move(by step: Int) {
        guard let state else { return }
        state.selection = PaletteSelection.moved(from: state.selection, by: step, in: state.rows)
    }

    /// ↩ from the field editor, through the same pure rule a click takes, never by reading the row
    /// here.
    func runSelection() {
        guard let state, let route = PaletteSelection.chosen(at: state.selection, in: state.rows)
        else { return }
        runRoute?(route)
    }

    /// Re-reads where the field is, and places the panel under it.
    ///
    /// The panel is the list, not the window: a click anywhere else lands on the window under
    /// it, and the mouse monitor dismisses on the way past.
    ///
    /// - Parameter retriesLeft: the field is a SwiftUI toolbar item that mounts a turn or two
    ///   after the flag that opens it, so the first look routinely finds nothing. Retried rather
    ///   than measured once, and the panel stays out of the way until it lands.
    ///
    ///   **A frame apart, never bare `async` hops:** blocks queued from inside a main-queue drain
    ///   run in that same drain, ahead of the SwiftUI update that mounts the field.
    private func refreshAnchor(retriesLeft: Int = CommandPalettePanelController.anchorAttempts) {
        guard let state else { return }
        guard let screenRect = anchor?(), screenRect.width > 0 else {
            // A retry chain can outlive its presentation (Escape and ⌘K again inside the retry
            // window) and resume against the new one. Harmless: it reaches the branch below only
            // when the anchor answers nil, and the new chain re-places once its field appears, so
            // the worst is hiding a list not yet on screen. It would not be harmless if the branch
            // below called `dismiss()`: it would close the new palette.
            guard retriesLeft > 0 else {
                // Logged: a palette with no anchor has nowhere to be, and no other trace.
                Logger.shared.warning("[palette] the Go to field is not in this window — the list "
                    + "is hidden until it comes back")
                // Hidden, not left hanging, and not closed. Either the field never mounted
                // (the panel is already invisible and inert), or it went away while the palette was
                // up: macOS folds a toolbar item behind the overflow chevron when the window is
                // dragged narrow, which would leave a list hanging under nothing.
                //
                // **Not `dismiss()`:** this cannot tell a field that is gone from one that is
                // merely unmeasurable. In full screen AppKit may host the toolbar in a separate
                // window, which `goToFieldItemView` refuses, and dismissing would make ⌘K close
                // itself. `place()` logs the field rect on first placement, so ⌘K in a full-screen
                // window and one `grep` settles it.
                hide()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.anchorRetryInterval) { [weak self] in
                self?.refreshAnchor(retriesLeft: retriesLeft - 1)
            }
            return
        }
        fieldRect = screenRect
        state.listWidth = screenRect.width
        place()
    }

    /// The height the list reported for itself. Arrives from SwiftUI, on its own schedule.
    ///
    /// Ignored until the width is real: `listWidth` is zero until the anchor lands, so the
    /// first height is a zero-wide list's. The report is dropped, never the callback suppressed: a
    /// suppressed `onGeometryChange` that then measures the same number at the real width never
    /// fires again, and the palette would open with no list.
    private func noteContentHeight(_ height: CGFloat) {
        guard let state, state.listWidth > 0, height > 0, height != contentHeight else { return }
        contentHeight = height
        place()
    }

    /// Takes the list off the screen without ending the presentation: the panel goes back to the
    /// inert, invisible state it is built in, and `place()` brings it back once an anchor answers.
    private func hide() {
        guard let panel else { return }
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
    }

    /// Puts the panel under the field, exactly as tall as its content.
    ///
    /// Clamped to the host's bottom edge rather than hanging past it: the palette is part of that
    /// window.
    ///
    /// When the clamp bites it is ugly: `NSHostingView` centres a root view taller than its
    /// bounds, so the first rows are cut as well as the last, and no SwiftUI alignment moves it.
    /// It can't bite in the app: the room under the field is at least the window's content floor,
    /// 560pt (`ContentView.frame(minHeight:)`), and a full list plus its gap is under that.
    /// `theWholeListFitsTheShortestWindowThisAppAllows` holds the sum against the floor.
    ///
    /// The panel ignores the mouse until placed: an unplaced panel is a transparent rectangle
    /// somewhere arbitrary, and would eat clicks over the app.
    private func place() {
        guard let panel, let field = fieldRect, contentHeight > 0 else { return }
        let top = field.minY - GoToResultsPanel.gapBelowField
        let floor = host?.frame.minY ?? (top - contentHeight)
        let height = max(0, min(contentHeight, top - floor))
        guard height > 0 else { return }
        // Logged on each presentation's first placement, since nothing else can see it: the
        // `[palette] panel …` line in `present` reports only the construction rect. The field rect
        // decides the list's width and is measured from a control that animates open, so this is
        // what shows a list drawn narrower than its field. `alphaValue == 0` is the first-placement
        // test, so a window drag doesn't log a line per frame.
        let frame = CGRect(x: field.minX, y: top - height, width: field.width, height: height)
        if panel.alphaValue == 0 {
            Logger.shared.debug("[palette] placed under field=\(field) → \(frame) "
                + "(content wanted \(contentHeight), room \(top - floor))")
        }
        panel.setFrame(frame, display: true)
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
    }

    /// Raises the palette over `host`.
    ///
    /// - Parameter onDismiss: called for every way it can close (the host resigning key, a click
    ///   outside the palette's surface, esc from the field editor, running a route), so the caller
    ///   has one place to put "it is closed now". A path that skipped it would leave a
    ///   chord-suspension flag stuck on.
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
        self.host = host
        self.fieldRect = nil
        self.contentHeight = 0
        self.runRoute = { [weak self] route in
            self?.dismiss()
            onRun(route)
        }

        let content = CommandPalettePanelContent(
            state: state, accent: accent, glassLevel: glassLevel,
            onRun: { [weak self] route in
                // Dismiss first, so the route lands on a window whose toolbar field has already
                // collapsed; a workspace change under an open field leaves the user typing at a
                // list about to be replaced.
                self?.dismiss()
                onRun(route)
            },
            onHeight: { [weak self] height in
                MainActor.assumeIsolated { self?.noteContentHeight(height) }
            })

        // Not the host's frame: the panel is the list, placed and sized by `place()` once the
        // field is found and the list has said how tall it is. It starts at the ceiling width and
        // the list's maximum so SwiftUI has a sane space to lay out in, and is inert to the mouse
        // until placed.
        let panel = CommandPaletteWindow(
            contentRect: CGRect(x: host.frame.minX, y: host.frame.minY,
                                width: GoToFieldMetrics.ceilingWidth,
                                height: GoToResultsPanel.listMaxHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Invisible as well as inert until placed: an unplaced panel still *draws*, and a list
        // rendered at the host's bottom-left corner for a frame reads as a glitch.
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        // No `hidesOnDeactivate`: `addChildWindow` clears that flag, so it would have to be set
        // after it, and it isn't needed. Deactivating the app makes the host resign key, and the
        // observer below dismisses the palette outright.
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        // Its own window, so the main window's root accent does not reach it.
        panel.contentView = NSHostingView(rootView: AnyView(content.nativeControlAccent()))

        // A child window rides the host: it moves, resizes and orders with it, so the list cannot
        // come adrift of the field it hangs from.
        host.addChildWindow(panel, ordered: .above)
        // `orderFront`, never `makeKeyAndOrderFront`: the host keeps key so its toolbar field keeps
        // the caret. `addChildWindow` already orders it above; this is the explicit half.
        panel.orderFront(nil)
        self.panel = panel
        refreshAnchor()

        // Logged because whether the panel takes key cannot be observed from a test host.
        // `active=` sits beside `key=` because a `.nonactivatingPanel` takes key only while its app
        // is active, and `paletteOnLaunchArmed` can raise the palette long after launch, when the
        // user may be in another app.
        //
        // `childWindows` lists only windows parented here, so it always contains the palette.
        // It is not what is on screen above this window: a window merely ordered above is not a
        // child, and AppKit attaches children of its own (sheets, popovers).
        Logger.shared.debug("[palette] panel key=\(panel.isKeyWindow) active=\(NSApp.isActive) "
            + "frame=\(panel.frame) "
            + "host children=\((host.childWindows ?? []).map { String(describing: type(of: $0)) })")

        // Resigning key covers a left-click in another window or another app. It does not cover a
        // click over the host itself (already key) or a right- or middle-click anywhere; the mouse
        // monitor below reaches those. See `clickDismissesThePalette` for the whole boundary.
        //
        // **Observed on the host, never the panel:** the panel cannot become key, so it can never
        // resign it, and an observer on it would never fire.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            hostFrameObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: host, queue: .main) { [weak self, weak panel, weak host] _ in
                    guard panel != nil, host != nil else { return }
                    MainActor.assumeIsolated {
                        // The field moved with the window: re-measure and re-place.
                        //
                        // Twice, and both matter. `didResize` is posted from inside `setFrame`,
                        // before the toolbar re-lays out its items, so the first read can return
                        // the field's old rect; the deferred read sees the new layout. The
                        // immediate one keeps the list with the window during a drag.
                        self?.refreshAnchor()
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.anchorRetryInterval) {
                            self?.refreshAnchor()
                        }
                    }
                })
        }
        // Clicks away, dismissing before the event is dispatched rather than after key has moved.
        // The whole of click-away over the app itself: a click on a pane is a click on a window
        // that is already key, and nothing else would notice it. Not a duplicate of the resign
        // observer: a right- or middle-click moves no key. What it must not dismiss on (the Go-to
        // field) is on `clickDismissesThePalette`.
        addMonitor(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // Asked of `self`, not a captured panel and rect: both are per-presentation, and a
            // monitor outliving its presentation would measure against a gone window and field.
            guard let self,
                  self.clickDismissesThePalette(clickedWindow: event.window,
                                                at: Self.screenPoint(of: event))
            else { return event }
            // The event is returned, never swallowed: the click that dismisses the palette is also
            // the click the user meant for whatever is under it.
            self.dismiss()
            return event
        }
        // **No ⌘K key monitor:** the host keeps key, so the menu item (a `@FocusedValue` from the
        // host) fires throughout, and ⌘K on an open field selects what is there, as in any other
        // Mac search field. A monitor would swallow the chord before the menu item saw it.
    }

    /// Installs a local monitor and tracks its token, so `dismiss()` has one bag to drain.
    ///
    /// The `guard let` is about the bag's element type. The API returns `Any?`, and an `Any?`
    /// appended to an `[Any]` bag becomes an `Optional<Any>` element; a `nil` one bridges to
    /// `NSNull`, and `NSEvent.removeMonitor` on that traps (`-[NSNull invalidate]: unrecognized
    /// selector`). Unwrapping first keeps the bag drainable. A failed install would silently stop
    /// the palette answering those events, so it is logged.
    private func addMonitor(matching mask: NSEvent.EventTypeMask,
                            handler: @escaping (NSEvent) -> NSEvent?) {
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler) else {
            Logger.shared.warning("[palette] event monitor for mask \(mask.rawValue) was not installed — "
                + "the palette will not respond to those events")
            return
        }
        eventMonitors.append(monitor)
    }

    /// The click rule, asked of the live presentation: the one call the monitor makes, so the rule
    /// the tests pin and the rule the app runs cannot come apart.
    ///
    /// The field is asked for live, not read from `fieldRect`. That cached rect is refreshed
    /// only when the window moves or resizes, but the pill grows into the field over 120ms when ⌘K
    /// opens, so it can be a frame from mid-animation, and a click on the part outside it would
    /// close the palette instead of moving the caret. `fieldRect` is the fallback once the anchor
    /// stops answering.
    func clickDismissesThePalette(clickedWindow: NSWindow?, at screenPoint: CGPoint?) -> Bool {
        guard let panel else { return false }
        return Self.clickDismissesThePalette(clickedWindow: clickedWindow, palette: panel,
                                             at: screenPoint, field: anchor?() ?? fieldRect)
    }

    /// Where a mouse event happened, in screen coordinates (the space `fieldRect` is in). An event
    /// with no window of this app's can't be converted; `NSEvent.mouseLocation` is the pointer when
    /// the monitor runs, which for a mouse-down is the same point.
    static func screenPoint(of event: NSEvent) -> CGPoint {
        guard let window = event.window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    /// Whether a mouse-down outside the palette should dismiss it.
    ///
    /// Two things are the palette: the panel, and the toolbar's Go-to field, which lives in the
    /// host window. Asking only "was the panel clicked" would make a click on the field (to move
    /// the caret, or on its clear button) close the palette and wipe the query. So the rule is the
    /// palette's surface: the panel by identity, and the field by the rect the panel is anchored
    /// to. `field` is the whole toolbar item (magnifier, text and keycap), what a person aims at.
    ///
    /// Everything else dismisses, returning the event: another window of this app (Keyboard
    /// Shortcuts, Activity and other `Window` scenes, an open/save panel; Settings and Help are
    /// in-window overlays under the panel), and the host's own content, title band and toolbar.
    ///
    /// Probably not redundant with the resign-key observer. A left-click in another window
    /// makes it key, so the observer would cover it a turn later. A right- or middle-click is
    /// believed not to change the key window, which would make this monitor the only dismissal for
    /// two of its three masks. Unverified: before deleting the monitor, log `event.window` and
    /// `NSApp.keyWindow` here and right-click another window.
    ///
    /// A local monitor does not see events consumed by nested tracking loops (control or menu
    /// tracking, window dragging; `NSEvent.h`), so the palette presumably stays up over a
    /// pulled-down menu; not observed.
    ///
    /// A `nil` window (a click this app can't attribute) or a `nil` `field` (no anchor yet) counts
    /// as outside: the safe direction, since the alternative is a palette that survives a click it
    /// cannot see.
    static func clickDismissesThePalette(clickedWindow: NSWindow?, palette: NSWindow,
                                         at screenPoint: CGPoint?, field: CGRect?) -> Bool {
        if clickedWindow === palette { return false }
        if let screenPoint, let field, field.contains(screenPoint) { return false }
        return true
    }

    /// Idempotent, because several things call it and two can race (esc arriving as the host
    /// resigns key, say).
    func dismiss() {
        state = nil
        anchor = nil
        runRoute = nil
        host = nil
        fieldRect = nil
        contentHeight = 0
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
    let onHeight: (CGFloat) -> Void

    var body: some View {
        GoToResultsPanel(
            rows: state.rows,
            query: state.query,
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
            accent: accent,
            glassLevel: glassLevel,
            width: state.listWidth,
            onRun: onRun,
            onHeight: onHeight)
    }
}
