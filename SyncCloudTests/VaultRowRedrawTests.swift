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
    static func mount(_ model: VaultModel, defaults: UserDefaults, draws: VaultDrawCount, height: CGFloat = 760) -> NSWindow {
        let size = CGSize(width: 1100, height: height)
        let panel = VaultCard(model: model, glassHue: .blue, onClose: {}, onOpenSettings: {},
                              onQuickLook: { _ in }, onReveal: { _ in }, onAddPerson: { _, _ in nil },
                              quickLookPath: nil, onCloseQuickLook: {})
            .frame(width: size.width, height: size.height)
            .defaultAppStorage(defaults)
            .environment(\.vaultDraws, draws)
            .coordinateSpace(.named(VaultDrawCount.space))
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

    /// Publishes until a publish draws no row and no heading, in turns: what a change draws once
    /// SwiftUI compares rows at all. It compares a row with its `==` only once AttributeGraph has
    /// worked out how to compare the row's type, the first time in each process and on a
    /// background queue; until then it draws every row again, `==` never called. Under load that
    /// took past ten settle turns, 1.8 s and more (docs/flaky-tests.md, "SwiftUI compares a view
    /// with its own equality only once it has worked out how"). Whether it ever stops is left to
    /// the caller's expectations: a row that is never skipped runs out the turns and fails them.
    static func untilAPublishDrawsNothing(_ model: VaultModel, _ window: NSWindow, _ draws: VaultDrawCount) async throws {
        for turn in 0..<300 {
            draws.rows = []
            draws.shells = 0
            draws.headers = 0
            model.notice = "Warming up \(turn)"
            try await settle(window)
            if draws.shells == 0, draws.rows.isEmpty, draws.headers == 0 { return }
        }
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
        // People opens each person with two rows of fact tiles and draws lazily, so not every
        // row is in this window: what is drawn is what is weighed below.
        let drawn = Set(draws.rows)
        if layout == .people {
            #expect(drawn.count >= 2 && drawn.isSubset(of: masked), "\(layout): rows drawn to begin with: \(draws.rows)")
        } else {
            #expect(drawn.isSuperset(of: masked), "\(layout): every row drawn to begin with: \(draws.rows)")
        }

        // A notice, like a read's progress, is a publish that changes no row.
        try await Self.untilAPublishDrawsNothing(rig.model, window, draws)
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
        let apart = rows.indices.filter { index in masked.filter { $0 == masked[index] }.count == 1 && drawn.contains(masked[index]) }
        for step in 0..<2 {
            let before = rig.model.selection
            let target = try #require(apart.first { rows[$0].id != before })
            let was = rows.firstIndex { $0.id == before }.map { masked[$0] }.flatMap { drawn.contains($0) ? $0 : nil }
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

    /// People draws every person's heading for each kind, though the kinds' names repeat from
    /// person to person: keyed by name alone, as children of one lazy stack, a kind's heading was
    /// drawn for one person only, and the others had a gap where it goes.
    @Test func peopleDrawsEachPersonsKindsHeading() async throws {
        let rig = try await VaultPanelRenderTests.rig(); defer { rig.cleanUp() }
        rig.defaults.set(VaultLayout.people.rawValue, forKey: "vaultLayout")
        rig.model.layout = .people
        let draws = VaultDrawCount()
        // Tall enough to lay out every person: each opens with two rows of fact tiles.
        let window = Self.mount(rig.model, defaults: rig.defaults, draws: draws, height: 1600); defer { window.orderOut(nil) }
        try await Self.settle(window, turns: 10)
        let kinds = rig.model.peopleSections.flatMap { section in section.groups.map { VaultDrawCount.kind(section.id, $0.name) } }
        let names = rig.model.peopleSections.flatMap { $0.groups.map(\.name) }
        try #require(Set(names).count < names.count, "a kind under two people: \(names)")
        let drawn = kinds.filter { draws.frames[$0] != nil }
        #expect(drawn == kinds, "every kind's heading laid out: \(drawn) of \(kinds)")
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

    /// Choosing an ID that was never drawn, as the arrow keys and Reveal do, brings it into the
    /// list: in the person on screen, in another, and the list's very last.
    ///
    /// Judged by where the row is laid out, not by the list's offset or the row's having been built:
    /// a lazy stack inside each person's item once left the list blank at the very last ID, its row
    /// built but never placed, with the offset at what the stack estimated was the end.
    @Test func choosingAnIDNotYetDrawnScrollsToIt() async throws {
        let rig = try await Self.manyIDs(); defer { rig.cleanUp() }
        let draws = VaultDrawCount()
        let window = Self.mount(rig.model, defaults: rig.defaults, draws: draws); defer { window.orderOut(nil) }
        try await Self.settle(window, turns: 10)
        let content = try #require(window.contentView)
        let scroll = try #require(VaultScrollFinder.tallest(in: content))
        let sections = rig.model.peopleSections
        let anna = try #require(sections.first)
        #expect(try #require(scroll.documentView).frame.height > 2000, "Anna's IDs run to many screens")

        let choices = [("Anna's last, far down her section", try #require(anna.rows.last)),
                       ("the very last, in another person", try #require(sections.last?.rows.last)),
                       ("back to Anna's first", anna.rows[0])]
        for (what, row) in choices {
            let masked = rig.model.masked(row)
            try #require(rig.model.rows.filter { rig.model.masked($0) == masked }.count == 1, "\(what): told apart by its number")
            draws.frames = [:]
            rig.model.selection = row.id
            // Laid out since it was chosen, and inside the list as it shows now. In turns, not
            // seconds: a loaded run takes more of them, and a row never placed fails all the same.
            var shown: CGRect { content.convert(scroll.contentView.bounds, from: scroll.contentView) }
            func inView() -> Bool {
                guard let frame = draws.frames[masked] else { return false }
                return frame.minY >= shown.minY - 0.5 && frame.maxY <= shown.maxY + 0.5
            }
            for _ in 0..<300 where !inView() { try await Self.settle(window) }
            #expect(inView(), "\(what): laid out at \(String(describing: draws.frames[masked])), the list showing \(shown)")
        }
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
