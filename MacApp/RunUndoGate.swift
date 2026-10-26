import AppKit
import Design
import FileExplorer

/// **Edit ▸ Undo and Redo wait while a long run is going** (Banner Room, CF, his call 2026-10-26).
///
/// be85be02e left undo live during a run: a ⌘Z could put a file back while a merge or a copy was
/// still moving the files around it. Now a step on the file operations' stack waits, as every
/// other write does, and says why — "Wait for the merge to finish".
///
/// **Only the file operations' stack.** Edit's document has its own (`EditorUndoStore`, through the
/// text view's delegate or `EditorUndoAnchorView`), and so do Fill & Sign and editable Preview:
/// typing undo goes on. The stack ⌘Z would reach is read the way AppKit resolves it
/// (`UndoStackReached`), and only when it is the window's own — `FileSyncManager`'s — does it wait.
///
/// **How:** Edit ▸ Undo and Redo are SwiftUI's items, sent up the responder chain, where `NSWindow`
/// answers them for its own stack. This takes them as their target, validates and sends them on to
/// whoever the chain would have reached, and stands in the way only during a run. SwiftUI rebuilds
/// its menus, so the target is re-applied whenever it adds or changes an item, as
/// `GoMenuDuplicates` does. A greyed item answers no key, so ⌘Z and ⇧⌘Z pressed anyway are caught
/// before the menu and refused aloud, as ⌫ is (`FileActionHandler.refusedWhileRunning`).
@MainActor
final class RunUndoGate: NSObject, NSMenuItemValidation {

    static let shared = RunUndoGate()

    static let undo = NSSelectorFromString("undo:")
    static let redo = NSSelectorFromString("redo:")

    /// Why the file operations' undo waits now — `runWriteLockReason` — or `nil`.
    var reason: String?
    /// The file operations' stack: `FileSyncManager.undoManager`, the window's own.
    var fileStack: () -> UndoManager? = { nil }
    /// Says a refusal where the user is looking — the window's banner.
    var refuse: (String) -> Void = { _ in }

    // MARK: - Which stack

    /// Whether Undo or Redo sent to `target` would step the file operations' stack. A responder
    /// that answers `undo:` itself is never asked for its stack: one that does not name it would
    /// inherit the window's from its next responder and read as the file operations'.
    func reachesFileStack(_ target: Any?) -> Bool {
        guard target is NSWindow, let files = fileStack() else { return false }
        return UndoStackReached.stack(for: target) === files
    }

    /// The reason Undo or Redo sent to `target` waits, or `nil` when it may go.
    func waitReason(for target: Any?) -> String? {
        guard let reason, reachesFileStack(target) else { return nil }
        return reason
    }

    /// Who the responder chain sends `action` to — the key window's, as a nil-targeted item's. A
    /// test hands in its own window, which is never key.
    var chainTarget: (Selector, Any?) -> Any? = { NSApp.target(forAction: $0, to: nil, from: $1) }

    // MARK: - The items

    @objc func undo(_ sender: Any?) { send(Self.undo, from: sender) }
    @objc func redo(_ sender: Any?) { send(Self.redo, from: sender) }

    private func send(_ action: Selector, from sender: Any?) {
        let target = chainTarget(action, sender)
        if let wait = waitReason(for: target) {
            refuse(wait)
            return
        }
        NSApp.sendAction(action, to: target, from: sender)
    }

    /// **Greyed with the reason as its tooltip while the step would wait**; otherwise whatever the
    /// responder it goes to says — the title ("Undo Move") included.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        let target = chainTarget(action, item)
        if let wait = waitReason(for: target) {
            let stack = UndoStackReached.stack(for: target)
            item.title = (action == Self.undo ? stack?.undoMenuItemTitle : stack?.redoMenuItemTitle)
                ?? (action == Self.undo ? "Undo" : "Redo")
            item.toolTip = wait
            return false
        }
        if item.toolTip != nil { item.toolTip = nil }
        if let validating = target as? NSMenuItemValidation { return validating.validateMenuItem(item) }
        if let validating = target as? NSUserInterfaceValidations { return validating.validateUserInterfaceItem(item) }
        return target != nil
    }

    // MARK: - The keys

    /// **Whether `event` is ⌘Z or ⇧⌘Z** — the keys a greyed item no longer answers.
    static func undoRedoAction(of event: NSEvent) -> Selector? {
        guard event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "z" else { return nil }
        switch event.modifierFlags.intersection([.command, .shift, .option, .control]) {
        case .command: return undo
        case [.command, .shift]: return redo
        default: return nil
        }
    }

    /// Refuses ⌘Z or ⇧⌘Z aloud while the step would wait, and swallows it — the menu item is greyed,
    /// and AppKit's answer to a greyed item's key is a beep that says nothing. `true` when it did.
    func refusesKey(_ event: NSEvent) -> Bool {
        guard reason != nil, let action = Self.undoRedoAction(of: event),
              let wait = waitReason(for: chainTarget(action, nil)) else { return false }
        refuse(wait)
        return true
    }

    // MARK: - Installing

    /// Takes Edit ▸ Undo and Redo in `menu` and its submenus. Sets the target only when it changes,
    /// so the change notification it posts ends here.
    func adopt(in menu: NSMenu) {
        for item in menu.items {
            if item.action == Self.undo || item.action == Self.redo {
                if item.target !== self { item.target = self }
            } else if let submenu = item.submenu {
                adopt(in: submenu)
            }
        }
    }

    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?

    /// Once, at launch: the items now and whenever SwiftUI rebuilds them, and the keys.
    func install() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification,
                                          NSMenu.didBeginTrackingNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    if let main = NSApp.mainMenu { RunUndoGate.shared.adopt(in: main) }
                }
            }
        }
        if let main = NSApp.mainMenu { adopt(in: main) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            RunUndoGate.shared.refusesKey(event) ? nil : event
        }
    }
}
