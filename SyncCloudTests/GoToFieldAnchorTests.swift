import Testing
import AppKit
@testable import SyncCloud

/// Where the Go-to field is, asked of a real toolbar. The anchor decides how wide the list draws,
/// where it hangs, and whether a click on the field closes the palette, so the refusals matter as
/// much as the measurement. `goToFieldItemView` needs `view.window === host`; `!= nil` would
/// accept a view in another window and anchor somewhere plausible and wrong.
@MainActor
@Suite struct GoToFieldAnchorTests {
    /// A toolbar with exactly one item, whose view the test owns and can put wherever it likes.
    private final class OneItem: NSObject, NSToolbarDelegate {
        static let id = NSToolbarItem.Identifier("gotofield")
        let view: NSView
        init(view: NSView) { self.view = view }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.id] }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.id] }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = view
            return item
        }
    }

    /// The field in the container the toolbar item hosts: the anchor measures the whole capsule.
    private func itemView() -> NSView {
        let container = NSView(frame: CGRect(x: 10, y: 20, width: 200, height: 28))
        let field = NSTextField(string: "")
        field.isEditable = true
        field.frame = container.bounds
        container.addSubview(field)
        return container
    }

    /// Returns the delegate too, because **`NSToolbar` holds its delegate weakly**; dropped, the
    /// toolbar has no items and every assertion fails for an unrelated reason. Not parked off-display:
    /// a `.titled` window's frame is constrained onto a screen (as in
    /// `CommandPalettePanelTests.makeHost`). Nothing is ordered in.
    private func host(carrying view: NSView) -> (NSWindow, OneItem) {
        let host = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let delegate = OneItem(view: view)
        let toolbar = NSToolbar(identifier: "gototest")
        toolbar.delegate = delegate
        host.toolbar = toolbar
        return (host, delegate)
    }

    /// The ordinary case, and the fixture's own proof that it can see anything at all.
    @Test func theFieldInTheHostIsFoundAndMeasuredInScreenSpace() throws {
        let view = itemView()
        let (host, delegate) = host(carrying: view)
        defer { _ = delegate }
        host.contentView?.addSubview(view)
        #expect(view.window === host, "the fixture never got the item's view into the host")

        let found = try #require(ContentView.goToFieldItemView(in: host),
                                 "the toolbar's editable item was not found — the refusal below would pass for the wrong reason")
        #expect(found === view)
        #expect(ContentView.goToFieldScreenFrame(in: host)
                == host.convertToScreen(view.convert(view.bounds, to: nil)))
    }

    /// An item view outside the window is refused. macOS leaves that behind when it folds an item
    /// behind the overflow chevron, and `convert(_:to: nil)` then answers in its own bounds: a
    /// plausible 200×28 at a window corner. Removing the view from the hierarchy reaches that state.
    @Test func anItemViewOutsideTheWindowIsRefusedRatherThanMeasured() {
        let view = itemView()
        let (host, delegate) = host(carrying: view)
        defer { _ = delegate }
        host.contentView?.addSubview(view)
        #expect(ContentView.goToFieldItemView(in: host) != nil, "the fixture never found the item to begin with")

        view.removeFromSuperview()
        #expect(view.window == nil, "the stand-in is still in a window — the refusal below is not exercised")
        #expect(ContentView.goToFieldItemView(in: host) == nil,
                "a folded toolbar item was measured — the palette anchors its list to the window's corner")
        #expect(ContentView.goToFieldScreenFrame(in: host) == nil)
    }

    /// A view in a different window is refused too: the rect it would produce is real, plausible and
    /// nowhere near the host.
    @Test func anItemViewInAnotherWindowIsRefused() {
        let view = itemView()
        let (host, delegate) = host(carrying: view)
        defer { _ = delegate }
        let elsewhere = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        elsewhere.isReleasedWhenClosed = false
        elsewhere.contentView?.addSubview(view)
        #expect(view.window === elsewhere, "the fixture never moved the view into the other window")

        #expect(ContentView.goToFieldItemView(in: host) == nil,
                "a view in another window was accepted as this window's Go to field")
    }
}
