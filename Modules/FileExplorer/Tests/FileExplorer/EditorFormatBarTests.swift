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
    /// menu's order, with one move: the heading group leads, as a menu.** All of it read off
    /// `MarkupVerb.menuOrder`, the list the menu bar's Markup menu and the right-click submenu are
    /// built from (`TextMarkupMenuTests` holds the built menu to the same list).
    ///
    /// Mutations: drop a verb from a group, reorder two within one, or move the lists ahead of the
    /// inline verbs — each fails a line.
    @Test func theBarHoldsTheMarkupMenusVerbsInItsGroupsAndOrder() {
        let menu = MarkupVerb.menuOrder.compactMap { $0 }
        let bar = EditorFormatBar.barOrder
        #expect(bar.count == menu.count && Set(bar) == Set(menu),
                "the bar holds \(bar.map(\.title)), the menu \(menu.map(\.title))")
        let menuGroups = MarkupVerb.menuOrder.split(separator: nil).map { Array($0.compactMap { $0 }) }
        let headings = menuGroups.filter { $0.allSatisfy { if case .heading = $0 { true } else { false } } }
        #expect(headings.count == 1, "the menu has \(headings.count) heading groups — the Heading menu is about nothing")
        #expect(EditorFormatBar.headingVerbs == headings.first,
                "the Heading menu offers \(EditorFormatBar.headingVerbs.map(\.title))")
        #expect(EditorFormatBar.groups == menuGroups.filter { $0 != headings.first },
                "the bar's button groups are not the menu's, in the menu's order")
        #expect(bar == EditorFormatBar.headingVerbs + EditorFormatBar.groups.flatMap { $0 },
                "the bar's reading order is not headings first, then the menu's groups")
        // The spelled-out order, so the derivation above cannot quietly agree with a changed menu.
        #expect(EditorFormatBar.groups.map { $0.map(\.title) } == [
            ["Bold", "Italic", "Strikethrough", "Inline Code", "Link…"],
            ["Bulleted List", "Numbered List", "Task Item", "Block Quote"],
            ["Code Block", "Horizontal Rule"],
        ])
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
        #expect(bar.components(separatedBy: "set: { _ in onVerb(verb) }").count - 1 == 2,
                "the Heading menu and the » menu do not both hand their verbs to onVerb")
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
        #expect(!shown(preference: false), "a bar with Text ▸ Format Bar off")
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

    static let width: CGFloat = 900

    /// A workspace with the rail folded, in a window, with Text ▸ Format Bar set as asked: the rings
    /// between the header's bottom and the text's top, and where the text starts.
    static func mounted(_ document: EditorDocument, mode: EditorMode,
                        preference: Bool = true) -> (bar: [CGRect], textTop: CGFloat) {
        let defaults = ScratchDefaults("EditorFormatBarTests")
        defaults.set(preference, forKey: EditorTextSettings.showsFormatBarKey)
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
            // Never Link, Code Block, Horizontal Rule or Body: they insert, or only remove.
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

    /// **Every glyph is a symbol the system has.** A misspelt name draws an empty button and fails
    /// nothing else.
    @Test func everyGlyphIsASymbolTheSystemHas() {
        for name in MarkupVerb.menuOrder.compactMap({ $0 }).map(EditorFormatBar.symbol) + [EditorFormatBar.overflowSymbol] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) is not a symbol")
        }
    }

    // MARK: The » menu

    /// **Every rung keeps a prefix of the buttons and puts the rest behind the », in order** — the
    /// kept buttons and the hidden ones are the button groups, flattened, split at the rung's count;
    /// each piece stays in the group it came from, so the » divides where the bar does; and the »
    /// is drawn exactly when something is hidden. Mutations: hide from the front, or merge the
    /// hidden groups into one, and a line fails.
    @Test func eachRungKeepsAPrefixAndHidesTheRestInOrder() {
        let flat = EditorFormatBar.groups.flatMap { $0 }
        for rung in EditorFormatBar.ladder {
            let layout = EditorFormatBar.layout(rung)
            let shown = layout.shown.flatMap { $0 }
            let hidden = layout.hidden.flatMap { $0 }
            #expect(shown == Array(flat.prefix(rung.visible)), "\(rung): the bar keeps \(shown.map(\.title))")
            #expect(shown + hidden == flat, "\(rung): kept and hidden are not the buttons, in order")
            for piece in layout.shown + layout.hidden {
                #expect(EditorFormatBar.groups.contains { group in
                    group.count >= piece.count && (0...(group.count - piece.count)).contains { Array(group[$0..<($0 + piece.count)]) == piece }
                }, "\(rung): \(piece.map(\.title)) runs across two of the menu's groups")
            }
            #expect(layout.shown.count + layout.hidden.count
                    <= EditorFormatBar.groups.count + 1, "\(rung): a group was split more than once")
        }
        #expect(EditorFormatBar.layout(EditorFormatBar.ladder[0]).hidden.isEmpty, "the widest rung hides a button")
        #expect(EditorFormatBar.layout(EditorFormatBar.ladder.last!).shown.isEmpty, "the narrowest rung keeps a button")
        // The rung that sheds Code and Link splits the inline group: Bold, Italic, Strikethrough
        // stay, and the » leads with the other two, ahead of the lists.
        let split = EditorFormatBar.layout(EditorFormatBar.Rung(headingWorded: false, visible: 3))
        #expect(split.shown.map { $0.map(\.title) } == [["Bold", "Italic", "Strikethrough"]])
        #expect(split.hidden.first?.map(\.title) == ["Inline Code", "Link…"])
    }

    /// **The » says what it hides that is applied** — to VoiceOver, as its accent says it on screen
    /// — and the verbs that never light are plain items in it, not toggles that are always off.
    @Test func theOverflowNamesWhatItHidesThatIsApplied() {
        let hidden = EditorFormatBar.layout(EditorFormatBar.ladder.last!).hidden
        #expect(EditorFormatBar.overflowValue(hidden: hidden, lit: []) == "")
        #expect(EditorFormatBar.overflowValue(hidden: hidden, lit: [.bulletList, .bold])
                == "Applied: Bold, Bulleted List", "the » reads \(EditorFormatBar.overflowValue(hidden: hidden, lit: [.bulletList, .bold]))")
        // A lit verb on the bar itself is not the »'s to announce.
        let wide = EditorFormatBar.layout(EditorFormatBar.ladder[1]).hidden
        #expect(EditorFormatBar.overflowValue(hidden: wide, lit: [.bold]) == "")
        #expect(EditorFormatBar.overflowValue(hidden: wide, lit: [.codeBlock]) == "Applied: Code Block")
        for verb in [MarkupVerb.link, .codeBlock, .horizontalRule, .heading(0)] {
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
        #expect(a != EditorFormatBar(state: .none, accent: .red, onVerb: { _ in }), "an accent change is held off")
        #expect(a != EditorFormatBar(state: .none, accent: .blue, onVerb: { _ in }, forcedRung: EditorFormatBar.ladder[2]))
        let workspace = try Self.source("EditorWorkspaceView.swift")
        let call = try Self.slice(workspace, from: "EditorFormatBar(state: formatState", to: ".padding")
        #expect(call.contains(".equatable()"), "the host does not apply .equatable() — a keystroke redraws the bar")
    }

    // MARK: Narrow widths

    /// The bar at one rung, at one text size, as it lays out with room to spare.
    static func width(of rung: EditorFormatBar.Rung, scale: CGFloat) -> CGFloat {
        NSHostingView(rootView: AnyView(
            EditorFormatBar(state: .none, accent: .blue, onVerb: { _ in }, forcedRung: rung)
                .environment(\.appFontScale, scale)
        )).fittingSize.width
    }

    /// **Each rung of the ladder is narrower than the one before it, at every text size** — which is
    /// what makes the ladder a degrade order: `ViewThatFits` takes the first that fits, so a rung
    /// wider than its predecessor would never be drawn.
    @Test func eachRungIsNarrowerThanTheOneBeforeIt() {
        for percent in FontSize.selectablePercents {
            let scale = CGFloat(percent) / 100
            let widths = EditorFormatBar.ladder.map { Self.width(of: $0, scale: scale) }
            for (a, b) in zip(widths, widths.dropFirst()) {
                #expect(b < a, "at \(percent)% the ladder reads \(widths.map { Int($0) }) — a rung is no narrower than the one before")
            }
        }
    }

    /// **At the narrowest a Split half may be — `minSplitColumnWidth`, 220pt — and at every
    /// selectable text size, the bar fits.** The widest case: the bar's width does not depend on what
    /// is lit (the Heading menu is laid out at its widest label), so the forced rungs measured with
    /// nothing lit ARE its widths. The rung drawn is the first that fits the half less the bar's
    /// insets, which is `ViewThatFits`' own rule; the real, unforced bar is then mounted at that
    /// width and every control it draws must lie inside.
    ///
    /// **What it keeps there, measured 2026-10-03** (208pt once the insets are off): up to 105% the
    /// compact Heading menu and all five inline buttons — 186 · 193 · 199 · 206pt; from 110% to 135%
    /// Bold, Italic and Strikethrough, with Code and Link behind the » — 165 to 190pt. The floors
    /// pinned are those two facts: the inline five at the default size, and never fewer than B I S.
    ///
    /// Mutations: drop the compact Heading rung, or shed the inline group before the line kinds, and
    /// a floor fails; give the last rung a button too many and the bar overflows.
    @Test func theBarFitsTheNarrowestSplitHalfAtEveryTextSize() throws {
        let available = EditorLayoutMetrics.minSplitColumnWidth - 2 * EditorWorkspaceView.formatBarInset
        let inline = EditorFormatBar.groups.first?.count ?? 0
        var report: [String] = []
        for percent in FontSize.selectablePercents {
            let scale = CGFloat(percent) / 100
            let widths = EditorFormatBar.ladder.map { Self.width(of: $0, scale: scale) }
            let chosen = try #require(widths.firstIndex { $0 <= available },
                                      "at \(percent)% no rung fits \(available)pt: \(widths.map { Int($0) })")
            let rung = EditorFormatBar.ladder[chosen]
            report.append("\(percent)%: rung \(chosen) (\(Int(widths[chosen]))pt)")
            #expect(rung.visible >= inline - 2,
                    "at \(percent)% the bar keeps \(rung.visible) buttons at \(available)pt — fewer than Bold, Italic and Strikethrough")
            if percent == FontSize.medium.percent {
                #expect(rung.visible >= inline,
                        "at the default size the bar keeps \(rung.visible) buttons at \(available)pt — fewer than the inline \(inline)")
            }

            // The real bar, choosing for itself, in that width.
            let size = CGSize(width: available, height: 40)
            let host = NSHostingView(rootView: AnyView(
                EditorFormatBar(state: .none, accent: .blue, onVerb: { _ in })
                    .environment(\.appFontScale, scale)
                    .frame(width: size.width, height: size.height, alignment: .leading)))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let rings = FocusRings.frames(in: host)
            #expect(!rings.isEmpty, "the bar drew no controls at \(percent)%")
            #expect(rings.allSatisfy { $0.maxX <= available + 0.5 && $0.minX >= -0.5 },
                    "at \(percent)% a control is drawn outside \(available)pt: \(rings.map { Int($0.maxX) })")
            window.contentView = nil
            window.close()
        }
        print("[format-bar-fit] at \(Int(available))pt: \(report.joined(separator: " · "))")
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

    static func slice(_ code: String, from start: String, to end: String) throws -> String {
        let a = try #require(code.range(of: start), "\(start) is not in the source")
        let rest = code[a.upperBound...]
        let b = rest.range(of: end)?.lowerBound ?? rest.endIndex
        return String(rest[..<b])
    }
}
