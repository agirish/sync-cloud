import AppKit
import Design

/// The pinned panel's place in the main window: it holds the hosting view, and it is the
/// keyboard's anchor for everything the floating panel's window did for the keys.
///
/// The floating panel is a window of its own, so its keys were its own: its typing, its undo,
/// its ⌘W, Esc and ⌥Space. Pinned, the panel is inside the main window, and every one of those
/// would otherwise reach the file list or the window. So the column answers them, wherever in it
/// the keyboard is, and takes the keyboard on any click inside it so Space, the arrows and Delete
/// never act on files by surprise. Modelled on Edit's `EditorUndoAnchorView`.
final class AskClaudeColumnView: NSView, NSUserInterfaceValidations {
    weak var controller: AskClaudeWindowController?

    /// The window is busy: the column stays in place and takes nothing.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            alphaValue = isPaused ? 0.5 : 1
            // The keyboard never stays in a column that is paused, and a question being spoken stops.
            if isPaused {
                onGone()
                if holdsKeyboard { window?.makeFirstResponder(nil) }
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isPaused ? nil : super.hitTest(point) }

    // MARK: Hosting

    /// Takes the hosting view in. `addSubview` removes it from wherever it was, as one move.
    func adopt(_ host: NSView) {
        guard host.superview !== self else { return }
        addSubview(host, positioned: .below, relativeTo: tint)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: The keyboard

    /// What the panel does with ⌥Space and Esc while a question is spoken, set by its talk hook.
    var onTalkKey: ((AskClaudeTalkKey) -> Bool)?
    /// Esc with nothing spoken: stops an edit. True when it did something.
    var onEscape: (() -> Bool)?
    /// The panel is going quiet (paused, or its window gone): a spoken question stops.
    var onGone: () -> Void = {}

    /// A view takes the keyboard when clicked on its empty parts, so the file list never keeps it
    /// while the pointer is in the column.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }
    override func isAccessibilityElement() -> Bool { false }

    /// Nothing typed at the column itself does anything: Space, the arrows, Delete and type-to-select
    /// stop here instead of reaching the window and its file list.
    override func keyDown(with event: NSEvent) {}

    /// The column in `responder`'s chain, if it is inside one.
    static func enclosing(_ responder: NSResponder?) -> AskClaudeColumnView? {
        var current = responder
        while let candidate = current {
            if let column = candidate as? AskClaudeColumnView { return column }
            current = (candidate as? NSView)?.superview ?? candidate.nextResponder
        }
        return nil
    }

    /// The column holding `window`'s keyboard, if any.
    @MainActor
    static func holder(in window: NSWindow?) -> AskClaudeColumnView? {
        enclosing(window?.firstResponder)
    }

    var holdsKeyboard: Bool { Self.enclosing(window?.firstResponder) === self }

    private var monitors: [Any] = []
    private var observation: NSKeyValueObservation?
    private let tint = AskClaudeColumnTint()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(tint)
        NotificationCenter.default.addObserver(forName: .NSUndoManagerDidCloseUndoGroup, object: typingUndo, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.typingChangedAt = Date() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func layout() {
        super.layout()
        tint.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        observation?.invalidate()
        observation = nil
        guard let window else { return }
        // Keys first, for Esc and ⌥Space: caught ahead of the field editor, as the floating
        // window's `sendEvent` did, where ⌥Space types a non-breaking space and Esc does nothing.
        if let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(keyDown: event) ?? event }
        }) { monitors.append(key) }
        // A click anywhere in the column leaves the keyboard in it.
        if let click = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.noteClick(event) }
            return event
        }) { monitors.append(click) }
        observation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.tint.isShown = self?.holdsKeyboard == true }
        }
    }

    deinit {
        monitors.forEach { NSEvent.removeMonitor($0) }
    }

    /// Esc and ⌥Space while the keyboard is here. Esc stops a spoken question, else an edit, else
    /// nothing: it never closes the pinned panel. Text being composed (an IME) is left alone.
    func handle(keyDown event: NSEvent) -> NSEvent? {
        guard event.window === window, !isPaused, holdsKeyboard,
              let key = AskClaudeTalkKey(event),
              (window?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return event }
        if onTalkKey?(key) == true { return nil }
        if key == .cancel {
            _ = onEscape?()
            return nil
        }
        return event
    }

    /// After the click is handled, the keyboard is in the column if nothing in it took it.
    private func noteClick(_ event: NSEvent) {
        guard event.window === window, !isPaused, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, !self.isPaused, !self.holdsKeyboard else { return }
            window.makeFirstResponder(self)
        }
    }

    // MARK: Undo

    /// Typing's own steps, apart from the file operations' that the window's stack holds. A text
    /// field inside asks its enclosing views for its stack, so ⌘Z in the box never reaches a move.
    private let typingUndo = UndoManager()
    override var undoManager: UndoManager? { typingUndo }
    private var typingChangedAt = Date.distantPast

    private var settings: AskClaudeSettingsUndo? { AskClaudePanelWindow.settingsUndo() }

    /// Whether Undo belongs to the draft: the box holds text with a step to take, and it is newer
    /// than the latest settings change. Steps come back in the order they were made, so a setting
    /// applied after typing is undone first.
    private var typingTakesUndo: Bool {
        guard let text = window?.firstResponder as? NSTextView, !text.string.isEmpty, typingUndo.canUndo else { return false }
        return Self.typingIsNewer(typingChangedAt: typingChangedAt, settingsLatest: settings?.undoSteps.last?.recordedAt)
    }

    /// Typing goes first when it is at least as new as the latest settings change.
    static func typingIsNewer(typingChangedAt: Date, settingsLatest: Date?) -> Bool {
        typingChangedAt >= (settingsLatest ?? .distantPast)
    }

    private var typingTakesRedo: Bool {
        guard let text = window?.firstResponder as? NSTextView, !text.string.isEmpty, typingUndo.canRedo else { return false }
        return !(settings?.canRedo ?? false)
    }

    @objc func undo(_ sender: Any?) {
        if !typingTakesUndo, let settings, settings.canUndo { settings.undo() } else { typingUndo.undo() }
    }

    @objc func redo(_ sender: Any?) {
        if !typingTakesRedo, let settings, settings.canRedo { settings.redo() } else { typingUndo.redo() }
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        let menuItem = item as? NSMenuItem
        switch item.action {
        case #selector(undo(_:)):
            if !typingTakesUndo, let settings, let title = settings.undoTitle {
                menuItem?.title = title
                return true
            }
            menuItem?.title = typingUndo.undoMenuItemTitle
            return typingUndo.canUndo
        case #selector(redo(_:)):
            if !typingTakesRedo, let settings, let title = settings.redoTitle {
                menuItem?.title = title
                return true
            }
            menuItem?.title = typingUndo.redoMenuItemTitle
            return typingUndo.canRedo
        default:
            return true
        }
    }

    /// Writes into the column's typing stack, for the tests: a change as typing would register it.
    func registerTypingStepForTesting(_ name: String) {
        typingUndo.beginUndoGrouping()
        typingUndo.registerUndo(withTarget: self) { _ in }
        typingUndo.setActionName(name)
        typingUndo.endUndoGrouping()
    }
}

/// A soft outline on the column while it holds the keyboard, so ⌘W and Esc are never a guess.
private final class AskClaudeColumnTint: NSView {
    var isShown = false { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard isShown else { return }
        // The app's accent, never the system's.
        NSColor(LiquidGlassHue.stored().accentColor).withAlphaComponent(0.28).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}
