import AppKit
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// What a change to the Vault draws again, and what People draws as it scrolls. The panel reads
/// one `ObservableObject`, so every publish runs its body; a row whose values did not change is
/// skipped (``VaultRow``). And People is lazy down to each line of rows, so a person's IDs are not
/// all built in the frame their name scrolls in, which took 40 ms for 14 IDs (2026-11-22).
/// Every ID is made up.
@MainActor
@Suite(.serialized) struct VaultRowRedrawTests {
    /// The panel in a window that is ordered in, so it updates as the app's does, and buried below
    /// the wallpaper.
    static func mount(_ model: VaultModel, defaults: UserDefaults, draws: VaultDrawCount) -> NSWindow {
        let size = CGSize(width: 1100, height: 760)
        let panel = VaultCard(model: model, people: model.people, glassHue: .blue, onClose: {}, onOpenSettings: {},
                              onQuickLook: { _ in }, onReveal: { _ in }, onAddPerson: { _, _ in nil },
                              quickLookPath: nil, onCloseQuickLook: {})
            .frame(width: size.width, height: size.height)
            .defaultAppStorage(defaults)
            .environment(\.vaultDraws, draws)
        let host = NSHostingView(rootView: panel)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        window.orderFront(nil)
        return window
    }

    /// Lets the panel draw what changed: its `.task`s, then one layout and display.
    static func settle(_ window: NSWindow, turns: Int = 1) async throws {
        for _ in 0..<turns {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    @Test(arguments: VaultLayout.allCases)
    func aChangeThatLeavesTheRowsAloneDrawsNoRowAgain(_ layout: VaultLayout) async throws {
        let rig = try await VaultPanelRenderTests.rig(); defer { rig.cleanUp() }
        rig.defaults.set(layout.rawValue, forKey: "vaultLayout")
        rig.model.layout = layout
        let draws = VaultDrawCount()
        let window = Self.mount(rig.model, defaults: rig.defaults, draws: draws); defer { window.orderOut(nil) }
        #expect(window.level.rawValue < NSWindow.Level.normal.rawValue, "buried, not on his screen")
        try await Self.settle(window, turns: 10)
        let rows = rig.model.visibleRows
        try #require(rows.count >= 2)
        let masked = rows.map(rig.model.masked)
        #expect(Set(draws.rows).isSuperset(of: masked), "\(layout): every row drawn to begin with: \(draws.rows)")

        // A notice, like a read's progress, is a publish that changes no row.
        draws.rows = []
        draws.shells = 0
        draws.headers = 0
        for count in 1...5 {
            rig.model.notice = "Read \(count) of 5"
            try await Self.settle(window)
        }
        #expect(draws.rows.isEmpty, "\(layout): five publishes drew rows again: \(draws.rows)")
        #expect(draws.shells == 0, "\(layout): and \(draws.shells) rows' buttons and menus")
        #expect(draws.headers == 0, "\(layout): and \(draws.headers) people's headings")

        // Choosing a row draws the two whose highlight moved, and no other: the one chosen
        // before (the panel keeps one chosen) and the one chosen now.
        // Rows told apart by their numbers as drawn.
        let apart = rows.indices.filter { index in masked.filter { $0 == masked[index] }.count == 1 }
        for step in 0..<2 {
            let before = rig.model.selection
            let target = try #require(apart.first { rows[$0].id != before })
            let was = rows.firstIndex { $0.id == before }.map { masked[$0] }
            draws.rows = []
            rig.model.selection = rows[target].id
            try await Self.settle(window)
            #expect(Set(draws.rows) == Set([masked[target]] + (was.map { [$0] } ?? [])),
                    "\(layout), choice \(step + 1): \(draws.rows)")
        }
    }

    /// A row's menu is built at its first right-click and kept; with its row skipped, it still
    /// follows what it reads from the Vault (an ID to merge with, a saved or waiting ID).
    @Test func aRowsMenuFollowsTheVaultThoughItsRowIsSkipped() async throws {
        let rig = try await VaultPanelRenderTests.rig(); defer { rig.cleanUp() }
        let row = try #require(rig.model.rows.first)
        let model = rig.model
        let menu = NSHostingMenu(rootView: VaultRowMenu(model: model, row: row) { _ in
            Button(model.notice ?? "Nothing said") {}
        })
        menu.update()
        #expect(menu.items.map(\.title) == ["Nothing said"])
        model.notice = "Merge…"
        try await Task.sleep(for: .milliseconds(20))
        menu.update()
        #expect(menu.items.map(\.title) == ["Merge…"])
    }

    /// Anna with 200 IDs and three others with 8, half of them current: Anna's are many screens.
    static func manyIDs() async throws -> (model: VaultModel, defaults: UserDefaults, cleanUp: () -> Void) {
        let rig = try await VaultPanelRenderTests.rig()
        let kinds: [(String, VaultCategory)] = [("Dental member ID", .health), ("Vision plan", .health), ("Water account", .utilities),
                                                ("Power account", .utilities), ("Auto loan", .loans), ("Library card", .other),
                                                ("Gym member", .other), ("Store card", .other)]
        var n = 0
        for (person, count) in [("anna", 200), ("erik", 8), ("liv", 8), ("ola", 8)] {
            for index in 0..<count {
                n += 1
                let (title, category) = kinds[index % kinds.count]
                var draft = VaultModel.Draft(title: "\(title) \(n)", value: String(format: "ZX%09d", 100_000_000 + n * 7919),
                                             personID: person, category: category)
                if n % 2 == 0 { draft.pin = .older }
                _ = rig.model.add(draft)
            }
        }
        rig.model.people = ["anna", "erik", "liv", "ola"].map { Person(id: $0, displayName: $0.capitalized) }
        rig.defaults.set(VaultLayout.people.rawValue, forKey: "vaultLayout")
        rig.model.layout = .people
        rig.model.selection = nil
        return (rig.model, rig.defaults, rig.cleanUp)
    }

    /// People is lazy down to each line of rows: a person's IDs are drawn as they come into view,
    /// not all in the frame their name does. All at once, a person of 14 took 40 ms to arrive.
    @Test func peopleDrawsAPersonsRowsAsTheyComeIntoView() async throws {
        let rig = try await Self.manyIDs(); defer { rig.cleanUp() }
        let draws = VaultDrawCount()
        let window = Self.mount(rig.model, defaults: rig.defaults, draws: draws); defer { window.orderOut(nil) }
        try await Self.settle(window, turns: 10)
        let anna = try #require(rig.model.peopleSections.first)
        #expect(anna.rows.count >= 100)
        #expect(Set(draws.rows).count < anna.rows.count, "Anna's \(anna.rows.count) IDs are not all drawn with her name: \(Set(draws.rows).count)")
        #expect(Set(draws.rows).count > 4)
    }

    /// Choosing an ID that was never drawn, as the arrow keys and Reveal do, scrolls to it: in
    /// the person on screen, and in another.
    @Test func choosingAnIDNotYetDrawnScrollsToIt() async throws {
        let rig = try await Self.manyIDs(); defer { rig.cleanUp() }
        let draws = VaultDrawCount()
        let window = Self.mount(rig.model, defaults: rig.defaults, draws: draws); defer { window.orderOut(nil) }
        try await Self.settle(window, turns: 10)
        let content = try #require(window.contentView)
        let scroll = try #require(VaultScrollFinder.tallest(in: content))
        func top() -> CGFloat { scroll.contentView.bounds.minY }
        let bottom = try #require(scroll.documentView).frame.height - scroll.contentView.bounds.height
        let sections = rig.model.peopleSections
        let anna = try #require(sections.first)
        #expect(bottom > 2000, "Anna's IDs run to many screens")

        // Anna's last, far down her section.
        let annasLast = try #require(anna.rows.last)
        rig.model.selection = annasLast.id
        try await Self.settle(window, turns: 6)
        #expect(draws.rows.contains(rig.model.masked(annasLast)))
        #expect(top() > 1000, "scrolled down to Anna's last ID: \(top())")

        // The very last, in another person: the end of the list.
        let last = try #require(sections.last?.rows.last)
        rig.model.selection = last.id
        try await Self.settle(window, turns: 6)
        #expect(draws.rows.contains(rig.model.masked(last)))
        let end = try #require(scroll.documentView).frame.height - scroll.contentView.bounds.height
        #expect(abs(top() - end) < 2, "scrolled to the end: \(top()) of \(end)")

        // And back to Anna's first.
        rig.model.selection = anna.rows[0].id
        try await Self.settle(window, turns: 6)
        #expect(top() < 200, "back up to Anna's first ID: \(top())")
    }
}

enum VaultScrollFinder {
    /// The scroll view with the tallest document: the panel's list.
    @MainActor static func tallest(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, let doc = s.documentView,
               best == nil || doc.frame.height > best!.documentView!.frame.height { best = s }
            v.subviews.forEach(walk)
        }
        walk(view)
        return best
    }
}
