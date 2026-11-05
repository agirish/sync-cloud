import AppKit
import Design

/// One visible item per tab step in the Go menu, with the ⌃ chords still live.
///
/// Next Tab ⇧⌘] and Previous Tab ⇧⌘[ each have a second chord (⌃⇥ is Next Tab in Browse, ⌃⇧⇥ is
/// always Previous Tab), and as items of their own they would list each step twice.
/// `NSMenuItem.isAlternate` can't fold them, since it needs the same key with different
/// modifiers, so the ⌃ item is hidden and its key kept live by `allowsKeyEquivalentWhenHidden`;
/// a hidden item answers ⌃⇥ (and ⌃⇧⇥, whose character is backtab, U+0019) only with that flag.
///
/// In Compare ⌃⇥ reads "Focus <pane>" and stays visible, so the rule reads the title. SwiftUI owns
/// and rebuilds these items, so this re-applies on every Go menu change, not once at launch.
///
/// SwiftUI also clears the flag silently: its item update in `menuNeedsUpdate(_:)` sets
/// `allowsKeyEquivalentWhenHidden` back to false with no notification, so a visible item would
/// lose its key. `keepKeysLive` watches the flag by KVO and sets it again the moment it is cleared.
@MainActor
enum GoMenuDuplicates {

    /// Is `item` the ⌃⇥ or ⌃⇧⇥ item, the two this hides, and if so, should it be hidden now? `nil`
    /// for every other item.
    static func shouldHide(_ item: NSMenuItem) -> Bool? {
        guard item.keyEquivalent == AppChord.switchPaneFocus.appKitKeyEquivalent else { return nil }
        switch item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) {
        case AppChord.previousTabControl.appKitModifierMask:
            // Always Previous Tab, so always a twin of Previous Tab ⇧⌘[.
            return true
        case AppChord.switchPaneFocus.appKitModifierMask:
            // A twin only when it is Next Tab (Browse); "Focus <pane>" in Compare is its own item.
            return item.title == NextTabCommand.title
        default:
            return nil
        }
    }

    /// Hides the twins in `menu`, keeps their keys live, and hides a separator left with nothing
    /// visible under it (the one above ⌃⇥ when that is last and hidden). Sets a property only when
    /// it changes, so the change notifications it posts don't loop.
    static func apply(to menu: NSMenu) {
        for item in menu.items {
            guard let hide = shouldHide(item) else { continue }
            if !item.allowsKeyEquivalentWhenHidden { item.allowsKeyEquivalentWhenHidden = true }
            if item.isHidden != hide { item.isHidden = hide }
        }
        let items = menu.items
        for (index, item) in items.enumerated() where item.isSeparatorItem {
            let below = items[(index + 1)...].prefix { !$0.isSeparatorItem }
            let hide = !below.isEmpty && below.allSatisfy(\.isHidden)
            if item.isHidden != hide { item.isHidden = hide }
        }
    }

    /// The Go menu as AppKit built it, if there is one.
    static var goMenu: NSMenu? { NSApp.mainMenu?.items.first { $0.title == "Go" }?.submenu }

    private static var observers: [NSObjectProtocol] = []
    private static var keyWatches: [ObjectIdentifier: NSKeyValueObservation] = [:]

    /// Watches the flag on each ⌃ item now in `go` and sets it again whenever anything clears it,
    /// as SwiftUI's update does silently. Drops the watches of items no longer there.
    static func keepKeysLive(in go: NSMenu) {
        var watches: [ObjectIdentifier: NSKeyValueObservation] = [:]
        for item in go.items where shouldHide(item) != nil {
            let id = ObjectIdentifier(item)
            watches[id] = keyWatches.removeValue(forKey: id)
                ?? item.observe(\.allowsKeyEquivalentWhenHidden) { item, _ in
                    guard Thread.isMainThread else { return }
                    MainActor.assumeIsolated {
                        if !item.allowsKeyEquivalentWhenHidden, shouldHide(item) != nil {
                            item.allowsKeyEquivalentWhenHidden = true
                        }
                    }
                }
        }
        keyWatches.values.forEach { $0.invalidate() }
        keyWatches = watches
    }

    /// Watches the menus SwiftUI builds and keeps `apply` current on the Go menu. Once, at launch.
    static func install() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification,
                                          NSMenu.didBeginTrackingNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                // AppKit changes menus on the main thread; anything else is left alone rather than
                // trapped in `assumeIsolated`.
                guard Thread.isMainThread else { return }
                let menu = note.object as? NSMenu
                MainActor.assumeIsolated {
                    guard let go = goMenu, menu === go || menu === NSApp.mainMenu else { return }
                    apply(to: go)
                    keepKeysLive(in: go)
                }
            }
        }
        if let go = goMenu {
            apply(to: go)
            keepKeysLive(in: go)
        }
    }
}
