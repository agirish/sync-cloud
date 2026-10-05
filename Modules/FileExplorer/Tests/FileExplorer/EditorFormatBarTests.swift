import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer
import FileExplorerTestSupport
import EventsTestSupport

/// The format bar (TE52): what it holds against the Markup menu, where it is drawn, what it lights,
/// how it narrows, and what a press does to the caret.
@MainActor
@Suite(.serialized) struct EditorFormatBarTests {

    // MARK: Parity with the Markup menu

    /// **The bar holds the Markup menu's verbs — every one, once — in the menu's groups and the
    /// menu's order, with one move: the heading group leads, as the Body menu.** All of it read off
    /// `MarkupVerb.menuOrder`, the list the menu bar's Markup menu and the right-click submenu are
    /// built from (`TextMarkupMenuTests` holds the built menu to the same list). The table run sits
    /// inside the last group and is one Table button where it starts (TE68, decision AA = C6).
    ///
    /// Mutations: drop a verb from a group, reorder two within one, move Quote back to the lists,
    /// or move the table run to the end — each fails a line.
    @Test func theBarHoldsTheMarkupMenusVerbsInItsGroupsAndOrder() throws {
        let menu = MarkupVerb.menuOrder.compactMap { $0 }
        let bar = EditorFormatBar.barOrder
        #expect(bar.count == menu.count && Set(bar) == Set(menu),
                "the bar holds \(bar.map(\.title)), the menu \(menu.map(\.title))")
        let menuGroups = MarkupVerb.menuOrder.split(separator: nil).map { Array($0.compactMap { $0 }) }
        let headings = menuGroups.filter { $0.allSatisfy { if case .heading = $0 { true } else { false } } }
        #expect(headings.count == 1, "the menu has \(headings.count) heading groups — the Body menu is about nothing")
        #expect(EditorFormatBar.headingVerbs == headings.first,
                "the Body menu offers \(EditorFormatBar.headingVerbs.map(\.title))")
        // The table verbs are one unbroken run, the Table submenu's, in its sections' order.
        let firstTable = menu.firstIndex { $0.isTable }
        let first = try #require(firstTable, "the menu holds no table verb")
        let run = Array(menu[first...].prefix { $0.isTable })
        #expect(run == Array(MarkupVerb.tableSections.joined()) && EditorFormatBar.tableVerbs == run,
                "the table verbs are not one run in the Table submenu's order")
        #expect(menu.filter(\.isTable).count == run.count, "a table verb sits outside the run")
        // The bar reads as the menu does, headings moved to the front.
        #expect(bar == EditorFormatBar.headingVerbs + menu.filter { !EditorFormatBar.headingVerbs.contains($0) },
                "the bar's reading order is not headings first, then the menu's order")
        // The spelled-out groups, so the derivation above cannot quietly agree with a changed menu.
        #expect(EditorFormatBar.groups.map { $0.map(\.title) } == [
            ["Bold", "Italic", "Strikethrough"],
            ["Bulleted List", "Numbered List", "Task Item"],
            ["Inline Code", "Code Block", "Block Quote"],
            ["Link…", "Insert Table", "Divider"],
        ])
        #expect(EditorFormatBar.tableVerbs.map(\.title) == [
            "Insert Table", "Make Table from Selection", "Add Row Above", "Add Row Below",
            "Add Column Left", "Add Column Right", "Delete Row", "Delete Column", "Format Table",
        ])
        #expect(EditorFormatBar.tableEditVerbs.map(\.title) == Array(EditorFormatBar.tableVerbs.map(\.title).dropFirst(2)),
                "the Table capsule's items are not the run less the two that make tables")
        #expect(EditorFormatBar.headingVerbs.map(\.title) == ["Heading 1", "Heading 2", "Heading 3", "Body"])
    }

    /// **The press runs the Markup menu's own function.** A synthetic click does not reach a
    /// SwiftUI `Button` under `swift test`, so the wiring is read from the source, comments stripped:
    /// each button and each menu item hands its verb to `onVerb`; the workspace hands `onVerb` to the
    /// text view's handle; and the handle ends in `EditorDocumentSurface.applyMarkup` — the function
    /// Markup ▸ runs (`MarkupVerbCommands.apply`). What that function then does is pinned below and
    /// in `EditorMenuChordTests`. Mutations: `Button {}`, a handle that calls `PlainTextEditor.apply`
    /// directly, or a workspace that hands `onVerb` anything else — each fails a line.
    @Test func everyPressRunsTheMarkupMenusFunction() throws {
        let bar = try Self.source("EditorFormatBar.swift")
        #expect(bar.contains("Button { onVerb(verb) }"), "a bar button does not hand its verb to onVerb")
        #expect(bar.components(separatedBy: "set: { _ in onVerb(verb) }").count - 1 == 1,
                "the folded menus' toggles do not hand their verbs to onVerb")
        #expect(bar.contains("Button(verb.title) { onVerb(verb) }"), "a folded menu's or the Table capsule's item does not hand its verb to onVerb")
        let handle = try Self.slice(bar, from: "func applyMarkup(_ verb: MarkupVerb) -> Bool",
                                    to: "\n    }\n")
        #expect(handle.contains("EditorDocumentSurface.applyMarkup(verb, in: window)"),
                "the handle does not run the Markup menu's function")
        #expect(!handle.contains("PlainTextEditor.apply"), "the handle reaches past the menu's function")
        let workspace = try Self.source("EditorWorkspaceView.swift")
        #expect(workspace.contains("onVerb: { verb in textViewHandle.applyMarkup(verb) }"),
                "the workspace does not route the bar through the text view's handle")
        #expect(workspace.contains("textViewHandle: textViewHandle)"),
                "the text view is not handed the handle the bar presses through")
    }

    // MARK: A press and the caret

    /// A text view in a window, marked as `PlainTextEditor` marks its own — `EditorMenuChordTests`'
    /// fixture.
    private func hosted(text: String) -> (view: NSTextView, window: NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 360)
        scroll.identifier = EditorDocumentSurface.identifier
        window.contentView?.addSubview(scroll)
        let view = scroll.documentView as! NSTextView
        view.allowsUndo = true
        view.string = text
        return (view, window)
    }

    /// **The ordinary press: the caret is in the text, the verb applies, and the caret stays.**
    @Test func aPressAppliesTheVerbAndLeavesTheCaretInTheText() {
        let (view, window) = hosted(text: "one two three\n")
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 4, length: 3))
        let handle = EditorTextViewHandle()
        handle.textView = view
        #expect(handle.applyMarkup(.bold))
        #expect(view.string == "one **two** three\n")
        #expect(view.selectedRange() == NSRange(location: 6, length: 3))
        #expect(window.firstResponder === view, "the press left the caret outside the text")
    }

    /// **A press with the caret elsewhere puts it back first, on the selection the text kept.** The
    /// menu's function refuses unless the caret is in the text; the bar sits on that text, so its
    /// press takes the caret back rather than doing nothing. Here a field holds the caret, as a
    /// click on a SwiftUI button might leave it; the text's selection survives the resign.
    /// Mutation: drop the `makeFirstResponder` and the verb refuses.
    @Test func aPressWithTheCaretElsewhereBringsItBackAndApplies() async {
        let log = LogCapture()
        let (view, window) = hosted(text: "# Title\nbody\n")
        view.setSelectedRange(NSRange(location: 8, length: 4))
        let field = NSTextField(string: "elsewhere")
        field.frame = NSRect(x: 0, y: 370, width: 200, height: 22)
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        #expect(window.firstResponder !== view, "the field did not take the caret — this case proves nothing")
        let handle = EditorTextViewHandle()
        handle.textView = view
        #expect(handle.applyMarkup(.bulletList))
        #expect(view.string == "# Title\n- body\n")
        #expect(window.firstResponder === view, "the caret was not put back in the text")
        #expect(field.stringValue == "elsewhere", "the field was edited")
        // Said, because it is the one thing the bar does that the menu would not.
        #expect(await log.holds(containing: "Format bar ▸ Bulleted List: the caret was in"),
                "the press pulled the caret out of a field and said nothing")
    }

    /// **No text view — or one that cannot be written — and the press does nothing, and says so.**
    /// A button that does nothing and says nothing is the defect the menu's own refusal line exists
    /// for, so the bar's refusals are logged too — each case on its own verb, because a capture also
    /// sees its sibling cases' lines.
    @Test func aPressWithNoWritableTextViewDoesNothingAndSaysSo() async {
        let log = LogCapture()
        let handle = EditorTextViewHandle()
        #expect(!handle.applyMarkup(.strikethrough), "a press with no text view claimed to apply")
        let (view, window) = hosted(text: "one two\n")
        view.isEditable = false
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 0, length: 3))
        handle.textView = view
        #expect(!handle.applyMarkup(.inlineCode))
        #expect(view.string == "one two\n", "a read-only text view was edited")
        #expect(await log.holds(containing: "Format bar ▸ Strikethrough ignored: no writable text view on screen"),
                "a press with no text view said nothing")
        #expect(await log.holds(containing: "Format bar ▸ Inline Code ignored: no writable text view on screen"),
                "a press on a read-only text view said nothing")
    }

    // MARK: Where it is drawn

    /// **Only for a writable Markdown document, open, in Source or Split, with the bar switched on.**
    /// Every gate flipped alone, against the one case that shows it. Mutation: drop any term of
    /// `isShown` and its line fails.
    @Test func theBarShowsOnlyForAWritableMarkdownDocumentInSourceOrSplit() {
        func shown(preference: Bool = true, hasDocument: Bool = true, isRefused: Bool = false,
                   isMarkdown: Bool = true, isReadOnly: Bool = false, mode: EditorMode = .edit) -> Bool {
            EditorFormatBar.isShown(preference: preference, hasDocument: hasDocument, isRefused: isRefused,
                                    isMarkdown: isMarkdown, isReadOnly: isReadOnly, mode: mode)
        }
        #expect(shown(mode: .edit), "no bar over Source")
        #expect(shown(mode: .split), "no bar over Split")
        #expect(!shown(mode: .preview), "a bar over Preview, which has no text to act on")
        #expect(!shown(isMarkdown: false), "a bar over plain text")
        // A plain-text file remembered in Split is drawn as Source — and still gets no bar.
        #expect(!shown(isMarkdown: false, mode: .split), "a bar over plain text left in Split")
        #expect(!shown(isReadOnly: true), "a bar over a read-only file")
        #expect(!shown(isRefused: true), "a bar over a refused file")
        #expect(!shown(hasDocument: false), "a bar over the empty page")
        #expect(!shown(preference: false), "a bar with View ▸ Format Bar off")
        #expect(EditorTextSettings.showsFormatBarDefault, "the bar is off by default")
    }

    /// **Drawn where the rule says, in a mounted workspace:** the bar's buttons sit between the
    /// header and the text — eleven of them and its two menus at this width — and the text starts
    /// under it; with no bar the text starts at the header's edge. Plain text, read-only, Preview
    /// and the preference off each draw none. Rings are counted between the header card's bottom and
    /// the text view's top, so the header's own buttons and the status line are not counted.
    @Test func theBarIsDrawnAboveTheTextExactlyWhereTheRuleSaysAndNowhereElse() throws {
        let markdown = try TestTextFiles.document(named: "Notes.md", text: "# Notes\n\nhello\n")
        let plain = try TestTextFiles.document(named: "Notes.txt", text: "hello\n")
        let readOnly = EditorDocument()
        readOnly.open(.readOnly(text: "caf\u{FFFD}\n", reason: EditorFileStore.lossyReason), at: "/tmp/Lossy.md")
        try #require(readOnly.isMarkdown && readOnly.isReadOnly, "the read-only fixture is not a read-only Markdown file")

        let on = Self.mounted(markdown, mode: .edit)
        try #require(on.bar.count >= 11, "a writable Markdown file in Source draws \(on.bar.count) controls above its text")
        #expect(on.textTop - LiquidGlass.headerHeight > 20, "the text starts \(on.textTop - LiquidGlass.headerHeight)pt under the header — not under a bar")
        let split = Self.mounted(markdown, mode: .split)
        #expect(split.bar.count >= 1, "Split draws no bar")
        #expect(split.bar.allSatisfy { $0.maxX <= Self.width / 2 + 1 }, "the bar reaches past Split's Source half")

        for (name, case_) in [("plain text", Self.mounted(plain, mode: .edit)),
                              ("read-only", Self.mounted(readOnly, mode: .edit)),
                              ("Preview", Self.mounted(markdown, mode: .preview)),
                              ("preference off", Self.mounted(markdown, mode: .edit, preference: false))] {
            #expect(case_.bar.isEmpty, "\(name) draws \(case_.bar.count) controls above its text")
            if name != "Preview" {
                #expect(abs(case_.textTop - LiquidGlass.headerHeight) < 40,
                        "\(name): the text starts \(case_.textTop)pt down — room was kept for a bar that is not there")
            }
        }
        #expect(on.textTop > Self.mounted(plain, mode: .edit).textTop + 20,
                "the bar takes no height — the text starts where a plain file's does")
    }

    /// Wide enough for every word at the default size, a quarter larger (TE75).
    static let width: CGFloat = 1_300

    /// A workspace with the rail folded, in a window, with View ▸ Format Bar set as asked: the rings
    /// between the header's bottom and the text's top, and where the text starts.
    static func mounted(_ document: EditorDocument, mode: EditorMode,
                        preference: Bool = true, labels: Bool = true) -> (bar: [CGRect], textTop: CGFloat) {
        let defaults = ScratchDefaults("EditorFormatBarTests")
        defaults.set(preference, forKey: EditorTextSettings.showsFormatBarKey)
        defaults.set(labels, forKey: EditorTextSettings.formatBarShowsLabelsKey)
        defaults.set(SurfaceStyle.unified.rawValue, forKey: LiquidGlass.surfaceStyleKey)
        let size = CGSize(width: width, height: 500)
        let host = NSHostingView(rootView: AnyView(
            EditorWorkspaceView.fixture(document: document, mode: mode)
                .frame(width: size.width, height: size.height)
                .defaultAppStorage(defaults)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        var textTop = size.height
        func walk(_ v: NSView) {
            if let scroll = v as? NSScrollView, scroll.documentView is NSTextView {
                textTop = min(textTop, scroll.convert(scroll.bounds, to: host).minY)
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        let rings = FocusRings.frames(in: host).map { ring -> CGRect in
            var frame = ring
            if !host.isFlipped { frame.origin.y = size.height - frame.maxY }
            return frame
        }
        // The bar's band: under the header, above the text, and no deeper than a bar could reach —
        // Preview has no text view, and its own controls further down are not the bar.
        let bar = rings.filter {
            $0.minY >= LiquidGlass.headerHeight - 1 && $0.maxY <= min(textTop + 1, LiquidGlass.headerHeight + 60)
        }
        return (bar, textTop)
    }

    // MARK: What it lights

    /// **Lit exactly where a press would take the formatting off** — the verbs' own test, so a
    /// lit button's press unwraps and a dark one's wraps. Each case is a buffer with its selection
    /// in brackets. Mutations: light Link, compute a line verb's lit state from the strip pattern,
    /// or drop the "something written" term (a blank line lights every line verb) — each fails.
    @Test func eachVerbLightsWhereItsPressWouldTakeItOff() {
        let cases: [(text: String, lit: Set<MarkupVerb>)] = [
            ("4. Finish with **⟦plenty⟧** of parmesan.", [.bold, .numberedList]),
            // A caret inside the word is NOT lit: Bold there would add a second pair. Selecting the
            // word (a double-click does) is what lights it — the verbs' own rule.
            ("4. Finish with **ple‸nty** of parmesan.", [.numberedList]),
            // The verbs' rule again, kept: Italic over `**loud**` selected whole takes one star off
            // each side, so it lights with Bold. `aLitButtonsPressTakesItOffAndADarkOnesPutsItOn`
            // holds the two together.
            ("say ⟦**loud**⟧ now", [.bold, .italic]),
            ("an *⟦aside⟧* here", [.italic]),
            ("a **⟦bold⟧** word", [.bold]),                  // not Italic: the neighbour guard
            ("~~⟦gone⟧~~", [.strikethrough]),
            ("run `⟦ls⟧` first", [.inlineCode]),
            ("⟦# Title⟧", [.heading(1)]),
            ("## Ing‸redients", [.heading(2)]),
            ("- [ ] milk‸", [.taskItem]),                    // not Bulleted List: a task is not a bullet
            ("- ⟦milk⟧", [.bulletList]),
            ("> ⟦quoted⟧", [.blockQuote]),
            ("> - ⟦both⟧", [.blockQuote]),                   // a quote nests; the list is under it
            ("⟦plain text⟧", []),
            ("‸", []),                                       // a blank line lights nothing
            ("a ⟦[link](url)⟧ here", []),
            ("---‸", []),
        ]
        for (marked, lit) in cases {
            let (text, selection) = Self.unmark(marked)
            let state = MarkupFormatState.of(text, selection: selection)
            #expect(state.lit == lit, "“\(marked)” lights \(state.lit.map(\.title).sorted()), expected \(lit.map(\.title).sorted())")
            // Never Link, Code Block, Divider or Body: they insert, or only remove.
            for verb in [MarkupVerb.link, .codeBlock, .horizontalRule, .heading(0)] {
                #expect(!state.lit.contains(verb), "“\(marked)” lights \(verb.title)")
            }
        }
    }

    /// **The lit state and the press can never disagree**: over every verb that toggles and a
    /// spread of buffers, a lit verb's press takes its formatting off and a dark verb's press puts it
    /// on. "Off" for an inline verb is a shorter buffer; for a line verb, no touched line still
    /// carries the verb's own marker. This is the property the lit state exists to have, checked
    /// against `MarkdownEdits.apply` rather than against a copy of its rules.
    @Test func aLitButtonsPressTakesItOffAndADarkOnesPutsItOn() {
        let buffers = ["**bold**", "say **loud** now", "*it*", "a **b** c", "~~x~~", "`c`", "# One",
                       "## Two", "### Three", "#### Four", "- item", "- [ ] task", "- [x] done",
                       "1. first", "> q", "> - q", "plain", "two\nlines", "# H\nbody", "- a\n- b"]
        let toggles: [MarkupVerb] = [.bold, .italic, .strikethrough, .inlineCode, .heading(1),
                                     .heading(2), .heading(3), .bulletList, .numberedList, .taskItem,
                                     .blockQuote]
        var checked = 0
        var everLit: Set<MarkupVerb> = []
        for text in buffers {
            let ns = text as NSString
            for selection in Self.selections(in: ns) {
                // The bar's one-walk answer is each verb's own answer, verb for verb.
                let bundled = MarkupFormatState.of(text, selection: selection)
                for verb in MarkupVerb.menuOrder.compactMap({ $0 }) {
                    #expect(bundled.lit.contains(verb) == MarkdownEdits.isApplied(verb, in: text, selection: selection),
                            "\(verb.title) over “\(text)” \(selection): the bar and the verb disagree")
                }
                #expect(bundled.heading == MarkdownEdits.headingLevel(in: text, selection: selection))
                for verb in bundled.lit {
                    #expect(EditorFormatBar.canLight(verb), "\(verb.title) lit, but the bar draws it as a verb that never lights")
                    everLit.insert(verb)
                }
                for verb in toggles {
                    let lit = MarkdownEdits.isApplied(verb, in: text, selection: selection)
                    guard let edit = MarkdownEdits.apply(verb, to: text, selection: selection) else {
                        #expect(!lit, "\(verb.title) lights over “\(text)” \(selection) where its press does nothing")
                        continue
                    }
                    checked += 1
                    let tookOff: Bool
                    if let prefix = MarkdownEdits.linePrefix(for: verb) {
                        // The SAME lines, by index: a line verb rewrites prefixes and never adds or
                        // removes a line, while the selection it leaves can drift onto the next one.
                        let touched = MarkdownEdits.lineRanges(covering: selection, in: ns).map { range in
                            ns.substring(to: range.location).filter { $0 == "\n" }.count
                        }
                        let after = edit.text.components(separatedBy: "\n")
                        tookOff = !touched.contains { index in
                            index < after.count
                                && after[index].range(of: prefix.appliedPattern, options: .regularExpression) != nil
                        }
                    } else {
                        tookOff = (edit.text as NSString).length < ns.length
                    }
                    #expect(lit == tookOff,
                            "\(verb.title) over “\(text)” \(selection): lit \(lit), but the press \(tookOff ? "takes it off" : "puts it on")")
                }
            }
        }
        #expect(checked > 200, "only \(checked) presses were checked — the sweep is near-vacuous")
        // Every verb the bar draws as able to light does light somewhere in the sweep.
        let lightable = Set(MarkupVerb.menuOrder.compactMap { $0 }.filter(EditorFormatBar.canLight))
        #expect(lightable.subtracting(everLit).isEmpty,
                "never lit in the sweep: \(lightable.subtracting(everLit).map(\.title)) — drawn as toggles for nothing")
    }

    /// **The whole way from a caret to a lit button, in a mounted workspace** — the text view's
    /// selection reaches the workspace, the debounced task derives the state off the main actor, and
    /// the bar draws it. Each step is pinned on its own elsewhere; this is the one that fails if they
    /// stop being connected (a task keyed on the wrong value, a state never handed to the bar).
    ///
    /// The caret is moved in the real text view and the bar's band read for the accent. It starts
    /// LIT (a list item), so the first "nothing lit" is a change and not the resting state. Then:
    /// a caret and a selection at the same place (only the length moves, so the task must be keyed
    /// on it); a switch to Split with Bold lit (the rebuilt text view holds a bare caret, so Bold
    /// must go dark — the stale-lit bug the second review found), then the same word selected again
    /// (the stored length must have followed the new view, or the key does not move); and the bar
    /// turned off and on with a word selected (the length is not kept while it is off).
    ///
    /// Polled, never slept. The thresholds are in POINTS, so the display's scale cannot move them.
    /// Mutations: hand the bar `.none`; drop the length from the key; drop the length reset on a
    /// switch; drop the length's catch-up when the bar comes on — each fails a step.
    @Test(.machinePinned(.pixelSampling))
    func aCaretOnAListItemLightsBulletedListInTheMountedBar() async throws {
        let doc = try TestTextFiles.document(named: "Lit.md", text: "plain words\n- an item\n**bold** end\n")
        let defaults = ScratchDefaults("EditorFormatBarTests.lit")
        defaults.set(true, forKey: EditorTextSettings.showsFormatBarKey)
        defaults.set(SurfaceStyle.unified.rawValue, forKey: LiquidGlass.surfaceStyleKey)
        let size = CGSize(width: 900, height: 300)
        // One wrapper for both modes, so swapping the root keeps the workspace's identity — and with
        // it the `@State` the stale-lit check is about. A different wrapper would reset that state
        // and pass the check for the wrong reason.
        func root(_ mode: EditorMode) -> AnyView {
            AnyView(EditorWorkspaceView.fixture(document: doc, mode: mode).defaultAppStorage(defaults)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color.white)
                .environment(\.selectionLensAppearance, .today)
                .environment(\.colorScheme, .light)
                .environment(\.controlActiveState, .active))
        }
        let rig = ProbeRig(root(.edit), size: size)
        func textView() -> NSTextView? {
            var found: NSTextView?
            func walk(_ v: NSView) { if let t = v as? NSTextView, found == nil { found = t }; v.subviews.forEach(walk) }
            walk(rig.host)
            return found
        }
        var text = try #require(textView(), "no text view mounted")
        rig.window.makeFirstResponder(text)
        // The bar's band: under the header, above the first line of text.
        let band: ClosedRange<CGFloat> = LiquidGlass.headerHeight...(LiquidGlass.headerHeight + 44)
        let accent = Pixel.near(.blue, within: 40)
        let perPoint = { () -> CGFloat in let rep = rig.capture(); return CGFloat(rep.pixelsWide * rep.pixelsHigh) / (size.width * size.height) }()

        /// The band's accent, in square points.
        func lit() -> CGFloat { CGFloat(rig.count(rows: band, accent)) / perPoint }
        /// Waits — through `LayoutPumpWait`, which yields the main actor so the debounced task can
        /// run — for the band to settle on `on`'s side.
        func settle(on: Bool) async -> CGFloat {
            var area: CGFloat = 0
            _ = await LayoutPumpWait.pump(rig.window, upTo: 5) {
                area = lit()
                return on ? area >= Self.litAccentFloor : area <= Self.unlitAccentCeiling
            }
            return area
        }
        func select(_ range: NSRange, on: Bool) async -> CGFloat {
            text.setSelectedRange(range)
            return await settle(on: on)
        }

        let item = await select(NSRange(location: 15, length: 0), on: true)
        #expect(item >= Self.litAccentFloor, "on a list item the bar wears \(item)pt² of accent — Bulleted List did not light")
        let paragraph = await select(NSRange(location: 3, length: 0), on: false)
        #expect(paragraph <= Self.unlitAccentCeiling, "over a paragraph the bar still wears \(paragraph)pt² of accent")
        let atWord = await select(NSRange(location: 24, length: 0), on: false)
        #expect(atWord <= Self.unlitAccentCeiling, "a caret before **bold**'s word lights \(atWord)pt²")
        let word = await select(NSRange(location: 24, length: 4), on: true)
        #expect(word >= Self.litAccentFloor, "with “bold” selected the bar wears \(word)pt² — Bold did not light")

        // Split rebuilds the text view with a bare caret: Bold must go dark…
        rig.host.rootView = root(.split)
        let split = await settle(on: false)
        #expect(split <= Self.unlitAccentCeiling, "after a switch to Split, Bold stays lit over a bare caret (\(split)pt²)")
        // …and selecting the same word again lights it.
        text = try #require(textView(), "no text view after the switch")
        rig.window.makeFirstResponder(text)
        let again = await select(NSRange(location: 24, length: 4), on: true)
        #expect(again >= Self.litAccentFloor, "in Split, “bold” selected again does not light Bold (\(again)pt²)")

        // The bar off, a selection made, the bar on: it lights from the selection there IS. The
        // caret is collapsed first WITH the bar on, so the length last kept is 0 and the one made
        // while the bar is off is 4 — a length that is not caught up when the bar comes on reads
        // as a bare caret and leaves Bold dark.
        let collapsedFirst = await select(NSRange(location: 24, length: 0), on: false)
        #expect(collapsedFirst <= Self.unlitAccentCeiling)
        defaults.set(false, forKey: EditorTextSettings.showsFormatBarKey)
        _ = await settle(on: false)
        text.setSelectedRange(NSRange(location: 24, length: 4))
        defaults.set(true, forKey: EditorTextSettings.showsFormatBarKey)
        let barOn = await settle(on: true)
        #expect(barOn >= Self.litAccentFloor, "the bar came on over a selected bold word, unlit (\(barOn)pt²)")
        // …and a caret at the same place then takes the light away.
        let collapsed = await select(NSRange(location: 24, length: 0), on: false)
        #expect(collapsed <= Self.unlitAccentCeiling, "collapsing the selection left Bold lit (\(collapsed)pt²)")
        print("[format-lit] item \(item) · paragraph \(paragraph) · caret \(atWord) · word \(word) · split \(split) · again \(again) · bar-on \(barOn) · collapsed \(collapsed) (pt²)")
    }

    /// See ``aCaretOnAListItemLightsBulletedListInTheMountedBar``: one lit button's wash and ink,
    /// in square points, clear the floor; an unlit bar draws no accent at all.
    static let litAccentFloor: CGFloat = 10
    static let unlitAccentCeiling: CGFloat = 2.5

    /// **The Heading menu names the level exactly** — `# Title` is Heading 1 and not Heading 3, a
    /// level the menu has no item for is "Heading", body text is Body. The conflation this guards
    /// against once demoted `# Title` when Heading 3 was asked for. Mutation: ask the strip pattern
    /// (`pattern`) before the level-exact one, and `# Title` reads as whatever level is asked first.
    @Test func theHeadingMenuNamesTheLevelExactly() {
        func level(_ marked: String) -> MarkdownEdits.HeadingLevel {
            let (text, selection) = Self.unmark(marked)
            return MarkdownEdits.headingLevel(in: text, selection: selection)
        }
        #expect(level("# Ti‸tle") == .level(1))
        #expect(level("## Ti‸tle") == .level(2))
        #expect(level("### Ti‸tle") == .level(3))
        #expect(level("#### Ti‸tle") == .otherHeading)
        #expect(level("⟦# One\n## Two⟧") == .otherHeading, "two levels selected read as one of them")
        #expect(level("⟦# One\n\n# Two⟧") == .level(1), "a blank line between two Heading 1s made them a mix")
        // Headings and body text together are neither: the menu names the mix and ticks nothing.
        #expect(level("⟦# One\nbody⟧") == .mixed, "a heading and a paragraph read as \(level("⟦# One\nbody⟧"))")
        #expect(level("⟦body\n#### Deep⟧") == .mixed)
        #expect(level("pla‸in") == .body)
        #expect(level("‸") == .body)
        #expect(!MarkdownEdits.isApplied(.heading(3), in: "# Title", selection: NSRange(location: 3, length: 0)),
                "Heading 3 lights on a Heading 1 line — the two questions are merged again")
        #expect(EditorFormatBar.headingTitle(.level(2), worded: true) == "Heading 2")
        #expect(EditorFormatBar.headingTitle(.level(2), worded: false) == "H2")
        #expect(EditorFormatBar.headingTitle(.body, worded: true) == "Body")
        #expect(EditorFormatBar.headingTitle(.mixed, worded: true) == "Mixed")
        #expect(!EditorFormatBar.headingVerbs.contains { EditorFormatBar.isCurrent($0, .mixed) },
                "an item is ticked over a mix of headings and body")
        #expect(EditorFormatBar.isCurrent(.heading(2), .level(2)))
        #expect(!EditorFormatBar.isCurrent(.heading(1), .level(2)))
        #expect(EditorFormatBar.isCurrent(.heading(0), .body))
        #expect(!EditorFormatBar.isCurrent(.heading(0), .otherHeading), "Body is ticked on a Heading 4")
    }

    /// **The tooltip is the verb's name and the chord the menu bar registers** — read from
    /// `MarkupVerb.chord`, so ⌘B in a tooltip is the ⌘B Markup ▸ Bold answers.
    @Test func eachTooltipNamesTheVerbAndItsRegisteredChord() {
        #expect(EditorFormatBar.tooltip(.bold) == ShortcutHint.tooltip("Bold", AppChord.bold.display))
        #expect(EditorFormatBar.tooltip(.italic) == ShortcutHint.tooltip("Italic", "⌘I"))
        #expect(EditorFormatBar.tooltip(.link) == ShortcutHint.tooltip("Link…", AppChord.link.display))
        #expect(EditorFormatBar.tooltip(.bulletList) == "Bulleted List", "a menu-only verb's tooltip advertises a chord")
        for verb in MarkupVerb.menuOrder.compactMap({ $0 }) {
            #expect(EditorFormatBar.tooltip(verb).hasPrefix(verb.title))
            if let chord = verb.chord { #expect(EditorFormatBar.tooltip(verb).hasSuffix(chord.display)) }
        }
    }

    /// **Every glyph is a symbol the system has** — the verbs', the folded groups', the Table
    /// capsule's and the merged menu's. A misspelt name draws an empty button and fails nothing else.
    @Test func everyGlyphIsASymbolTheSystemHas() {
        let parts = EditorFormatBar.foldableGroups + [.table]
        let names = MarkupVerb.menuOrder.compactMap({ $0 }).map(EditorFormatBar.symbol)
            + parts.map(EditorFormatBar.symbol) + [EditorFormatBar.overflowSymbol, "chevron.down", "checkmark"]
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) is not a symbol")
        }
        // Divider no longer wears the bare dash that read as a minus (TE69).
        #expect(EditorFormatBar.symbol(.horizontalRule) != "minus")
        #expect(MarkupVerb.horizontalRule.title == "Divider" && EditorFormatBar.word(.horizontalRule) == "Divider")
    }

    // MARK: Narrowing, group by group (TE72)

    /// **The ladder: words off group by group, then the Body menu shortens, then each group folds
    /// into a button of its own, and only last do the folded groups merge into one » — Bold, Italic
    /// and Strikethrough last of all.** Out of a table, Insert's words go first and Insert folds
    /// first, the end people press least; in one, the greyed groups go first and the Table capsule
    /// last. Icon Only is the same ladder from where the words are off.
    ///
    /// Mutations: fold before the words are off, fold Lists before Insert, merge before every
    /// group is folded, or start Icon Only on a worded rung — each fails a line.
    @Test func theLadderTakesWordsOffThenFoldsGroupByGroup() {
        typealias Part = EditorFormatBar.Part
        let lists = Part.group(1), code = Part.group(2), insert = Part.group(3)
        #expect(EditorFormatBar.foldableGroups == [lists, code, insert])
        #expect([lists, code, insert].map(EditorFormatBar.title) == ["Lists", "Code and Quote", "Insert"])

        let out = EditorFormatBar.ladder(showsLabels: true, inTable: false)
        #expect(out.count == 10, "the ladder has \(out.count) rungs")
        #expect(out.map(\.worded) == [[lists, code, insert], [lists, code], [lists], [], [], [], [], [], [], []],
                "out of a table the words come off \(out.map { $0.worded.map(EditorFormatBar.title) })")
        #expect(out.map(\.headingWorded) == [true, true, true, true, false, false, false, false, false, false])
        #expect(out.map(\.folded) == [[], [], [], [], [], [insert], [insert, code], [insert, code, lists],
                                      [insert, code, lists], [insert, code, lists]],
                "out of a table the groups fold \(out.map { $0.folded.map(EditorFormatBar.title) })")
        #expect(out.map(\.merged) == Array(repeating: false, count: 8) + [true, true])
        #expect(out.map(\.marksFolded) == Array(repeating: false, count: 9) + [true])

        let inside = EditorFormatBar.ladder(showsLabels: true, inTable: true)
        #expect(inside.count == 12, "in a table the ladder has \(inside.count) rungs")
        #expect(inside.map(\.worded).prefix(5) == [[lists, code, insert, .table], [code, insert, .table],
                                                   [insert, .table], [.table], []],
                "in a table the words come off \(inside.map { $0.worded.map(EditorFormatBar.title) })")
        #expect(inside.map(\.folded).dropFirst(6) == [[lists], [lists, code], [lists, code, insert],
                                                      [lists, code, insert], [lists, code, insert, .table],
                                                      [lists, code, insert, .table]],
                "in a table the groups fold \(inside.map { $0.folded.map(EditorFormatBar.title) })")
        // The groups merge BEFORE the Table capsule folds, so the table's own edits outlast them.
        #expect(inside.map(\.merged) == Array(repeating: false, count: 9) + [true, true, true])
        #expect(inside.last?.marksFolded == true && inside.filter(\.marksFolded).count == 1)

        for ladder in [out, inside] {
            // Each rung changes one thing from the one before.
            for (a, b) in zip(ladder, ladder.dropFirst()) {
                let changes = [a.worded != b.worded, a.headingWorded != b.headingWorded, a.folded != b.folded,
                               a.merged != b.merged, a.marksFolded != b.marksFolded].filter { $0 }.count
                #expect(changes == 1, "\(a) → \(b) changes \(changes) things")
                #expect(b.worded.isSubset(of: a.worded) && a.folded.isSubset(of: b.folded), "\(a) → \(b) puts something back")
            }
            // Nothing folds while a word is still on, and nothing merges while a group is out.
            for rung in ladder where !rung.folded.isEmpty { #expect(rung.worded.isEmpty && !rung.headingWorded) }
            for rung in ladder where rung.merged { #expect(rung.folded.isSuperset(of: [lists, code, insert])) }
            for rung in ladder where rung.folded.contains(.table) { #expect(rung.merged, "the Table capsule folds before the merge") }
        }
        #expect(EditorFormatBar.ladder(showsLabels: false, inTable: false) == Array(out.drop { !$0.worded.isEmpty }),
                "Icon Only is not Icon and Text's ladder from where the words are off")
        #expect(EditorFormatBar.ladder(showsLabels: false, inTable: true) == Array(inside.drop { !$0.worded.isEmpty }))
        #expect(EditorTextSettings.formatBarShowsLabelsDefault, "Icon and Text is not the default (decision Q)")
    }

    /// **A folded group, and the merged », say what they hide that is applied** — to VoiceOver, as
    /// their accent says it on screen — and the verbs that never light are plain items in them, not
    /// toggles that are always off.
    @Test func aFoldedGroupNamesWhatItHidesThatIsApplied() {
        let lists = EditorFormatBar.verbs(of: .group(1))
        #expect(EditorFormatBar.appliedValue(lists, lit: []) == "")
        #expect(EditorFormatBar.appliedValue(lists, lit: [.bulletList, .bold]) == "Applied: Bulleted List",
                "a folded Lists announces a verb it does not hold")
        let merged = (EditorFormatBar.groups.first ?? []) + lists
        #expect(EditorFormatBar.appliedValue(merged, lit: [.bulletList, .bold]) == "Applied: Bold, Bulleted List")
        #expect(EditorFormatBar.verbs(of: .table) == EditorFormatBar.tableEditVerbs)
        #expect(EditorFormatBar.foldedParts(EditorFormatBar.ladder(showsLabels: false, inTable: true).last!, inTable: true)
                == EditorFormatBar.foldableGroups + [.table], "the merged » does not hold every group, in order")
        for verb in [MarkupVerb.link, .codeBlock, .horizontalRule, .heading(0), .table(.insert)] {
            #expect(!EditorFormatBar.canLight(verb), "\(verb.title) is drawn as a toggle")
        }
    }

    /// **The bar is compared on what it draws, and nothing else** — so `.equatable()` holds off the
    /// redraw a keystroke causes, and still lets every change the reader could see through. The
    /// press closure is the one member left out. And the host really applies `.equatable()`.
    @Test func theBarIsComparedOnWhatItDraws() throws {
        let a = EditorFormatBar(state: .none, accent: .blue, onVerb: { _ in })
        #expect(a == EditorFormatBar(state: .none, accent: .blue, onVerb: { _ in print("another") }),
                "two bars that draw the same differ — every keystroke redraws it")
        #expect(a != EditorFormatBar(state: MarkupFormatState(lit: [.bold], heading: .body), accent: .blue, onVerb: { _ in }),
                "a lit Bold compares equal to an unlit one — the bar would not light")
        #expect(a != EditorFormatBar(state: MarkupFormatState(lit: [], heading: .level(2)), accent: .blue, onVerb: { _ in }))
        #expect(a != EditorFormatBar(state: MarkupFormatState(lit: [], heading: .body, touchesTable: true),
                                     accent: .blue, onVerb: { _ in }), "a caret moving into a table would not grey the bar")
        #expect(a != EditorFormatBar(state: .none, accent: .red, onVerb: { _ in }), "an accent change is held off")
        #expect(a != EditorFormatBar(state: .none, accent: .blue, showsLabels: false, onVerb: { _ in }),
                "Icon Only compares equal to Icon and Text — the right-click choice would not redraw the bar")
        #expect(a != EditorFormatBar(state: .none, accent: .blue, onVerb: { _ in },
                                     forcedRung: EditorFormatBar.ladder(showsLabels: false, inTable: false)[1]))
        let workspace = try Self.source("EditorWorkspaceView.swift")
        let call = try Self.slice(workspace, from: "EditorFormatBar(state: formatState", to: ".padding")
        #expect(call.contains(".equatable()"), "the host does not apply .equatable() — a keystroke redraws the bar")
        #expect(call.contains("showsLabels: formatBarShowsLabels"), "the host does not hand the bar the reader's Icon and Text choice")
    }

    // MARK: Narrow widths

    /// A caret in a table's body row, as `MarkupFormatState.of` reports one.
    static let inTable = MarkupFormatState(lit: [], heading: .body,
                                           tables: [.addRowAbove, .addRowBelow, .addColumnLeft, .addColumnRight,
                                                    .deleteRow, .deleteColumn, .tidy],
                                           touchesTable: true)

    /// The bar at one rung, at one text size, as it lays out with room to spare.
    static func width(of rung: EditorFormatBar.Rung, scale: CGFloat, state: MarkupFormatState = .none) -> CGFloat {
        NSHostingView(rootView: AnyView(
            EditorFormatBar(state: state, accent: .blue, onVerb: { _ in }, forcedRung: rung)
                .environment(\.appFontScale, scale)
        )).fittingSize.width
    }

    /// **Each rung of the ladder is narrower than the one before it, at every text size, in a table
    /// and out of one** — which is what makes the ladder a degrade order: `ViewThatFits` takes the
    /// first that fits, so a rung wider than its predecessor would never be drawn.
    @Test func eachRungIsNarrowerThanTheOneBeforeIt() {
        for table in [false, true] {
            for percent in FontSize.selectablePercents {
                let scale = CGFloat(percent) / 100
                let widths = EditorFormatBar.ladder(showsLabels: true, inTable: table)
                    .map { Self.width(of: $0, scale: scale, state: table ? Self.inTable : .none) }
                for (a, b) in zip(widths, widths.dropFirst()) {
                    #expect(b < a, "\(table ? "in a table" : "out of one"), at \(percent)% the ladder reads \(widths.map { Int($0) }) — a rung is no narrower than the one before")
                }
            }
        }
    }

    /// **At the narrowest a Split half may be — `minSplitColumnWidth`, 220pt — and at every
    /// selectable text size, the bar fits**, in a table and out of one. The bar's width does not
    /// depend on what is lit (the Body menu is laid out at its widest label), so the forced rungs
    /// measured with nothing lit ARE its widths. The rung drawn is the first that fits the half less
    /// the bar's insets, which is `ViewThatFits`' own rule; the real, unforced bar is then mounted at
    /// that width and every control it draws must lie inside.
    ///
    /// **What it keeps there**, measured 2026-10-05 (208pt once the insets are off) and printed as
    /// `[format-bar-fit]`: at every size, in a table and out of one, the Body menu shortened to ¶
    /// and Bold, Italic and Strikethrough with the merged » beside them — 161 to 199pt from 90% to
    /// 135%. In a table the Table capsule has folded into the » too. The floor pinned is that
    /// fact: B, I and S never leave the bar there.
    ///
    /// Mutations: drop the merged rungs, or fold the marks before the groups merge, and a floor
    /// fails or the bar overflows.
    @Test func theBarFitsTheNarrowestSplitHalfAtEveryTextSize() throws {
        let available = EditorLayoutMetrics.minSplitColumnWidth - 2 * EditorWorkspaceView.formatBarInset
        var report: [String] = []
        for table in [false, true] {
            let state = table ? Self.inTable : .none
            for percent in FontSize.selectablePercents {
                let scale = CGFloat(percent) / 100
                let ladder = EditorFormatBar.ladder(showsLabels: false, inTable: table)
                let widths = ladder.map { Self.width(of: $0, scale: scale, state: state) }
                let chosen = try #require(widths.firstIndex { $0 <= available },
                                          "at \(percent)% no rung fits \(available)pt: \(widths.map { Int($0) })")
                let rung = ladder[chosen]
                report.append("\(table ? "table " : "")\(percent)%: \(chosen) (\(Int(widths[chosen]))pt)")
                #expect(!rung.marksFolded,
                        "\(table ? "in a table, " : "")at \(percent)% Bold, Italic and Strikethrough go behind the » at \(available)pt")

                // The real bar, choosing for itself, in that width — each way. Icon and Text
                // changes nothing here: none of its worded rungs fits.
                var drawn: [[CGRect]] = []
                for labels in [false, true] {
                    let rings = Self.rings(of: EditorFormatBar(state: state, accent: .blue, showsLabels: labels,
                                                               onVerb: { _ in }),
                                           width: available, scale: scale)
                    #expect(!rings.isEmpty, "the bar drew no controls at \(percent)%")
                    #expect(rings.allSatisfy { $0.maxX <= available + 0.5 && $0.minX >= -0.5 },
                            "at \(percent)% a control is drawn outside \(available)pt: \(rings.map { Int($0.maxX) })")
                    drawn.append(rings)
                }
                #expect(drawn[0] == drawn[1],
                        "at \(percent)% Icon and Text draws \(drawn[1].map { Int($0.width) }) where Icon Only draws \(drawn[0].map { Int($0.width) })")
            }
        }
        print("[format-bar-fit] at \(Int(available))pt: \(report.joined(separator: " · "))")
    }

    /// **Every button wears a word but B, I and S, and the word is the menu's title, shortened** —
    /// pinned, because the words ARE the feature, and the full names stay in the tooltips.
    @Test func everyButtonButTheLettersWearsAShortWord() {
        let expected: [MarkupVerb: String] = [
            .inlineCode: "Code", .link: "Link", .bulletList: "Bullets", .numberedList: "Numbered",
            .taskItem: "Tasks", .blockQuote: "Quote", .codeBlock: "Code Block", .horizontalRule: "Divider",
            .table(.insert): "Table",
            .table(.addRowBelow): "Row", .table(.addColumnRight): "Column", .table(.deleteRow): "Delete",
            .table(.tidy): "Format",
        ]
        for verb in EditorFormatBar.groups.flatMap({ $0 }) + EditorFormatBar.tableEditVerbs {
            let letter = [MarkupVerb.bold, .italic, .strikethrough].contains(verb)
            #expect(EditorFormatBar.wearsWord(verb) == !letter, "\(verb.title) \(letter ? "wears" : "has no") word")
            if !letter, let word = expected[verb] {
                #expect(EditorFormatBar.word(verb) == word, "\(verb.title) reads “\(EditorFormatBar.word(verb))”")
            }
            if !letter {
                #expect(EditorFormatBar.word(verb).count <= verb.title.count)
                #expect(EditorFormatBar.tooltip(verb).hasPrefix(verb.title), "\(verb.title)'s tooltip lost the full name")
            }
        }
    }

    /// **A quarter larger than it first shipped** (TE75, decision AD): 14-point glyphs in 25-point
    /// boxes and 12.5-point words, against 11, 20 and 11 — and a bare button really is its box wide,
    /// and the capsules really stand apart: the room between Strikethrough and Bullets is a capsule
    /// gap wider than the room between Bold and Italic.
    @Test func theBarIsAQuarterLargerAndItsGroupsStandApart() throws {
        #expect(EditorFormatBar.glyphPoint == 14 && EditorFormatBar.boxSize == 25 && EditorFormatBar.wordPoint == 12.5)
        #expect(EditorFormatBar.box(at: 1) == 25)
        let rings = Self.rings(of: EditorFormatBar(state: .none, accent: .blue, showsLabels: false, onVerb: { _ in }),
                               width: 1_400, scale: 1)
        try #require(rings.count == 13, "the icons-only bar draws \(rings.count) controls")
        #expect(abs(rings[1].width - 25) < 1, "a bare Bold is \(rings[1].width)pt wide, not its 25pt box")
        let inside = rings[2].minX - rings[1].maxX
        let between = rings[4].minX - rings[3].maxX
        // A fixed figure, not `capsuleGap` itself, which a mutation would move with the bar: the
        // two capsules' insets (3pt each) and an 8pt gap stand between them, against the 2pt between
        // two buttons in one capsule.
        #expect(between >= inside + 10, "Strikethrough and Bullets are \(between)pt apart, Bold and Italic \(inside)pt — no capsule gap")
    }

    /// The bar's rings, drawn for itself in `width`, left to right.
    static func rings(of bar: EditorFormatBar, width: CGFloat, scale: CGFloat) -> [CGRect] {
        let size = CGSize(width: width, height: 40)
        let host = NSHostingView(rootView: AnyView(
            bar.environment(\.appFontScale, scale)
                .frame(width: size.width, height: size.height, alignment: .leading)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        return FocusRings.frames(in: host).sorted { $0.minX < $1.minX }
    }

    /// **The words come off group by group as the room shrinks — Insert's, then Code and Quote's,
    /// then the lists' — and never a button**, at every text size, on the real bar choosing for
    /// itself. At exactly each worded rung's width it draws that rung: words on nine buttons, then
    /// six, then three, then none; and every button is still on the bar, nothing folded.
    ///
    /// A ring counts as worded when it is clearly wider than a bare glyph's box. Mutations: drop a
    /// word, take Lists' words off first, or word B — each fails a count.
    @Test func theWordsComeOffBeforeAnyButtonAsTheBarNarrows() {
        let buttons = EditorFormatBar.groups.flatMap { $0 }
        let ladder = EditorFormatBar.ladder(showsLabels: true, inTable: false)
        var report: [String] = []
        for percent in FontSize.selectablePercents {
            let scale = CGFloat(percent) / 100
            let box = EditorFormatBar.box(at: scale)
            let widths = ladder.prefix(4).map { Self.width(of: $0, scale: scale) }
            report.append("\(percent)%: " + widths.map { "\(Int($0.rounded(.up)))" }.joined(separator: " · "))
            let expected = [9, 6, 3, 0]
            for (index, width) in widths.enumerated() {
                // 8pt over the measured width, because `ViewThatFits` asks for a little more room
                // than the rung draws in (measured 2026-10-04: up to 4pt over). The rungs are far
                // more than 8pt apart, so 8pt cannot reach the one before.
                let rings = Self.rings(of: EditorFormatBar(state: .none, accent: .blue, showsLabels: true, onVerb: { _ in }),
                                       width: width.rounded(.up) + 8, scale: scale)
                // The Body menu, then one ring per button: nothing folded.
                #expect(rings.count == 1 + buttons.count,
                        "at \(percent)%, \(Int(width))pt, the bar draws \(rings.count) controls — a group folded")
                let wide = rings.dropFirst().filter { $0.width > box + 8 }.count
                #expect(wide == expected[index],
                        "at \(percent)%, \(Int(width))pt, \(wide) buttons wear words — \(expected[index]) expected")
                // B, I and S stay bare even with every word drawn.
                #expect(rings.dropFirst().prefix(3).allSatisfy { $0.width <= box + 2 },
                        "at \(percent)% B, I or S wears a word: \(rings.dropFirst().prefix(3).map { Int($0.width) })")
                // And the words that are on are the groups still worded, from the front.
                if index > 0 && index < 3 {
                    let worded = rings.dropFirst(4).map { $0.width > box + 8 }
                    #expect(worded == Array(repeating: true, count: 3 * (3 - index)) + Array(repeating: false, count: 3 * index),
                            "at \(percent)%, rung \(index), the words sit on \(worded) — not the front groups")
                }
            }
        }
        print("[format-bar-words] all · Insert bare · Code bare · icons, in pt: \(report.joined(separator: " — "))")
    }

    /// **In the workspace, Icon and Text draws the words and Icon Only does not** — the choice read
    /// from the stored setting by the host, at a Source width with room for every word.
    @Test func theStoredChoiceDecidesWordsInTheWorkspace() throws {
        let markdown = try TestTextFiles.document(named: "Notes.md", text: "# Notes\n\nhello\n")
        let words = Self.mounted(markdown, mode: .edit, labels: true).bar.sorted { $0.minX < $1.minX }
        let icons = Self.mounted(markdown, mode: .edit, labels: false).bar.sorted { $0.minX < $1.minX }
        let box = EditorFormatBar.box(at: 1)
        try #require(words.count == icons.count && words.count >= 12,
                     "Icon and Text draws \(words.count) controls, Icon Only \(icons.count)")
        let wordCount = EditorFormatBar.groups.flatMap { $0 }.filter(EditorFormatBar.wearsWord).count
        #expect(wordCount == 9, "\(wordCount) buttons take a word — the eight verbs and the Table button")
        #expect(words.dropFirst().filter { $0.width > box + 8 }.count == wordCount,
                "Icon and Text at \(Int(Self.width))pt words \(words.dropFirst().filter { $0.width > box + 8 }.count) buttons: \(words.map { Int($0.width) })")
        #expect(icons.dropFirst().allSatisfy { $0.width <= box + 2 }, "Icon Only draws a word: \(icons.map { Int($0.width) })")
        #expect(words.first == icons.first, "the Heading menu moved between the two")
    }

    /// **A lit worded button lights its word too** — the wash spans the glyph and the word, not the
    /// glyph's square alone. Counted as in `theExpandButtonLightsWhenTheRailIsHidden`: pixels of the
    /// accent's soft tint, in square points, here in the word's half of the Bullets ring.
    ///
    /// Mutation: wash the glyph alone (the old square) and the word half holds none.
    @Test(.machinePinned(.pixelSampling))
    func aLitWordedButtonWashesItsWordToo() throws {
        let rung = EditorFormatBar.ladder(showsLabels: true, inTable: false)[0]
        let size = CGSize(width: 1_400, height: 40)
        func render(_ lit: Set<MarkupVerb>) throws -> Rendered {
            try #require(Rendered(EditorFormatBar(state: MarkupFormatState(lit: lit, heading: .body), accent: .blue,
                                                  onVerb: { _ in }, forcedRung: rung), size: size))
        }
        let on = try render([.bulletList])
        let off = try render([])
        let row = off.nameRowRings
        let index = try #require(EditorFormatBar.groups.flatMap { $0 }.firstIndex(of: .bulletList)) + 1
        try #require(row.count > index, "the bar drew \(row.count) controls")
        let bullets = row[index]
        let wordHalf = CGRect(x: bullets.midX, y: bullets.minY, width: bullets.width / 2, height: bullets.height)
        let wash: (CGFloat, CGFloat, CGFloat) -> Bool = { r, g, b in b > 0.95 && (0.6...0.93).contains(r) && g > r }
        let lit = CGFloat(on.pixels(in: wordHalf, matching: wash)) / on.pixelsPerPoint
        let unlit = CGFloat(off.pixels(in: wordHalf, matching: wash)) / off.pixelsPerPoint
        let area = wordHalf.width * wordHalf.height
        print("[format-bar-lit-word] wash \(Int(lit))pt² lit, \(Int(unlit))pt² unlit, in the word's \(Int(area))pt²")
        #expect(unlit < 1, "the unlit word wears \(unlit)pt² of the wash")
        #expect(lit > area * 0.4, "the lit word's half holds \(lit)pt² of wash of \(area)pt² — the wash stops at the glyph")
        #expect(on.nameRowRings == row, "lighting Bullets moved the bar's buttons")
    }

    /// **The right-click menu: Icon and Text, Icon Only, then Hide Format Bar** — each choice
    /// written to its setting and said in the log once, a press on the ticked one changing nothing,
    /// and Hide turning off the very setting View ▸ Format Bar ticks.
    @Test func theRightClickMenuChoosesWordsOrIconsAndHidesTheBar() async throws {
        let log = LogCapture()
        var labels = true
        var shown = true
        let labelsBinding = Binding(get: { labels }, set: { labels = $0 })
        let shownBinding = Binding(get: { shown }, set: { shown = $0 })
        EditorFormatBarMenu.choose(labels: true, labelsBinding)
        #expect(labels, "Icon and Text, pressed while ticked, turned the words off")
        EditorFormatBarMenu.choose(labels: false, labelsBinding)
        #expect(!labels, "Icon Only left the words on")
        #expect(await log.holds(containing: "[edit] Format bar ▸ Icon Only"), "Icon Only said nothing")
        EditorFormatBarMenu.choose(labels: true, labelsBinding)
        #expect(labels)
        #expect(await log.holds(containing: "[edit] Format bar ▸ Icon and Text"), "Icon and Text said nothing")
        EditorFormatBarMenu.hide(shownBinding)
        #expect(!shown, "Hide Format Bar left the bar on")
        #expect(await log.holds(containing: "[edit] Format bar hidden from its menu"), "Hide Format Bar said nothing")

        #expect([EditorFormatBarMenu.iconAndText, EditorFormatBarMenu.iconOnly, EditorFormatBarMenu.hide]
                == ["Icon and Text", "Icon Only", "Hide Format Bar"])
        let source = try Self.source("EditorFormatBar.swift")
        let body = try Self.slice(source, from: "struct EditorFormatBarMenu: View", to: "static func choose")
        let order = ["Toggle(Self.iconAndText", "Toggle(Self.iconOnly", "Divider()", "Button(Self.hide)"]
            .map { body.range(of: $0)?.lowerBound }
        #expect(order.allSatisfy { $0 != nil } && zip(order, order.dropFirst()).allSatisfy { $0! < $1! },
                "the menu is not Icon and Text, Icon Only, a divider, then Hide Format Bar")
        // …and each item does what it says.
        let iconAndText = try Self.slice(body, from: "Toggle(Self.iconAndText", to: "Toggle(Self.iconOnly")
        let iconOnly = try Self.slice(body, from: "Toggle(Self.iconOnly", to: "Divider()")
        #expect(iconAndText.contains("choose(labels: true") && !iconAndText.contains("choose(labels: false"),
                "Icon and Text does not choose the words")
        #expect(iconOnly.contains("choose(labels: false") && !iconOnly.contains("choose(labels: true"),
                "Icon Only does not choose the icons")
        #expect(Self.squeezed(body).contains("Button(Self.hide){Self.hide($showsBar)}"), "Hide Format Bar does not hide the bar")

        // On the bar, writing the two stored settings the rest of the app reads.
        let workspace = try Self.source("EditorWorkspaceView.swift")
        let call = try Self.slice(workspace, from: "EditorFormatBar(state: formatState", to: ".padding")
        #expect(call.contains(".contextMenu {") && call.contains("EditorFormatBarMenu(showsLabels: $formatBarShowsLabels")
                && call.contains("showsBar: $showsFormatBarPreference"),
                "the bar's right-click menu is not attached to the bar, or writes the wrong settings")
        #expect(Self.squeezed(workspace).contains(Self.squeezed(
            "@AppStorage(EditorTextSettings.formatBarShowsLabelsKey) private var formatBarShowsLabels: Bool = EditorTextSettings.formatBarShowsLabelsDefault")),
                "the host does not read Icon and Text from its stored setting")
    }

    // MARK: In a table (TE73, TE76) and the Body menu (TE74)

    /// A small table with prose either side, and where the caret sits in it.
    static let tableText = "Intro, then:\n\n| Day | Where |\n|-----|-------|\n| Sat | Gion  |\n\nAfter."
    static func offset(of needle: String, in text: String = tableText) -> Int {
        (text as NSString).range(of: needle).location
    }

    /// **The Table capsule comes with the caret into a table and goes when it leaves** (TE73): six
    /// more controls — Row and its chevron, Column and its chevron, Delete, Format — on the real
    /// bar, from the state the caret's place derives. Mutations: draw the capsule on `touchesTable`
    /// rather than `isInTable`, or drop a control — a count fails.
    @Test func theTableCapsuleComesAndGoesWithTheCaret() {
        let text = Self.tableText
        let inCell = MarkupFormatState.of(text, selection: NSRange(location: Self.offset(of: "Gion"), length: 0))
        let outside = MarkupFormatState.of(text, selection: NSRange(location: Self.offset(of: "After"), length: 0))
        #expect(inCell.isInTable && inCell.touchesTable, "a caret in a cell is not in the table")
        #expect(!outside.isInTable && !outside.touchesTable, "a caret in the prose after is in the table")
        // From the prose INTO the table: it touches the table (and greys), but no capsule — its start is outside.
        let into = MarkupFormatState.of(text, selection: NSRange(location: Self.offset(of: "Intro"),
                                                                  length: Self.offset(of: "Gion") - Self.offset(of: "Intro")))
        #expect(into.touchesTable && !into.isInTable)
        let count = { (state: MarkupFormatState) in
            Self.rings(of: EditorFormatBar(state: state, accent: .blue, showsLabels: true, onVerb: { _ in }),
                       width: 2_000, scale: 1).count
        }
        #expect(count(outside) == 13, "out of a table the bar draws \(count(outside)) controls")
        #expect(count(inCell) == 13 + 6, "in a table the bar draws \(count(inCell)) controls — not the Table capsule's six more")
        #expect(count(into) == 13, "a selection that only ends in a table draws the Table capsule")
    }

    /// **In a table, what would break it greys — on the bar, in the right-click menu, and in the
    /// verbs themselves** (TE76): headings, the lists, Quote, Code Block and Divider rewrite whole
    /// lines and would take rows out of the table; the inline marks and Link work inside a cell.
    /// The bar's Table button greys too, since a table cannot hold one. A selection from the prose
    /// before a table to the prose after is NOT refused — its ends say the table is part of it.
    ///
    /// Mutations: drop `touchesTable` from `isOffered`, refuse on one end only, take `.blockQuote`
    /// out of `breaksTables`, or drop the refusal from `apply` — each fails a line.
    @Test func whatWouldBreakATableGreysAndIsRefusedThere() throws {
        let breaking: Set<MarkupVerb> = [.heading(1), .heading(2), .heading(3), .heading(0), .bulletList,
                                         .numberedList, .taskItem, .blockQuote, .codeBlock, .horizontalRule]
        let all = MarkupVerb.menuOrder.compactMap { $0 }
        #expect(Set(all.filter(\.breaksTables)) == breaking, "the verbs that break a table read \(all.filter(\.breaksTables).map(\.title))")

        let text = Self.tableText
        let cell = NSRange(location: Self.offset(of: "Gion"), length: 0)
        let state = MarkupFormatState.of(text, selection: cell)
        for verb in all where !verb.isTable {
            let breaks = breaking.contains(verb)
            #expect(EditorFormatBar.isOffered(verb, in: state) == !breaks, "\(verb.title) \(breaks ? "is live" : "greys") in a table")
            #expect(MarkdownEdits.breaksTable(verb, in: text, selection: cell) == breaks)
            if breaks {
                #expect(MarkdownEdits.apply(verb, to: text, selection: cell) == nil, "\(verb.title) broke the table")
            }
        }
        #expect(MarkdownEdits.apply(.bold, to: text, selection: NSRange(location: Self.offset(of: "Gion"), length: 4)) != nil,
                "Bold in a cell is refused")
        #expect(!EditorFormatBar.isOffered(EditorFormatBar.tableMenuStandIn, in: state), "the Table button is live in a table")
        // Out of a table, everything but the table edits is offered.
        let outside = MarkupFormatState.of(text, selection: NSRange(location: Self.offset(of: "After"), length: 0))
        for verb in all where !verb.isTable { #expect(EditorFormatBar.isOffered(verb, in: outside)) }
        // Either end in a table refuses; both ends outside it does not.
        let into = NSRange(location: 0, length: Self.offset(of: "Gion"))
        let outOf = NSRange(location: Self.offset(of: "Sat"), length: (text as NSString).length - Self.offset(of: "Sat"))
        let across = NSRange(location: 0, length: (text as NSString).length)
        #expect(MarkdownEdits.apply(.bulletList, to: text, selection: into) == nil, "a list from the prose into a table broke it")
        #expect(MarkdownEdits.apply(.bulletList, to: text, selection: outOf) == nil, "a list from a table into the prose broke it")
        #expect(MarkdownEdits.apply(.blockQuote, to: text, selection: across) != nil, "quoting the whole note, table and all, is refused")

        // The right-click menu greys the same items, and only with the caret in a table.
        func enabled(_ menu: NSMenu) -> [String: Bool] {
            Dictionary(menu.items.filter { !$0.isSeparatorItem && $0.submenu == nil }.map { ($0.title, $0.isEnabled) },
                       uniquingKeysWith: { a, _ in a })
        }
        let inMenu = enabled(PlainTextEditor.Coordinator.markupMenu(target: nil, action: #selector(NSText.copy(_:)),
                                                                     tables: state.tables, inTable: true))
        let outMenu = enabled(PlainTextEditor.Coordinator.markupMenu(target: nil, action: #selector(NSText.copy(_:)),
                                                                      tables: outside.tables, inTable: false))
        for verb in all where !verb.isTable {
            #expect(inMenu[verb.title] == !breaking.contains(verb), "the right-click \(verb.title) is \(inMenu[verb.title] == true ? "live" : "greyed") in a table")
            #expect(outMenu[verb.title] == true, "the right-click \(verb.title) greys out of a table")
        }
        let surface = try Self.source("EditorDocumentSurface.swift")
        #expect(surface.contains("MarkdownEdits.breaksTable(verb, in: view.string, selection: view.selectedRange())"),
                "a press from the menu bar that a table refuses says nothing")
        let editor = try Self.source("PlainTextEditor.swift")
        #expect(editor.contains("inTable: MarkdownTables.touches(ns, view.selectedRange())"),
                "the right-click menu is not told the caret is in a table")
    }

    /// **The Table button makes a table from the selected lines when they split into cells, else
    /// inserts one** (decision AB) — and says which in its tooltip; it is the run's first section
    /// in a folded Insert. Mutation: always insert, and the first line fails.
    @Test func theTableButtonMakesATableFromTheSelectionOrInsertsOne() throws {
        let rows = "a,b\nc,d\n"
        let selected = MarkupFormatState.of(rows, selection: NSRange(location: 0, length: (rows as NSString).length))
        #expect(EditorFormatBar.tableVerb(in: selected) == .table(.fromSelection))
        let caret = MarkupFormatState.of(rows, selection: NSRange(location: 0, length: 0))
        #expect(EditorFormatBar.tableVerb(in: caret) == .table(.insert))
        #expect(EditorFormatBar.isOffered(EditorFormatBar.tableMenuStandIn, in: caret))
        let bar = try Self.source("EditorFormatBar.swift")
        let button = try Self.slice(bar, from: "private func tableButton(worded: Bool)", to: "\n    }\n")
        #expect(button.contains("let verb = Self.tableVerb(in: state)") && button.contains("Button { onVerb(verb) }")
                && button.contains(".help(verb.title)"), "the Table button does not press, or name, the verb it chose")
    }

    /// **The Body menu draws each style as it looks** (TE74, decision AC): a popover of Heading 1,
    /// 2, 3 and Body, each larger than the next and the headings bold, as Notes draws its Aa list —
    /// ticked at the level the selection is at. Mutations: draw every row at 13 points, or tick by
    /// anything but `isCurrent`, and a line fails.
    @Test func theBodyMenuDrawsEachStyleAsItLooks() throws {
        let sizes = EditorFormatBar.headingVerbs.map { EditorStylePicker.font($0).size }
        #expect(sizes == sizes.sorted(by: >) && Set(sizes).count == sizes.count, "the styles' sizes read \(sizes)")
        #expect(EditorFormatBar.headingVerbs.dropLast().allSatisfy { EditorStylePicker.font($0).weight == .bold })
        #expect(EditorStylePicker.font(.heading(0)) == (13, .regular))
        // Drawn: the picker is taller than four rows of body text would be.
        let height = NSHostingView(rootView: AnyView(EditorStylePicker(current: .body, onPick: { _ in })
            .environment(\.appFontScale, 1))).fittingSize.height
        #expect(height > 4 * (13 + 8) + 12, "the picker lays out \(height)pt high — its styles are not drawn in their sizes")
        let bar = try Self.source("EditorFormatBar.swift")
        #expect(Self.squeezed(bar).contains(Self.squeezed(".popover(isPresented: $showsStyles, arrowEdge: .bottom) {\nEditorStylePicker(current: state.heading) { verb in\nshowsStyles = false\nonVerb(verb)\n}")),
                "the Body menu does not open the picker, or the picker's choice does not reach onVerb")
        let picker = try Self.slice(bar, from: "struct EditorStylePicker: View", to: "private struct EditorStyleRow")
        #expect(picker.contains("isCurrent: EditorFormatBar.isCurrent(verb, current)"), "the picker ticks by something else")
        let row = try Self.slice(bar, from: "private struct EditorStyleRow", to: "\n}\n")
        #expect(row.contains(".scaledFont(.system(size: font.size, weight: font.weight))"), "a row is not drawn in its style")
    }

    // MARK: Helpers

    /// `text` with its selection marked — `⟦…⟧` around a selection, `‸` for a caret — unmarked:
    /// the buffer and the range. Marks no Markdown uses, so a task box or a link stays itself.
    static func unmark(_ marked: String) -> (String, NSRange) {
        let ns = marked as NSString
        let caret = ns.range(of: "‸")
        if caret.location != NSNotFound {
            return (ns.replacingCharacters(in: caret, with: ""), NSRange(location: caret.location, length: 0))
        }
        let open = ns.range(of: "⟦")
        let close = ns.range(of: "⟧")
        precondition(open.location != NSNotFound && close.location != NSNotFound, "“\(marked)” marks no selection")
        let without = ns.replacingCharacters(in: close, with: "") as NSString
        return (without.replacingCharacters(in: open, with: ""),
                NSRange(location: open.location, length: close.location - open.location - open.length))
    }

    /// A spread of selections over `ns`: every caret, the whole buffer, and each run between spaces.
    static func selections(in ns: NSString) -> [NSRange] {
        var out = (0...ns.length).map { NSRange(location: $0, length: 0) }
        out.append(NSRange(location: 0, length: ns.length))
        var start = 0
        for i in 0...ns.length where i == ns.length || ns.character(at: i) == 0x20 || ns.character(at: i) == 0x0A {
            if i > start { out.append(NSRange(location: start, length: i - start)) }
            start = i + 1
        }
        // The inside of every delimited run: `**x**` → `x`.
        for (open, width) in [("**", 2), ("~~", 2), ("*", 1), ("`", 1)] {
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let a = ns.range(of: open, options: [], range: search)
                guard a.location != NSNotFound else { break }
                let afterA = a.location + width
                guard afterA < ns.length else { break }
                let b = ns.range(of: open, options: [], range: NSRange(location: afterA, length: ns.length - afterA))
                guard b.location != NSNotFound else { break }
                out.append(NSRange(location: afterA, length: b.location - afterA))
                search = NSRange(location: b.location + width, length: max(0, ns.length - b.location - width))
            }
        }
        return out
    }

    static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/\(file)")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { codePart(of: String($0)) }
            .joined(separator: "\n")
    }

    /// A line up to its `//` comment — a `//` inside a string literal (a URL) is text, not a
    /// comment, and cutting there would let the scan miss code after it.
    static func codePart(of line: String) -> String {
        var inString = false
        var escaped = false
        var previous: Character?
        for index in line.indices {
            let c = line[index]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "/", previous == "/" {
                return String(line[..<line.index(before: index)])
            }
            previous = inString ? nil : c
        }
        return line
    }

    /// `code` with every space and line break taken out, so a scan survives the source being
    /// rewrapped — the reason `ChromeGlassWiringTests` moved to a whitespace-blind match.
    static func squeezed(_ code: String) -> String {
        code.filter { !$0.isWhitespace }
    }

    static func slice(_ code: String, from start: String, to end: String) throws -> String {
        let a = try #require(code.range(of: start), "\(start) is not in the source")
        let rest = code[a.upperBound...]
        let b = rest.range(of: end)?.lowerBound ?? rest.endIndex
        return String(rest[..<b])
    }
}
