@testable import SyncCloud
import Design
import Testing
import AppKit

/// **Go shows one row per tab step, and the ⌃ chords still answer** (SH3).
///
/// Read off the running app's `NSApp.mainMenu` — the test host is the app — and off a menu built
/// here, where the ⌃⇥ item can be made to read "Next Tab" without driving Browse into two tabs.
@MainActor
@Suite(.serialized) struct GoMenuDuplicatesTests {

    final class Target: NSObject {
        var fired = 0
        @objc func hit(_ sender: NSMenuItem) { fired += 1 }
    }

    static func item(_ title: String, _ chord: AppChord, _ target: Target? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(Target.hit(_:)), keyEquivalent: chord.appKitKeyEquivalent)
        item.keyEquivalentModifierMask = chord.appKitModifierMask
        item.target = target
        return item
    }

    /// A real ⌃⇥ / ⌃⇧⇥ key-down, its characters filled in by the keyboard layout — ⌃⇧⇥ arrives as
    /// backtab (U+0019), not a tab, which a hand-built event would get wrong.
    static func tabKey(shift: Bool) throws -> NSEvent {
        let cg = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        cg.flags = shift ? [.maskControl, .maskShift] : .maskControl
        return try #require(NSEvent(cgEvent: cg))
    }

    /// The Go menu's tail as `GoMenuDuplicates` meets it in Browse with two tabs.
    func browseShapedMenu(_ target: Target) -> (menu: NSMenu, next: NSMenuItem, previousControl: NSMenuItem,
                                                separator: NSMenuItem, control: NSMenuItem) {
        let menu = NSMenu(title: "Go")
        let next = Self.item("Next Tab", .nextTab, target)
        let previousControl = Self.item("Previous Tab", .previousTabControl, target)
        let separator = NSMenuItem.separator()
        let control = Self.item(NextTabCommand.title, .switchPaneFocus, target)
        for item in [next, Self.item("Previous Tab", .previousTab, target), previousControl, separator, control] {
            menu.addItem(item)
        }
        return (menu, next, previousControl, separator, control)
    }

    /// The twins go, their keys stay: the ⌃ items are hidden and still fire on their chords. A
    /// hidden item answers no key unless `allowsKeyEquivalentWhenHidden` is set — measured — so the
    /// key half is driven, not assumed.
    @Test func theTwinsAreHiddenAndTheirKeysStillFire() throws {
        let target = Target()
        let m = browseShapedMenu(target)
        GoMenuDuplicates.apply(to: m.menu)

        #expect(!m.next.isHidden, "the visible Next Tab went too")
        #expect(m.control.isHidden, "Next Tab ⌃⇥ is still drawn beside Next Tab ⇧⌘]")
        #expect(m.previousControl.isHidden, "Previous Tab ⌃⇧⇥ is still drawn beside Previous Tab ⇧⌘[")
        #expect(m.separator.isHidden, "a separator is left over nothing at the foot of the menu")
        #expect(m.menu.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title) == ["Next Tab", "Previous Tab"])

        #expect(m.menu.performKeyEquivalent(with: try Self.tabKey(shift: false)))
        #expect(m.menu.performKeyEquivalent(with: try Self.tabKey(shift: true)))
        #expect(target.fired == 2, "a hidden ⌃ item no longer answers its chord")
    }

    /// **In Compare ⌃⇥ is its own item** — "Focus <pane>" — and is drawn, its separator with it.
    /// SwiftUI retitles the item in place, so the rule has to undo itself as well as apply.
    @Test func inCompareTheControlTabItemIsDrawn() {
        let m = browseShapedMenu(Target())
        GoMenuDuplicates.apply(to: m.menu)
        m.control.title = "Focus Dropbox"
        GoMenuDuplicates.apply(to: m.menu)
        #expect(!m.control.isHidden, "the pane switch is hidden in Compare")
        #expect(!m.separator.isHidden)
        #expect(m.previousControl.isHidden, "Previous Tab ⌃⇧⇥ is a twin in every workspace")
    }

    /// The item in `menu` registering `chord`.
    static func find(_ chord: AppChord, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first {
            $0.keyEquivalent == chord.appKitKeyEquivalent
                && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == chord.appKitModifierMask
        }
    }

    /// **The app's own Go menu carries the pair, and the hook is installed**: Previous Tab ⌃⇧⇥ sits
    /// hidden under Previous Tab ⇧⌘[, both ⌃ items keep their keys live, and retitling the live ⌃⇥
    /// item to Next Tab hides it at once — which only the launch-time observer can do.
    ///
    /// Read after SwiftUI's own update of Go, when one is pending — the pass that clears the flag
    /// without a notification. On the hosted VM something in the suite ran it first, about one run
    /// in ten, and the drawn ⌃⇥ item was found without its live key.
    @Test func theAppsGoMenuCarriesThePairAndKeepsItCurrent() throws {
        let go = try #require(GoMenuDuplicates.goMenu, "the app has no Go menu — this check would be vacuous")
        go.delegate?.menuNeedsUpdate?(go)
        func find(_ chord: AppChord) -> NSMenuItem? { Self.find(chord, in: go) }
        let next = try #require(find(.nextTab))
        let previous = try #require(find(.previousTab))
        let previousControl = try #require(find(.previousTabControl), "nothing in Go registers ⌃⇧⇥")
        let control = try #require(find(.switchPaneFocus))
        #expect(next.title == "Next Tab" && !next.isHidden)
        #expect(previous.title == "Previous Tab" && !previous.isHidden)
        #expect(previousControl.title == "Previous Tab")
        #expect(go.index(of: previousControl) == go.index(of: previous) + 1, "⌃⇧⇥ is not beside its twin")
        #expect(previousControl.isHidden, "Previous Tab is drawn twice")
        // One assertion per item, each naming its state: on a hosted CI VM this failed with both in
        // one `&&`, which could not say which item had lost its live key.
        #expect(previousControl.allowsKeyEquivalentWhenHidden,
                "⌃⇧⇥ \"\(previousControl.title)\" (hidden \(previousControl.isHidden)) has no live key while hidden")
        #expect(control.allowsKeyEquivalentWhenHidden,
                "⌃⇥ \"\(control.title)\" (hidden \(control.isHidden)) has no live key while hidden")

        let original = control.title
        defer { control.title = original }
        control.title = NextTabCommand.title
        #expect(control.isHidden, "the ⌃⇥ item read Next Tab and stayed drawn — the observer is not installed")
        control.title = "Focus Dropbox"
        #expect(!control.isHidden)
    }

    /// **A flag SwiftUI clears is set again at once.** SwiftUI's update of Go
    /// (`PlatformItemList.Item.update`) writes `allowsKeyEquivalentWhenHidden = false` on each item,
    /// which posts no notification; on the drawn ⌃⇥ item nothing else changes, so no notification
    /// the hook watches says so (measured 2026-10-30). Written here as SwiftUI writes it — and on
    /// the hidden twin after un-hiding it as well as before, since the hook must not lean on the
    /// order SwiftUI happens to use.
    @Test func aLiveKeySwiftUIClearsIsSetAgain() throws {
        let go = try #require(GoMenuDuplicates.goMenu, "the app has no Go menu — this check would be vacuous")
        let control = try #require(Self.find(.switchPaneFocus, in: go), "nothing in Go registers ⌃⇥")
        let previousControl = try #require(Self.find(.previousTabControl, in: go), "nothing in Go registers ⌃⇧⇥")
        try #require(control.allowsKeyEquivalentWhenHidden && previousControl.allowsKeyEquivalentWhenHidden,
                     "the premise: both ⌃ items start with live keys")

        control.allowsKeyEquivalentWhenHidden = false
        #expect(control.allowsKeyEquivalentWhenHidden,
                "⌃⇥ \"\(control.title)\" (hidden \(control.isHidden)) stayed without its live key once cleared")

        previousControl.allowsKeyEquivalentWhenHidden = false
        previousControl.isHidden = false
        #expect(previousControl.isHidden && previousControl.allowsKeyEquivalentWhenHidden,
                "⌃⇧⇥ cleared, then un-hidden: hidden \(previousControl.isHidden), live \(previousControl.allowsKeyEquivalentWhenHidden)")
        previousControl.isHidden = false
        previousControl.allowsKeyEquivalentWhenHidden = false
        #expect(previousControl.isHidden && previousControl.allowsKeyEquivalentWhenHidden,
                "⌃⇧⇥ un-hidden, then cleared: hidden \(previousControl.isHidden), live \(previousControl.allowsKeyEquivalentWhenHidden)")
    }

    /// The live Go menu's ⌃⇥ item, taken out of the menu and retitled Next Tab while out — so no
    /// notification the hook watches has seen it — and the closure that puts everything back.
    ///
    /// **The live item, not a new one**: the main menu clears the key of an item added with a
    /// chord another item already has (measured: a second ⌃⇥ arrives with an empty key), so only
    /// re-adding the one ⌃⇥ item models a SwiftUI rebuild.
    private func detachedControlTab() throws -> (go: NSMenu, item: NSMenuItem, index: Int, restore: () -> Void) {
        let go = try #require(GoMenuDuplicates.goMenu, "the app has no Go menu — this check would be vacuous")
        let item = try #require(go.items.first {
            $0.keyEquivalent == AppChord.switchPaneFocus.appKitKeyEquivalent
                && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                    == AppChord.switchPaneFocus.appKitModifierMask
        }, "nothing in Go registers ⌃⇥")
        let index = go.index(of: item), original = item.title
        go.removeItem(item)
        item.title = NextTabCommand.title
        item.isHidden = false
        return (go, item, index, {
            if item.menu == nil { go.insertItem(item, at: index) }
            item.title = original
            GoMenuDuplicates.apply(to: go)
        })
    }

    /// **An item SwiftUI adds to the live Go menu is hidden as it arrives** — the
    /// `didAddItemNotification` half of the hook, posted inside `insertItem` (measured). SwiftUI
    /// rebuilds Go's items on a workspace switch, and a rebuilt Next Tab ⌃⇥ is a new item no
    /// change notification ever names.
    ///
    /// The `didBeginTrackingNotification` half has no test: every way of making a twin here —
    /// adding it, retitling it, with Go's `menuChangedMessagesEnabled` off, or from another thread
    /// — had the add or change notification hide it first (measured 2026-10-26), so tracking
    /// could never be the observer that did.
    @Test func aNextTabItemAddedToTheLiveGoMenuIsHidden() throws {
        let (go, item, index, restore) = try detachedControlTab()
        defer { restore() }
        try #require(!item.isHidden, "the premise: the item is drawn before it is added")
        go.insertItem(item, at: index)
        try #require(item.keyEquivalent == AppChord.switchPaneFocus.appKitKeyEquivalent, "re-adding cleared the ⌃⇥ key")
        #expect(item.isHidden, "a Next Tab ⌃⇥ added to Go stayed drawn — didAddItem is not observed")
        #expect(item.allowsKeyEquivalentWhenHidden)
    }
}
