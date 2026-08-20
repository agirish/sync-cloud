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
// - **Keyboard.** Originally: the panel becomes key, so its field is the first responder and the
//   pane's field cannot be. **§7 inverted this and the inversion is load-bearing** — the field
//   moved to the host's toolbar, so the panel must now REFUSE key or taking it would pull the
//   caret out of the field being typed into. `CommandPaletteWindow` below carries the whole
//   argument; do not "restore" `canBecomeKey` to `true` on the strength of this paragraph.
// - **Clicking away.** Originally split across three mechanisms, of which the first was the panel
//   spanning the host's whole frame so that clicks over the host landed on its own scrim. **That
//   half is gone as of 2026-08-19**, because with the dim removed it meant the palette ate every
//   click over the app instead of letting it through (measured: the panel's frame was the host's
//   exactly, and its content claimed a hit at the host's far corner). The panel is sized to its
//   list now, so what remains is the mouse monitor — which dismisses and **returns** the event, so
//   the click also does what the user meant — plus resigning key for another app or another window
//   of this one. `clickDismissesThePalette` carries the boundary and the corrections; read it
//   before changing any half.
// - **There is no scrim any more.** The panel drew a dimmed backdrop with a card floating near the
//   top — a view since deleted — until §7 replaced that with `GoToResultsPanel`: **no dim**, and a
//   list hung under the toolbar field rather than centred. The transparent hit-testing fill
//   outlived the dim by one step and was removed with it: a window you can see through is a window
//   you expect to click. The panel is now exactly its list, placed under the field by
//   `refreshAnchor`/`place`.
//
//   **What that leaves outside the panel is not all "the window underneath", and the first
//   version of this sentence said it was.** The toolbar's Go-to field is part of the palette and
//   lives in the HOST window, so a rule that reads "which window was clicked" calls it the window
//   underneath and dismisses on it — which is exactly what shipped for a day, taking the query and
//   the field's own clear button with it. The palette's surface is two objects in two windows;
//   `clickDismissesThePalette` is where that is reconciled.

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
    /// How wide the list draws, which is the field's width. Published rather than passed once
    /// because the field's width is the row's to decide and changes with every window resize.
    /// Zero until the field has been found — the panel draws nothing at that width.
    @Published var listWidth: CGFloat = 0

    let index: PaletteIndex
    /// What is at a typed path, for **Go to Folder** — the one thing the router cannot answer from
    /// the snapshot, because the user has not typed it yet. Held here rather than on the index
    /// because a closure is neither `Equatable` nor `Sendable` and the index is both.
    ///
    /// Optional, and `nil` means no path rows: a default that answered "yes, it is there" would be
    /// a fixture whose expected value is its own fallback. The app passes a real one and
    /// `theHostGivesTheRouterARealPathProbe` is what says so.
    let pathProbe: PalettePathProbe?

    init(index: PaletteIndex, pathProbe: PalettePathProbe? = nil) {
        self.index = index
        self.pathProbe = pathProbe
        self.selection = PaletteSelection.initialIndex(in: PaletteRouter.rows(query: "", index: index))
    }

    /// The last path asked about and what was there — **a one-entry memo, and it is not a
    /// micro-optimisation.**
    ///
    /// Measured 2026-08-19 by counting probe calls through a live presentation: one keystroke cost
    /// **two** `stat`s and one ↓ cost **two more**. `rows` is a computed property read twice per
    /// change — once by `setQuery` to re-seat the selection, once by the SwiftUI body — and an
    /// arrow key re-ran the whole router, and its probe, against a query that had not changed at
    /// all. With the memo a keystroke costs one and an arrow key costs none.
    ///
    /// Caching a filesystem answer for the life of a presentation is the rule this palette already
    /// follows rather than an exception to it: the index is snapshotted at open and never re-read,
    /// because the answer to "what is there" cannot honestly change inside one palette session.
    private var lastProbed: (path: String, kind: PathKind)?

    private func probeKind(_ path: String) -> PathKind {
        if let lastProbed, lastProbed.path == path { return lastProbed.kind }
        // `.missing` is unreachable: this is only reached through the closure below, which exists
        // only when `pathProbe` does.
        let kind = pathProbe?(path) ?? .missing
        lastProbed = (path, kind)
        return kind
    }

    var rows: [PaletteRow] {
        PaletteRouter.rows(query: query, index: index,
                           probe: pathProbe == nil ? nil : { [self] in probeKind($0) })
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

    /// ↩ from the field editor — **through the same pure rule a click takes**, never by reading the
    /// row here.
    func runSelection() {
        guard let state, let route = PaletteSelection.chosen(at: state.selection, in: state.rows)
        else { return }
        runRoute?(route)
    }

    /// Re-reads where the field is, and places the panel under it.
    ///
    /// **The panel is the list, not the window.** It used to be sized to the host's whole frame so
    /// a scrim inside it could dim the window; with the dim gone that only meant the palette
    /// swallowed every click over the app (measured 2026-08-19 — the content claimed a hit at the
    /// host's far corner). Sized to the list, a click anywhere else lands on the window under it
    /// and the mouse monitor dismisses on the way past, which is what that monitor was written to
    /// do.
    ///
    /// - Parameter retriesLeft: the field is a SwiftUI toolbar item that mounts a turn or two
    ///   after the flag that opens it, so the first look routinely finds nothing. Retried on the
    ///   main queue rather than measured once, and the panel stays out of the way until it lands.
    ///
    ///   **A frame apart, and not six bare `async` hops.** Measured 2026-08-19: blocks queued from
    ///   inside a main-queue drain run in that same drain, so six "retries" were six calls in one
    ///   runloop turn — all of them ahead of the SwiftUI update that mounts the field. The palette
    ///   then logged `the Go to field never appeared` and put an invisible panel over the window
    ///   with no list in it. Spacing the attempts is what gives the runloop the turn this is
    ///   waiting for.
    private func refreshAnchor(retriesLeft: Int = CommandPalettePanelController.anchorAttempts) {
        guard let state else { return }
        guard let screenRect = anchor?(), screenRect.width > 0 else {
            // **A chain outliving its own presentation was chased on 2026-08-20 and is not a
            // defect — recorded so the next reviewer does not re-derive it.** Escape and ⌘K again
            // inside the retry window, and the old chain does resume against the new presentation's
            // state and anchor. It cannot hurt it: a chain only reaches the branch below when the
            // anchor answers *nil*, and the new presentation's own chain re-places the moment its
            // field appears — so the worst it can do is hide a list that was not on screen yet, and
            // put a spurious line in the log. It was a real bug while this branch called `dismiss()`
            // (it closed the second palette on the first one's leftover budget); `6282ad7d` changing
            // it to `hide()` removed that, which is a second reason not to change it back.
            guard retriesLeft > 0 else {
                // Said out loud: a palette with no anchor is a palette with nowhere to be, and it
                // has no other trace.
                Logger.shared.warning("[palette] the Go to field is not in this window — the list "
                    + "is hidden until it comes back")
                // **Hidden, not left hanging — and not closed either.** Two states reach here. The
                // field never mounted, which leaves an invisible inert panel: hiding is what it
                // already was. Or the field went away while the palette was up — macOS folds a
                // toolbar item behind the overflow chevron when the window is dragged narrow, so
                // `anchor` starts answering nil and the panel stayed exactly where it was last
                // placed, a list hanging under nothing, following a field no longer on the row.
                // That is the defect; hiding fixes it.
                //
                // **`dismiss()` was written here first, and it claims more than this can know.**
                // Closing the palette is right when the field is genuinely gone and wrong when it
                // is merely unmeasurable — and this cannot tell those apart. The case that decides
                // it is full screen, where AppKit is understood to move a window's toolbar into a
                // window of its own; `goToFieldItemView` requires the host, so it would answer nil
                // for a field sitting in plain sight, and dismissing would make ⌘K close itself.
                // **That premise could not be verified** (a bare binary cannot enter full screen,
                // and no test host can), so the behaviour is the one that is never worse than what
                // shipped. `place()` logs the field rect on first placement; ⌘K in a full-screen
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
    /// **Ignored until the width is real.** `listWidth` is zero until the anchor lands, and the
    /// list is laid out at that width in the meantime — so the first height to arrive is the height
    /// of a zero-wide list, and taking it would place the panel at a height measured for something
    /// nobody is going to see. The report is dropped rather than the callback suppressed: a
    /// suppressed `onGeometryChange` that then measures the same number at the real width never
    /// fires again, and the palette would open with no list at all.
    private func noteContentHeight(_ height: CGFloat) {
        guard let state, state.listWidth > 0, height > 0, height != contentHeight else { return }
        contentHeight = height
        place()
    }

    /// Takes the list off the screen without ending the presentation — the panel goes back to the
    /// inert, invisible state it is built in, and `place()` brings it back the moment an anchor
    /// answers again.
    private func hide() {
        guard let panel else { return }
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
    }

    /// Puts the panel under the field, exactly as tall as its content.
    ///
    /// Clamped to the host's own bottom edge rather than hanging past it — the palette is part of
    /// that window, not a thing beside it.
    ///
    /// **What the clamp does when it bites is ugly, and the reason it is left alone is that it
    /// cannot.** A panel shorter than its content does not crop the bottom of the list: measured
    /// 2026-08-19 with a colour ladder, `NSHostingView` **centres** a root view whose ideal height
    /// exceeds its bounds, so the first rows go as well as the last — and none of `.frame(maxHeight:
    /// .infinity, alignment: .top)`, a trailing `Spacer`, a top-aligned `ZStack` or `.clipped()`
    /// moves it, because the placement is AppKit's and not SwiftUI's.
    ///
    /// It is unreachable in the shipped app **by 97pt, measured**. The field is a toolbar item, so
    /// its bottom edge is never below the content's top edge — which puts the room under it at no
    /// less than the window's content floor, 560pt (`ContentView.frame(minHeight:)`), without
    /// needing to know how tall the toolbar band is. A full list measures 463pt (`listMaxHeight`
    /// 420, plus the divider and the ↑↓ ↩ esc footer) and wants 6pt of gap above it.
    /// `theWholeListFitsTheShortestWindowThisAppAllows` holds that sum against the floor read out
    /// of `ContentView`'s own source: raise `listMaxHeight` to 600 and it fails naming 643 against
    /// 560, which is the mutation it was written against.
    ///
    /// **The panel ignores the mouse until it has been placed**: an unplaced panel is a
    /// transparent rectangle sitting somewhere arbitrary, and one of those over the app eats clicks
    /// exactly the way the scrim used to.
    private func place() {
        guard let panel, let field = fieldRect, contentHeight > 0 else { return }
        let top = field.minY - GoToResultsPanel.gapBelowField
        let floor = host?.frame.minY ?? (top - contentHeight)
        let height = max(0, min(contentHeight, top - floor))
        guard height > 0 else { return }
        // **Logged on the first placement of each presentation, because this is the half of the
        // surface nothing can see.** The existing `[palette] panel …` line is stamped in `present`
        // and reports the CONSTRUCTION rect (the ceiling width by the list's maximum, at the host's
        // origin) — 29 of them in `~/sync-cloud.log` all read `620.0, 420.0`, which says nothing
        // about where the list ended up or how wide the field really was. The field rect is the
        // interesting number: it decides the list's width, and it is measured once, from a control
        // that animates open over 120ms. If ⌘K ever draws a list narrower than its field, this line
        // is what says so. `alphaValue == 0` is the first-placement test — no extra state, and it
        // keeps a window drag from stamping a line per frame.
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
                // Dismiss FIRST, so the routing that follows lands on a window whose toolbar field
                // has already collapsed — a route that changes workspace underneath an open field
                // leaves the user typing at a list that is about to be replaced.
                self?.dismiss()
                onRun(route)
            },
            onHeight: { [weak self] height in
                MainActor.assumeIsolated { self?.noteContentHeight(height) }
            })

        // **Not the host's frame.** The panel is the list; it is placed and sized by `place()`
        // once the field has been found and the list has said how tall it is. It starts at the
        // ceiling width and the list's own maximum so SwiftUI has a sane space to lay out in, and
        // **inert to the mouse** until placed — see `place()`.
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

        // A child window rides the host: it moves, resizes and orders with it, so the list cannot
        // come adrift of the field it hangs from.
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

        // **Resigning key covers a left-click in another window, and another app.** It does not
        // cover a click over the host itself — the host is *already* key, so clicking its content
        // moves no key at all — and it does not cover a right- or middle-click anywhere. The mouse
        // monitor below is the only thing that reaches those, which since `963faf4b` includes every
        // click over the app's own panes. See `clickDismissesThePalette` for the whole boundary and
        // for which parts of it are still unverified.
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
                    guard panel != nil, host != nil else { return }
                    MainActor.assumeIsolated {
                        // The field moved with the window — re-measure and re-place. The panel is
                        // no longer a copy of the host's frame, so there is nothing else to mirror.
                        //
                        // **Twice, and the second one is not belt and braces.** `didResize` is
                        // posted from inside `setFrame`, before the toolbar has re-laid out its
                        // items, so this first read can still answer with the field's *old* rect —
                        // which would leave the list at the width and offset it had before the
                        // drag. The deferred read is the one that sees the new layout; the
                        // immediate one is what keeps the list with the window during a drag,
                        // where nothing about the toolbar is changing.
                        self?.refreshAnchor()
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.anchorRetryInterval) {
                            self?.refreshAnchor()
                        }
                    }
                })
        }
        // Clicks away, dismissing before the event is dispatched rather than after key has moved.
        // **Since `963faf4b` this is the whole of click-away over the app itself**, not just the
        // other-window case: the panel no longer covers the host, so a click on a pane is a click
        // on a window that is already key and nothing else would notice it. It was never deletable
        // as a duplicate of the resign observer either — a right- or middle-click moves no key, so
        // for two of these three masks this is the only dismissal path. What it can and cannot
        // reach — including the Go-to field, which it must NOT dismiss on — is written out on
        // `clickDismissesThePalette`.
        addMonitor(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // Asked of `self`, not of a captured panel and rect: both are per-presentation, and a
            // monitor outliving its presentation would otherwise measure a click against a window
            // that is no longer on screen and a field that has since moved.
            guard let self,
                  self.clickDismissesThePalette(clickedWindow: event.window,
                                                at: Self.screenPoint(of: event))
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

    /// The click rule, asked of the live presentation — **the one call the monitor makes**, so the
    /// rule the tests pin and the rule the app runs cannot come apart.
    ///
    /// **The field is asked for LIVE rather than read from `fieldRect`.** That cached rect is only
    /// refreshed when the window moves or resizes, and the field moves without either: the pill
    /// grows into the field over 120ms when ⌘K opens, so the rect captured by the first anchor that
    /// answered can be a frame from the middle of that animation. Placement can live with being a
    /// frame behind; a click rule cannot, because the part of the field outside a stale rect is
    /// precisely where a click would close the palette instead of moving the caret. One toolbar
    /// walk per mouse-down while the palette is up is not a cost worth caching against.
    ///
    /// `fieldRect` is still the fallback: an anchor that has stopped answering means the field is
    /// going away and the palette with it, and until it does, the last place it was is a better
    /// guess than nothing.
    func clickDismissesThePalette(clickedWindow: NSWindow?, at screenPoint: CGPoint?) -> Bool {
        guard let panel else { return false }
        return Self.clickDismissesThePalette(clickedWindow: clickedWindow, palette: panel,
                                             at: screenPoint, field: anchor?() ?? fieldRect)
    }

    /// Where a mouse event happened, in screen coordinates — the space `fieldRect` is in.
    ///
    /// An event with no window of this app's is one this app cannot convert, and
    /// `NSEvent.mouseLocation` is where the pointer is at the moment the monitor runs, which for a
    /// mouse-down is the same point.
    static func screenPoint(of event: NSEvent) -> CGPoint {
        guard let window = event.window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    /// Whether a mouse-down **outside the palette** should dismiss it.
    ///
    /// **Two things are the palette, and it took a regression to learn the second.** The panel is
    /// one; the toolbar's Go-to field is the other, and it lives in the HOST window. While the
    /// panel was sized to the host's whole frame, every click over the app — the field included —
    /// was attributed to the panel and this rule answered `false` for all of it. `963faf4b` sized
    /// the panel to its list, which is what stopped the palette eating clicks meant for the panes,
    /// and in the same move made a click on the field a click on *the host*: `clickedWindow !==
    /// palette` was suddenly true for the control the user was typing into, so touching the field
    /// to move the caret — or pressing its own clear button — closed the palette and wiped the
    /// query. The clear button could not be used at all.
    ///
    /// So the rule is about the palette's SURFACE, not about one window: the panel by identity,
    /// and the field by the rect the panel is already anchored to. `field` is the whole toolbar
    /// item — magnifier, text and keycap — because that is what the anchor measures and what a
    /// person aims at.
    ///
    /// ## What this does NOT cover
    ///
    /// The reachable job of the rest of it is **another window of this app** — Keyboard Shortcuts,
    /// Activity Log and Sync History are real `Window` scenes (Settings and Help are in-window
    /// overlays and are *under* the panel, not other windows), plus an open/save panel — and,
    /// since `963faf4b`, the host's own content, title band and toolbar: those now land on the
    /// host and dismiss, **returning the event**, which is the click-away the user means.
    ///
    /// **Probably not redundant with the resign-key observer, and the difference is the mask.** A
    /// left-click in another window makes it key, so the observer would have covered it and this
    /// monitor merely gets there first — synchronously during dispatch, where the observer is
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
    /// `nil` for the window is a click this app cannot attribute to a window of its own; treating
    /// it as outside is the safe direction, since the alternative is a palette that survives a
    /// click it cannot see. A `nil` `field` is a palette whose anchor has not landed yet, which is
    /// the same direction: nothing to spare.
    static func clickDismissesThePalette(clickedWindow: NSWindow?, palette: NSWindow,
                                         at screenPoint: CGPoint?, field: CGRect?) -> Bool {
        if clickedWindow === palette { return false }
        if let screenPoint, let field, field.contains(screenPoint) { return false }
        return true
    }

    /// Idempotent, because six different things call it and two of them can race — esc arriving
    /// as the panel is already resigning key, say.
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
