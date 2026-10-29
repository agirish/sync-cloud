import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// Readable Line Length (TE51): Source's text in a centred column no wider than Preview's, made by
/// growing the text view's side insets.
///
/// **Every switch is read and written on ``defaults``, a scratch suite of this test's own** — the
/// hosted editors through `.defaultAppStorage`, the menu through the coordinator's store. Never the
/// standard domain: under `swift test` that is `swiftpm-testing-helper`'s, shared by every test
/// process on the machine, so `.serialized` could only ever order this suite against itself.
@MainActor
@Suite(.serialized) struct EditorReadableColumnTests {

    /// A fresh one per test: swift-testing builds a new instance of the suite for each.
    private let defaults = ScratchDefaults("EditorReadableColumnTests")

    // MARK: The rule

    /// **Off by default.** Source has always run edge to edge; nobody's editor changes shape on
    /// upgrade.
    @Test func theSwitchIsOffByDefault() {
        #expect(EditorTextSettings.readableLineLengthDefault == false)
        #expect(EditorReadableColumn.column(enabled: EditorTextSettings.readableLineLengthDefault,
                                            wraps: true, fontScale: 1) == nil)
    }

    /// The cap is Preview's 720pt at the default Text size — and there is none with the switch off,
    /// or with Wrap Lines off, where one long line is the point.
    @Test func theCapIsPreviewsWidthAndOnlyWhileLinesWrap() {
        #expect(EditorReadableColumn.column(enabled: true, wraps: true, fontScale: 1) == 720)
        #expect(EditorReadableColumn.column(enabled: false, wraps: true, fontScale: 1) == nil)
        #expect(EditorReadableColumn.column(enabled: true, wraps: false, fontScale: 1) == nil,
                "an unwrapped line is capped — turning wrapping off would only move where it starts")
    }

    /// **The column holds the same number of characters at every Text size** — it grows exactly as
    /// the editor's own font does, damped ramp included, not by the bare scale.
    @Test func theColumnScalesWithTheEditorsFont() throws {
        for scale: CGFloat in [0.9, 1.15, 1.35] {
            let column = try #require(EditorReadableColumn.column(enabled: true, wraps: true, fontScale: scale))
            let font = PlainTextEditor.font(scale: scale).pointSize
            #expect(abs(column / font - 720 / 13) < 0.001,
                    "at \(scale) the column is \(column)pt for \(font)pt text — \(column / font) to the point, not \(720 / 13)")
        }
        // And it does move: larger text, wider column.
        let large = try #require(EditorReadableColumn.column(enabled: true, wraps: true, fontScale: 1.35))
        #expect(large > 720)
    }

    /// The inset centres the column exactly — and a view too narrow for the cap keeps today's 14pt,
    /// which is the case that must not change at all.
    @Test func theInsetCentresTheColumnAndNeverShrinksBelowToday() {
        #expect(EditorReadableColumn.horizontalInset(viewWidth: 1000, column: 720) == 140)
        #expect(EditorReadableColumn.horizontalInset(viewWidth: 1001, column: 720) == 140.5,
                "rounded: the column is 721pt here and 720pt a pixel away, and lines re-wrap as a window is dragged")
        #expect(EditorReadableColumn.horizontalInset(viewWidth: 600, column: 720) == 14,
                "a pane narrower than the cap lost its margin")
        #expect(EditorReadableColumn.horizontalInset(viewWidth: 749, column: 720) == 14.5)
        #expect(EditorReadableColumn.horizontalInset(viewWidth: 747, column: 720) == 14)
        #expect(EditorReadableColumn.horizontalInset(viewWidth: 1000, column: nil) == 14)
        #expect(EditorReadableColumn.baseInset == NSSize(width: 14, height: 12))
    }

    // MARK: The text view

    /// The editor's own text view, in a window, `width` wide, holding enough text to wrap.
    private func hosted(width: CGFloat, column: CGFloat?, legacyScrollers: Bool = false, text: String? = nil)
        -> (window: NSWindow, scroll: NSScrollView, view: EditorTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let scroll = EditorTextView.scrollableTextView()
        if legacyScrollers { scroll.scrollerStyle = .legacy }
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true    // as `makeNSView` sets it: the scroller comes and goes
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        scroll.autoresizingMask = [.width, .height]
        window.contentView = scroll
        let view = scroll.documentView as! EditorTextView
        view.font = PlainTextEditor.font(scale: 1)
        view.drawsBackground = false    // as `makeNSView` sets it — and so only the text inks
        view.textContainerInset = EditorReadableColumn.baseInset
        view.string = text ?? String(repeating: "readable line length keeps prose in a column ", count: 30)
        PlainTextEditor.applyWrapping(true, to: view, in: scroll)
        view.readableColumnWidth = column
        return (window, scroll, view)
    }

    /// **The column is centred, the container is the column, and the view stays on TextKit 2** —
    /// nothing here may read `layoutManager`.
    @Test func aWideViewCentresTheColumn() {
        let rig = hosted(width: 1000, column: 720)
        defer { withExtendedLifetime(rig.window) {} }
        let width = rig.view.frame.width
        let inset = rig.view.textContainerInset.width
        #expect(inset == (width - 720) / 2, "the inset is \(inset) in a \(width)pt view")
        #expect(abs((rig.view.textContainer?.size.width ?? 0) - (width - 2 * inset)) < 0.5,
                "the container is \(rig.view.textContainer?.size.width ?? 0)pt, not the column")
        #expect(rig.view.textContainerInset.height == 12, "the top inset moved")
        #expect(rig.view.textLayoutManager != nil, "the editor fell back to TextKit 1")
    }

    /// **A resize re-centres it, both ways** — and below the cap the view is exactly as it was.
    @Test func resizingReCentresTheColumn() {
        let rig = hosted(width: 1000, column: 720)
        defer { withExtendedLifetime(rig.window) {} }
        for width: CGFloat in [1400, 600, 1100] {
            rig.window.setContentSize(NSSize(width: width, height: 400))
            rig.window.contentView?.layoutSubtreeIfNeeded()
            let viewWidth = rig.view.frame.width
            let expected = EditorReadableColumn.horizontalInset(viewWidth: viewWidth, column: 720)
            #expect(rig.view.textContainerInset.width == expected,
                    "at \(viewWidth)pt the inset is \(rig.view.textContainerInset.width), not \(expected)")
            #expect(abs((rig.view.textContainer?.size.width ?? 0) - (viewWidth - 2 * expected)) < 0.5)
        }
        #expect(rig.view.textLayoutManager != nil)
    }

    /// **Past the cap, a live resize slides the text and never re-wraps it**: the container is the
    /// column exactly, a pixel at a time.
    @Test func pastTheCapTheContainerIsExactlyTheColumn() {
        let rig = hosted(width: 800, column: 720)
        defer { withExtendedLifetime(rig.window) {} }
        for width in stride(from: CGFloat(800), through: 820, by: 1) {
            rig.window.setContentSize(NSSize(width: width, height: 400))
            rig.window.contentView?.layoutSubtreeIfNeeded()
            #expect(rig.view.textContainer?.size.width == 720,
                    "at \(width)pt the container is \(rig.view.textContainer?.size.width ?? 0)pt")
        }
    }

    /// **Taking the cap away puts today's inset back**, in place — Readable Line Length or Wrap
    /// Lines turned off under a mounted view.
    @Test func clearingTheCapRestoresTheBaseInset() {
        let rig = hosted(width: 1000, column: 720)
        defer { withExtendedLifetime(rig.window) {} }
        #expect(rig.view.textContainerInset.width > 14)
        rig.view.readableColumnWidth = nil
        #expect(rig.view.textContainerInset.width == 14)
        #expect(abs((rig.view.textContainer?.size.width ?? 0) - (rig.view.frame.width - 28)) < 0.5)
    }

    /// **No oscillation where a legacy scroller comes and goes.** Narrowing the column makes the
    /// text taller, which can bring a vertical scroller that narrows the view — the classic loop.
    /// Swept across the cap's edge in width and across the text's own height in height, so the
    /// scroller is both there and not: each size settles on the rule's answer for the width the
    /// view ended up, and asking again changes nothing.
    @Test func theInsetSettlesAcrossTheScrollerBoundary() {
        let rig = hosted(width: 760, column: 720, legacyScrollers: true)
        defer { withExtendedLifetime(rig.window) {} }
        var scrollerStates: Set<Bool> = []
        for width: CGFloat in [744, 748, 752, 760, 766] {
            for height in stride(from: CGFloat(120), through: 520, by: 8) {
                rig.window.setContentSize(NSSize(width: width, height: height))
                rig.window.contentView?.layoutSubtreeIfNeeded()
                rig.scroll.tile()
                scrollerStates.insert(rig.view.frame.width < width - 1)
                let settled = rig.view.textContainerInset.width
                #expect(settled == EditorReadableColumn.horizontalInset(viewWidth: rig.view.frame.width, column: 720),
                        "at \(width)×\(height) the inset is \(settled) in a \(rig.view.frame.width)pt view")
                rig.view.setFrameSize(rig.view.frame.size)
                #expect(rig.view.textContainerInset.width == settled, "at \(width)×\(height) a repeat pass moved the inset")
            }
        }
        #expect(scrollerStates == [true, false],
                "the sweep never crossed the scroller's boundary — it saw only \(scrollerStates)")
    }

    /// **One resize sets the inset once, to the new width's** — never back to the old width's.
    ///
    /// Setting the inset makes the text view re-fit itself at its current width, which inside
    /// `setFrameSize` is still the OLD one; unguarded, that nested pass undid the inset and a later
    /// re-fit redid it — three re-wraps a frame across the Expand animation, measured in the app.
    @Test(.machinePinned(.layoutMetrics)) func aResizeSetsTheInsetOnceAndNeverBackToTheOldWidth() {
        let rig = hosted(width: 1000, column: 720)
        defer { withExtendedLifetime(rig.window) {} }
        rig.view.layoutSubtreeIfNeeded()
        for width in [1010.0, 1025, 1240, 1180] as [CGFloat] {
            let old = rig.view.textContainerInset.width
            var set: [CGFloat] = []
            rig.view.onReadableInset = { set.append($0) }
            rig.view.setFrameSize(NSSize(width: width, height: rig.view.frame.height))
            rig.view.onReadableInset = nil
            #expect(set == [(width - 720) / 2],
                    "a resize to \(width) from an inset of \(old) set the inset to \(set)")
            #expect(rig.view.textContainerInset.width == (width - 720) / 2)
        }
    }

    /// **A resize past the cap leaves the text under the pointer where it was** — in a scrolled long
    /// document, the case where it went wrong.
    ///
    /// The column does not change past the cap, so nothing should re-wrap. It did: the inset's own
    /// setter resized the tracking container against the OLD width before `super` gave it the new
    /// one, TextKit 2 dropped the visible layout on that detour, and laid it out again from an
    /// estimate — 460 to 837 characters away from where it had been, measured 2026-10-10, so a click
    /// on a line the reader was looking at landed 10–15 lines off.
    @Test func aResizePastTheCapKeepsTheTextUnderThePointer() {
        let rig = hosted(width: 1000, column: 720, text: (0..<1500).map { i in
            i % 3 == 0 ? "para \(i) " + String(repeating: "lorem ipsum dolor sit amet consectetur ", count: 6)
                       : "line \(i) short"
        }.joined(separator: "\n"))
        defer { withExtendedLifetime(rig.window) {} }
        func settle() {
            rig.window.contentView?.layoutSubtreeIfNeeded()
            rig.window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            rig.window.contentView?.layoutSubtreeIfNeeded()
            rig.window.displayIfNeeded()
        }
        settle()
        rig.view.scroll(NSPoint(x: 0, y: 30000))
        settle()
        func underThePointer() -> Int {
            let visible = rig.view.visibleRect
            return rig.view.characterIndexForInsertion(
                at: NSPoint(x: rig.view.textContainerOrigin.x + 10, y: visible.minY + 30))
        }
        let before = underThePointer()
        #expect(before > 10_000, "the probe is not scrolled into the document — it reads \(before)")
        for width in [1002.0, 1004, 1006, 1040, 1100] as [CGFloat] {
            rig.window.setContentSize(NSSize(width: width, height: 400))
            settle()
            #expect(underThePointer() == before,
                    "a resize to \(width)pt moved the text under the pointer from \(before) to \(underThePointer())")
            #expect(rig.view.textContainer?.widthTracksTextView == true, "tracking was left off")
        }
    }

    /// The x of the end of the first visual line, asked as a click in the right margin is.
    private func firstLineEnd(of view: NSTextView) -> Int {
        let y = view.textContainerInset.height + 4
        return view.characterIndexForInsertion(at: NSPoint(x: view.frame.width - 2, y: y))
    }

    /// **Clicks in the margins land in the text** — the left margin at the start of the line, the
    /// right at the end of the first visual line, which now wraps at the column, not at the edge.
    @Test func aClickInEitherMarginLandsOnTheLineBesideIt() {
        let capped = hosted(width: 1200, column: 720)
        let free = hosted(width: 1200, column: nil)
        defer { withExtendedLifetime((capped.window, free.window)) {} }
        let y = capped.view.textContainerInset.height + 4
        #expect(capped.view.characterIndexForInsertion(at: NSPoint(x: 3, y: y)) == 0,
                "a click in the left margin missed the start of the line")
        let advance = ("m" as NSString).size(withAttributes: [.font: PlainTextEditor.font(scale: 1)]).width
        let padding = 2 * (capped.view.textContainer?.lineFragmentPadding ?? 0)
        let perLine = Int(((720 - padding) / advance).rounded(.down))
        let end = firstLineEnd(of: capped.view)
        // Word wrapping breaks at a space, so a little under the column's count is expected.
        #expect(end <= perLine && end > perLine - 15,
                "the first line ends at \(end) — a \(perLine)-character column")
        #expect(firstLineEnd(of: free.view) > perLine + 30, "the uncapped control did not run wider")
    }

    /// The pixels: with the cap on, every inked column is inside the text column; the uncapped
    /// control inks past its right edge — so the assertion can fail.
    @Test func theInkStaysInsideTheColumn() throws {
        func inkSpan(_ view: NSTextView) throws -> ClosedRange<Int> {
            // The first lines are enough, and keep the pixel walk short.
            let rect = NSRect(x: 0, y: 0, width: view.bounds.width, height: 160)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
            view.cacheDisplay(in: rect, to: rep)
            var minX = Int.max, maxX = Int.min
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.3 else { continue }
                    minX = min(minX, x); maxX = max(maxX, x)
                }
            }
            try #require(minX <= maxX, "nothing was drawn — the measure would be vacuous")
            let scale = CGFloat(rep.pixelsWide) / rect.width
            return Int(CGFloat(minX) / scale)...Int(CGFloat(maxX) / scale)
        }
        let capped = hosted(width: 1200, column: 720)
        let free = hosted(width: 1200, column: nil)
        defer { withExtendedLifetime((capped.window, free.window)) {} }
        free.view.frame.size.height = capped.view.frame.height
        let inset = capped.view.textContainerInset.width
        let span = try inkSpan(capped.view)
        #expect(CGFloat(span.lowerBound) >= inset && CGFloat(span.upperBound) <= inset + 720,
                "ink runs \(span) against a column \(inset)…\(inset + 720)")
        #expect(CGFloat(span.upperBound) > inset + 720 - 40, "the text stops at \(span.upperBound), well short of the column")
        #expect(CGFloat(try inkSpan(free.view).upperBound) > inset + 720 + 50,
                "the uncapped control never inked past the column")
    }

    // MARK: Where the editor applies it

    /// Mounts the real `PlainTextEditor` and returns the text view `makeNSView` built.
    private func mounted(width: CGFloat, fontScale: CGFloat = 1)
        -> (host: NSHostingView<AnyView>, view: NSTextView) {
        let editor = PlainTextEditor(source: EditorSourceStorage(text: "words words words\n"),
                                     isEditable: true, fontScale: fontScale,
                                     documentID: "/a/b.md", undoManager: UndoManager())
        let host = NSHostingView(rootView: AnyView(editor.defaultAppStorage(defaults)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        host.layoutSubtreeIfNeeded()
        var found: NSTextView?
        func walk(_ v: NSView) {
            if let scroll = v as? NSScrollView, scroll.identifier == EditorDocumentSurface.identifier {
                found = scroll.documentView as? NSTextView
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        return (host, found!)
    }

    private func withSetting(_ on: Bool?, _ body: () throws -> Void) rethrows {
        if let on { defaults.set(on, forKey: EditorTextSettings.readableLineLengthKey) }
        else { defaults.removeObject(forKey: EditorTextSettings.readableLineLengthKey) }
        try body()
    }

    /// **The call site: the editor reads the switch and hands the text view its column** — the
    /// rule above is one revert away from unused without this. Off (and never set) is today's 14pt
    /// at any width; on, a wide editor centres a column scaled by Text size.
    @Test func theEditorAppliesTheSwitch() throws {
        defaults.set(true, forKey: EditorTextSettings.wrapsKey)
        withSetting(nil) {
            let rig = mounted(width: 1200)
            #expect(rig.view.textContainerInset.width == 14, "the switch is on with nothing stored")
        }
        withSetting(false) {
            #expect(mounted(width: 1200).view.textContainerInset.width == 14)
        }
        try withSetting(true) {
            let rig = mounted(width: 1200)
            let width = rig.view.frame.width
            #expect(rig.view.textContainerInset.width == (width - 720) / 2,
                    "a \(width)pt editor has a \(rig.view.textContainerInset.width)pt inset")
            let large = mounted(width: 1200, fontScale: 1.35)
            let column = try #require(EditorReadableColumn.column(enabled: true, wraps: true, fontScale: 1.35))
            #expect(large.view.textContainerInset.width == (large.view.frame.width - column) / 2,
                    "Text size did not reach the column")
            #expect(mounted(width: 500).view.textContainerInset.width == 14, "a narrow editor changed")
            // Wrap Lines off: no cap, whatever the switch says.
            defaults.set(false, forKey: EditorTextSettings.wrapsKey)
            let unwrapped = mounted(width: 1200)
            defaults.set(true, forKey: EditorTextSettings.wrapsKey)
            #expect(unwrapped.view.textContainerInset.width == 14, "an unwrapped editor was given a column")
        }
    }

    /// **Flipping the switch under a mounted editor re-centres it, and flipping it back restores
    /// today's inset** — the menu writes the key, every mounted editor re-renders from it, and the
    /// change arrives through `updateNSView`, the only place the column is handed over.
    @Test func flippingTheSwitchUnderAMountedEditorAppliesIt() {
        defaults.set(true, forKey: EditorTextSettings.wrapsKey)
        withSetting(false) {
            let rig = mounted(width: 1200)
            #expect(rig.view.textContainerInset.width == 14)
            defaults.set(true, forKey: EditorTextSettings.readableLineLengthKey)
            rig.host.rootView = rig.host.rootView    // the re-render the key's observers cause
            rig.host.layoutSubtreeIfNeeded()
            #expect(rig.view.textContainerInset.width == (rig.view.frame.width - 720) / 2,
                    "turning the switch on left a mounted editor edge to edge")
            defaults.set(false, forKey: EditorTextSettings.readableLineLengthKey)
            rig.host.rootView = rig.host.rootView
            rig.host.layoutSubtreeIfNeeded()
            #expect(rig.view.textContainerInset.width == 14, "turning it off left the column in place")
        }
    }

    /// **Wrap Lines off under a mounted, capped editor drops the column; back on brings it back** —
    /// the wrapping and the column change in one pass, in that order.
    @Test func turningWrappingOffAndOnUnderAMountedEditor() {
        defaults.set(true, forKey: EditorTextSettings.wrapsKey)
        withSetting(true) {
            let rig = mounted(width: 1200)
            let centred = rig.view.textContainerInset.width
            #expect(centred > 14)
            defaults.set(false, forKey: EditorTextSettings.wrapsKey)
            rig.host.rootView = rig.host.rootView
            rig.host.layoutSubtreeIfNeeded()
            #expect(rig.view.textContainerInset.width == 14, "the column outlived Wrap Lines")
            #expect(rig.view.textContainer?.widthTracksTextView == false)
            defaults.set(true, forKey: EditorTextSettings.wrapsKey)
            rig.host.rootView = rig.host.rootView
            rig.host.layoutSubtreeIfNeeded()
            #expect(rig.view.textContainerInset.width == centred, "Wrap Lines back on did not re-centre")
            #expect(abs((rig.view.textContainer?.size.width ?? 0) - 720) < 0.5)
        }
    }

    // MARK: The right-click menu

    private func coordinator() -> PlainTextEditor.Coordinator {
        let subject = PlainTextEditor.Coordinator(source: EditorSourceStorage(), undoManager: UndoManager(),
                                                  documentID: nil, onSelectionChange: { _ in })
        subject.defaults = defaults
        return subject
    }

    /// **Beside Wrap Lines, ticked by the stored setting** — on a read-only file too, since it
    /// changes nothing on disk.
    @Test func theRightClickMenuOffersItBesideWrapLines() {
        for on in [true, false] {
            withSetting(on) {
                let menu = NSMenu()
                let subject = coordinator()
                subject.offersMarkup = false
                subject.insertTextSettings(into: menu, at: 0)
                let titles = menu.items.map(\.title)
                let wrap = titles.firstIndex(of: "Wrap Lines")
                #expect(wrap != nil && titles.firstIndex(of: "Readable Line Length") == wrap! + 1,
                        "the menu reads \(titles)")
                #expect(menu.items.first { $0.title == "Readable Line Length" }?.state == (on ? .on : .off))
            }
        }
    }

    /// **The item flips the stored setting**, both ways — which every mounted editor reads.
    @Test func theItemTogglesTheSetting() {
        withSetting(false) {
            let subject = coordinator()
            subject.toggleReadableLineLength(NSMenuItem())
            #expect(defaults.bool(forKey: EditorTextSettings.readableLineLengthKey))
            subject.toggleReadableLineLength(NSMenuItem())
            #expect(!defaults.bool(forKey: EditorTextSettings.readableLineLengthKey))
        }
    }

    /// **Greyed while Wrap Lines is off**, where it would change nothing — and only that item: the
    /// validation must not grey Wrap Lines, the way back.
    @Test func itIsGreyedWhileLinesDoNotWrap() throws {
        let subject = coordinator()
        let menu = NSMenu()
        subject.insertTextSettings(into: menu, at: 0)
        let readable = try #require(menu.items.first { $0.title == "Readable Line Length" })
        let wrap = try #require(menu.items.first { $0.title == "Wrap Lines" })

        defaults.set(false, forKey: EditorTextSettings.wrapsKey)
        let offReadable = subject.validateMenuItem(readable)
        let offWrap = subject.validateMenuItem(wrap)
        let offMenu = NSMenu()
        subject.insertTextSettings(into: offMenu, at: 0)
        defaults.set(true, forKey: EditorTextSettings.wrapsKey)
        let onReadable = subject.validateMenuItem(readable)

        #expect(!offReadable, "Readable Line Length is offered while lines do not wrap")
        #expect(offMenu.items.first { $0.title == "Readable Line Length" }?.isEnabled == false,
                "the item itself is enabled while lines do not wrap")
        #expect(offWrap, "validation greyed Wrap Lines — the way back")
        #expect(onReadable, "Readable Line Length is greyed while lines wrap")
    }
}
