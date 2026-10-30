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
            if probing, menu === goMenu {
                if !item.allowsKeyEquivalentWhenHidden || item.isHidden != hide { note("apply sets " + describe(item)) }
                watch(item)
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

    /// Off with `GO_PROBE=0`, which leaves the hook as it was before the probe but for the cheap
    /// bookkeeping below.
    static let probing = ProcessInfo.processInfo.environment["GO_PROBE"] != "0"

    /// Probe bookkeeping, kept even with `GO_PROBE=0` because it costs a set insert per apply:
    /// every ⌃ item an apply on Go has met, how many applies ran and when the last did, the Go menu
    /// install found, and how many notifications of each kind reached an apply.
    static private(set) var metItems: Set<ObjectIdentifier> = []
    /// Holds every met item alive, so a freed item's address can't come back as a "met" new one.
    private static var metAlive: [NSMenuItem] = []
    static private(set) var applies = 0
    static private(set) var lastApply: TimeInterval = 0
    static private(set) var installedGo: ObjectIdentifier?
    static private(set) var reached: [String: Int] = [:]

    private static func keep(_ go: NSMenu) {
        applies += 1
        lastApply = ProcessInfo.processInfo.systemUptime
        for item in go.items where shouldHide(item) != nil && metItems.insert(ObjectIdentifier(item)).inserted {
            metAlive.append(item)
        }
    }

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
                    if probing {
                        let menu = (note.object as? NSMenu)?.title ?? "?"
                        DispatchQueue.main.async { Self.note("off-main \(note.name.rawValue) '\(menu)'") }
                    }
                    return
                }
                let menu = note.object as? NSMenu
                MainActor.assumeIsolated {
                    guard let go = goMenu, menu === go || menu === NSApp.mainMenu else {
                        if probing { record(note, applied: false) }
                        return
                    }
                    if probing { record(note, applied: true) }
                    apply(to: go)
                    keep(go)
                    reached[(menu === go ? "go " : "main ") + note.name.rawValue, default: 0] += 1
                }
            }
        }
        if probing {
            observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didRemoveItemNotification,
                                                                    object: nil, queue: nil) { note in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { record(note, applied: false) }
            })
            note("install: go \(describe(goMenu)), main has \(NSApp.mainMenu?.items.count ?? -1) items")
            for item in goMenu?.items ?? [] { note("  at install " + describe(item)) }
        }
        if let go = goMenu {
            apply(to: go)
            keep(go)
            installedGo = ObjectIdentifier(go)
        }
        if probing { watch() }
    }

    /// Probe: KVO on every ⌃ item the hook has met, with the stack that changed it, and a 0.2 s
    /// poll of Go that notes each ⌃ item it has not met before and each one it finds unflagged.
    private static var watched: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private static var reported: Set<String> = []

    /// The callers outside this probe, Swift's runtime and KVO: "module:symbol", innermost first.
    private static func stack() -> String {
        Thread.callStackSymbols.compactMap { line -> String? in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count > 3 else { return nil }
            let module = String(fields[1])
            let symbol = fields[3...].prefix { $0 != "+" }.joined(separator: " ")
            if ["libswiftCore.dylib", "libswift_Concurrency.dylib", "Foundation"].contains(module)
                || symbol.contains("GoMenuDuplicates") || symbol.hasPrefix("NSKeyValue") || symbol.hasPrefix("_NSSetObjectValue")
                || symbol.hasPrefix("$sxs5Error") || symbol.hasPrefix("$sScM14assume") { return nil }
            return "\(module.prefix(12)):\(symbol.prefix(70))"
        }.prefix(16).joined(separator: " < ")
    }

    private static func watch(_ item: NSMenuItem) {
        let key = ObjectIdentifier(item)
        guard watched[key] == nil else { return }
        note("watching " + describe(item))
        func changed(_ what: String) -> (NSMenuItem, Any) -> Void {
            { item, _ in
                guard Thread.isMainThread else {
                    let trace = stack()
                    DispatchQueue.main.async { note("KVO \(what) OFF MAIN by " + trace) }
                    return
                }
                MainActor.assumeIsolated { note("KVO \(what) → " + describe(item) + " by " + stack()) }
            }
        }
        watched[key] = [
            item.observe(\.allowsKeyEquivalentWhenHidden, options: [.new]) { i, c in changed("live")(i, c) },
            item.observe(\.keyEquivalent, options: [.new]) { i, c in changed("key")(i, c) },
            item.observe(\.keyEquivalentModifierMask, options: [.new]) { i, c in changed("mask")(i, c) },
            item.observe(\.title, options: [.new]) { i, c in changed("title")(i, c) },
            item.observe(\.menu, options: [.new]) { i, c in changed("menu")(i, c) },
        ]
    }

    private static func watch() {
        let began = ProcessInfo.processInfo.systemUptime
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            MainActor.assumeIsolated {
                if ProcessInfo.processInfo.systemUptime - began > 600 { timer.invalidate(); return }
                guard let go = goMenu else {
                    if reported.insert("no go").inserted { note("poll: no Go menu") }
                    return
                }
                if reported.insert("go \(describe(go))").inserted { note("poll: Go is \(describe(go))") }
                for item in go.items where item.keyEquivalent == AppChord.switchPaneFocus.appKitKeyEquivalent
                    || item.title.hasPrefix("Focus ") || item.title == NextTabCommand.title {
                    let id = describe(item).prefix(6)
                    if watched[ObjectIdentifier(item)] == nil {
                        note("poll: unmet ⌃ item " + describe(item))
                        watch(item)
                    }
                    if !item.allowsKeyEquivalentWhenHidden, shouldHide(item) != nil,
                       reported.insert("unflagged \(id)").inserted {
                        note("poll: UNFLAGGED " + describe(item))
                    }
                }
            }
        }
    }
}
