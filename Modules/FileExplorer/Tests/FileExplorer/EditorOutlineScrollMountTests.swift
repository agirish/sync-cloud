import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// Checks that `EditorOutlineScroll`'s pure rules reach the scroll view AppKit builds. A restore that
/// computes the right row and never reaches `.scrollPosition(id:)` passes every pure test.
@MainActor
@Suite(.serialized) struct EditorOutlineScrollMountTests {

    private func outline(_ count: Int) -> [MarkdownOutlineEntry] {
        (1...count).map {
            MarkdownOutlineEntry(line: $0 * 2, level: 2, depth: 1, title: "Heading number \($0)")
        }
    }

    /// Where the view's writes land, so the recording half can be asserted too.
    final class AnchorBox { var anchors: [String: Int] = [:] }

    private func mount(anchors: [String: Int], current: Int? = nil,
                       rows: Int = 40, box: AnchorBox? = nil) -> NSWindow {
        let store = box ?? AnchorBox()
        store.anchors = anchors
        let rail = EditorFileRailView(
            folderName: "Notes",
            entries: [EditorRailEntry(path: "/a/one.md", name: "one.md", size: 10,
                                      isCloudOnly: false)],
            selectedPath: "/a/one.md",
            accent: .blue, accentFill: .blue, onAccent: .white,
            tab: .constant(.outline),
            isNaming: .constant(false), typedName: .constant(""),
            prefilledName: { "Untitled.md" }, refusal: { _ in nil },
            filter: .constant(""), filterIsExpanded: .constant(false),
            outline: outline(rows), currentOutlineIndex: current,
            outlineAnchors: Binding(get: { store.anchors }, set: { store.anchors = $0 }),
            onOpen: { _ in }, onCreate: { _ in true },
            onNewTextFile: nil, folderTrail: nil, onGoToFolder: nil,
            rowActions: .inert)
        let host = NSHostingView(rootView: AnyView(rail))
        host.frame = NSRect(x: 0, y: 0, width: 232, height: 260)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        // The opening scroll is decided in the first update, but AppKit applies it on a later
        // layout, so pump a few passes.
        for _ in 0..<30 {
            _ = CFRunLoopRunInMode(.defaultMode, 0.02, true)
            window.layoutIfNeeded()
        }
        return window
    }

    private func scrollOffset(_ window: NSWindow) -> CGFloat? {
        var found: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, found == nil { found = s }
            for sub in v.subviews { walk(sub) }
        }
        walk(window.contentView!)
        return found.map { $0.documentVisibleRect.origin.y }
    }

    /// Control: an unscrolled outline with the caret in no section sits at the top, so a non-zero
    /// offset below is this code's doing, not the list's resting state.
    @Test func anOutlineWithNothingToGoOnSitsAtTheTop() throws {
        let offset = try #require(scrollOffset(mount(anchors: [:])),
                                  "no NSScrollView in the mounted rail — this test cannot see anything")
        #expect(abs(offset) < 1, "an unscrolled outline started at \(offset)")
    }

    /// End to end: a remembered line for this path, through `restoreTarget`, into
    /// `.scrollPosition(id:)`, out as a scrolled `NSScrollView`.
    @Test func aRememberedAnchorReallyScrollsTheMountedOutline() throws {
        let offset = try #require(scrollOffset(mount(anchors: ["/a/one.md": 60])))
        #expect(offset > 1, "the outline did not move for a remembered anchor: offset \(offset)")
    }

    /// Anchored at the top with the caret in the last of forty headings, the list opens further
    /// down than the anchor alone would put it. An offscreen host ignores scrolls issued after its
    /// first update pass, so the reveal must be decided in that pass to show up here.
    @Test func aCaretHeadingPastTheFoldOpensTheListFurtherDownThanTheAnchor() throws {
        let anchored = try #require(scrollOffset(mount(anchors: ["/a/one.md": 2])))
        let revealed = try #require(scrollOffset(mount(anchors: ["/a/one.md": 2], current: 39)))
        #expect(abs(anchored) < 1, "the anchor alone did not open at the top: \(anchored)")
        #expect(revealed > anchored + 1,
                "the caret's heading did not override the anchor: \(anchored) then \(revealed)")
    }

    /// The anchor stands when it already shows the caret's heading: the negative control for the
    /// test above, which "always scroll to the caret" would also pass.
    @Test func aCaretHeadingTheAnchorAlreadyShowsDoesNotMoveTheList() throws {
        let plain = try #require(scrollOffset(mount(anchors: ["/a/one.md": 60])))
        // Row 30 is line 60 — the anchor itself, so it is on screen by construction.
        let withCaret = try #require(scrollOffset(mount(anchors: ["/a/one.md": 60], current: 29)))
        #expect(abs(withCaret - plain) < 1,
                "the caret moved a list that was already showing it: \(plain) then \(withCaret)")
    }

    /// The opening scroll goes through the binding the reader's scrolling reports on, so it is
    /// recorded, and as the revealed row, not the anchor it overrode: that is where the list is.
    @Test func theOpeningScrollIsWrittenBackAsTheDocumentsAnchor() {
        let box = AnchorBox()
        _ = mount(anchors: ["/a/one.md": 2], current: 39, box: box)
        // Row 39 of the outline built here is line 80.
        #expect(box.anchors["/a/one.md"] == 80,
                "the opened position was not recorded: \(String(describing: box.anchors["/a/one.md"]))")
    }

    /// The row height the fold is computed from matches a drawn row. A drifted estimate would call
    /// a heading visible that isn't, or reveal one that already was.
    @Test func theRowHeightEstimateMatchesADrawnRow() {
        for scale in FontSize.allCases.map(\.scale) {
            let row = EditorFileRailView.outlineRowProbe(
                MarkdownOutlineEntry(line: 2, level: 2, depth: 1, title: "Heading number 1"),
                isCurrent: false)
                .environment(\.appFontScale, scale)
            let drawn = NSHostingView(rootView: AnyView(row)).fittingSize.height
            let estimated = EditorOutlineScroll.rowHeight(scale: scale)
            #expect(abs(drawn - estimated) < 3,
                    "a drawn row measured \(drawn) against an estimate of \(estimated) at scale \(scale)")
        }
    }
}
