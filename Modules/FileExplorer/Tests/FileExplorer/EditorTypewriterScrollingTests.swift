import Testing
import SwiftUI
import AppKit
@testable import FileExplorer

/// Typewriter scrolling (TE62): with Text ▸ Typewriter Scrolling on, a keyboard move of Source's
/// caret holds its line at mid-height; a click, a selection and an input method scroll as AppKit
/// always has, and off is AppKit's own throughout.
///
/// **Every assertion is against the off control or a literal**, never the rule against itself: a
/// caret brought into view by AppKit lands at the screen's edge, a centred one at its middle, and
/// the gap between them is many lines.
@MainActor
@Suite(.serialized) struct EditorTypewriterScrollingTests {

    private let defaults = ScratchDefaults("EditorTypewriterScrollingTests")

    // MARK: The setting

    /// **Off by default**, on its own key: nobody's editor starts moving under them on upgrade.
    @Test func theSwitchIsOffByDefault() {
        #expect(EditorTextSettings.typewriterScrollingDefault == false)
        #expect(EditorTextSettings.typewriterScrollingKey == "editorTypewriterScrolling")
        #expect(EditorTextView().typewriterScrolling == false)
    }

    // MARK: The text view

    /// 400 numbered lines in the editor's own text view, in a buried window `height` tall.
    private func hosted(height: CGFloat = 400, text: String? = nil, on: Bool)
        -> (window: NSWindow, scroll: EditorDocumentScrollView, view: EditorTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.buryUnderEverything()
        let scroll = EditorTextView.scrollableTextView() as! EditorDocumentScrollView
        scroll.hasVerticalScroller = true
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: height)
        scroll.autoresizingMask = [.width, .height]
        window.contentView = scroll
        let view = scroll.documentView as! EditorTextView
        view.font = PlainTextEditor.font(scale: 1)
        view.drawsBackground = false
        view.textContainerInset = EditorReadableColumn.baseInset
        view.string = text ?? (1...400).map { "line \($0)" }.joined(separator: "\n")
        PlainTextEditor.applyWrapping(true, to: view, in: scroll)
        // The caret at the top, as a fresh editor's is after `restoreCaret` — so turning the switch
        // on below centres nothing, and the on and off rigs start alike.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.typewriterScrolling = on
        window.makeFirstResponder(view)
        settle(window)
        return (window, scroll, view)
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<3 {
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
    }

    /// The UTF-16 offset of the start of 1-based `line` in the hosted text.
    private func offset(ofLine line: Int, in view: NSTextView) -> Int {
        let text = view.string as NSString
        var location = 0
        for _ in 1..<line { location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0))) }
        return location
    }

    /// Where the caret's line sits on screen: its centre's distance from the top of the clip, as a
    /// share of the clip's height — 0.5 is centred.
    ///
    /// **Measured by AppKit's `firstRect`, not by ``EditorTextView/caretRect(at:)``**, which is the
    /// rule's own measure: asked of the rule, a wrong row would be centred and measured centred.
    private func caretShare(_ rig: (window: NSWindow, scroll: EditorDocumentScrollView, view: EditorTextView)) throws -> CGFloat {
        let caret = try caretRectByAppKit(rig.view, at: rig.view.selectedRange().location)
        let bounds = rig.scroll.contentView.bounds
        return (caret.midY - bounds.minY) / bounds.height
    }

    /// The caret's rectangle in the view, as AppKit's text input answers it.
    private func caretRectByAppKit(_ view: NSTextView, at offset: Int) throws -> NSRect {
        let onScreen = view.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
        try #require(onScreen.height > 0, "AppKit has no rectangle for the caret at \(offset)")
        let window = try #require(view.window)
        return view.convert(window.convertFromScreen(onScreen), from: nil)
    }

    private typealias Rig = (window: NSWindow, scroll: EditorDocumentScrollView, view: EditorTextView)

    private func placeCaret(_ rig: Rig, atLine line: Int) {
        place(rig, NSRange(location: offset(ofLine: line, in: rig.view), length: 0))
    }

    private func place(_ rig: Rig, _ range: NSRange) {
        rig.view.setSelectedRange(range)
        rig.view.scrollRangeToVisible(range)
        settle(rig.window)
    }

    /// The start of the line drawn at `share` of the screen's height.
    private func lineOnScreen(at share: CGFloat, _ rig: Rig) -> NSRange {
        let bounds = rig.scroll.contentView.bounds
        let index = rig.view.characterIndexForInsertion(at: NSPoint(x: 40, y: bounds.minY + bounds.height * share))
        let line = (rig.view.string as NSString).lineRange(for: NSRange(location: index, length: 0))
        return NSRange(location: line.location, length: 0)
    }

    /// **On, a caret low on the screen comes up to the middle; off, AppKit leaves a visible caret
    /// where it is** — the control that makes the first worth anything. (A caret OFF the screen
    /// is no control: TextKit 2's own scroll centres that one too, measured at 0.49.)
    @Test func aBareCaretIsCentredOnlyWhileOn() throws {
        let on = hosted(on: true), off = hosted(on: false)
        defer { withExtendedLifetime((on.window, off.window)) {} }
        for rig in [on, off] { place(rig, lineOnScreen(at: 0.85, rig)) }
        let onShare = try caretShare(on), offShare = try caretShare(off)
        #expect(abs(onShare - 0.5) < 0.03, "on, the caret's line sits at \(onShare) of the height")
        #expect(offShare > 0.8, "off, AppKit moved a visible caret to \(offShare)")
        #expect(off.scroll.contentView.bounds.minY == 0, "off, a visible caret scrolled the text")
        #expect(on.view.textLayoutManager != nil && off.view.textLayoutManager != nil,
                "the editor fell back to TextKit 1")
    }

    /// The UTF-16 offset of a line far down a long file still lands centred — Go to Line, a heading
    /// jump — with TextKit 2 laid out from the caret, not from the top.
    @Test func aFarCaretInALongFileIsCentred() throws {
        let text = (1...6000).map { "line \($0) " + String(repeating: "word ", count: $0 % 7) }.joined(separator: "\n")
        let rig = hosted(text: text, on: true)
        defer { withExtendedLifetime(rig.window) {} }
        placeCaret(rig, atLine: 4800)
        let share = try caretShare(rig)
        #expect(abs(share - 0.5) < 0.03, "line 4800 sits at \(share) of the height")
        let shown = try caretRectByAppKit(rig.view, at: rig.view.selectedRange().location)
        let index = rig.view.characterIndexForInsertion(at: NSPoint(x: 30, y: shown.midY))
        let line = (rig.view.string as NSString).substring(to: index).filter { $0 == "\n" }.count + 1
        #expect(line == 4800, "the line drawn at the caret's height is \(line), not the caret's")
    }

    /// **The end of the file reaches mid-height too** — the bottom inset is what lets it; without
    /// it the last line could only sit at the bottom edge.
    @Test func theLastLineReachesMidHeight() throws {
        let rig = hosted(on: true)
        defer { withExtendedLifetime(rig.window) {} }
        let end = (rig.view.string as NSString).length
        rig.view.setSelectedRange(NSRange(location: end, length: 0))
        rig.view.scrollRangeToVisible(NSRange(location: end, length: 0))
        settle(rig.window)
        let share = try caretShare(rig)
        #expect(abs(share - 0.5) < 0.03, "the last line sits at \(share) of the height")
    }

    /// **…and the empty line after a final line break** — where a caret goes after Return at the
    /// end of a file, and TextKit 2 has no fragment of its own.
    @Test func theEmptyLastLineReachesMidHeight() throws {
        let rig = hosted(text: (1...400).map { "line \($0)" }.joined(separator: "\n") + "\n", on: true)
        defer { withExtendedLifetime(rig.window) {} }
        place(rig, NSRange(location: (rig.view.string as NSString).length, length: 0))
        let share = try caretShare(rig)
        #expect(abs(share - 0.5) < 0.03, "the empty last line sits at \(share) of the height")
    }

    /// **Turned on, the caret's line comes to the middle at once** — not at the next keystroke.
    @Test func turningItOnCentresTheCaretAtOnce() throws {
        let rig = hosted(on: false)
        defer { withExtendedLifetime(rig.window) {} }
        placeCaret(rig, atLine: 150)
        place(rig, lineOnScreen(at: 0.85, rig))
        let before = try caretShare(rig)
        try #require(before > 0.8, "the caret is at \(before) — this proves nothing")
        rig.view.typewriterScrolling = true
        settle(rig.window)
        let share = try caretShare(rig)
        #expect(abs(share - 0.5) < 0.03, "turned on, the caret's line sits at \(share)")
    }

    /// **Unwrapped, a caret far along a long line is brought in sideways as well** — centring
    /// only the height would leave it off the right edge.
    @Test func anUnwrappedCaretIsBroughtInSideways() throws {
        let long = String(repeating: "a long unwrapped line ", count: 80)
        let rig = hosted(text: (1...200).map { "line \($0) " + ($0 == 120 ? long : "") }.joined(separator: "\n"), on: true)
        defer { withExtendedLifetime(rig.window) {} }
        PlainTextEditor.applyWrapping(false, to: rig.view, in: rig.scroll)
        settle(rig.window)
        let start = offset(ofLine: 120, in: rig.view)
        place(rig, NSRange(location: start + ("line 120 " as NSString).length + (long as NSString).length - 5, length: 0))
        let caret = try caretRectByAppKit(rig.view, at: rig.view.selectedRange().location)
        let bounds = rig.scroll.contentView.bounds
        #expect(caret.minX > 600, "the caret is at x \(caret.minX) — not far along the line, this proves nothing")
        #expect(bounds.minX <= caret.minX && caret.maxX <= bounds.maxX,
                "the caret at x \(caret.minX) is off the screen's \(bounds.minX)…\(bounds.maxX)")
        #expect(abs((caret.midY - bounds.minY) / bounds.height - 0.5) < 0.03, "and not centred in height")
    }

    /// **The first line stays where it is**: there is no room above it, and none is invented.
    @Test func theFirstLinesStayAtTheTop() throws {
        let rig = hosted(on: true)
        defer { withExtendedLifetime(rig.window) {} }
        placeCaret(rig, atLine: 100)
        placeCaret(rig, atLine: 2)
        #expect(abs(rig.scroll.contentView.bounds.minY) < 1, "the clip is at \(rig.scroll.contentView.bounds.minY)")
    }

    /// **A wrapped paragraph centres the caret's ROW, not the paragraph** — the line being typed.
    @Test func aWrappedParagraphCentresTheCaretsRow() throws {
        let paragraph = String(repeating: "a long paragraph that wraps across many rows ", count: 60)
        let text = (1...80).map { "line \($0)" }.joined(separator: "\n") + "\n" + paragraph + "\n"
            + (1...80).map { "after \($0)" }.joined(separator: "\n")
        let rig = hosted(text: text, on: true)
        defer { withExtendedLifetime(rig.window) {} }
        let start = offset(ofLine: 81, in: rig.view)
        // Near the paragraph's end: its middle would be many rows above the caret.
        let range = NSRange(location: start + (paragraph as NSString).length - 20, length: 0)
        rig.view.setSelectedRange(range)
        rig.view.scrollRangeToVisible(range)
        settle(rig.window)
        let share = try caretShare(rig)
        #expect(abs(share - 0.5) < 0.03, "the caret's row sits at \(share) of the height")
    }

    // MARK: What it leaves alone

    /// **A selection scrolls as AppKit's does** — a Find match is shown where it always was.
    @Test func aSelectionKeepsNormalScrolling() throws {
        let on = hosted(on: true), off = hosted(on: false)
        defer { withExtendedLifetime((on.window, off.window)) {} }
        for rig in [on, off] {
            let range = NSRange(location: offset(ofLine: 150, in: rig.view), length: 4)
            rig.view.setSelectedRange(range)
            rig.view.scrollRangeToVisible(range)
            settle(rig.window)
        }
        let onTop = on.scroll.contentView.bounds.minY, offTop = off.scroll.contentView.bounds.minY
        #expect(abs(onTop - offTop) < 1, "a selection scrolled to \(onTop) on and \(offTop) off")
    }

    /// **An input method composing is not moved under its candidate window** — a caret low on the
    /// screen stays there, as off, where a centring would move it up half a screen.
    @Test func markedTextLeavesItToAppKit() throws {
        let rig = hosted(on: true)
        defer { withExtendedLifetime(rig.window) {} }
        let range = lineOnScreen(at: 0.85, rig)
        rig.view.setSelectedRange(range)
        rig.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: range)
        try #require(rig.view.hasMarkedText())
        rig.view.scrollRangeToVisible(NSRange(location: range.location + 1, length: 0))
        settle(rig.window)
        let share = try caretShare(rig)
        #expect(share > 0.8, "while composing the caret was moved to \(share)")
    }

    /// **And a composing caret already at mid-height stays put** — AppKit sees the whole screen as
    /// visible, room below the text included, so it has nothing to scroll.
    @Test func aCentredCompositionDoesNotJitter() throws {
        let rig = hosted(on: true)
        defer { withExtendedLifetime(rig.window) {} }
        placeCaret(rig, atLine: 150)
        let before = rig.scroll.contentView.bounds.minY
        let range = rig.view.selectedRange()
        rig.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: range)
        rig.view.scrollRangeToVisible(NSRange(location: range.location + 1, length: 0))
        settle(rig.window)
        #expect(rig.scroll.contentView.bounds.minY == before,
                "composing at mid-height scrolled \(before) → \(rig.scroll.contentView.bounds.minY)")
    }

    /// **With Page on, the room below the last line is page too** — the column and its margins,
    /// the window outside them, as above the end of the text. The room is the clip's, past the end
    /// of the text view that draws the page, so it is drawn there. Rendered and read back, against
    /// a pixel of the page above it.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func withPageOnTheRoomBelowTheTextIsPage(_ appearance: NSAppearance.Name) throws {
        let rig = hosted(text: (1...40).map { "line \($0)" }.joined(separator: "\n"), on: true)
        defer { withExtendedLifetime(rig.window) {} }
        rig.window.appearance = NSAppearance(named: appearance)
        rig.view.readableColumnWidth = 360
        rig.view.drawsPage = true
        place(rig, NSRange(location: (rig.view.string as NSString).length, length: 0))
        let clip = rig.scroll.contentView
        let room = clip.bounds.maxY - rig.view.frame.maxY
        try #require(room > 120, "only \(room)pt of room on screen — this proves nothing")
        let page = rig.view.pageRect
        try #require(page.minX > 60, "the page spans the editor — the margin check would be vacuous")

        func pixels(atY y: CGFloat, _ xs: [CGFloat]) throws -> [NSColor] {
            let rect = NSRect(x: 0, y: y - 2, width: clip.bounds.width, height: 4)
            let rep = try #require(clip.bitmapImageRepForCachingDisplay(in: rect))
            clip.cacheDisplay(in: rect, to: rep)
            let scale = CGFloat(rep.pixelsWide) / rect.width
            return try xs.map { try #require(rep.colorAt(x: Int($0 * scale), y: rep.pixelsHigh / 2)) }
        }
        let xs = [page.minX - 30, page.minX + 4, page.midX, page.maxX - 4, page.maxX + 30]
        // Above the end of the text, between two lines' ink: the text view's own page.
        let above = try pixels(atY: rig.view.frame.maxY - 4, xs)
        try #require(above[2].alphaComponent > 0.99, "Page drew nothing above the room: \(above[2])")
        let below = try pixels(atY: clip.bounds.maxY - 30, xs)
        for i in 1...3 {
            #expect(below[i].alphaComponent > 0.99 && abs(below[i].redComponent - above[2].redComponent) < 0.02,
                    "the room at x \(xs[i]) is \(below[i]), the page above it \(above[2])")
        }
        #expect(below[0].alphaComponent < 0.05 && below[4].alphaComponent < 0.05,
                "the room's margins are painted: \(below[0]), \(below[4])")

        // **The clip redraws the room when the page or its column changes** — `cacheDisplay` above
        // draws afresh whatever is marked, so only a real display pass sees a room left stale.
        // Counted, because `needsDisplay` reads back false here even just after being set; and
        // a pass is a run-loop turn and a flush, since `displayIfNeeded` alone draws nothing.
        let roomClip = try #require(clip as? EditorDocumentClipView)
        var drawn: [NSRect] = []
        roomClip.onDraw = { drawn.append($0) }
        defer { roomClip.onDraw = nil }
        rig.window.orderFrontRegardless()
        defer { rig.window.orderOut(nil) }
        func pass() { settle(rig.window); CATransaction.flush(); rig.window.display() }
        let roomRect = NSRect(x: 0, y: rig.view.frame.maxY + 1, width: clip.bounds.width, height: 10)
        clip.setNeedsDisplay(clip.bounds)
        pass()
        try #require(drawn.contains { $0.intersects(roomRect) }, "the clip never drew on screen — counting proves nothing")
        drawn = []
        pass()
        try #require(drawn.isEmpty, "the clip draws on every pass — counting proves nothing: \(drawn)")
        rig.view.readableColumnWidth = 300
        pass()
        #expect(drawn.contains { $0.intersects(roomRect) }, "a narrower column left the room's old page standing: \(drawn)")
        drawn = []
        // Off again, the room is the window's.
        rig.view.drawsPage = false
        pass()
        #expect(drawn.contains { $0.intersects(roomRect) }, "Page off left the room's page standing: \(drawn)")
        settle(rig.window)
        #expect(try pixels(atY: clip.bounds.maxY - 30, xs)[2].alphaComponent < 0.05, "Page off left the room painted")
    }

    // MARK: The keyboard (decision BI)

    private func key(_ code: UInt16, _ characters: String, function: Bool = true, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero,
                         modifierFlags: function ? [.function, .numericPad] : [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    /// **↓ re-centres; off, ↓ inside the screen scrolls nothing.** A real key event, through the
    /// window, so this is AppKit's own path from the key to the scroll.
    @Test func anArrowKeyReCentres() throws {
        let on = hosted(on: true), off = hosted(on: false)
        defer { withExtendedLifetime((on.window, off.window)) {} }
        placeCaret(on, atLine: 150)
        placeCaret(off, atLine: 150)
        let onBefore = on.scroll.contentView.bounds.minY, offBefore = off.scroll.contentView.bounds.minY
        // Up, so the off control's caret stays on screen and AppKit has no reason to scroll.
        for rig in [on, off] {
            for _ in 0..<3 { rig.window.sendEvent(key(126, "\u{F700}", in: rig.window)) }
            settle(rig.window)
        }
        #expect(on.view.selectedRange().location == offset(ofLine: 147, in: on.view), "↑ did not move the caret")
        let share = try caretShare(on)
        #expect(abs(share - 0.5) < 0.03, "after ↑↑↑ the caret's line sits at \(share)")
        #expect(on.scroll.contentView.bounds.minY < onBefore - 30, "on, ↑ scrolled nothing")
        #expect(off.scroll.contentView.bounds.minY == offBefore, "off, ↑ inside the screen scrolled")
    }

    /// **Typing re-centres too** — a Return, the commonest move of a writer's caret.
    @Test func aReturnReCentres() throws {
        let rig = hosted(on: true)
        defer { withExtendedLifetime(rig.window) {} }
        placeCaret(rig, atLine: 150)
        let before = rig.scroll.contentView.bounds.minY
        for _ in 0..<4 { rig.window.sendEvent(key(36, "\r", function: false, in: rig.window)) }
        settle(rig.window)
        #expect((rig.view.string as NSString).length > 0)
        let share = try caretShare(rig)
        #expect(abs(share - 0.5) < 0.03, "after four Returns the caret's line sits at \(share)")
        #expect(rig.scroll.contentView.bounds.minY > before + 30, "four Returns scrolled nothing")
    }

    // MARK: The room below the last line

    /// **On, the bounds may run half a screen past the end of the text, and a resize carries it;
    /// off, every bound is AppKit's** — and turning it off while scrolled into the room puts the
    /// text's end back at the bottom edge.
    @Test func theRoomBelowTheTextFollowsTheHeightAndGoesAwayCleanly() throws {
        let rig = hosted(on: false)
        defer { withExtendedLifetime(rig.window) {} }
        let clip = try #require(rig.scroll.contentView as? EditorDocumentClipView)
        func furthest() -> CGFloat {
            clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: 1e6), size: clip.bounds.size)).minY
        }
        let end = rig.view.frame.maxY, height = clip.bounds.height, appKits = furthest()
        // AppKit's own: near the text's height less the clip's — measured 6pt past it.
        #expect(abs(appKits - (end - height)) < 10, "off, the bounds run to \(appKits) for a \(end)pt text in \(height)pt")
        let insets = rig.scroll.contentInsets, automatic = rig.scroll.automaticallyAdjustsContentInsets

        rig.view.typewriterScrolling = true
        #expect(furthest() == appKits + (height / 2).rounded(), "on, a \(height)pt editor runs to \(furthest()), AppKit to \(appKits)")
        rig.window.setContentSize(NSSize(width: 600, height: 600))
        settle(rig.window)
        let taller = clip.bounds.height
        #expect(taller > height + 150, "the resize did not reach the clip: \(taller)")
        let appKitsTaller = appKits - (taller - height)
        #expect(furthest() == appKitsTaller + (taller / 2).rounded(), "after a resize to \(taller)pt: \(furthest())")
        #expect([rig.scroll.contentInsets.top, rig.scroll.contentInsets.bottom] == [insets.top, insets.bottom],
                "the content insets moved — AppKit would think part of the screen covered")
        #expect(rig.scroll.automaticallyAdjustsContentInsets == automatic)

        let fullyDown = NSPoint(x: 0, y: furthest())
        clip.scroll(to: fullyDown)
        rig.scroll.reflectScrolledClipView(clip)
        try #require(clip.bounds.minY > appKitsTaller + 100, "the clip never went into the room: \(clip.bounds.minY)")
        rig.view.typewriterScrolling = false
        #expect(clip.bounds.minY == appKitsTaller, "off again, the clip stayed in the room at \(clip.bounds.minY)")
        #expect(furthest() == appKitsTaller)
    }

    /// **The text in the lower half is drawn** — a content inset marks the region as covered, and
    /// a view that believed it would leave it blank. Rendered and read back.
    @Test func theLowerHalfIsDrawn() throws {
        let rig = hosted(on: true)
        defer { withExtendedLifetime(rig.window) {} }
        placeCaret(rig, atLine: 150)
        let view = rig.window.contentView!
        let rect = view.bounds
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: rep)
        // Rows of ink in the bottom quarter — the overscroll's own region, filled with lines 160 on.
        var inkedRows = 0
        for y in stride(from: rep.pixelsHigh * 3 / 4, to: rep.pixelsHigh, by: 2) {
            if (0..<rep.pixelsWide / 3).contains(where: { (rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.3 }) {
                inkedRows += 1
            }
        }
        #expect(inkedRows > 10, "the bottom quarter has \(inkedRows) inked rows — the text under the inset is not drawn")
    }

    // MARK: Where the editor applies it

    /// Mounts the real `PlainTextEditor` over 400 lines and returns the text view `makeNSView` built.
    private func mounted(follow: EditorScrollRequest? = nil, source: EditorSourceStorage? = nil)
        -> (window: NSWindow, host: NSHostingView<AnyView>, view: EditorTextView, source: EditorSourceStorage) {
        let storage = source ?? EditorSourceStorage(text: (1...400).map { "line \($0)" }.joined(separator: "\n"))
        let editor = PlainTextEditor(source: storage, isEditable: true, fontScale: 1,
                                     documentID: "/a/b.md", undoManager: UndoManager(), followRequest: follow)
        let host = NSHostingView(rootView: AnyView(editor.defaultAppStorage(defaults)))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.buryUnderEverything()
        window.contentView = host
        settle(window)
        var found: EditorTextView?
        func walk(_ v: NSView) {
            if let scroll = v as? NSScrollView, scroll.identifier == EditorDocumentSurface.identifier {
                found = scroll.documentView as? EditorTextView
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        return (window, host, found!, storage)
    }

    /// **The call site: the editor reads the switch and hands it to the text view** — and a flip
    /// under a mounted editor arrives, both ways. The rule above is one revert away from unused
    /// without this.
    @Test func theEditorAppliesTheSwitch() {
        defaults.removeObject(forKey: EditorTextSettings.typewriterScrollingKey)
        let rig = mounted()
        defer { withExtendedLifetime(rig.window) {} }
        let clip = rig.view.enclosingScrollView?.contentView as? EditorDocumentClipView
        #expect(clip != nil, "Source's clip is not ours")
        #expect(rig.view.typewriterScrolling == false, "on with nothing stored")
        #expect(clip?.allowsTypewriterOverscroll == false)
        defaults.set(true, forKey: EditorTextSettings.typewriterScrollingKey)
        rig.host.rootView = rig.host.rootView
        settle(rig.window)
        #expect(rig.view.typewriterScrolling, "turning the switch on did not reach a mounted editor")
        #expect(clip?.allowsTypewriterOverscroll == true, "no room below the last line")
        defaults.set(false, forKey: EditorTextSettings.typewriterScrollingKey)
        rig.host.rootView = rig.host.rootView
        settle(rig.window)
        #expect(rig.view.typewriterScrolling == false, "turning it off did not reach a mounted editor")
        #expect(clip?.allowsTypewriterOverscroll == false)
    }

    /// **Split's Preview leads, and Source follows to the line it names — at the top, not pulled to
    /// the caret.** The follow is the reader's scroll, made in the other half. It moves the clip and
    /// never the caret, so nothing reaches the centring (mutation-tested: a guard against it there
    /// changed nothing, and is not kept); this pins that it stays so.
    @Test func aPreviewLedFollowIsNotPulledBackToTheCaret() throws {
        defaults.set(true, forKey: EditorTextSettings.typewriterScrollingKey)
        let rig = mounted()
        defer { withExtendedLifetime(rig.window) {} }
        rig.view.setSelectedRange(NSRange(location: offset(ofLine: 10, in: rig.view), length: 0))
        let editor = PlainTextEditor(source: rig.source, isEditable: true, fontScale: 1, documentID: "/a/b.md",
                                     undoManager: UndoManager(), followRequest: EditorScrollRequest(line: 200, token: 1))
        rig.host.rootView = AnyView(editor.defaultAppStorage(defaults))
        settle(rig.window)
        let top = rig.view.enclosingScrollView!.contentView.bounds.minY
        let line200 = try caretRectByAppKit(rig.view, at: offset(ofLine: 200, in: rig.view))
        #expect(abs(line200.minY - rig.view.textContainerInset.height - top) < 2,
                "line 200 is at \(line200.minY), the clip at \(top) — not followed to the top")
        #expect(rig.view.selectedRange().location == offset(ofLine: 10, in: rig.view), "the follow moved the caret")
    }

    /// **An edit made from outside — Split's Preview typing into the same storage — leaves Source
    /// where the reader has it**, as off.
    @Test func anEditFromOutsideDoesNotMoveSource() throws {
        for on in [true, false] {
            let rig = hosted(on: on)
            defer { withExtendedLifetime(rig.window) {} }
            rig.view.setSelectedRange(NSRange(location: offset(ofLine: 10, in: rig.view), length: 0))
            let clip = rig.scroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: 3000))
            rig.scroll.reflectScrolledClipView(clip)
            settle(rig.window)
            let before = clip.bounds.minY
            rig.window.makeFirstResponder(nil)
            let at = offset(ofLine: 205, in: rig.view)
            rig.view.textStorage?.replaceCharacters(in: NSRange(location: at, length: 0), with: "typed elsewhere ")
            settle(rig.window)
            #expect(clip.bounds.minY == before, "\(on ? "on" : "off"): an outside edit scrolled \(before) → \(clip.bounds.minY)")
        }
    }

    // MARK: The mouse (decision BI)

    /// **A caret the mouse moves is AppKit's to scroll, never a centring** — a click, or a drag that
    /// autoscrolls. Inside ``EditorTextView/trackingMouse(_:)``, which `mouseDown(with:)` wraps
    /// around AppKit's tracking loop, a caret low on screen stays put; outside it, the same scroll
    /// centres — the control.
    @Test func theMousesCaretIsNotCentred() throws {
        let rig = hosted(on: true)
        defer { withExtendedLifetime(rig.window) {} }
        let low = lineOnScreen(at: 0.85, rig)
        rig.view.trackingMouse { place(rig, low) }
        let share = try caretShare(rig)
        #expect(share > 0.8, "a caret the mouse moved was centred to \(share)")
        place(rig, low)
        let control = try caretShare(rig)
        #expect(abs(control - 0.5) < 0.03, "the same move from the keyboard sits at \(control) — this proves nothing")
    }
}
