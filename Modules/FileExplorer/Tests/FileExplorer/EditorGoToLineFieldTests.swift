import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// **TE61 — Go to Line's field, mounted.** The status line hosted with a live binding in a key
/// window, and the field read the only ways a hosted SwiftUI popover can be read: the popover
/// windows on screen, the field editor that holds the typing, and what the binding and `onGo` hear.
@MainActor
@Suite(.serialized) struct EditorGoToLineFieldTests {

    final class Model: ObservableObject {
        @Published var shown = false
        @Published var selection: EditorSelectionFacts?
        @Published var notice: String?
        @Published var width: CGFloat = 900
        @Published var scale: CGFloat = 1
        var went: [EditorGoToLine.Target] = []
    }

    struct Harness: View {
        @ObservedObject var model: Model
        let headings: EditorStatusHeadings?
        var body: some View {
            EditorStatusLine(facts: EditorDocumentFacts(words: 4_218, characters: 24_907, lines: 412,
                                                        lineEnding: .crlf, encoding: "UTF-8"),
                             caret: EditorCaret(line: 48, column: 12), fileSize: "4 KB",
                             headings: headings, selection: model.selection,
                             goToLine: EditorStatusGoToLine(
                                isPresented: Binding(get: { model.shown }, set: { model.shown = $0 }),
                                lineCount: 412, accent: .blue, onGo: { model.went.append($0) }),
                             notice: model.notice)
                .environment(\.appFontScale, model.scale)
                .frame(width: model.width)
        }
    }

    static let headings = EditorStatusHeadings(
        outline: [MarkdownOutlineEntry(line: 1, level: 2, depth: 0, title: "Method for the very patient weekend cook")],
        current: 0, offersRailOutline: false, accent: .blue, onSelect: { _ in }, onShowRailOutline: {})

    // MARK: The rig

    private func spin(_ window: NSWindow, _ turns: Int = 15) {
        for _ in 0..<turns {
            _ = CFRunLoopRunInMode(.defaultMode, 0.03, true)
            window.layoutIfNeeded()
        }
    }

    /// Every popover up — each buried with the window it opened from, under everything on screen.
    private func popovers(sourceLocation: SourceLocation = #_sourceLocation) -> [NSWindow] {
        let open = NSApp.windows.filter { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
        for popover in open {
            #expect(BuriedWindow.isBuried(popover), "a popover opened above the buried window, at level \(popover.level.rawValue)",
                    sourceLocation: sourceLocation)
        }
        return open
    }

    private func mount(_ model: Model, headings: EditorStatusHeadings? = nil) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: Harness(model: model, headings: headings))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 40)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        // Key and ordered in, because the popover presents only from a visible window — and buried,
        // so no package run stands this status line on the user's desktop.
        window.buryUnderEverything()
        window.makeKeyAndOrderFront(nil)
        #expect(BuriedWindow.isBuried(window), "the fixture window is above the desktop, at level \(window.level.rawValue)")
        spin(window)
        return (window, host)
    }

    private func close(_ model: Model, _ window: NSWindow) {
        model.shown = false
        spin(window)
        for popover in popovers() { popover.orderOut(nil) }
        window.orderOut(nil)
        spin(window, 3)
    }

    /// The field editor typing goes into — the popover's first responder once the field has focus.
    private func fieldEditor(_ popover: NSWindow?) -> NSTextView? { popover?.firstResponder as? NSTextView }

    /// The caret button's bounds on screen, by the one handle a hosted button leaves: its focus
    /// ring (`reading-a-hosted-swiftui-control-by-focus-ring`). The heading menu draws one too, so
    /// the caret's is the one right of every count — the last in the strip's run before the facts.
    private func caretRingOnScreen(in host: NSView, window: NSWindow) -> NSRect? {
        var rings: [NSRect] = []
        func walk(_ view: NSView) {
            if String(describing: type(of: view)).contains("FocusRing") {
                rings.append(window.convertToScreen(view.convert(view.bounds, to: nil)))
            }
            view.subviews.forEach(walk)
        }
        walk(host)
        // One ring without a heading; with one, the heading's comes first, leftmost.
        return rings.max { $0.minX < $1.minX }
    }

    // MARK: Opening

    /// **The field opens once, focused, its arrow on "Line, Col"** — with and without a heading
    /// leading the line, which draws a second ladder.
    @Test(arguments: [false, true])
    func theFieldOpensFocusedUnderTheCaret(withHeadings: Bool) throws {
        let model = Model()
        let (window, host) = mount(model, headings: withHeadings ? Self.headings : nil)
        defer { close(model, window) }
        #expect(popovers().isEmpty, "a field was up before anything asked for one")
        model.shown = true
        spin(window)
        let open = popovers()
        #expect(open.count == 1, "\(open.count) fields opened")
        #expect(fieldEditor(open.first) != nil,
                "the field did not take focus — first responder \(String(describing: open.first?.firstResponder))")
        // The arrow is on the caret: the popover is centred on the caret button, not on the line.
        let caret = try #require(caretRingOnScreen(in: host, window: window), "no caret button drawn")
        let popover = try #require(open.first)
        #expect(abs(popover.frame.midX - caret.midX) < 6,
                "the field is centred at \(popover.frame.midX), the caret at \(caret.midX) — the line is 200…1100")
    }

    // MARK: Changing rung under it

    enum RungChange: CaseIterable, CustomTestStringConvertible {
        /// A selection across lines is counted, which adds two rungs at the ladder's head.
        case multiLineCountArrives
        /// The column narrows past the full rung.
        case columnNarrows
        /// ⌘+ — a larger text size takes another rung.
        case textGrows
        var testDescription: String { "\(self)" }
    }

    /// The full rung's own width at the usual text size, as the harness draws it.
    private static func fullRungWidth(withHeadings: Bool) -> CGFloat {
        NSHostingView(rootView: EditorStatusLine(
            facts: EditorDocumentFacts(words: 4_218, characters: 24_907, lines: 412, lineEnding: .crlf, encoding: "UTF-8"),
            caret: EditorCaret(line: 48, column: 12), fileSize: "4 KB", forcedRung: .full,
            headings: withHeadings ? headings : nil).fixedSize()).fittingSize.width
    }

    /// **The field stays up, with what was typed, whatever rung the line moves to** (review of
    /// TE61). The popover hung on the caret button, which every rung draws afresh, so a change of
    /// rung took the field away mid-typing. Each case was run against the old line and closed the
    /// field there, so none of them leaves the rung alone and passes for that.
    @Test(arguments: RungChange.allCases, [false, true])
    func theFieldSurvivesARungChange(change: RungChange, withHeadings: Bool) throws {
        let model = Model()
        if change == .textGrows {
            // Just room for the full rung at the usual size, so the larger size cannot keep it.
            model.width = Self.fullRungWidth(withHeadings: withHeadings) + 4
        }
        let (window, host) = mount(model, headings: withHeadings ? Self.headings : nil)
        defer { close(model, window) }
        model.shown = true
        spin(window)
        let popover = try #require(popovers().first, "no field opened")
        let editor = try #require(fieldEditor(popover), "the field did not take focus")
        editor.insertText("21", replacementRange: editor.selectedRange())
        spin(window, 3)
        let caretBefore = try #require(caretRingOnScreen(in: host, window: window))

        switch change {
        case .multiLineCountArrives: model.selection = EditorSelectionFacts(words: 12, characters: 64, lines: 3)
        case .columnNarrows: model.width = 330
        case .textGrows: model.scale = 1.4
        }
        spin(window)

        let caretAfter = try #require(caretRingOnScreen(in: host, window: window))
        try #require(abs(caretAfter.minX - caretBefore.minX) > 1 || abs(caretAfter.width - caretBefore.width) > 1,
                     "the caret did not move (\(caretBefore) → \(caretAfter)) — nothing moved under the field")
        let open = popovers()
        #expect(open.count == 1 && model.shown, "the field closed: \(open.count) up, shown \(model.shown)")
        #expect(fieldEditor(open.first)?.string == "21",
                "the typing went: \(String(describing: fieldEditor(open.first)?.string))")
        // And it follows the caret to where the new rung drew it.
        if let popover = open.first {
            #expect(abs(popover.frame.midX - caretAfter.midX) < 6,
                    "the field is centred at \(popover.frame.midX), the caret now at \(caretAfter.midX)")
        }
    }

    // MARK: A notice from elsewhere (TE59)

    static let notice = "Reloaded — changed elsewhere"

    /// **⌃⌘L while a notice holds the line opens the field at once, on the caret** — the notice gives
    /// way. It held the slot the caret is drawn in, so the field had nothing to hang from and
    /// opened by itself seconds later, when the notice cleared.
    @Test func askingForTheFieldUnderANoticeOpensItOnTheCaret() throws {
        let model = Model()
        model.notice = Self.notice
        let (window, host) = mount(model)
        defer { close(model, window) }
        #expect(caretRingOnScreen(in: host, window: window) == nil, "the notice is not holding the slot")
        model.shown = true
        spin(window)
        let open = popovers()
        #expect(open.count == 1, "\(open.count) fields opened")
        #expect(fieldEditor(open.first) != nil, "the field did not take focus")
        let caret = try #require(caretRingOnScreen(in: host, window: window), "the notice kept the caret off the line")
        if let popover = open.first {
            #expect(abs(popover.frame.midX - caret.midX) < 6,
                    "the field is centred at \(popover.frame.midX), the caret at \(caret.midX)")
        }
        // The notice's time running out changes nothing under the field.
        model.notice = nil
        spin(window)
        #expect(popovers().count == 1 && model.shown)
    }

    /// **A notice arriving while the field is up waits** — the field, what was typed and the caret it
    /// hangs from all stay, and the notice is said once the field closes, if its seconds are not up.
    @Test func aNoticeArrivingWhileTheFieldIsUpWaits() throws {
        let model = Model()
        let (window, host) = mount(model)
        defer { close(model, window) }
        model.shown = true
        spin(window)
        let editor = try #require(fieldEditor(popovers().first), "the field did not take focus")
        editor.insertText("7", replacementRange: editor.selectedRange())
        spin(window, 3)
        model.notice = Self.notice
        spin(window)
        let open = popovers()
        #expect(open.count == 1 && model.shown, "the field closed: \(open.count) up, shown \(model.shown)")
        #expect(fieldEditor(open.first)?.string == "7", "the typing went")
        let caret = try #require(caretRingOnScreen(in: host, window: window), "the notice took the caret's slot")
        if let popover = open.first {
            #expect(abs(popover.frame.midX - caret.midX) < 6)
        }
        // Closed, the line says the notice.
        model.shown = false
        spin(window)
        #expect(caretRingOnScreen(in: host, window: window) == nil, "the notice was not said after the field closed")
    }
}
