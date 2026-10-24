import AppKit
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// **Both background menus sort through one picker that ticks the current order (BR7).**
///
/// The tree's empty-area menu had five plain buttons — nothing said which order the panes were in —
/// and the columns' menu had no Sort By at all, while the pane bar's picker ticked its choice. Read
/// through `NSHostingMenu`, which builds the real `NSMenu` (titles, submenus, item state).
@MainActor
@Suite struct PaneSortByMenuTests {

    /// The submenu's lines as AppKit draws them, a ticked item marked "✓".
    private static func lines(_ current: SortOption) throws -> (title: String, items: [String]) {
        let menu = NSHostingMenu(rootView: SharedFileMenuItems.sortBy(current) { _ in })
        menu.update()
        let item = try #require(menu.items.first { $0.submenu != nil }, "no Sort By submenu was built")
        let submenu = try #require(item.submenu)
        submenu.update()
        let items = submenu.items.filter { !$0.isSeparatorItem }
            .map { ($0.state == .on ? "✓ " : "") + $0.title }
        return (item.title, items)
    }

    @Test func theCurrentOrderIsTicked() throws {
        let size = try Self.lines(.size)
        #expect(size.title == "Sort By")
        #expect(size.items == ["Name", "Kind", "Date Modified", "✓ Size", "Tags"],
                "the Sort By submenu reads \(size.items)")
        // The tick follows the value, so the rule is not a fixed decoration on one row.
        #expect(try Self.lines(.name).items == ["✓ Name", "Kind", "Date Modified", "Size", "Tags"])
    }

    /// **Both menus draw it, from the pane's own order.** A picker nobody calls ticks nothing, and
    /// a pane that forgot to pass the order would tick Name forever.
    @Test func theTreeAndColumnsMenusBothDrawIt() throws {
        let tree = try OrganizeScopeCallSiteTests.source("FileTreeView.swift")
        let treeMenu = try OrganizeScopeCallSiteTests.body(of: "private var emptyAreaContextMenu: some View {",
                                                           in: tree)
        #expect(treeMenu.contains("SharedFileMenuItems.sortBy(sortOption) { delegate.handleSort($0) }"),
                "the tree's background menu no longer draws the shared Sort By")
        #expect(!treeMenu.contains("Button(\"Name\")"), "the tree's untick-able buttons are back")
        #expect(tree.contains("sortOption: sortOption,"), "the tree does not hand its order to Columns")

        let columns = try OrganizeScopeCallSiteTests.source("PaneColumnsView.swift")
        let columnsMenu = try OrganizeScopeCallSiteTests.body(
            of: "private func emptyAreaMenu(directory: String, previewSupported: Bool) -> some View {",
            in: columns)
        #expect(columnsMenu.contains("SharedFileMenuItems.sortBy(sortOption) { delegate.handleSort($0) }"),
                "the columns' background menu has no Sort By")
    }
}
