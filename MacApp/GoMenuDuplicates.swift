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
            if menu === goMenu, !item.allowsKeyEquivalentWhenHidden || item.isHidden != hide {
                note("apply sets " + describe(item))
            }
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

    /// **A probe, for the hosted CI VM only**: what the hook saw, newest last — every menu
    /// notification that names Go, the main menu or a ⌃ item, and every `apply`. Printed by
    /// `GoMenuDuplicatesTests` when a ⌃ item is found without its live key.
    static private(set) var trail: [String] = []

    static func describe(_ menu: NSMenu?) -> String {
        guard let menu else { return "nil" }
        let role = menu === goMenu ? "go" : menu === NSApp.mainMenu ? "main" : "'\(menu.title)'"
        return "\(role)@\(String(UInt(bitPattern: ObjectIdentifier(menu).hashValue), radix: 16).suffix(5))"
    }

    static func describe(_ item: NSMenuItem) -> String {
        let id = String(UInt(bitPattern: ObjectIdentifier(item).hashValue), radix: 16).suffix(5)
        let key = item.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: ",")
        let mask = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).rawValue >> 17
        return "#\(id) '\(item.title)' key[\(key)] mask\(mask) hidden\(item.isHidden ? 1 : 0) "
            + "live\(item.allowsKeyEquivalentWhenHidden ? 1 : 0) in \(describe(item.menu))"
    }

    private static func note(_ line: String) {
        trail.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + line)
        if trail.count > 1000 { trail.removeFirst(trail.count - 1000) }
    }

    private static func record(_ note: Notification, applied: Bool) {
        let menu = note.object as? NSMenu
        let index = note.userInfo?["NSMenuItemIndex"] as? Int
        let item = index.flatMap { i in menu.flatMap { $0.items.indices.contains(i) ? $0.items[i] : nil } }
        let isControl = item.map { $0.keyEquivalent == AppChord.switchPaneFocus.appKitKeyEquivalent
            || $0.title == NextTabCommand.title || $0.title.hasPrefix("Focus ") } ?? false
        let isGo = menu?.title == "Go"
        guard isControl || isGo || menu === NSApp.mainMenu else { return }
        let name = note.name.rawValue.replacingOccurrences(of: "NSMenu", with: "").replacingOccurrences(of: "Notification", with: "")
        Self.note("\(name) \(describe(menu)) idx \(index.map(String.init) ?? "-")"
            + (item.map { " " + describe($0) } ?? "") + (applied ? " → apply" : ""))
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
                guard Thread.isMainThread else {
                    let menu = (note.object as? NSMenu)?.title ?? "?"
                    DispatchQueue.main.async { Self.note("off-main \(note.name.rawValue) '\(menu)'") }
                    return
                }
                let menu = note.object as? NSMenu
                MainActor.assumeIsolated {
                    guard let go = goMenu, menu === go || menu === NSApp.mainMenu else {
                        record(note, applied: false)
                        return
                    }
                    record(note, applied: true)
                    apply(to: go)
                }
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didRemoveItemNotification,
                                                                object: nil, queue: nil) { note in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { record(note, applied: false) }
        })
        note("install: go \(describe(goMenu)), main has \(NSApp.mainMenu?.items.count ?? -1) items")
        if let go = goMenu { apply(to: go) }
    }
}
