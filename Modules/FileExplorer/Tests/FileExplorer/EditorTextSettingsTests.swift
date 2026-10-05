import Testing
import AppKit
@testable import FileExplorer
import EventsTestSupport

/// Wrapping and spell checking: what each switch actually does to the text view.
@MainActor
@Suite(.serialized) struct EditorTextSettingsTests {

    private func hosted() -> (scroll: NSScrollView, view: NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let view = scroll.documentView as! NSTextView
        view.string = String(repeating: "a very long line that will not fit ", count: 40)
        return (scroll, view)
    }

    /// **All five properties, because leaving any one out gets you a view that half-wraps.** The
    /// long line is laid out and then clipped, with no scroller to reach the end of it — which
    /// looks like the text being truncated rather than the setting being half-applied.
    @Test func turningWrappingOffLetsTheLineRunOn() {
        let (scroll, view) = hosted()
        PlainTextEditor.applyWrapping(false, to: view, in: scroll)

        #expect(view.textContainer?.widthTracksTextView == false)
        #expect(view.textContainer?.size.width == CGFloat.greatestFiniteMagnitude)
        #expect(view.isHorizontallyResizable)
        #expect(scroll.hasHorizontalScroller)
    }

    @Test func turningItBackOnWrapsAtTheVisibleWidth() {
        let (scroll, view) = hosted()
        PlainTextEditor.applyWrapping(false, to: view, in: scroll)
        PlainTextEditor.applyWrapping(true, to: view, in: scroll)

        #expect(view.textContainer?.widthTracksTextView == true)
        #expect(!view.isHorizontallyResizable)
        #expect(!scroll.hasHorizontalScroller)
        // **The view's own width has to come back too.** Unwrapped, it grew to the width of its
        // longest line; a container that starts tracking THAT width wraps at a column far off the
        // right edge, which reads as the setting not having worked.
        #expect(abs(view.frame.width - scroll.contentSize.width) < 0.51,
                "the view stayed \(view.frame.width)pt wide against a \(scroll.contentSize.width)pt column")
    }

    /// The round trip, because a wrap toggle is pressed twice more often than once.
    @Test func theSwitchSurvivesBeingFlippedRepeatedly() {
        let (scroll, view) = hosted()
        for _ in 0..<3 {
            PlainTextEditor.applyWrapping(false, to: view, in: scroll)
            PlainTextEditor.applyWrapping(true, to: view, in: scroll)
        }
        #expect(view.textContainer?.widthTracksTextView == true)
        #expect(!scroll.hasHorizontalScroller)
    }

    // MARK: The two switches on the menu

    private func coordinator() -> PlainTextEditor.Coordinator {
        PlainTextEditor.Coordinator(source: EditorSourceStorage(), undoManager: UndoManager(),
                                    documentID: nil, onSelectionChange: { _ in })
    }

    /// **Offered on a read-only document too, unlike the markup verbs.** Neither switch changes
    /// anything on disk, so a file you can only read should not also be harder to read.
    @Test func bothSwitchesAreOfferedEvenWithNoMarkupVerbs() {
        let menu = NSMenu()
        let subject = coordinator()
        subject.offersMarkup = false
        subject.insertTextSettings(into: menu, at: 0)

        let titles = menu.items.map(\.title)
        #expect(titles.contains("Wrap Lines"), "the menu read \(titles)")
        #expect(titles.contains("Check Spelling While Typing"), "the menu read \(titles)")
    }

    /// The tick has to describe the stored setting rather than a fixed default, or the menu says
    /// "off" over a view that is wrapping.
    @Test func theTicksFollowTheStoredSetting() {
        let defaults = UserDefaults.standard
        let wraps = defaults.object(forKey: EditorTextSettings.wrapsKey)
        let checks = defaults.object(forKey: EditorTextSettings.checksSpellingKey)
        defer {
            defaults.set(wraps, forKey: EditorTextSettings.wrapsKey)
            defaults.set(checks, forKey: EditorTextSettings.checksSpellingKey)
        }

        defaults.set(false, forKey: EditorTextSettings.wrapsKey)
        defaults.set(true, forKey: EditorTextSettings.checksSpellingKey)
        let menu = NSMenu()
        coordinator().insertTextSettings(into: menu, at: 0)

        #expect(menu.items.first { $0.title == "Wrap Lines" }?.state == .off)
        #expect(menu.items.first { $0.title == "Check Spelling While Typing" }?.state == .on)
    }

    // MARK: The way back to a hidden format bar

    /// **Format Bar is on the text's right-click menu wherever the bar can be drawn** — a writable
    /// Markdown file — and nowhere else, ticked by the stored setting. Hiding the bar from its own
    /// menu takes that menu away too, so this is the way back on screen.
    @Test func theTextsMenuOffersFormatBarWhereTheBarCanBeDrawn() {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: EditorTextSettings.showsFormatBarKey)
        defer { defaults.set(stored, forKey: EditorTextSettings.showsFormatBarKey) }
        defaults.set(false, forKey: EditorTextSettings.showsFormatBarKey)

        func titles(offersMarkup: Bool, editsMarkdown: Bool) -> [NSMenuItem] {
            let menu = NSMenu()
            let subject = coordinator()
            subject.offersMarkup = offersMarkup
            subject.editsMarkdown = editsMarkdown
            subject.insertTextSettings(into: menu, at: 0)
            return menu.items
        }
        let markdown = titles(offersMarkup: true, editsMarkdown: true)
        let item = markdown.first { $0.title == "Format Bar" }
        #expect(item != nil, "a Markdown file's right-click menu has no way back to the bar: \(markdown.map(\.title))")
        #expect(item?.state == .off, "Format Bar is ticked over a hidden bar")
        #expect(markdown.map(\.title).prefix(4) == ["Wrap Lines", "Check Spelling While Typing", "Format Bar", ""],
                "the switches read \(markdown.map(\.title)) — Format Bar belongs with the other two, before the separator")
        #expect(markdown[3].isSeparatorItem)
        for (name, items) in [("plain text", titles(offersMarkup: true, editsMarkdown: false)),
                              ("read-only Markdown", titles(offersMarkup: false, editsMarkdown: true))] {
            #expect(!items.contains { $0.title == "Format Bar" }, "\(name) offers a format bar it never draws")
        }
    }

    /// **The item flips View ▸ Format Bar's own setting, and says so.**
    @Test func theTextsFormatBarItemFlipsTheSettingAndSaysSo() async {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: EditorTextSettings.showsFormatBarKey)
        defer { defaults.set(stored, forKey: EditorTextSettings.showsFormatBarKey) }
        defaults.set(false, forKey: EditorTextSettings.showsFormatBarKey)
        let log = LogCapture()
        let subject = coordinator()
        subject.toggleFormatBar(NSMenuItem())
        #expect(defaults.bool(forKey: EditorTextSettings.showsFormatBarKey), "Format Bar left the bar hidden")
        #expect(await log.holds(containing: "[edit] Format bar shown from the text's right-click menu"))
        subject.toggleFormatBar(NSMenuItem())
        #expect(!defaults.bool(forKey: EditorTextSettings.showsFormatBarKey))
        #expect(await log.holds(containing: "[edit] Format bar hidden from the text's right-click menu"))
    }
}
