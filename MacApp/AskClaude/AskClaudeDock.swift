import AppKit
import SwiftUI
import Design
import Events

// MARK: - Why the column is a view in the window and not a window of its own
//
// Ask Claude used to be a child window, because a SwiftUI overlay over the panes' AppKit tables was
// not reliably hit above them: a composer could lose the caret, and a Delete meant for the draft
// could reach the file list. The column is now an AppKit view hosted in the main window, and
// `OverlayHitTestSpikeTests` walks the hit-test over a real `NSTableView`: the column, and a SwiftUI
// drawer over a pane, take the click, and the table keeps the clicks outside them. The keys a window
// of its own used to answer (typing, undo, ⌘W, Esc, ⌥Space) are `AskClaudeColumnView`'s.

/// The panel's own keys for talking.
enum AskClaudeTalkKey: Equatable {
    /// ⌥Space: start listening, or send what was said. A held key's repeats are taken and do
    /// nothing, so holding it doesn't start and stop over and over.
    case toggle(isRepeat: Bool)
    /// Esc.
    case cancel

    init?(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        switch event.keyCode {
        case 49 where modifiers == .option: self = .toggle(isRepeat: event.isARepeat)
        case 53 where modifiers.isEmpty: self = .cancel
        default: return nil
        }
    }
}

/// Holds the one hosting view that carries the panel, and puts it in the window's column.
///
/// The panel's draft, a running voice and an open card live in the hosting view, so it is built once
/// and kept while the column is open. The column's view (`AskClaudeColumnView`) adopts it; closing
/// the column drops it.
@MainActor
final class AskClaudeDock {
    private var host: NSHostingView<AnyView>?
    /// The column's view, set by the column slot while it is on screen. The hosting view goes in it.
    weak var columnView: AskClaudeColumnView? {
        didSet { if columnView !== oldValue { adoptIntoColumn() } }
    }
    /// The chat's settings steps, for Undo with the keyboard in the column. One chat for the app, so
    /// one provider: set when the panel is built.
    static var settingsUndo: @MainActor () -> AskClaudeSettingsUndo? = { nil }

    /// The main window is busy (Settings, Help, a sheet, a question): the column stays in place and
    /// takes nothing.
    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            columnView?.isPaused = isSuspended
        }
    }

    /// What closes the panel, for ⌘W with the keyboard in the column.
    private var closePanel: () -> Void = {}
    func closeColumn() { closePanel() }

    /// Gives the hosting view its content, building it the first time, and puts it in the column.
    func show(_ content: AnyView, onClose: @escaping () -> Void = {}) {
        let root = AnyView(content.nativeControlAccent().appFontSizeFromSettings())
        closePanel = onClose
        let host = self.host ?? makeHost(content)
        host.rootView = root
        self.host = host
        columnView?.isPaused = isSuspended
        adoptIntoColumn()
    }

    /// The one hosting view. Its own view, so the main window's root accent and text size don't
    /// reach it: `show` wraps the content in both.
    private func makeHost(_ content: AnyView) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(content.nativeControlAccent().appFontSizeFromSettings()))
        host.translatesAutoresizingMaskIntoConstraints = false
        // The column's size comes from the layout; the content mustn't size it as well.
        host.sizingOptions = []
        return host
    }

    private func adoptIntoColumn() {
        guard let columnView, let host else { return }
        columnView.adopt(host)
        columnView.isPaused = isSuspended
    }

    /// Gives an open panel's text box the keyboard.
    func focus() {
        if let column = columnView, let window = column.window, !isSuspended { window.makeFirstResponder(column) }
    }

    func hide() {
        guard host != nil else { return }
        host?.removeFromSuperview()
        host = nil
        Logger.shared.debug("[askclaude] panel hidden")
    }
}

/// An invisible view in the main window that feeds the panel its content and watches for sheets: SwiftUI
/// updates it with the panel's content, and AppKit tells it when a sheet comes or goes (a Save sheet, a
/// PDF tool), which SwiftUI does not redraw for. A sheet pauses the column until it ends.
struct AskClaudeDockAnchor: NSViewRepresentable {
    let dock: AskClaudeDock
    let isOpen: Bool
    /// The main window is busy; the column pauses until it isn't.
    var isSuspended = false
    let content: AnyView
    var onClose: () -> Void = {}
    /// This window's own edge is being dragged (true) or let go (false). Another window's resize is
    /// not this one's.
    var onLiveResize: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.dock = dock
        view.onLiveResize = onLiveResize
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.dock = dock
        view.onLiveResize = onLiveResize
        view.wanted = isOpen ? (content, onClose) : nil
        view.busy = isSuspended
        view.sync()
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.dock?.hide()
    }

    final class AnchorView: NSView {
        weak var dock: AskClaudeDock?
        /// What to show, kept so a view that reaches its window late still opens the panel.
        var wanted: (content: AnyView, onClose: () -> Void)?
        var busy = false
        var onLiveResize: (Bool) -> Void = { _ in }
        /// A drag of the window's edge is under way. Left behind by a move to another window, it is
        /// let go, so the room rule is never frozen by a resize this view can no longer see end.
        private var liveResizing = false {
            didSet { if liveResizing != oldValue { onLiveResize(liveResizing) } }
        }
        private var sheetBeginning = false
        private var observers: [NSObjectProtocol] = []

        // Never in the way: clicks here are the panes'.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func sync() {
            guard let dock else { return }
            // Sheets are read here, live: SwiftUI doesn't redraw when one comes or goes.
            dock.isSuspended = busy || window?.attachedSheet != nil || sheetBeginning
            if let wanted, window != nil {
                dock.show(wanted.content, onClose: wanted.onClose)
            } else if wanted == nil {
                dock.hide()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            liveResizing = false
            guard let window else { dock?.hide(); return }
            let center = NotificationCenter.default
            // A sheet on the main window pauses the column: at once as it begins (it may not be
            // attached yet), and checked again a turn after one ends, once it has really gone.
            observers.append(center.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sheetBeginning = true
                    self?.sync()
                }
            })
            observers.append(center.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sheetBeginning = false
                    DispatchQueue.main.async { self?.sync() }
                }
            })
            // This window's edge only: nothing switches while it is dragged, and what it left is
            // decided the moment it is let go.
            observers.append(center.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.liveResizing = true }
            })
            observers.append(center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.liveResizing = false }
            })
            sync()
        }
    }
}
