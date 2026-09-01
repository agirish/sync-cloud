import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// The rules in `EditorOutlineScroll` are pure and tested as such. This asks the other half of the
/// question: **is any of it wired to the scroll view AppKit actually built?** A restore that
/// computes the right row and never reaches `.scrollPosition(id:)` passes every test in that file.
@MainActor
@Suite(.serialized) struct EditorOutlineScrollMountTests {

    private func outline(_ count: Int) -> [MarkdownOutlineEntry] {
        (1...count).map {
            MarkdownOutlineEntry(line: $0 * 2, level: 2, depth: 1, title: "Heading number \($0)")
        }
    }

    /// Somewhere for the view's writes to land, so the recording half can be asserted rather than
    /// only the restoring half.
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
            accent: .blue, onAccent: .white,
            tab: .constant(.outline),
            isNaming: .constant(false), typedName: .constant(""),
            prefilledName: { "Untitled.md" }, refusal: { _ in nil },
            filter: .constant(""), filterIsExpanded: .constant(false),
            outline: outline(rows), currentOutlineIndex: current,
            outlineAnchors: Binding(get: { store.anchors }, set: { store.anchors = $0 }),
            onOpen: { _ in }, onCreate: { _ in true })
        let host = NSHostingView(rootView: AnyView(rail))
        host.frame = NSRect(x: 0, y: 0, width: 232, height: 260)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        // The opening scroll is decided during the first update — which is the point of deciding
        // it there. A few passes anyway, because AppKit applies it on the layout after.
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

    /// The positive control the assertions below need: an outline nobody has scrolled, with the
    /// caret in no section, sits at the top — so a non-zero offset anywhere below is something this
    /// code did and not the list's resting state.
    @Test func anOutlineWithNothingToGoOnSitsAtTheTop() throws {
        let offset = try #require(scrollOffset(mount(anchors: [:])),
                                  "no NSScrollView in the mounted rail — this test cannot see anything")
        #expect(abs(offset) < 1, "an unscrolled outline started at \(offset)")
    }

    /// **The wiring, end to end**: a remembered line for this path, through `restoreTarget`, into
    /// `.scrollPosition(id:)`, out as a scrolled `NSScrollView`.
    @Test func aRememberedAnchorReallyScrollsTheMountedOutline() throws {
        let offset = try #require(scrollOffset(mount(anchors: ["/a/one.md": 60])))
        #expect(offset > 1, "the outline did not move for a remembered anchor: offset \(offset)")
    }

    /// **The other half of the decision, in pixels.** Anchored at the very top with the caret in the
    /// last heading of forty, the list has to open further down than the anchor alone would put it.
    ///
    /// This is the assertion the first design could not make: the reveal was decided from
    /// `onScrollTargetVisibilityChange`, and nothing an offscreen host does after its first update
    /// pass takes effect — a scroll issued from that callback, by binding or by `ScrollViewProxy`,
    /// never landed, so a working reveal and a dead one measured the same 0.0.
    @Test func aCaretHeadingPastTheFoldOpensTheListFurtherDownThanTheAnchor() throws {
        let anchored = try #require(scrollOffset(mount(anchors: ["/a/one.md": 2])))
        let revealed = try #require(scrollOffset(mount(anchors: ["/a/one.md": 2], current: 39)))
        #expect(abs(anchored) < 1, "the anchor alone did not open at the top: \(anchored)")
        #expect(revealed > anchored + 1,
                "the caret's heading did not override the anchor: \(anchored) then \(revealed)")
    }

    /// And it leaves the anchor alone when the caret's heading is one the anchor already shows —
    /// the negative control for the test above, without which "it always scrolls to the caret"
    /// would pass just as well.
    @Test func aCaretHeadingTheAnchorAlreadyShowsDoesNotMoveTheList() throws {
        let plain = try #require(scrollOffset(mount(anchors: ["/a/one.md": 60])))
        // Row 30 is line 60 — the anchor itself, so it is on screen by construction.
        let withCaret = try #require(scrollOffset(mount(anchors: ["/a/one.md": 60], current: 29)))
        #expect(abs(withCaret - plain) < 1,
                "the caret moved a list that was already showing it: \(plain) then \(withCaret)")
    }

    /// **The remembering half.** The opening scroll goes through the same binding the reader's own
    /// scrolling reports on, so a list that opens somewhere writes that somewhere down — and the
    /// value written is the revealed row, not the anchor it overrode, because the list really is
    /// there now.
    @Test func theOpeningScrollIsWrittenBackAsTheDocumentsAnchor() {
        let box = AnchorBox()
        _ = mount(anchors: ["/a/one.md": 2], current: 39, box: box)
        // Row 39 of the outline built here is line 80.
        #expect(box.anchors["/a/one.md"] == 80,
                "the opened position was not recorded: \(String(describing: box.anchors["/a/one.md"]))")
    }

    /// The estimate the fold is computed from has to match the rows actually drawn. **A row height
    /// that drifts from the real one is an estimate answering a different question** — it would
    /// call a heading visible that is not, or reveal one that was already there.
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
