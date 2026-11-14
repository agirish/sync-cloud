import AppKit
import Design

/// Puts ⌘L on Window ▸ Activity. SwiftUI writes that entry for the Activity scene with no key
/// equivalent, and neither direct fix works: a scene's `.keyboardShortcut` never reaches the
/// automatic entry, and suppressing it for a hand-written item also takes the main window's
/// "SyncCloud" opener out of the menu. So the key goes on SwiftUI's item, and back on whenever
/// SwiftUI rebuilds the menu, as `GoMenuDuplicates` does for its items.
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
        observers = MenuRebuildWatch.observe { menu in
            guard let window = windowMenu, menu === window || menu === NSApp.mainMenu else { return }
            apply(to: window)
        }
        if let window = windowMenu { apply(to: window) }
    }
}
