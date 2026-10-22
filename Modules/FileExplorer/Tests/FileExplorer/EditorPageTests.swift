import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// Page: Source's text on the system's text background — the column and its margins with
/// Readable Line Length on, the whole editor without it — and the window left as it was outside.
///
/// Switches are read on ``defaults``, a scratch suite of this test's own, for the reason
/// `EditorReadableColumnTests` gives.
@MainActor
@Suite(.serialized) struct EditorPageTests {

    private let defaults = ScratchDefaults("EditorPageTests")

    /// **Off by default**, so nobody's editor changes colour on upgrade.
    @Test func theSwitchIsOffByDefault() {
        #expect(EditorTextSettings.drawsPageDefault == false)
        #expect(EditorTextView().drawsPage == false)
    }

    /// The page is the column plus the 14pt margin the text always keeps — and the whole view
    /// wherever nothing caps the text.
    @Test func thePageIsTheColumnAndItsMargins() {
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 400)
        #expect(EditorTextView.pageRect(in: bounds, horizontalInset: 14) == bounds)
        #expect(EditorTextView.pageRect(in: bounds, horizontalInset: 140)
                == NSRect(x: 126, y: 0, width: 748, height: 400))
        #expect(EditorTextView.pageRect(in: bounds, horizontalInset: 10) == bounds,
                "an inset under the base one grew the page past the view")
    }

    // MARK: The pixels

    private func hosted(width: CGFloat, column: CGFloat?, wraps: Bool = true, appearance: NSAppearance.Name)
        -> (window: NSWindow, view: EditorTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let scroll = EditorTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        scroll.autoresizingMask = [.width, .height]
        window.contentView = scroll
        window.appearance = NSAppearance(named: appearance)
        let view = scroll.documentView as! EditorTextView
        view.font = PlainTextEditor.font(scale: 1)
        view.drawsBackground = false    // as `makeNSView` sets it
        view.textContainerInset = EditorReadableColumn.baseInset
        view.string = "one line"
        PlainTextEditor.applyWrapping(wraps, to: view, in: scroll)
        view.readableColumnWidth = column
        return (window, view)
    }

    /// The pixel at `x` (in points), well below the one line of text, as drawn.
    private func pixels(of view: NSTextView, at xs: [CGFloat]) throws -> [NSColor] {
        let rect = NSRect(x: 0, y: 200, width: view.bounds.width, height: 20)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: rep)
        let scale = CGFloat(rep.pixelsWide) / rect.width
        return try xs.map { try #require(rep.colorAt(x: Int($0 * scale), y: rep.pixelsHigh / 2)) }
    }

    /// **With the cap on, the page is the column and its margins and nothing else**: opaque
    /// white from one margin's edge to the other, the window's own (transparent) ground outside —
    /// and with the switch off, the column too is the window's, so the assertion can fail.
    @Test func inLightModeThePageIsWhiteAndOnlyTheColumn() throws {
        let rig = hosted(width: 1000, column: 720, appearance: .aqua)
        defer { withExtendedLifetime(rig.window) {} }
        let edge = rig.view.pageRect.minX
        try #require(edge > 100, "the column never capped the text — the measure would be vacuous")

        rig.view.drawsPage = true
        let on = try pixels(of: rig.view, at: [edge - 4, edge + 2, rig.view.bounds.midX,
                                                rig.view.pageRect.maxX - 2, rig.view.pageRect.maxX + 4])
        #expect(on[0].alphaComponent < 0.05, "the left margin is painted: \(on[0])")
        for c in on[1...3] {
            #expect(c.alphaComponent > 0.99 && c.redComponent > 0.97 && c.greenComponent > 0.97
                    && c.blueComponent > 0.97, "the page is not white: \(c)")
        }
        #expect(on[4].alphaComponent < 0.05, "the right margin is painted: \(on[4])")

        rig.view.drawsPage = false
        let off = try pixels(of: rig.view, at: [rig.view.bounds.midX])
        #expect(off[0].alphaComponent < 0.05, "switched off, the column is still painted: \(off[0])")
    }

    /// **In Dark Mode the page follows the appearance** — opaque and dark, not white.
    @Test func inDarkModeThePageIsDark() throws {
        let rig = hosted(width: 1000, column: 720, appearance: .darkAqua)
        defer { withExtendedLifetime(rig.window) {} }
        rig.view.drawsPage = true
        let c = try pixels(of: rig.view, at: [rig.view.bounds.midX])[0]
        #expect(c.alphaComponent > 0.99 && c.redComponent < 0.3 && c.greenComponent < 0.3
                && c.blueComponent < 0.3, "the dark page is \(c)")
    }

    /// **With no cap — Readable Line Length off, or Wrap Lines off — the page is the whole editor.**
    @Test func withNoCapThePageSpansTheEditor() throws {
        for wraps in [true, false] {
            let rig = hosted(width: 1000, column: nil, wraps: wraps, appearance: .aqua)
            defer { withExtendedLifetime(rig.window) {} }
            rig.view.drawsPage = true
            #expect(rig.view.pageRect.minX == 0)
            let row = try pixels(of: rig.view, at: [2, rig.view.bounds.midX, 990])
            for c in row {
                #expect(c.alphaComponent > 0.99 && c.redComponent > 0.97,
                        "wraps \(wraps): the edge-to-edge page has a hole: \(c)")
            }
        }
    }

    /// **A resize moves the page with the column** — the margins grow, the page keeps the column.
    @Test func aResizeMovesThePageWithTheColumn() {
        let rig = hosted(width: 1000, column: 720, appearance: .aqua)
        defer { withExtendedLifetime(rig.window) {} }
        rig.view.drawsPage = true
        for width: CGFloat in [1400, 600, 1100] {
            rig.window.setContentSize(NSSize(width: width, height: 400))
            rig.window.contentView?.layoutSubtreeIfNeeded()
            let page = rig.view.pageRect
            let expected = max(0, (rig.view.frame.width - 720) / 2 - 14)
            #expect(abs(page.minX - expected) < 0.01 && abs(page.width - (rig.view.frame.width - 2 * expected)) < 0.01,
                    "at \(rig.view.frame.width)pt the page is \(page)")
        }
    }

    // MARK: Past the text's ends

    /// The pixels at `xs` (in the clip's points) in a 20pt strip `y` down the clip's bounds, as the
    /// clip draws them — its own drawing and the text view's, as a rubber-band scroll shows them.
    private func pixels(of clip: NSClipView, y: CGFloat, at xs: [CGFloat]) throws -> [NSColor] {
        let rect = NSRect(x: clip.bounds.minX, y: y, width: clip.bounds.width, height: 20)
        let rep = try #require(clip.bitmapImageRepForCachingDisplay(in: rect))
        clip.cacheDisplay(in: rect, to: rep)
        let scale = CGFloat(rep.pixelsWide) / rect.width
        return try xs.map { try #require(rep.colorAt(x: Int(($0 - rect.minX) * scale), y: rep.pixelsHigh / 2)) }
    }

    /// The clip with the text view hidden, so what is drawn is the clip's alone — what an elastic
    /// scroll past either end, or typewriter scrolling's room, shows. Not the clip's bounds moved
    /// off the text: outside a live scroll AppKit constrains them back onto the document — measured,
    /// a `setBoundsOrigin` past the top landed on the text, and a text view moved down took the
    /// bounds with it.
    private func clipAlone(_ rig: (window: NSWindow, view: EditorTextView)) throws -> EditorDocumentClipView {
        let clip = try #require(rig.view.enclosingScrollView?.contentView as? EditorDocumentClipView)
        rig.view.isHidden = true
        return clip
    }

    /// **Past either end the page goes on — the column and its margins, nothing else.** The clip
    /// paints the band on its own, and the band runs the clip's full height whatever its bounds,
    /// so an overscroll's strip above or below the text is page too. With the switch off the clip
    /// paints nothing, so the assertion can fail.
    @Test func pastTheTextTheClipCarriesThePagesBand() throws {
        let rig = hosted(width: 1000, column: 720, appearance: .aqua)
        defer { withExtendedLifetime(rig.window) {} }
        let page = rig.view.pageRect
        try #require(page.minX > 100, "the column never capped the text — the measure would be vacuous")
        rig.view.drawsPage = true
        let clip = try clipAlone(rig)
        let band = try #require(clip.pageBand)
        #expect(band.minY == clip.bounds.minY && band.maxY == clip.bounds.maxY,
                "the band stops short of the clip's ends: \(band) in \(clip.bounds)")
        for y in [clip.bounds.minY + 4, clip.bounds.midY, clip.bounds.maxY - 24] {
            let row = try pixels(of: clip, y: y, at: [page.minX - 4, page.minX + 2, page.midX,
                                                     page.maxX - 2, page.maxX + 4])
            #expect(row[0].alphaComponent < 0.05, "at \(y): the left margin is painted: \(row[0])")
            for c in row[1...3] {
                #expect(c.alphaComponent > 0.99 && c.redComponent > 0.97 && c.greenComponent > 0.97
                        && c.blueComponent > 0.97, "at \(y): the clip leaves a hole in the page: \(c)")
            }
            #expect(row[4].alphaComponent < 0.05, "at \(y): the right margin is painted: \(row[4])")
        }

        rig.view.drawsPage = false
        #expect(clip.pageBand == nil)
        let off = try pixels(of: clip, y: clip.bounds.midY, at: [page.midX])
        #expect(off[0].alphaComponent < 0.05, "switched off, the clip still paints the page: \(off[0])")
    }

    /// **With no cap the clip's page is edge to edge** — wrapped, and unwrapped too, where a
    /// sideways overscroll shows the clip past the text's right end.
    @Test func withNoCapTheClipsPageIsEdgeToEdge() throws {
        for wraps in [true, false] {
            let rig = hosted(width: 1000, column: nil, wraps: wraps, appearance: .aqua)
            defer { withExtendedLifetime(rig.window) {} }
            rig.view.drawsPage = true
            let clip = try clipAlone(rig)
            #expect(clip.pageBand == clip.bounds, "wraps \(wraps): the band is \(String(describing: clip.pageBand))")
            for c in try pixels(of: clip, y: clip.bounds.midY, at: [2, 500, 990]) {
                #expect(c.alphaComponent > 0.99 && c.redComponent > 0.97,
                        "wraps \(wraps): the clip leaves a hole in the page: \(c)")
            }
        }
    }

    // MARK: Where the editor applies it

    private func mounted() -> (host: NSHostingView<AnyView>, view: EditorTextView) {
        let editor = PlainTextEditor(source: EditorSourceStorage(text: "words\n"),
                                     isEditable: true, fontScale: 1,
                                     documentID: "/a/b.txt", undoManager: UndoManager())
        let host = NSHostingView(rootView: AnyView(editor.defaultAppStorage(defaults)))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        host.layoutSubtreeIfNeeded()
        var found: EditorTextView?
        func walk(_ v: NSView) {
            if let scroll = v as? NSScrollView, scroll.identifier == EditorDocumentSurface.identifier {
                found = scroll.documentView as? EditorTextView
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        return (host, found!)
    }

    /// **The editor reads the switch and hands it to the text view** — never set is off, and a
    /// flip under a mounted editor arrives through `updateNSView`.
    @Test func theEditorAppliesTheSwitch() {
        defaults.removeObject(forKey: EditorTextSettings.drawsPageKey)
        let rig = mounted()
        #expect(rig.view.drawsPage == false, "the page is on with nothing stored")
        defaults.set(true, forKey: EditorTextSettings.drawsPageKey)
        rig.host.rootView = rig.host.rootView
        rig.host.layoutSubtreeIfNeeded()
        #expect(rig.view.drawsPage == true, "turning the switch on left a mounted editor without a page")
        defaults.set(false, forKey: EditorTextSettings.drawsPageKey)
        rig.host.rootView = rig.host.rootView
        rig.host.layoutSubtreeIfNeeded()
        #expect(rig.view.drawsPage == false, "turning it off left the page in place")
    }

    // MARK: The header's switch

    /// Shown wherever a file's text was read, writable or not; greyed only in Preview.
    @Test func theHeaderSwitchIsOfferedWhereThereIsText() {
        #expect(EditorWorkspaceView.showsPageSwitch(hasPath: true, wasRefused: false))
        #expect(!EditorWorkspaceView.showsPageSwitch(hasPath: true, wasRefused: true))
        #expect(!EditorWorkspaceView.showsPageSwitch(hasPath: false, wasRefused: false))
        #expect(EditorWorkspaceView.pageSwitchApplies(.edit))
        #expect(EditorWorkspaceView.pageSwitchApplies(.split))
        #expect(!EditorWorkspaceView.pageSwitchApplies(.preview))
    }
}
