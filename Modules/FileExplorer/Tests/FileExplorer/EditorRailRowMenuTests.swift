import Testing
import Foundation
import SwiftUI
import AppKit
import Design
@testable import FileExplorer
import FileExplorerTestSupport

/// The context menu on a row of Edit's Text Files rail, also offered on the header's file name:
/// Download, Reveal in Browse (greyed where Browse can't go), Rename and Delete among its acts.
///
/// The order, words and groups are pinned by calling
/// ``EditorRailRowMenu/items(for:isCloudOnly:actions:)``, each act's path by running each item, and
/// the menus as drawn, dim rows included, by reading them off hosted views: in a window,
/// `NSHostingView.menu(for:)` on a synthesised right-click answers the real `NSMenu` SwiftUI built
/// for the row (as in `DuplicateRowMenuTests`). The app-side closures are scanned in
/// `SyncCloudTests/EditorHandOffTests.swift`.
@MainActor
@Suite struct EditorRailRowMenuTests {

    /// Which act ran, and on which path. `refusal` is what Reveal in Browse's greying answers.
    final class Recorder {
        var calls: [String] = []
        var refusal: String?
        var actions: EditorRailRowActions {
            EditorRailRowActions(revealInBrowse: { self.calls.append("browse \($0)") },
                                 revealInBrowseRefusal: { _ in self.refusal },
                                 quickLook: { self.calls.append("quicklook \($0)") },
                                 download: { self.calls.append("download \($0)") },
                                 rename: { self.calls.append("rename \($0)") },
                                 delete: { self.calls.append("delete \($0)") },
                                 revealInFinder: { self.calls.append("finder \($0)") })
        }
    }

    /// A row that is not the open document, which the header's menu can't reach.
    static let rowPath = "/Users/me/Notes/ideas.md"

    static let five = ["Reveal in Browse", "Reveal in Finder", "Quick Look", "Rename", "Move to Trash…"]

    /// Five acts for a file on disk: the three ways out, then Browse's Rename and Delete in their own
    /// group at the bottom, with Browse's words and glyphs, Delete destructive. No Get Info: the rail
    /// is drawn only while the file pane is hidden, and Info lives in the pane. Mutation: dropping the
    /// group break or the destructive role, or swapping Rename and Delete, must fail a line.
    @Test func theMenuOffersFiveActsInTwoGroupsInOrder() {
        let items = EditorRailRowMenu.items(for: Self.rowPath, actions: Recorder().actions)
        #expect(items.map(\.title) == Self.five, "the rail row menu reads \(items.map(\.title))")
        #expect(items.map(\.systemImage) == ["folder", RevealGlyph.inFinder, "doc.viewfinder",
                                             "pencil", "trash"],
                "the rail row menu's glyphs read \(items.map(\.systemImage))")
        #expect(items.map(\.startsGroup) == [false, false, false, true, false],
                "the separators fall before \(items.filter(\.startsGroup).map(\.title))")
        #expect(items.map(\.isDestructive) == [false, false, false, false, true])
        #expect(items.allSatisfy { $0.refusal == nil }, "an item is greyed for a file Browse can show")
    }

    /// A file still in the cloud leads with Download, in a group of its own, and only such a file: a
    /// downloaded one has nothing to fetch. Mutation: offering Download whatever the flag says, or
    /// dropping the break after it, must fail it.
    @Test func aCloudOnlyFileLeadsWithDownload() {
        let items = EditorRailRowMenu.items(for: Self.rowPath, isCloudOnly: true, actions: Recorder().actions)
        #expect(items.map(\.title) == ["Download"] + Self.five, "the cloud-only row's menu reads \(items.map(\.title))")
        #expect(items.first?.systemImage == "icloud.and.arrow.down")
        #expect(items.map(\.startsGroup) == [false, true, false, false, true, false])
    }

    /// Reveal in Browse is greyed where Browse can't show the file, with the reason under it, and the
    /// other acts stay, Reveal in Finder above all, which still reaches it. Mutation: ignoring
    /// `revealInBrowseRefusal` must fail it.
    @Test func revealInBrowseIsGreyedWithItsReasonWhereBrowseCannotGo() {
        let recorder = Recorder()
        recorder.refusal = "Not in the source Browse shows"
        let items = EditorRailRowMenu.items(for: Self.rowPath, actions: recorder.actions)
        #expect(items.map(\.refusal) == ["Not in the source Browse shows", nil, nil, nil, nil])
    }

    /// Each item runs its own act, on this row's path. A swapped pair (Reveal in Finder opening Quick
    /// Look, Rename deleting) draws identically, and a closure bound to the open document instead of
    /// the row passes every test that opens only one file.
    @Test func everyActReceivesTheRowsPath() {
        let recorder = Recorder()
        for item in EditorRailRowMenu.items(for: Self.rowPath, isCloudOnly: true, actions: recorder.actions) {
            item.perform()
        }
        let p = Self.rowPath
        #expect(recorder.calls == ["download \(p)", "browse \(p)", "finder \(p)", "quicklook \(p)",
                                   "rename \(p)", "delete \(p)"],
                "the acts ran as \(recorder.calls)")
    }

    /// The header's door keeps its own Reveal in Browse: `revealing(through:)` swaps that one act
    /// and leaves the other four the row's. Mutation: returning `self` must fail it.
    @Test func theHeadersDoorSwapsOnlyRevealInBrowse() {
        let recorder = Recorder()
        let header = recorder.actions.revealing(through: { recorder.calls.append("header \($0)") })
        for item in EditorRailRowMenu.items(for: Self.rowPath, isCloudOnly: true, actions: header) {
            item.perform()
        }
        let p = Self.rowPath
        #expect(recorder.calls == ["download \(p)", "header \(p)", "finder \(p)", "quicklook \(p)",
                                   "rename \(p)", "delete \(p)"],
                "the header's acts ran as \(recorder.calls)")
    }

    /// The menu as an `NSMenu` draws it: separators as untitled items.
    static let fiveDrawn = ["Reveal in Browse", "Reveal in Finder", "Quick Look", "", "Rename", "Move to Trash…"]

    /// The workspace hands the rail the host's acts as they are (the app's Reveal in Browse is its own
    /// door, so its log can tell the rail's press from the header's): right-clicked on a hosted
    /// workspace, the row's menu runs the recorder's acts on the row's path. Mutation: building the
    /// rail with actions of the workspace's own (`{ _ in }`) must fail it.
    @Test func theWorkspaceHandsTheRailTheHostsActs() {
        let recorder = Recorder()
        let entry = EditorRailEntry(path: Self.rowPath, name: "ideas.md", size: 10, isCloudOnly: false)
        let workspace = EditorWorkspaceView.fixture(folder: "/Users/me/Notes", entries: [entry],
                                                    showsRail: true, railRowActions: recorder.actions)
        let menus = Self.drawnMenus(AnyView(workspace), width: 800, height: 420, probeX: 100) { menu in
            for index in menu.items.indices where !menu.items[index].isSeparatorItem {
                menu.performActionForItem(at: index)
            }
            return recorder.calls.joined(separator: ", ")
        }
        #expect(menus.first?.titles == Self.fiveDrawn, "the workspace's rail row draws \(menus.map(\.titles))")
        let p = Self.rowPath
        #expect(menus.first?.act?.hasPrefix("browse \(p), finder \(p), quicklook \(p), rename \(p), delete \(p)") == true,
                "the rail row's menu ran \(menus.first?.act ?? "nothing") — not the host's acts on the row's path")
    }

    /// The file name above the document offers the row's menu, read off a hosted header. Its Reveal
    /// in Browse is the header's door (`onRevealInBrowse`), the rest the row's acts, all on the open
    /// file. Mutation: a one-item menu, or the row's actions unswapped, must fail it.
    @Test func theFileNameOffersTheRowsMenuThroughTheHeadersDoor() throws {
        let recorder = Recorder()
        let document = try TestTextFiles.document(named: "plan.md")
        let path = try #require(document.path)
        let workspace = EditorWorkspaceView.fixture(
            document: document, onRevealInBrowse: { recorder.calls.append("header \($0)") },
            railRowActions: recorder.actions)
        let menus = Self.drawnMenus(AnyView(workspace.headerCard), width: 600, height: 52, probeX: 30) { menu in
            for index in menu.items.indices where !menu.items[index].isSeparatorItem {
                menu.performActionForItem(at: index)
            }
            return recorder.calls.joined(separator: ", ")
        }
        #expect(menus.first?.titles == Self.fiveDrawn, "the file name's menu reads \(menus.map(\.titles))")
        #expect(menus.first?.act?.hasPrefix("header \(path), finder \(path), quicklook \(path), rename \(path), delete \(path)") == true,
                "the file name's menu ran \(menus.first?.act ?? "nothing")")
    }

    /// Greyed, with its reason drawn under it, read off a hosted rail: Reveal in Browse is a disabled
    /// item, and the next item is the reason, also disabled. Mutation: dropping `.disabled` or the
    /// reason's `Text` must fail it.
    @Test func theGreyedRevealDrawsDisabledWithItsReason() {
        let recorder = Recorder()
        recorder.refusal = "Not in the source Browse shows"
        let entry = EditorRailEntry(path: Self.rowPath, name: "ideas.md", size: 10, isCloudOnly: false)
        let rail = Self.rail([entry], actions: recorder.actions)
        var enabled: [Bool] = []
        let menus = Self.drawnMenus(AnyView(rail), width: 260, height: 200) { menu in
            enabled = menu.items.map(\.isEnabled)
            return nil
        }
        #expect(menus.first?.titles.prefix(3) == ["Reveal in Browse", "Not in the source Browse shows", "Reveal in Finder"],
                "the greyed reveal draws \(menus.map(\.titles))")
        #expect(enabled.prefix(3) == [false, false, true], "the items' enabled states are \(enabled)")
    }

    /// The same words and glyphs as the menus these acts already live in: the pane's row menu owns
    /// Download, Reveal in Finder, Quick Look, Rename and Delete; the header's file name menu is this
    /// one. Read from their source rather than re-typed, so a rename on either side fails.
    @Test func theWordsMatchThePaneRowMenuAndTheHeader() throws {
        let pane = try SourceText.fileExplorer("FileTreeView.swift")
        // Download's word is the offer's title for one file; its glyph is the row's item.
        #expect(pane.contains(#"Label(offer.title, systemImage: "icloud.and.arrow.down")"#))
        #expect(try SourceText.fileExplorer("CloudDownloadOffer.swift").contains(#"case .file: return "Download""#))
        #expect(pane.contains(#"Label("Reveal in Finder", systemImage: RevealGlyph.inFinder)"#))
        #expect(pane.contains(#"Label("Quick Look", systemImage: "doc.viewfinder")"#))
        #expect(pane.contains(#"Label("Rename", systemImage: "pencil")"#))
        #expect(pane.contains(#"Label(count > 1 ? "Move \(count) Items to Trash…" : "Move to Trash…", systemImage: "trash")"#))
        // Both headers draw this menu, through their own Reveal in Browse door.
        let workspace = try SourceText.fileExplorer("EditorWorkspaceView.swift")
        #expect(workspace.contains("EditorRailRowMenu(path: path, isCloudOnly: Self.isNotDownloaded(document.refusal),")
                && workspace.contains("actions: railRowActions.revealing(through: onRevealInBrowse))"),
                "the text header's file name no longer offers the row's menu")
        let pdf = try SourceText.fileExplorer("EditorPDFCard.swift")
        #expect(pdf.contains("actions: rowActions.revealing(through: onRevealInBrowse))"),
                "the PDF header's file name no longer offers the row's menu")
        // …and the rail is handed the workspace's actions, not a set of its own.
        #expect(workspace.contains("rowActions: railRowActions,"),
                "the rail is built without the workspace's row actions")
    }

    /// Every row carries the menu, dim or not, bound to the row's path: a right-click swept down a
    /// hosted rail answers each row's menu, and its Reveal in Browse, performed, reveals that row's
    /// file. The second row is dim (cloud-only) and adds Download first: the files the editor can't
    /// show are the most worth revealing. Mutation: an `if !entry.isDimmed` around the menu,
    /// `selectedPath` for `entry.path`, no menu on the row, or a row that never says it is cloud-only
    /// must fail it.
    @Test func everyRowCarriesTheMenuDimRowsIncluded() throws {
        let recorder = Recorder()
        let entries = [EditorRailEntry(path: "/Users/me/Notes/ideas.md", name: "ideas.md", size: 10, isCloudOnly: false),
                       EditorRailEntry(path: "/Users/me/Notes/cloud.md", name: "cloud.md", size: 10, isCloudOnly: true)]
        #expect(entries.map(\.isDimmed) == [false, true], "the premise: one ordinary row, one dim row")
        let rail = Self.rail(entries, selectedPath: entries[0].path, actions: recorder.actions)
        var unglyphed: Set<String> = []
        // Two rows' menus read alike, so each is told apart by what its Reveal in Browse does: it is
        // performed at every probe, and a run is a stretch of the same titles and the same path.
        let menus = Self.drawnMenus(AnyView(rail), width: 260, height: 420) { menu in
            unglyphed.formUnion(menu.items.filter { !$0.isSeparatorItem && $0.image == nil }.map(\.title))
            guard let reveal = menu.items.firstIndex(where: { $0.title == "Reveal in Browse" }) else { return nil }
            menu.performActionForItem(at: reveal)
            return recorder.calls.last
        }
        #expect(menus.map(\.titles) == [Self.fiveDrawn, ["Download", ""] + Self.fiveDrawn],
                "the rail's rows draw these menus, top to bottom: \(menus.map(\.titles))")
        #expect(unglyphed.isEmpty, "these items draw no glyph: \(unglyphed.sorted())")
        #expect(menus.map(\.act) == entries.map { "browse \($0.path)" },
                "each row's Reveal in Browse ran as \(menus.map(\.act))")
    }

    /// Reveal in Finder's default is Finder, not nothing. It is the one act the host doesn't supply,
    /// so a default of `{ _ in }` would draw the item and do nothing at every real site.
    @Test func revealInFinderDefaultsToFinder() throws {
        let source = try SourceText.fileExplorer("EditorRailRowMenu.swift")
        #expect(source.contains("revealInFinder: @escaping (String) -> Void = EditorRailRowActions.revealInFinder)"),
                "Reveal in Finder no longer defaults to the Finder reveal")
        #expect(source.contains("NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])"),
                "the Finder reveal no longer selects the row's file in Finder")
    }

    static func rail(_ entries: [EditorRailEntry], selectedPath: String? = nil,
                     actions: EditorRailRowActions) -> EditorFileRailView {
        EditorFileRailView(
            folderName: "Notes", entries: entries, selectedPath: selectedPath, accent: .blue,
            accentFill: .blue, onAccent: .white, tab: .constant(.files), isNaming: .constant(false),
            typedName: .constant(""), prefilledName: { "" }, refusal: { _ in nil },
            filter: .constant(""), filterIsExpanded: .constant(false),
            outlineAnchors: .constant([:]), onOpen: { _ in }, onCreate: { _ in true },
            onNewTextFile: nil, folderTrail: nil, onGoToFolder: nil,
            rowActions: actions)
    }

    // MARK: - Helpers

    /// A right-click swept down `view`'s middle, 2pt at a time, in a window: each run of the same
    /// non-empty menu, once, top to bottom, as in `DuplicateRowMenuTests`. `act` says what the menu
    /// under each probe does, so two rows whose menus read alike are still two runs.
    private static func drawnMenus(_ view: AnyView, width: CGFloat, height: CGFloat, probeX: CGFloat? = nil,
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
                with: .rightMouseDown, location: NSPoint(x: probeX ?? width / 2, y: height - fromTop),
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
}
