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
/// running each item; that the row really carries the menu, dim rows included, by scanning the
/// row's builder — a SwiftUI context menu attached inside a hosting view is not reachable from a
/// test (measured: neither the hosting view nor any subview exposes an `NSMenu`, and
/// `menu(for:)` on a synthesised right-click answers an empty one). The app-side closures are
/// scanned in `SyncCloudTests/EditorHandOffTests.swift`, beside the other doors' wiring.
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
    /// Reveal in Browse and the rail's are one verb: both must reach `onRevealInBrowse`.
    @Test func theWorkspaceForwardsItsClosuresToTheRowMenu() {
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
            onToggleJustTheText: {}, onNewTextFile: {}, onCloseDocument: {})
        let items = EditorRailRowMenu.items(for: Self.rowPath, actions: workspace.railRowActions)
        for item in items where item.title != "Reveal in Finder" { item.perform() }
        #expect(calls == ["browse \(Self.rowPath)", "info \(Self.rowPath)", "quicklook \(Self.rowPath)"],
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

    /// **The row carries the menu — every row, dim or not, bound to the ROW's path.**
    ///
    /// Scanned, because a context menu inside a hosting view cannot be read back (see the suite's
    /// doc). The exact expression is the claim: `selectedPath` in place of `entry.path` would aim
    /// every row's menu at the open document, and an `if !entry.isDimmed` inside the block would
    /// strip it from the files it matters most on. Neither changes a pixel of the rail.
    @Test func everyRowCarriesTheMenuDimRowsIncluded() throws {
        let rail = try Self.source("EditorFileRailView.swift")
        let start = try #require(rail.range(of: "private func row(_ entry: EditorRailEntry) -> some View {"),
                                 "the rail's row builder is gone or renamed")
        let rest = rail[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"), "the row builder never closes")
        let row = String(rest[..<end.lowerBound])
        #expect(row.contains("onOpen(entry)"), "the slice is not the row builder")
        let menu = ".contextMenu { EditorRailRowMenu(path: entry.path, actions: rowActions) }"
        #expect(row.components(separatedBy: menu).count == 2,
                "the row does not carry exactly one ungated menu on its own path")
        // Not gated on the row's state anywhere around it: the one other mention of dimness is the
        // opacity, which is not a condition on the menu.
        #expect(!row.contains("if entry.isDimmed") && !row.contains("if !entry.isDimmed")
                && !row.contains("isDimmed ?"),
                "the row branches on dimness, so a dim row may be drawn without its menu")
        // …and the menu itself takes no row state it could gate on: a path, and the acts.
        let source = try Self.source("EditorRailRowMenu.swift")
        let body = try #require(source.range(of: "struct EditorRailRowMenu: View {"))
        let tail = String(source[body.upperBound...])
        #expect(!tail.contains("isDimmed") && !tail.contains("isCloudOnly") && !tail.contains("isTooLarge"),
                "the menu has learned about the row's state, so a dim row can lose items")
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
