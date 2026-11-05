import AppKit
import SwiftUI
import Design
import Events

// MARK: - Why the panel is a window and not an overlay
//
// The panes are real AppKit tables in the hosting view, and a SwiftUI overlay drawn above them is
// not reliably hit above them: an overlay composer can lose the caret and its selection, and a
// Delete meant for the draft can reach the file list underneath and offer to trash the selected
// folder. The ⌘K palette has the same constraint (`CommandPalettePanel.swift`).
//
// A child window settles it by construction: its own views take its clicks, its field takes the
// keyboard when it is key, and it rides the main window when that moves.

/// The panel's window: borderless, never main, and able to become key so the composer can hold the
/// caret, unlike the palette's, whose field lives in the host's toolbar.
///
/// The window's shortcuts still work while it is key. The menu's commands read the main window's
/// focused values, which a key panel turns off, so ⌘K, ⌘[ and ⌘1–4 would go dead with the caret in
/// the composer. A chord nothing here handles goes to the main window, made key first; the
/// text-editing chords stay, so ⌘C and ⌘V work on the draft.
final class AskClaudePanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onClose: () -> Void = {}

    /// What the composer's field editor answers: cut, copy, paste, select all, undo and redo, and
    /// ⌘W, which closes the panel (`performClose`) rather than a tab behind it.
    static let ownChords: Set<String> = ["x", "c", "v", "a", "z", "w"]

    /// Whether a ⌘-chord goes to the main window. Only a printed key (a letter, digit or mark)
    /// that isn't one of `ownChords`: ⌘⌫, ⌘-arrows, Home, End and the rest are the field's own
    /// editing keys, and handed over they'd become the main window's file actions (⌘⌫ offering to
    /// trash the selected folder, ⌘← copying it to the left).
    static func forwards(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased(), key.unicodeScalars.count == 1,
              let scalar = key.unicodeScalars.first else { return false }
        let printed = scalar.value >= 0x21 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        // The field's chords are plain ⌘ (and ⇧⌘Z, redo); ⇧⌘C, ⇧⌘V and ⇧⌘X are the app's.
        let own = ownChords.contains(key) && (!event.modifierFlags.contains(.shift) || key == "z")
        return printed && !own
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard Self.forwards(event), let parent, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        Logger.shared.debug("[askclaude] \(event.modifierFlags.contains(.shift) ? "⇧" : "")⌘\(key.uppercased()) handed to the main window")
        parent.makeKey()
        // A turn later, once the main window's focused values are back, to the menu bar itself:
        // never re-sent to a window, so it can't come back here.
        DispatchQueue.main.async {
            guard parent.isKeyWindow else { return }
            _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
        }
        return true
    }

    // MARK: Talk keys (TE311)

    /// ⌥Space and, while a question is being spoken, Esc, answered by the panel: true when it
    /// took the key. Caught here, ahead of the field editor, where ⌥Space types a non-breaking
    /// space and Esc closes the panel; in this window only, so it needs no Accessibility grant.
    var onTalkKey: ((AskClaudeTalkKey) -> Bool)?
    /// Called as the window goes away, closed or stepping aside, so the microphone never stays
    /// open behind a panel that isn't there.
    var onGone: () -> Void = {}

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let key = AskClaudeTalkKey(event),
           (firstResponder as? NSTextView)?.hasMarkedText() != true, onTalkKey?(key) == true {
            return
        }
        super.sendEvent(event)
    }

    override func orderOut(_ sender: Any?) {
        onGone()
        super.orderOut(sender)
    }

    override func performClose(_ sender: Any?) {
        onClose()
    }

    override func cancelOperation(_ sender: Any?) {
        onClose()
    }

    // MARK: Undo (TE290 step 4b)

    /// The chat's settings steps. One chat for the app, so one provider: set when the panel is built.
    static var settingsUndo: @MainActor () -> AskClaudeSettingsUndo? = { nil }

    /// Whether Undo belongs to the draft being typed: a text field has the keyboard, holds text, and
    /// has typing to undo. Otherwise it goes to the chat's settings steps — which outlive this
    /// window, torn down whenever the panel closes or steps aside, where typing's steps don't need to.
    private var typingTakesUndo: Bool {
        guard let text = firstResponder as? NSTextView, !text.string.isEmpty else { return false }
        return undoManager?.canUndo == true
    }

    private var typingTakesRedo: Bool {
        guard let text = firstResponder as? NSTextView, !text.string.isEmpty else { return false }
        return undoManager?.canRedo == true
    }

    @objc func undo(_ sender: Any?) {
        if !typingTakesUndo, let settings = Self.settingsUndo(), settings.canUndo { settings.undo() } else { undoManager?.undo() }
    }

    @objc func redo(_ sender: Any?) {
        if !typingTakesRedo, let settings = Self.settingsUndo(), settings.canRedo { settings.redo() } else { undoManager?.redo() }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let menuItem = item as? NSMenuItem
        switch item.action {
        case #selector(undo(_:)):
            if !typingTakesUndo, let settings = Self.settingsUndo(), let title = settings.undoTitle {
                menuItem?.title = title
                return true
            }
            menuItem?.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return undoManager?.canUndo == true
        case #selector(redo(_:)):
            if !typingTakesRedo, let settings = Self.settingsUndo(), let title = settings.redoTitle {
                menuItem?.title = title
                return true
            }
            menuItem?.title = undoManager?.redoMenuItemTitle ?? "Redo"
            return undoManager?.canRedo == true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

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

/// Shows the panel in a child window over the area it may move in (`container`, in screen
/// coordinates), at the frame the panel asks for (`panelRect`, top-left within the container).
@MainActor
final class AskClaudeWindowController {
    private var window: AskClaudePanelWindow?
    private var host: NSHostingView<AnyView>?
    private weak var parent: NSWindow?
    /// The area the panel lives in: the window's content below the toolbar, on screen.
    var container: NSRect = .zero { didSet { if container != oldValue { place() } } }
    /// Where the panel wants to be, top-left within `container`.
    ///
    /// Applied a turn later, never at once. The panel sets it from its own view update (New Chat
    /// shrinking the thread, an answer growing it), and resizing the window there resizes the
    /// hosting view mid-layout: the layout finishes with the size it began with, and the content no
    /// longer matches the window, its header cut off.
    var panelRect: CGRect = .zero { didSet { if panelRect != oldValue { placeSoon() } } }
    private var placeQueued = false
    /// Out of the way while the main window is busy (Settings, Help, a sheet, a question): a
    /// child window would otherwise sit over them and keep the keyboard. It comes back after.
    ///
    /// It comes back as a new window: one ordered out and back in draws only its composer's field,
    /// blank everywhere else. So stepping aside closes the window and the next `show` builds one;
    /// the thread, the draft and the panel's place live outside it.
    var isSuspended = false { didSet { if isSuspended && !oldValue { tearDown() } } }
    private var placed = false
    /// The window stepped aside: the one built next is it coming back, and leaves the keyboard
    /// where it is, as the old one did (the main window's, after a Save sheet or Settings).
    private var returning = false

    var isShowing: Bool { window != nil }

    /// - Parameter activate: whether the panel takes the keyboard (false in tests, which must not
    ///   change the shared host's key window).
    func show(_ content: AnyView, over parent: NSWindow, activate: Bool = true, onClose: @escaping () -> Void = {}) {
        let root = AnyView(content.nativeControlAccent().appFontSizeFromSettings())
        if let host {
            host.rootView = root
            window?.onClose = onClose
            return
        }
        guard !isSuspended else { return }
        let window = AskClaudePanelWindow(contentRect: NSRect(x: 0, y: 0, width: 372, height: 420),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.onClose = onClose
        window.title = "Ask Claude"
        window.setAccessibilityLabel("Ask Claude")
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovable = false
        window.ignoresMouseEvents = false
        // Its parent carries it between Spaces and full screen; it moves with nothing else.
        window.collectionBehavior = [.fullScreenAuxiliary]
        // Invisible until placed: an unplaced window draws for a frame at the screen's corner.
        window.alphaValue = 0
        // A frosted backdrop, blending with what is behind the window, rounded like the app's
        // cards. The SwiftUI panel paints a pane's surface and accent over it: opaque at
        // Solid, so only Frosted and Clear show this blur.
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        // The blur's own shape. The window server blends behind-window over the whole window,
        // which the layer's rounding below doesn't reach, so without it each corner shows a square
        // of blur outside the panel's curve.
        backdrop.maskImage = Self.cornerMask(radius: Radius.card)
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Radius.card
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        // Its own window, so the main window's root accent and text size don't reach it.
        let host = NSHostingView(rootView: AnyView(content.nativeControlAccent().appFontSizeFromSettings()))
        host.translatesAutoresizingMaskIntoConstraints = false
        // The window's frame is set by `place()`; the content mustn't size the window as well.
        host.sizingOptions = []
        backdrop.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            host.topAnchor.constraint(equalTo: backdrop.topAnchor),
            host.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        window.contentView = backdrop
        self.window = window
        self.host = host
        self.parent = parent
        placed = false
        place()
        Logger.shared.debug("[askclaude] panel window shown")
        // A child window rides the main one: it moves and orders with it.
        parent.addChildWindow(window, ordered: .above)
        // After the parenting, which clears it (see CommandPalettePanel.swift): a panel
        // hides whenever the app is inactive otherwise, taking the answer away while they check
        // something in another app.
        window.hidesOnDeactivate = false
        // Key, so the composer takes the keyboard at once.
        if activate && !returning { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
        returning = false
    }

    /// A rounded rectangle the backdrop stretches to its size: the corners kept, the middle
    /// stretched. Continuous like the panel's border, whose curve runs about 1.53 radii along
    /// each side, so the caps hold 1.6.
    static func cornerMask(radius: CGFloat) -> NSImage {
        let cap = (radius * 1.6).rounded(.up)
        let side = cap * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
        image.resizingMode = .stretch
        return image
    }

    /// Makes an open panel the key window, so its text box takes the keyboard.
    func focus() {
        guard let window, window.isVisible, !isSuspended else { return }
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        returning = false
        guard window != nil else { return }
        tearDown()
        Logger.shared.debug("[askclaude] panel window hidden")
    }

    private func tearDown() {
        guard let window else { return }
        let wasKey = window.isKeyWindow
        parent?.removeChildWindow(window)
        window.orderOut(nil)
        self.window = nil
        host = nil
        if isSuspended {
            returning = true
            Logger.shared.debug("[askclaude] panel stepped aside: the window is busy")
        }
        // The main window takes the keyboard back, as when a popover closes — only if the panel
        // had it, and never a window that is itself going away.
        if wasKey, let parent, parent.isVisible { parent.makeKey() }
    }

    /// Places the window once the current update is done; several changes in one turn place once.
    private func placeSoon() {
        guard !placeQueued else { return }
        placeQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.placeQueued = false
            self.place()
        }
    }

    private func place() {
        guard let window, panelRect.width > 0, panelRect.height > 0, container.width > 0 else { return }
        let frame = NSRect(x: container.minX + panelRect.minX, y: container.maxY - panelRect.maxY,
                           width: panelRect.width, height: panelRect.height)
        if frame != window.frame {
            window.setFrame(frame, display: true)
            window.invalidateShadow()
        }
        // Content that doesn't fill its window draws cut off; said, and put right.
        if let content = window.contentView {
            let fits = window.contentRect(forFrameRect: window.frame).size
            if content.frame.size != fits {
                Logger.shared.info("[askclaude] panel content was \(content.frame.size) in a \(fits) window; refitted")
                content.frame = NSRect(origin: .zero, size: fits)
            }
        }
        if !placed {
            placed = true
            window.alphaValue = 1
        }
    }
}

/// An invisible view in the main window that marks the panel's area and opens or closes its
/// window: SwiftUI updates it with the panel's content, and AppKit tells it when the area moves.
struct AskClaudeWindowAnchor: NSViewRepresentable {
    let controller: AskClaudeWindowController
    let isOpen: Bool
    /// The main window is busy; the panel steps aside until it isn't.
    var isSuspended = false
    let content: AnyView
    var onClose: () -> Void = {}

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.controller = controller
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.controller = controller
        view.wanted = isOpen ? (content, onClose) : nil
        view.busy = isSuspended
        view.sync()
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.controller?.hide()
    }

    final class AnchorView: NSView {
        weak var controller: AskClaudeWindowController?
        /// What to show, kept so a view that reaches its window late still opens the panel.
        var wanted: (content: AnyView, onClose: () -> Void)?
        var busy = false
        private var sheetBeginning = false
        private var observers: [NSObjectProtocol] = []

        // Never in the way: the area is the panes', and clicks there are theirs.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            reportArea()
        }

        func sync() {
            reportArea()
            guard let controller else { return }
            // Sheets are read here, live: SwiftUI doesn't redraw when one comes or goes.
            controller.isSuspended = busy || window?.attachedSheet != nil || sheetBeginning
            if let wanted, let window {
                controller.show(wanted.content, over: window, onClose: wanted.onClose)
            } else if wanted == nil {
                controller.hide()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let window else { controller?.hide(); return }
            let center = NotificationCenter.default
            // The panel's window rides the main one by itself; its area is re-read so the next
            // placement starts from where the main window is now.
            observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportArea() }
            })
            // A sheet on the main window (Save, a PDF tool) takes the panel out of its way too:
            // at once as it begins (it may not be attached yet), and checked again a turn after
            // one ends, once it has really gone.
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
            sync()
        }

        func reportArea() {
            guard let window else { return }
            controller?.container = window.convertToScreen(convert(bounds, to: nil))
        }
    }
}
