import Testing
import AppKit
import Design
import SwiftUI
@testable import Dashboard

/// Escape closes the search field **and nothing else**.
///
/// This is the “close, keep selection” half of the design, and it is not a property of any code in
/// this repo — it is a property of how SwiftUI routes Escape, which had to be MEASURED rather than
/// reasoned about. The pane column that hosts this header carries its own `.onKeyPress(.escape)`
/// that CLEARS the pane's selection (`ContentView.paneColumn`), so if both handlers ran, dismissing
/// the field would also throw away the hit the walk had just selected.
///
/// Measured on macOS 26: with the field focused, its `onExitCommand` consumes the key outright and
/// the ancestor's `.onKeyPress(.escape)` is never invoked at all. So no guard is needed in
/// `paneColumn` — and this test is what will say so if that ever stops being true, because the
/// symptom otherwise is a selection that quietly disappears when you dismiss a search.
@MainActor
@Suite struct PaneSearchEscapeTests {

    final class Box: ObservableObject {
        @Published var query = "tax"
        @Published var isExpanded = true
        /// Whether the ancestor's Escape handler — the stand-in for the pane's selection clear —
        /// ever ran.
        @Published var ancestorSawEscape = false
    }

    /// A header with an open field, wrapped in the same `.onKeyPress(.escape)` the pane column puts
    /// around it.
    private struct Harness: View {
        @ObservedObject var box: Box

        var body: some View {
            PaneHeader(
                title: "Left", provider: nil, rootPath: "/root", relativePath: "",
                canGoBack: false, canGoForward: false,
                onBack: {}, onForward: {}, onNavigate: { _ in }, onNavigateBoth: { _ in },
                sortOption: .constant(.name), showHiddenFiles: .constant(false),
                searchText: Binding(get: { box.query }, set: { box.query = $0 }),
                searchIsExpanded: Binding(get: { box.isExpanded }, set: { box.isExpanded = $0 }))
            .onKeyPress(.escape) {
                box.ancestorSawEscape = true
                return .handled
            }
        }
    }

    private static func fieldEditor(_ window: NSWindow) -> NSTextView? {
        var found: NSTextView?
        func walk(_ v: NSView) {
            if found == nil, let text = v as? NSTextView, text.isEditable { found = text }
            for sub in v.subviews where found == nil { walk(sub) }
        }
        walk(window.contentView!)
        return found
    }

    @Test("Escape closes the field, clears the query, and never reaches the pane's own handler")
    func escapeBelongsToTheField() async {
        let box = Box()
        let host = NSHostingView(rootView: Harness(box: box).frame(width: 560))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()

        // The field claims focus one Task hop after it appears. Without this the test would send
        // Escape to nothing and pass vacuously.
        let focused = await LayoutPumpWait.pump(window, upTo: 5) { Self.fieldEditor(window) != nil }
        #expect(focused.held, "the revealed field should exist and be editable (\(focused.pumps) pumps)")

        Self.fieldEditor(window)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        let closed = await LayoutPumpWait.pump(window, upTo: 5) { !box.isExpanded }
        #expect(closed.held, "Escape should close the field (\(closed.pumps) pumps)")
        #expect(box.query.isEmpty,
                "a query left live behind a hidden field is a filter you cannot see or undo")
        #expect(!box.ancestorSawEscape,
                "the pane's own Escape handler clears the SELECTION — it must not also run here")
    }
}
