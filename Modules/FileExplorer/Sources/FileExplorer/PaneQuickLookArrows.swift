import AppKit
import Quartz

/// Sends the arrow keys back to the pane's list while Quick Look previews its selection.
///
/// Space opens the shared `QLPreviewPanel`, which takes the keyboard. In Finder ↑ and ↓ still move
/// the selection and the preview follows; here the panel kept them and dropped them, so stepping
/// through a folder of pictures meant closing the preview for every file. The pane already
/// re-targets an open preview when its selection moves (`CurrentSelection.previewFollow`), so all
/// this has to do is hand the key to the list: the list moves, and the preview follows it.
///
/// Only a preview that follows the pane. A To File card's files step with ← and → inside the panel
/// itself, and a Differences row or the Vault hold selections of their own that a pane arrow
/// would never reach, so those previews keep every key.
///
/// The list is the main window's first responder, and only when it is a pane list
/// (`PaneListKeyFocus`): the panel is an `NSPanel`, which never becomes main, so the window behind
/// it keeps its focus while the panel holds the keys. Anything else there, and the key stays with
/// the panel.
@MainActor
public enum PaneQuickLookArrows {

    /// Whether the open preview follows the pane selection. Mirrored from the host's own flag.
    /// Setting it installs the monitor the first time.
    public static var followsPane = false {
        didSet { installIfNeeded() }
    }

    /// ↑ ↓ ← →. ← and → are the pane's too (Columns steps between columns, Tree folds a folder):
    /// a preview that follows the pane is one file, so the panel has nothing of its own to step.
    static let arrowKeyCodes: Set<UInt16> = [126, 125, 123, 124]

    private static var monitor: Any?

    private static func installIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            forward(event) ? nil : event
        }
    }

    /// Hands `event` to the pane list when every condition holds.
    /// - Returns: whether it was handed on, and so must not reach the panel too.
    static func forward(_ event: NSEvent,
                        keyWindow: NSWindow? = NSApp.keyWindow,
                        mainWindow: NSWindow? = NSApp.mainWindow) -> Bool {
        guard let list = target(for: event, keyWindow: keyWindow, mainWindow: mainWindow) else {
            return false
        }
        list.keyDown(with: event)
        return true
    }

    /// The pane list `event` belongs to, or nil when the panel should keep it.
    static func target(for event: NSEvent, keyWindow: NSWindow?, mainWindow: NSWindow?) -> NSTableView? {
        guard followsPane,
              event.type == .keyDown,
              arrowKeyCodes.contains(event.keyCode),
              // Plain arrows only: ⇧ would extend a selection the preview cannot show, and ⌘ or ⌥
              // arrows are the panel's (or nobody's).
              event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              let keyWindow, keyWindow is QLPreviewPanel,
              let mainWindow, mainWindow !== keyWindow,
              let list = mainWindow.firstResponder as? NSTableView,
              PaneListKeyFocus.isRegistered(list)
        else { return nil }
        return list
    }
}
