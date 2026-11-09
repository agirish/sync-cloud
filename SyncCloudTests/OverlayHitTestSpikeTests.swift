import AppKit
import SwiftUI
import Testing
@testable import SyncCloud

/// Does a view drawn over an AppKit table take the click, or does the table under it?
///
/// `AskClaudeWindow.swift` records that a SwiftUI overlay over the panes' tables once lost the
/// caret and let a Delete meant for the chat reach the file list. The narrow-window overlay and
/// Info's drawer put the Ask Claude column and a SwiftUI drawer over the file panes again, so this
/// walks the real hit-test over a real `NSTableView` before either is built.
@MainActor
@Suite struct OverlayHitTestSpikeTests {
    /// A pane's table, as the app hosts one: an `NSTableView` in a scroll view behind a representable.
    struct TableRep: NSViewRepresentable {
        func makeNSView(context: Context) -> NSScrollView {
            let table = NSTableView()
            table.addTableColumn(NSTableColumn(identifier: .init("name")))
            table.dataSource = context.coordinator
            let scroll = NSScrollView()
            scroll.documentView = table
            return scroll
        }
        func updateNSView(_ view: NSScrollView, context: Context) {}
        func makeCoordinator() -> Rows { Rows() }
        final class Rows: NSObject, NSTableViewDataSource {
            func numberOfRows(in tableView: NSTableView) -> Int { 40 }
            func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { "row \(row)" }
        }
    }

    private func host<V: View>(_ view: V) -> (NSWindow, NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1000, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func isInside(_ view: NSView?, _ ancestor: NSView.Type) -> Bool {
        var current = view
        while let v = current { if type(of: v) == ancestor || v.isKind(of: ancestor) { return true }; current = v.superview }
        return false
    }

    private func settle() async { for _ in 0..<12 { try? await Task.sleep(for: .milliseconds(10)) } }

    /// The column drawn as the last thing in a ZStack over a table.
    @Test func theColumnOverATableTakesTheClickAndNotTheTable() async throws {
        let controller = AskClaudeWindowController()
        let (window, hosting) = host(
            ZStack(alignment: .trailing) {
                TableRep()
                AskClaudeColumnHost(controller: controller).frame(width: 372)
            })
        await settle()
        _ = window
        // A point inside the column's 372 pt, on the table beneath it. AppKit's y runs up.
        let inColumn = NSPoint(x: 1000 - 100, y: 350)
        let hit = hosting.hitTest(inColumn)
        #expect(hit != nil)
        #expect(isInside(hit, AskClaudeColumnView.self), "the column should take the click; got \(String(describing: hit))")
        #expect(!isInside(hit, NSTableView.self), "the table under the column took the click")
        // And outside it, the table still does.
        let onTable = hosting.hitTest(NSPoint(x: 200, y: 350))
        #expect(isInside(onTable, NSTableView.self), "the table should keep the clicks outside the column; got \(String(describing: onTable))")
    }

    /// The same, as a SwiftUI `.overlay`, which is how the narrow-window overlay would be drawn.
    @Test func aSwiftUIOverlayOfTheColumnDoesTheSame() async throws {
        let controller = AskClaudeWindowController()
        let (window, hosting) = host(
            TableRep().overlay(alignment: .trailing) {
                AskClaudeColumnHost(controller: controller).frame(width: 372)
            })
        await settle()
        _ = window
        let hit = hosting.hitTest(NSPoint(x: 900, y: 350))
        #expect(isInside(hit, AskClaudeColumnView.self), "got \(String(describing: hit))")
        #expect(!isInside(hit, NSTableView.self))
    }

    /// Info's drawer is SwiftUI, not AppKit: a filled view over the table.
    @Test func aSwiftUIDrawerOverATableTakesTheClickAndNotTheTable() async throws {
        let (window, hosting) = host(
            ZStack(alignment: .trailing) {
                TableRep()
                Color.white.frame(width: 300).overlay { Button("Close") {} }
            })
        await settle()
        _ = window
        let hit = hosting.hitTest(NSPoint(x: 900, y: 350))
        #expect(hit != nil)
        #expect(!isInside(hit, NSTableView.self), "the table under the drawer took the click; got \(String(describing: hit))")
        let onTable = hosting.hitTest(NSPoint(x: 200, y: 350))
        #expect(isInside(onTable, NSTableView.self))
    }

    /// An empty, transparent column area must not let a click fall through to the table either.
    @Test func theColumnsBackgroundBlocksTheClickToo() async throws {
        let controller = AskClaudeWindowController()
        let (window, hosting) = host(
            ZStack(alignment: .trailing) {
                TableRep()
                AskClaudeColumnHost(controller: controller).frame(width: 372)
            })
        await settle()
        _ = window
        // Near the top-left corner of the column, where nothing is drawn in an empty host.
        let hit = hosting.hitTest(NSPoint(x: 1000 - 370, y: 690))
        #expect(!isInside(hit, NSTableView.self), "a click on the column's empty edge reached the table; got \(String(describing: hit))")
    }
}
