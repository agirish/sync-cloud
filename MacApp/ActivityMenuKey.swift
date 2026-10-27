import AppKit
import Design

/// **⌘L on Window ▸ Activity** (Run Room TE232). The entry is the one SwiftUI writes for the
/// Activity scene, which carries no key equivalent, and neither way of giving it one works: a
/// scene's `.keyboardShortcut` never reaches the automatic entry, and suppressing it for a
/// hand-written item — beside Keyboard Shortcuts', which is suppressed for ⌘/ — takes the main
/// window's own "SyncCloud" opener out of the menu (both measured 2026-10-27). So the key is put on
/// SwiftUI's item, and put back whenever SwiftUI rebuilds the menu, as `GoMenuDuplicates` does for
/// its items.
@MainActor
enum ActivityMenuKey {
    private static var observers: [NSObjectProtocol] = []

    static var windowMenu: NSMenu? {
        NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu
    }

    /// Sets ⌘L on the item titled "Activity" — only when it differs, so the change notification it
    /// posts ends here.
    static func apply(to menu: NSMenu) {
        guard let item = menu.items.first(where: { $0.title == "Activity" }) else { return }
        let key = String(AppChord.activityLog.key.character)
        let modifiers = AppChord.activityLog.appKitModifierMask
        if item.keyEquivalent != key { item.keyEquivalent = key }
        if item.keyEquivalentModifierMask != modifiers { item.keyEquivalentModifierMask = modifiers }
    }

    static func install() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification,
                                          NSMenu.didBeginTrackingNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                guard Thread.isMainThread else { return }
                let menu = note.object as? NSMenu
                MainActor.assumeIsolated {
                    guard let window = windowMenu, menu === window || menu === NSApp.mainMenu else { return }
                    apply(to: window)
                }
            }
        }
        if let window = windowMenu { apply(to: window) }
    }
}
