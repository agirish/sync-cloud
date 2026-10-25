import AppKit
import Design

/// **One visible item per tab step in the Go menu, with the ⌃ chords still live** (SH3).
///
/// Go ▸ Next Tab ⇧⌘] and Previous Tab ⇧⌘[ each have a second chord: ⌃⇥ is Next Tab in Browse,
/// and ⌃⇧⇥ is Previous Tab wherever Previous Tab is. Drawn as items of their own they put "Next
/// Tab" in the menu twice. The owner's call was to make each ⌃ item an *alternate* of its ⇧⌘
/// twin — one row, the ⌃ form showing while ⌃ is held.
///
/// **AppKit cannot fold these two.** `NSMenuItem.isAlternate` folds an item into the one above
/// only when both share a key equivalent and differ in modifiers (Apple's documentation of the
/// property); ⇧⌘] and ⌃⇥ differ in the key itself, so an "alternate" here is drawn as a second
/// row regardless. This is the fallback the decision named: **the ⌃ item is hidden, and its key
/// stays live** through `allowsKeyEquivalentWhenHidden` — measured 2026-10-25, a hidden item
/// answers ⌃⇥ (and a ⌃⇧⇥ event, whose character is backtab, U+0019) only with that flag set.
///
/// In Compare the ⌃⇥ item is not a duplicate: it reads "Focus <pane>" and stays visible. So the
/// rule reads the item's title, which SwiftUI keeps current, and is re-applied whenever SwiftUI
/// adds or changes an item in the Go menu — SwiftUI owns these items and rebuilds them, so a
/// one-time pass at launch would not survive the first workspace switch.
@MainActor
enum GoMenuDuplicates {

    /// Is `item` the ⌃⇥ or ⌃⇧⇥ item — the two this hides — and if so, should it be hidden now?
    /// `nil` for every other item.
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
    /// visible under it — the one above ⌃⇥ when ⌃⇥ is the menu's last item and hidden. Sets a
    /// property only when it changes, so the change notifications it posts end here.
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
                }
            }
        }
        if let go = goMenu { apply(to: go) }
    }
}
