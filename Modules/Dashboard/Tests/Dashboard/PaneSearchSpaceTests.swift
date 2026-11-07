import Testing
import AppKit
import Design
import SwiftUI
@testable import Dashboard

/// A space typed into the pane search field must reach the query.
///
/// SwiftUI gives an ancestor's `.onKeyPress(.space)` the key before the focused `TextField`, so a
/// Space → Quick Look handler on a subtree holding the field swallows every space typed into it
/// (`PaneQuickLookScopeTests` keeps the handler off that subtree). Escape routes the other way
/// (`PaneSearchEscapeTests`), so each key needs its own test. Sent as a real `keyDown` through
/// `NSWindow.sendEvent`, not `insertText`, which would skip the routing under test.
@MainActor
@Suite struct PaneSearchSpaceTests {

    final class Box: ObservableObject {
        @Published var query = "tax"
        @Published var isExpanded = true
        /// Whether the ancestor's Space handler, standing in for Space → Quick Look, ran.
        @Published var ancestorSawSpace = false
    }

    /// A header with an open field, wrapped in an ancestor `.onKeyPress(.space)` like a pane-wide
    /// Quick Look handler.
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

    /// The fixture window: key, and never ordered in, so no test window stands on the user's desktop
    /// during a run. Nothing here reads the backing store: the key goes in through `sendEvent` and
    /// the responder chain routes it, not the window server. `makeKey()` stays because focus is the
    /// subject; `ExpandingSearchFieldTests` mounts its field the same way. `windowIsUnseen` fails if
    /// the window is ever ordered in again.
    private static func unseenWindow(hosting host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKey()
        window.layoutIfNeeded()
        return window
    }

    /// Fails when the fixture window stands on a display the user can see. An ordered-in window
    /// parked past every display (as `DetailsWhereItLivesTests` does) also passes. Restoring
    /// `makeKeyAndOrderFront` must make it fail. The screen half is vacuous with no displays
    /// attached; the visibility half is not.
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

    /// With a Space handler around the header, a space typed into the focused field is swallowed:
    /// the ancestor fires instead, which in the app would open Quick Look and take key focus. The
    /// ancestor half is the one that matters; a query that fails to grow could also mean the key
    /// was never delivered.
    @Test("An ancestor Space handler swallows the space the field was typed")
    func anAncestorHandlerStealsTheSpace() async {
        let box = Box()
        let host = NSHostingView(rootView: Harness(box: box).frame(width: 560))
        let window = Self.unseenWindow(hosting: host)

        let focused = await LayoutPumpWait.pump(window, upTo: 5) { FieldEditor.find(in: window) != nil }
        #expect(focused.held, "the revealed field should exist and be editable (\(focused.pumps) pumps)")
        #expect(FieldEditor.find(in: window)?.window?.firstResponder === FieldEditor.find(in: window),
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

        let focused = await LayoutPumpWait.pump(window, upTo: 5) { FieldEditor.find(in: window) != nil }
        #expect(focused.held, "the revealed field should exist (\(focused.pumps) pumps)")

        Self.sendSpace(to: window)
        let typed = await LayoutPumpWait.pump(window, upTo: 5) { box.query.contains(" ") }
        #expect(typed.held, "a space typed into an unobstructed field should reach the query (\(typed.pumps) pumps, query \"\(box.query)\") — if this fails the harness cannot deliver a keystroke and the test above proves nothing")
        #expect(!box.ancestorSawSpace, "there is no ancestor handler in this arm")
        Self.windowIsUnseen(window)
    }
}
