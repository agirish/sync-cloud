import Testing
import AppKit
import Design
import SwiftUI
@testable import Dashboard

/// A space typed into the pane search field must reach the query.
///
/// **This is the measurement the Quick Look defect turned on, so it is a test rather than a
/// comment.** The pane column carried `.onKeyPress(.space)` — Space → Quick Look — from before the
/// search field existed, and its own note said the scoping made it safe: onKeyPress "only fires
/// while key focus is inside this subtree (the pane Lists) … so text fields elsewhere get Space
/// normally." The field is not elsewhere. It is inside that subtree.
///
/// Whether that actually matters depends on something no amount of reading settles: does SwiftUI
/// give an ancestor's `.onKeyPress` the key before the focused `TextField` gets it? Escape does the
/// opposite — `PaneSearchEscapeTests` measured the field consuming it outright and the ancestor
/// never running — so the two directions genuinely had to be checked separately, and the answers
/// differ.
///
/// Measured here with a real `keyDown` through `NSWindow.sendEvent`, not `insertText`, which would
/// skip the routing that is the entire subject.
@MainActor
@Suite struct PaneSearchSpaceTests {

    final class Box: ObservableObject {
        @Published var query = "tax"
        @Published var isExpanded = true
        /// Whether the ancestor's Space handler — the stand-in for Space → Quick Look — ever ran.
        @Published var ancestorSawSpace = false
    }

    /// A header with an open field, wrapped in the `.onKeyPress(.space)` the pane column used to
    /// put around it.
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
            .onKeyPress(.space) {
                box.ancestorSawSpace = true
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

    /// The fixture window: key, and **never ordered in**.
    ///
    /// This suite used to `makeKeyAndOrderFront`, which stood a 560×120 titled window — an empty
    /// title bar over a pane header with "tax" in its field — in the middle of the user's desktop
    /// for the length of every package run. `DetailsWhereItLivesTests` had already measured the
    /// general form of this ("ordered in" and "on a display" are separate things); here the
    /// stronger answer holds, because nothing in these tests reads the backing store: the key is
    /// delivered by hand through `sendEvent`, and what routes it is the responder chain, not the
    /// window server.
    ///
    /// Measured three ways, both tests, same verdict — key and ordered front (the old arrangement),
    /// key and never ordered in (this one), and no key at all: all three pass, including the two
    /// halves that would go vacuous first, the field holding first responder and the query growing
    /// a space. `makeKey()` is what is kept, because focus is the thing these tests are about and
    /// it is one call rather than none; `ExpandingSearchFieldTests` mounts its field the same way.
    ///
    /// `windowIsUnseen` is the guard: it fails if a later edit orders this window in again.
    private static func unseenWindow(hosting host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKey()
        window.layoutIfNeeded()
        return window
    }

    /// The other direction, and the one a well-meant edit trips: a fixture window the user can see.
    ///
    /// Both halves of "unseen" are named rather than just the mechanism this suite happens to use —
    /// an ordered-in window parked past every display (what `DetailsWhereItLivesTests` does, because
    /// its card must render) would be just as fine. What fails here is a window standing on a
    /// screen. Mutation-verified by restoring `makeKeyAndOrderFront`.
    ///
    /// The screen half goes vacuous on a host with no displays attached; the visibility half does
    /// not, and it is the one that carries this suite.
    private static func windowIsUnseen(_ window: NSWindow,
                                       sourceLocation: SourceLocation = #_sourceLocation) {
        let frame = window.frame
        #expect(!window.isVisible || NSScreen.screens.allSatisfy { !$0.frame.intersects(frame) },
                "the fixture window is on a display at \(frame) — it covers whatever the user is doing for the length of the run",
                sourceLocation: sourceLocation)
    }

    /// A real space keystroke, delivered the way the window system delivers one.
    private static func sendSpace(to window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)
        else { return }
        window.sendEvent(event)
    }

    /// **The bug, as an assertion.** With a Space handler wrapped around the header, a space typed
    /// into the focused field was swallowed: the query never grew and the ancestor fired instead —
    /// which in the app opened the Quick Look panel over whatever the pane had selected, and the
    /// panel then took key focus, so typing stopped dead.
    ///
    /// Both halves are checked, and the ancestor half is the one that matters: a query that fails
    /// to grow could just as easily mean the harness never delivered the key at all, and this test
    /// would then pass for the wrong reason once the arrangement is fixed.
    @Test("An ancestor Space handler swallows the space the field was typed")
    func anAncestorHandlerStealsTheSpace() async {
        let box = Box()
        let host = NSHostingView(rootView: Harness(box: box).frame(width: 560))
        let window = Self.unseenWindow(hosting: host)

        let focused = await LayoutPumpWait.pump(window, upTo: 5) { Self.fieldEditor(window) != nil }
        #expect(focused.held, "the revealed field should exist and be editable (\(focused.pumps) pumps)")
        #expect(Self.fieldEditor(window)?.window?.firstResponder === Self.fieldEditor(window),
                "the field must hold the caret, or this test measures nothing")

        Self.sendSpace(to: window)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { box.ancestorSawSpace }

        #expect(box.ancestorSawSpace,
                "the ancestor never saw the space — the scoping rule this test exists to pin has changed, and PaneQuickLookScopeTests now guards a hazard that no longer exists")
        #expect(!box.query.contains(" "),
                "the space reached the query as well — the two handlers are not in conflict after all")
        Self.windowIsUnseen(window)
    }

    /// The control, and the shipped arrangement: the same field with no Space handler above it takes
    /// the space itself. Without this the test above proves only that *something* ate the key.
    @Test("With no handler above it, the field takes the space")
    func theBareFieldKeepsItsSpace() async {
        let box = Box()
        let host = NSHostingView(rootView:
            PaneHeader(
                title: "Left", provider: nil, rootPath: "/root", relativePath: "",
                canGoBack: false, canGoForward: false,
                onBack: {}, onForward: {}, onNavigate: { _ in }, onNavigateBoth: { _ in },
                sortOption: .constant(.name), showHiddenFiles: .constant(false),
                searchText: Binding(get: { box.query }, set: { box.query = $0 }),
                searchIsExpanded: Binding(get: { box.isExpanded }, set: { box.isExpanded = $0 }))
            .frame(width: 560))
        let window = Self.unseenWindow(hosting: host)

        let focused = await LayoutPumpWait.pump(window, upTo: 5) { Self.fieldEditor(window) != nil }
        #expect(focused.held, "the revealed field should exist (\(focused.pumps) pumps)")

        Self.sendSpace(to: window)
        let typed = await LayoutPumpWait.pump(window, upTo: 5) { box.query.contains(" ") }
        #expect(typed.held, "a space typed into an unobstructed field should reach the query (\(typed.pumps) pumps, query \"\(box.query)\") — if this fails the harness cannot deliver a keystroke and the test above proves nothing")
        #expect(!box.ancestorSawSpace, "there is no ancestor handler in this arm")
        Self.windowIsUnseen(window)
    }
}
