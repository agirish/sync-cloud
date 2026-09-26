import Testing
import Foundation
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// The context menu on a row of Edit's Text Files rail — TE33.
///
/// **What is pinned, and how.** The order and the words by calling ``EditorRailRowMenu/items(for:actions:)``
/// and, separately, by reading the menu as it is DRAWN; that every act receives the ROW's path by
/// running each item; and that every row of a real rail carries the menu, dim rows included, by
/// READING it off a hosted rail — `NSHostingView.menu(for:)` on a synthesised right-click, inside a
/// window, answers the real `NSMenu` SwiftUI built for the row under the event (the technique
/// `DuplicateRowMenuTests` measured; TE33 believed a hosted context menu unreadable, having asked a
/// host with no window). The app-side closures are scanned in
/// `SyncCloudTests/EditorHandOffTests.swift`, beside the other doors' wiring.
@MainActor
@Suite struct EditorRailRowMenuTests {

    /// Which act ran, and on which path.
    final class Recorder {
        var calls: [String] = []
        var actions: EditorRailRowActions {
            EditorRailRowActions(revealInBrowse: { self.calls.append("browse \($0)") },
                                 getInfo: { self.calls.append("info \($0)") },
                                 quickLook: { self.calls.append("quicklook \($0)") },
                                 revealInFinder: { self.calls.append("finder \($0)") })
        }
    }

    /// A row that is NOT the open document — the case the header's menu could never reach.
    static let rowPath = "/Users/me/Notes/ideas.md"

    @Test func theMenuOffersFourActsInOrder() {
        let items = EditorRailRowMenu.items(for: Self.rowPath, actions: Recorder().actions)
        #expect(items.map(\.title) == ["Reveal in Browse", "Get Info", "Reveal in Finder", "Quick Look"],
                "the rail row menu reads \(items.map(\.title))")
        #expect(items.map(\.systemImage) == ["folder", "info.circle", RevealGlyph.inFinder, "doc.viewfinder"],
                "the rail row menu's glyphs read \(items.map(\.systemImage))")
    }

    /// **Each item runs its OWN act, on THIS row's path.** A swapped pair — Get Info opening
    /// Quick Look — draws identically, and a closure bound to the open document instead of the row
    /// passes every test that opens only one file.
    @Test func everyActReceivesTheRowsPath() {
        let recorder = Recorder()
        for item in EditorRailRowMenu.items(for: Self.rowPath, actions: recorder.actions) {
            item.perform()
        }
        #expect(recorder.calls == ["browse \(Self.rowPath)", "info \(Self.rowPath)",
                                   "finder \(Self.rowPath)", "quicklook \(Self.rowPath)"],
                "the acts ran as \(recorder.calls)")
    }

    /// **The workspace hands the rail its own closures, each to the right act.** The header's
    /// Reveal in Browse and the rail's are one verb: with no row door of its own the rail reaches
    /// `onRevealInBrowse`, and given one (`onRevealRowInBrowse`, the app's, so its log can tell the
    /// two doors apart) it reaches that instead.
    @Test(arguments: [false, true])
    func theWorkspaceForwardsItsClosuresToTheRowMenu(rowDoor: Bool) {
        var calls: [String] = []
        let workspace = EditorWorkspaceView(
            document: EditorDocument(), autosavePolicy: EditorAutosavePolicy(),
            folder: "/Users/me/Notes", entries: [], showsRail: true, railIsHidden: false,
            accent: .blue, onAccent: .white, mode: .constant(.edit), splitFraction: .constant(0.5),
            isNaming: .constant(false), typedName: .constant(""), railFilter: .constant(""),
            railFilterIsExpanded: .constant(false), railTab: .constant(.files),
            railOutlineAnchors: .constant([:]), undoManager: UndoManager(),
            prefilledName: { "Untitled.md" }, refusal: { _ in nil },
            onOpen: { _ in }, onCreate: { _ in true },
            onRevealInBrowse: { calls.append("browse \($0)") },
            location: nil, onLocationDoor: { _ in },
            onGetInfo: { calls.append("info \($0)") },
            onQuickLook: { calls.append("quicklook \($0)") },
            onRevealRowInBrowse: rowDoor ? { calls.append("row browse \($0)") } : nil,
            onToggleJustTheText: {}, onNewTextFile: {}, onCloseDocument: {})
        let items = EditorRailRowMenu.items(for: Self.rowPath, actions: workspace.railRowActions)
        for item in items where item.title != "Reveal in Finder" { item.perform() }
        #expect(calls == ["\(rowDoor ? "row " : "")browse \(Self.rowPath)", "info \(Self.rowPath)",
                          "quicklook \(Self.rowPath)"],
                "the workspace forwarded \(calls)")
    }

    /// **The same words and glyphs as the menus these acts already live in.** The pane's row menu
    /// owns Get Info, Reveal in Finder and Quick Look; the header's filename menu owns Reveal in
    /// Browse. Read from their source rather than re-typed here, so a rename on either side fails.
    @Test func theWordsMatchThePaneRowMenuAndTheHeader() throws {
        let pane = try Self.source("FileTreeView.swift")
        #expect(pane.contains(#"Label("Get Info", systemImage: "info.circle")"#))
        #expect(pane.contains(#"Label("Reveal in Finder", systemImage: RevealGlyph.inFinder)"#))
        #expect(pane.contains(#"Label("Quick Look", systemImage: "doc.viewfinder")"#))
        // The header's item, still there and still aimed at the open document — TE33 adds a door,
        // it does not move the old one.
        let workspace = try Self.source("EditorWorkspaceView.swift")
        #expect(workspace.contains("Button(action: { onRevealInBrowse(path) }) {")
                && workspace.contains(#"Label("Reveal in Browse", systemImage: "folder")"#),
                "the header's Reveal in Browse has changed shape or gone")
        #expect(workspace.contains("if let path = document.path {"),
                "the header's Reveal in Browse no longer names the open document")
        // …and the rail is handed the workspace's actions, not a set of its own.
        #expect(workspace.contains("rowActions: railRowActions)"),
                "the rail is built without the workspace's row actions")
    }

    /// **The row carries the menu — every row, dim or not, bound to the ROW's path — READ off a
    /// hosted rail.** A right-click swept down the rail's middle answers, row by row, the menu
    /// SwiftUI built there; each is the four items in order, and its first item, performed, reveals
    /// that row's own file. The second row is dim (cloud-only): the files the editor cannot show
    /// are the ones most worth revealing, so an `if !entry.isDimmed` around the menu fails here, as
    /// do `selectedPath` in place of `entry.path` and a menu taken off the row.
    @Test func everyRowCarriesTheMenuDimRowsIncluded() throws {
        let recorder = Recorder()
        let entries = [EditorRailEntry(path: "/Users/me/Notes/ideas.md", name: "ideas.md", size: 10, isCloudOnly: false),
                       EditorRailEntry(path: "/Users/me/Notes/cloud.md", name: "cloud.md", size: 10, isCloudOnly: true)]
        #expect(entries.map(\.isDimmed) == [false, true], "the premise: one ordinary row, one dim row")
        let rail = EditorFileRailView(
            folderName: "Notes", entries: entries, selectedPath: entries[0].path, accent: .blue,
            onAccent: .white, tab: .constant(.files), isNaming: .constant(false),
            typedName: .constant(""), prefilledName: { "" }, refusal: { _ in nil },
            filter: .constant(""), filterIsExpanded: .constant(false),
            outlineAnchors: .constant([:]), onOpen: { _ in }, onCreate: { _ in true },
            rowActions: recorder.actions)
        // Two rows' menus read the same, so each is told apart by what its first item does: it is
        // performed at every probe, and a run is a stretch of the same titles AND the same path.
        let menus = Self.drawnMenus(AnyView(rail), width: 260, height: 420) { menu in
            menu.performActionForItem(at: 0)
            return recorder.calls.last
        }
        let four = ["Reveal in Browse", "Get Info", "Reveal in Finder", "Quick Look"]
        #expect(menus.map(\.titles) == [four, four],
                "the rail's rows draw these menus, top to bottom: \(menus.map(\.titles))")
        #expect(menus.map(\.act) == entries.map { "browse \($0.path)" },
                "each row's Reveal in Browse ran as \(menus.map(\.act))")
    }

    /// **Reveal in Finder's default is Finder, not nothing.** It is the one act the host does not
    /// supply, so a default of `{ _ in }` would draw the item and do nothing at every real site.
    @Test func revealInFinderDefaultsToFinder() throws {
        let source = try Self.source("EditorRailRowMenu.swift")
        #expect(source.contains("var revealInFinder: (String) -> Void = EditorRailRowActions.revealInFinder"),
                "Reveal in Finder no longer defaults to the Finder reveal")
        #expect(source.contains("NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])"),
                "the Finder reveal no longer selects the row's file in Finder")
    }

    /// **The menu as DRAWN, in order.** `items(for:actions:)` is what the tests above call; this is
    /// what proves the body draws that list and nothing else. Hosting the menu in a `VStack` lays
    /// each item out as one focus-ring view at its own y, and each is recognised by the width its
    /// label draws at alone — the technique `OpenInEditorVerbTests` uses for the pane's row menu.
    @Test func theDrawnMenuIsTheFourItemsInOrder() {
        let actions = Recorder().actions
        let solo = EditorRailRowMenu.items(for: Self.rowPath, actions: actions).map { item in
            Self.focusRingWidths(AnyView(Button(action: {}) {
                Label(item.title, systemImage: item.systemImage)
            })).first ?? 0
        }
        #expect(solo.allSatisfy { $0 > 0 }, "an item drew nothing alone: \(solo)")
        #expect(Set(solo).count == 4, "two labels measure the same, so the order cannot be read: \(solo)")
        let drawn = Self.focusRingWidths(AnyView(EditorRailRowMenu(path: Self.rowPath, actions: actions)))
        #expect(drawn == solo, "the menu draws \(drawn), expected \(solo) in that order")
    }

    // MARK: - Helpers

    /// A right-click swept down `view`'s middle, 2pt at a time, in a window: each run of the same
    /// non-empty menu, once, top to bottom — the `DuplicateRowMenuTests` technique. `act` says what
    /// the menu under each probe does, so two rows whose menus read alike are still two runs.
    private static func drawnMenus(_ view: AnyView, width: CGFloat, height: CGFloat,
                                   act: (NSMenu) -> String?) -> [(titles: [String], act: String?)] {
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var found: [(titles: [String], act: String?)] = []
        var fromTop: CGFloat = 1
        while fromTop < height {
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: width / 2, y: height - fromTop),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)
            if let menu = event.flatMap({ host.menu(for: $0) }), !menu.items.isEmpty {
                let probe = (titles: menu.items.map(\.title), act: act(menu))
                if found.last.map({ $0.titles != probe.titles || $0.act != probe.act }) ?? true {
                    found.append(probe)
                }
            }
            fromTop += 2
        }
        return found
    }

    private static func focusRingWidths(_ view: AnyView) -> [CGFloat] {
        let host = NSHostingView(rootView: AnyView(
            VStack(alignment: .leading, spacing: 0) { view }.frame(width: 260)))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        host.layoutSubtreeIfNeeded()
        var found: [CGRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("FocusRing") { found.append(v.frame) }
            v.subviews.forEach(walk)
        }
        walk(host)
        return found.sorted { $0.minY < $1.minY }.map(\.width)
    }

    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FileExplorer (tests)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/FileExplorer")
            .appendingPathComponent(name)
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — this scan would be vacuous")
        try #require(text.count > 500, "\(name) is implausibly short — the scan would be near-vacuous")
        return text
    }
}
