import Testing
import AppKit
@testable import SyncCloud

/// **Where the Go-to field is, asked of a real toolbar.**
///
/// The anchor decides three things — how wide the list draws, where it hangs, and (since the click
/// rule started sparing the field) whether a click on the control the user is typing into closes
/// the palette. All three go wrong the same way if this answers confidently about the wrong place,
/// which is why the refusal below matters as much as the measurement above it.
///
/// This suite exists because `goToFieldItemView`'s window requirement was loosened on 2026-08-19
/// and backed out the same hour: with `view.window != nil` in place of `view.window === host`, a
/// fixture whose host was parked at `(-9000, -9000)` got a confident anchor at `(1272, 444)`. The
/// rule's own doc carries the argument; these are the measurements.
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

    /// A field wrapped in the container the toolbar item hosts, which is what the anchor measures —
    /// the whole capsule, not the text field inside it.
    private func itemView() -> NSView {
        let container = NSView(frame: CGRect(x: 10, y: 20, width: 200, height: 28))
        let field = NSTextField(string: "")
        field.isEditable = true
        field.frame = container.bounds
        container.addSubview(field)
        return container
    }

    /// Returns the delegate alongside the window because **`NSToolbar` holds its delegate weakly** —
    /// dropping it on the floor leaves a toolbar with no items and every assertion here failing for
    /// a reason that has nothing to do with the rule under test.
    ///
    /// The window is not parked off-display: a `.titled` window's frame is constrained onto a
    /// screen whatever origin it is given (measured here and in `CommandPalettePanelTests.makeHost`),
    /// so pretending otherwise would be a fixture lying about itself. Nothing is ordered in.
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

    /// **The case the guard is for: an item whose view is not in the window.**
    ///
    /// That is what macOS leaves behind when it folds a toolbar item behind the overflow chevron,
    /// and `convert(_:to: nil)` on such a view answers in its own bounds — so the frame that comes
    /// back is a plausible 200×28 at some window's corner, which the caller cannot tell from a real
    /// anchor. Reached here by taking the view back out of the hierarchy, which is the one way to
    /// produce the state deterministically: a `.titled` host is constrained onto a display and its
    /// toolbar is built whether or not anything is ordered in.
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

    /// A view in a **different** window is refused too, and this is the measurement that backed out
    /// the loosened guard: the rect it would otherwise have produced is real, plausible and nowhere
    /// near the host.
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
