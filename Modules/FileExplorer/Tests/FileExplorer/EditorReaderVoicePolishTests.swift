import Testing
import AppKit
import PDFKit
import SwiftUI
import Design
@testable import FileExplorer
import FileExplorerTestSupport

/// **Edit's text, Markdown and PDF fixes ahead of 6.1** — ED2, ED3, ED4, ED5, ED10, PD3, PD6: what
/// the status line says beside a file just opened, a folded format-bar group with nothing to offer,
/// what Voice Control and VoiceOver hear, the ink editable Preview's links wear, and a restricted
/// file in a PDF batch.
///
/// Each rule is pinned by value, and its call site read off the code: an offscreen host has no
/// accessibility tree to ask, and a SwiftUI `Menu`'s disabled state cannot be read back.
@MainActor
@Suite(.serialized) struct EditorReaderVoicePolishTests {

    private static func code(_ file: String) throws -> String {
        EditorAcrossPolishTests.squashed(try EditorAcrossPolishTests.source(file))
    }

    // MARK: ED2 — the status line beside a file just opened

    private static let counted = EditorDocumentFacts(words: 412, characters: 2_301, lines: 40,
                                                     lineEnding: .crlf, encoding: "UTF-16")

    /// **Counts are shown only beside the file they were counted for** — another file's, or none
    /// counted yet, and they are left out; the same file's stand, however many keystrokes old.
    @Test func theCountsAreShownOnlyBesideTheFileTheyWereCountedFor() {
        #expect(EditorStatusLine.shownFacts(Self.counted, countedFor: "/n/Old.md", open: "/n/New.md") == nil,
                "the last file's counts stood beside the new file")
        #expect(EditorStatusLine.shownFacts(Self.counted, countedFor: nil, open: "/n/New.md") == nil)
        #expect(EditorStatusLine.shownFacts(Self.counted, countedFor: "/n/New.md", open: "/n/New.md") == Self.counted)
    }

    /// **Without counts the line says the caret and the size, and nothing of the last file** — no
    /// words, no encoding, no line endings.
    @Test func aLineWithoutCountsSaysOnlyTheCaretAndTheSize() {
        let caret = EditorCaret(line: 3, column: 7)
        #expect(EditorStatusLine.accessibilityLabel(facts: nil, caret: caret, fileSize: "4 KB")
                == "Line 3, Col 7, 4 KB")
        #expect(EditorStatusLine.countCaptions(facts: nil, selection: nil, rung: .full, lines: true) == [])
        // The control: the same line with counts says them all.
        #expect(EditorStatusLine.accessibilityLabel(facts: Self.counted, caret: caret, fileSize: "4 KB")
                == "412 words, 2,301 characters, Line 3, Col 7, 4 KB, UTF-16, CRLF line endings")
    }

    /// **The workspace gates the counts and Line/Col on the file** — the call site of the rule
    /// above, the path each was taken on, and no caret walked on the main actor as a file arrives
    /// (EP4): a 4 MB file with the caret at its end walked all of it there.
    @Test func theWorkspaceGatesTheCountsAndTheCaretOnTheFile() throws {
        let code = try Self.code("EditorWorkspaceView.swift")
        #expect(code.contains("EditorStatusLine(facts: EditorStatusLine.shownFacts(facts, countedFor: factsPath, open: document.path),"),
                "the status line is handed counts without asking whose they are")
        #expect(code.contains("notice: diskNotice, heldFacts: facts, caretIsCurrent: caretPath == document.path)"),
                "the status line draws Line/Col without asking whose caret it is")
        #expect(code.contains("let path = document.path let version = document.textVersion"))
        #expect(code.contains("factsVersion = version factsPath = path"), "the count does not record the file it was taken on")
        #expect(code.contains("caret = position caretPath = path"), "the caret does not record the file it was taken on")
        let start = try #require(code.range(of: ".onChange(of: document.path, initial: true)"))
        let end = try #require(code.range(of: "liveSelection.set(length: 0)", range: start.upperBound..<code.endIndex))
        let arrival = code[start.upperBound..<end.lowerBound]
        #expect(arrival.contains("caretOffset = EditorCaretAnchors.clamped("), "the premise: this is the arrival")
        #expect(!arrival.contains("EditorCaret.at("), "a file's arrival walks its text for Line/Col on the main actor")
    }

    // MARK: EP4–EP7 — the line holds still while a new file is counted

    /// **A move keeps the counts; an open does not** (EP5) — the same text under a new path is the
    /// same counts, and an open always writes the buffer, moving its version.
    @Test func aMoveKeepsTheCountsAndAnOpenDoesNot() throws {
        #expect(EditorStatusLine.keepsCounts(countedAt: 7, textVersion: 7))
        #expect(!EditorStatusLine.keepsCounts(countedAt: 7, textVersion: 8))
        #expect(!EditorStatusLine.keepsCounts(countedAt: nil, textVersion: 0))
        let code = try Self.code("EditorWorkspaceView.swift")
        #expect(code.contains("if EditorStatusLine.keepsCounts(countedAt: factsVersion, textVersion: document.textVersion) { factsPath = document.path if caretPath != nil { caretPath = document.path } } else { factsPath = nil caretPath = nil }"),
                "a file's arrival does not keep a moved file's counts, or does not drop another file's")
        // The premise: an open writes the buffer even with the same text, and a move does not.
        let document = EditorDocument()
        document.open(.readOnly(text: "same", reason: "test"), at: "/n/A.md")
        let opened = document.textVersion
        document.open(.readOnly(text: "same", reason: "test"), at: "/n/B.md")
        #expect(document.textVersion != opened, "an open of the same text left the version where it was")
        let reopened = document.textVersion
        document.retarget(to: "/n/C.md")
        #expect(document.textVersion == reopened, "a move rewrote the buffer")
    }

    /// **Only a file's first count skips the debounce** (EP6) — a keystroke before it lands waits
    /// its turn, as does every count once it has; the next file's first skips it again, and so does
    /// a return to a file whose count never landed.
    @Test func onlyAFilesFirstCountSkipsTheDebounce() throws {
        let gate = EditorFirstCountGate()
        #expect(gate.skipsDebounce(open: "/n/A.md", countedFor: nil), "a file's first count waits")
        #expect(!gate.skipsDebounce(open: "/n/A.md", countedFor: nil), "a keystroke before the first count landed skipped the debounce")
        #expect(!gate.skipsDebounce(open: "/n/A.md", countedFor: "/n/A.md"))
        #expect(gate.skipsDebounce(open: "/n/B.md", countedFor: "/n/A.md"))
        #expect(gate.skipsDebounce(open: "/n/A.md", countedFor: nil), "back to a file counted for nothing")
        #expect(!gate.skipsDebounce(open: nil, countedFor: nil))
        let code: String? = try Self.code("EditorWorkspaceView.swift")
        #expect(code?.contains("guard await factsGate.settle(open: document.path, countedFor: factsPath, debounce: .milliseconds(150)) else { return }") == true,
                "the count's debounce is not asked of the gate")
        #expect(code?.contains("guard await caretGate.settle(open: document.path, countedFor: caretPath, debounce: .milliseconds(120)) else { return }") == true,
                "the caret's debounce is not asked of the gate")
    }

    /// **A task cancelled before it ran keeps the file's skip for the one that replaced it** (F-E1).
    /// A file's arrival writes the caret it was left at, which restarts the caret's task before it
    /// has run; asking the gate first used the skip up, and the file's first Line/Col waited out the
    /// debounce after all. Driven through a restart: the first task is cancelled before it starts.
    @Test func aRestartedTaskLeavesTheFirstSkipToItsReplacement() async {
        let gate = EditorFirstCountGate()
        let restarted = Task { @MainActor in
            await gate.settle(open: "/n/A.md", countedFor: nil, debounce: .seconds(30))
        }
        restarted.cancel()
        #expect(await restarted.value == false, "a cancelled task went on to count")
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await gate.settle(open: "/n/A.md", countedFor: nil, debounce: .seconds(30)),
                "the replacement was not let through")
        #expect(clock.now - started < .seconds(10),
                "the restarted task used up the skip, and its replacement waited out the debounce")
        #expect(!gate.skipsDebounce(open: "/n/A.md", countedFor: nil), "the replacement did not take the skip")
    }

    /// **The caret names a heading only beside the file it was derived for** (F-E1) — the rail's
    /// outline and the status line's "in …" read the last file's line against this file's headings.
    @Test func theCaretNamesAHeadingOnlyBesideItsOwnFile() throws {
        let caret = EditorCaret(line: 30, column: 1)
        #expect(EditorStatusLine.shownCaretLine(caret, derivedFor: "/n/Old.md", open: "/n/New.md") == nil,
                "the last file's caret named a heading in the new file")
        #expect(EditorStatusLine.shownCaretLine(caret, derivedFor: nil, open: nil) == nil)
        #expect(EditorStatusLine.shownCaretLine(caret, derivedFor: "/n/New.md", open: "/n/New.md") == 30)
        let outline = [MarkdownOutlineEntry(line: 1, level: 1, depth: 0, title: "Intro"),
                       MarkdownOutlineEntry(line: 20, level: 2, depth: 1, title: "Method")]
        func heading(_ line: Int?) -> String? {
            EditorStatusHeadings.make(outline: outline, caretLine: line, isMarkdown: true, offersRailOutline: true,
                                      accent: .blue, onSelect: { _ in }, onShowRailOutline: {})?.title
        }
        #expect(heading(nil) == "Headings", "a caret not yet derived named a heading")
        #expect(heading(30) == "in Method")
        let code = try Self.code("EditorWorkspaceView.swift")
        #expect(code.contains("EditorStatusHeadings.make(outline: outline, caretLine: shownCaretLine,"),
                "the status line's heading reads a caret without asking whose it is")
        #expect(code.contains("currentOutlineIndex: shownCaretLine.flatMap { MarkdownOutline.currentEntry(forLine: $0, in: outline) },"),
                "the rail's outline reads a caret without asking whose it is")
        #expect(code.contains("EditorStatusLine.shownCaretLine(caret, derivedFor: caretPath, open: document.path)"))
    }

    /// **Go to Line says this file's line count, or none** (EP7) — never the last file's.
    @Test func goToLineSaysOnlyThisFilesLineCount() throws {
        #expect(EditorGoToLineField.lineCountCaption(nil) == nil)
        #expect(EditorGoToLineField.lineCountCaption(1) == "This file has 1 line.")
        #expect(EditorGoToLineField.lineCountCaption(4_000) == "This file has 4,000 lines.")
        let code = try Self.code("EditorWorkspaceView.swift")
        #expect(code.contains("let lines = EditorStatusLine.shownFacts(facts, countedFor: factsPath, open: document.path).map { max($0.lines, 1) } return EditorStatusGoToLine(isPresented: $goToLineShown, lineCount: lines,"),
                "Go to Line counts the last file's lines")
    }

    /// **Rendered and read back: while a new file is counted, the line holds still** (EP5). The
    /// counts and the caret hold their room undrawn, so what IS drawn — the caret once it lands,
    /// the size — stands exactly where it stood, and nothing of the last file is drawn.
    @Test func theLineHoldsStillWhileANewFileIsCounted() throws {
        let caret = EditorCaret(line: 48, column: 12)
        let counted = try Self.inkColumns(EditorStatusLine(facts: Self.counted, caret: caret, fileSize: "4 KB",
                                                           forcedRung: .full), name: "counted")
        let counting = try Self.inkColumns(EditorStatusLine(facts: nil, caret: caret, fileSize: "4 KB", forcedRung: .full,
                                                            heldFacts: Self.counted), name: "counting")
        let noCaret = try Self.inkColumns(EditorStatusLine(facts: nil, caret: caret, fileSize: "4 KB", forcedRung: .full,
                                                           heldFacts: Self.counted, caretIsCurrent: false), name: "no-caret")
        print("[EP5] ink columns: counted \(counted.count) · counting \(counting.count) · no caret \(noCaret.count)")
        #expect(!counting.isEmpty && !noCaret.isEmpty, "the size is not drawn")
        let moved = counting.subtracting(counted).sorted().prefix(8)
        #expect(counting.isSubset(of: counted), "the caret or the size moved while the file was counted: \(moved)")
        let firstCount = try #require(counted.min())
        #expect(!counting.contains(firstCount), "the last file's word count is drawn")
        #expect(counting.count < counted.count * 3 / 4, "the last file's counts and facts are drawn")
        #expect(noCaret.isSubset(of: counting) && noCaret.count < counting.count, "the last file's caret is drawn")
        // Not read aloud either: the caret and the counts said only once they are this file's.
        #expect(EditorStatusLine.accessibilityLabel(facts: nil, caret: nil, fileSize: "4 KB") == "4 KB")
    }

    /// **A caret held undrawn is not a button** (F-E8): no hover wash, tooltip or press over blank
    /// room, no ⌥ keycap, and VoiceOver's line neither says it nor offers its press. Read off the
    /// code — a SwiftUI button's hit testing cannot be asked offscreen.
    @Test func anUndrawnCaretIsNotAButton() throws {
        let code = try Self.code("EditorStatusLine.swift")
        #expect(code.contains(".shortcutKeycap(AppChord.goToLine.display, compact: true, shown: caretIsCurrent)"),
                "an undrawn caret shows its keycap")
        #expect(code.contains(".help(EditorStatusGoToLine.help) .allowsHitTesting(caretIsCurrent) .accessibilityHidden(!caretIsCurrent)"),
                "an undrawn caret is still a live, hoverable button")
        #expect(code.contains(".accessibilityHint(goToLine == nil || !caretIsCurrent ? \"\" : \"Goes to a line\")"),
                "VoiceOver offers Go to Line on a line with no caret drawn")
    }

    /// The columns of `line` that carry ink, drawn at 1× in a window — saved beside the test's run
    /// for a look.
    private static func inkColumns(_ line: EditorStatusLine, name: String) throws -> Set<Int> {
        let host = NSHostingView(rootView: line.frame(width: 620))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 30)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = NSTemporaryDirectory() + "ep5-status-line-\(name).png"
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: png))
        print("[EP5] \(name): \(png)")
        var columns: Set<Int> = []
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
            guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.1 else { continue }
            if (c.redComponent + c.greenComponent + c.blueComponent) / 3 < 0.8 { columns.insert(x); break }
        } }
        return columns
    }

    // MARK: ED3 — a folded group with nothing to offer

    /// **Lists greys when it folds inside a table**, where every list would break it — and only then:
    /// the other groups each keep an item that still works there.
    @Test func aFoldedGroupGreysWhenNoneOfItsItemsWouldAct() throws {
        let inTable = EditorFormatBarTests.inTable
        let lists = EditorFormatBar.Part.group(1)
        #expect(EditorFormatBar.title(lists) == "Lists", "the premise: group 1 is Lists")
        #expect(!EditorFormatBar.isFoldOffered(lists, in: inTable), "folded Lists stays live in a table")
        #expect(EditorFormatBar.isFoldOffered(lists, in: .none), "folded Lists is greyed outside a table")
        for part in EditorFormatBar.foldableGroups where part != lists {
            #expect(EditorFormatBar.isFoldOffered(part, in: inTable), "\(EditorFormatBar.title(part)) greys in a table")
        }
        // The Table button counts as the two items its folded menu lists, each by its own rule.
        let insert = try #require(EditorFormatBar.foldableGroups.last)
        #expect(EditorFormatBar.itemVerbs(of: insert) == [.link, .table(.insert), .table(.fromSelection), .horizontalRule],
                "\(EditorFormatBar.itemVerbs(of: insert))")
    }

    /// The folded button is greyed and dimmed by that rule, and its menu lists those items.
    @Test func theFoldedButtonIsGreyedByTheRule() throws {
        let code = try Self.code("EditorFormatBar.swift")
        #expect(code.contains("let offered = Self.isFoldOffered(part, in: state) return Menu { items(of: part) } label: { label(Self.symbol(part), word: nil, lit: lit, offered: offered, chevron: true) }"))
        #expect(code.contains(".fixedSize() .disabled(!offered) .help(Self.title(part))"),
                "the folded group's button is not disabled")
        #expect(code.contains("ForEach(Self.itemVerbs(of: part), id: \\.self) { item($0) }"))
    }

    /// **Inside the merged », Lists greys in a table too** (EP2) — read off the » menu's own items as
    /// AppKit builds them. It opened a submenu of greyed items there; the other groups stay live,
    /// and outside a table Lists is live again.
    @Test func theMergedMenuGreysAGroupWithNothingToOffer() throws {
        let rung = EditorFormatBar.Rung(headingWorded: false, folded: Set(EditorFormatBar.foldableGroups),
                                        merged: true, marksFolded: true)
        // Each group's line: "Lists ▸" for a submenu AppKit draws live, "(Lists)" for one greyed.
        func groups(_ state: MarkupFormatState) -> [String] {
            let bar = EditorFormatBar(state: state, accent: .blue, onVerb: { _ in })
            let menu = NSHostingMenu(rootView: bar.mergedItems(rung))
            menu.update()
            let titles = Set(EditorFormatBar.foldableGroups.map(EditorFormatBar.title))
            return menu.items.filter { titles.contains($0.title) }.map { item in
                item.submenu != nil && item.isEnabled ? "\(item.title) ▸" : item.isEnabled ? item.title : "(\(item.title))"
            }
        }
        #expect(groups(EditorFormatBarTests.inTable) == ["(Lists)", "Code and Quote ▸", "Insert ▸"],
                "folded Lists stays live inside the merged menu in a table: \(groups(EditorFormatBarTests.inTable))")
        #expect(groups(.none) == ["Lists ▸", "Code and Quote ▸", "Insert ▸"], "\(groups(.none))")
    }

    // MARK: ED4 — Voice Control answers to the bar's words

    /// **"Click Bullets" finds Bulleted List** — the word on screen first, the full name kept.
    @Test func theBarsWordsAreWhatVoiceControlAnswersTo() throws {
        func names(_ verb: MarkupVerb) -> [String] {
            EditorSpokenNames.names(word: EditorFormatBar.word(verb), label: verb.title)
        }
        #expect(names(.bulletList) == ["Bullets", "Bulleted List"])
        #expect(names(.taskItem) == ["Tasks", "Task Item"])
        #expect(names(.blockQuote) == ["Quote", "Block Quote"])
        #expect(names(.bold) == ["Bold"])
        let code = try Self.code("EditorFormatBar.swift")
        #expect(code.contains(".accessibilityLabel(verb.title) .accessibilityInputLabels(EditorSpokenNames.names(word: Self.word(verb), label: verb.title))"),
                "the bar's buttons do not answer to their words")
        #expect(code.contains(".accessibilityLabel(verb.title) .accessibilityInputLabels(EditorSpokenNames.names(word: Self.word(Self.tableMenuStandIn), label: verb.title))"),
                "the Table button does not answer to its word")
    }

    /// **"Click Body" and "Click Heading 2" find the style menu** (EP8) — the word it shows, and "H2"
    /// where it shows that; "¶" is no word to say.
    @Test func theStyleMenuAnswersToItsWord() throws {
        typealias Bar = EditorFormatBar
        #expect(Bar.headingInputLabels(.body, worded: true) == ["Body", "Paragraph style"])
        #expect(Bar.headingInputLabels(.level(2), worded: true) == ["Heading 2", "Paragraph style"])
        #expect(Bar.headingInputLabels(.level(2), worded: false) == ["H2", "Heading 2", "Paragraph style"])
        #expect(Bar.headingInputLabels(.body, worded: false) == ["Body", "Paragraph style"])
        let code = try Self.code("EditorFormatBar.swift")
        #expect(code.contains(".accessibilityLabel(\"Paragraph style: \\(Self.headingTitle(state.heading, worded: true))\") .accessibilityInputLabels(Self.headingInputLabels(state.heading, worded: worded))"),
                "the style menu does not answer to its word")
    }

    // MARK: ED5 — editable Preview's links wear the window's hue

    private static let coral = NSColor(LiquidGlassHue.coral.accentColor)

    /// **The session colours a link with the hue it is handed, and a new hue redecorates the page.**
    @Test func theSessionColoursLinksWithTheHue() throws {
        let source = EditorSourceStorage(text: "See [the plan](https://example.com/plan) today.\n")
        let session = PreviewEditSession(source: source, undoManager: UndoManager(), linkColor: Self.coral)
        func ink() -> NSColor? {
            let at = (session.display.string as NSString).range(of: "the plan").location
            return session.display.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor
        }
        #expect(ink() == Self.coral, "a link wears \(String(describing: ink())), not the hue")
        let green = NSColor(LiquidGlassHue.green.accentColor)
        session.linkColor = green
        #expect(ink() == green, "a new hue left the page's links as they were")
    }

    /// **Rendered and read back: the link is the hue, never system blue** — AppKit paints its own
    /// `linkTextAttributes` over a link's colour, so the run's colour alone was not what was drawn.
    @Test func editablePreviewDrawsLinksInTheHue() throws {
        let text = "[Coral coral coral coral coral coral](https://example.com/a)\n"
        let source = EditorSourceStorage(text: text)
        let view = PreviewEditorView(source: source, undoManager: UndoManager(), fontScale: 2,
                                     linkColor: LiquidGlassHue.coral.accentColor)
        let host = NSHostingView(rootView: view.frame(width: 520, height: 200))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let textView = try #require(Self.previewTextView(in: host), "no editable Preview mounted")
        #expect((textView.linkTextAttributes?[.foregroundColor] as? NSColor) == Self.coral,
                "the text view paints links in \(String(describing: textView.linkTextAttributes?[.foregroundColor]))")
        textView.layoutSubtreeIfNeeded()
        let bounds = textView.visibleRect
        let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: bounds))
        textView.cacheDisplay(in: bounds, to: rep)
        // Read as-is — `colorAt` tags sRGB numbers as calibrated; converting them moves every one.
        var warm = 0, blue = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            if c.redComponent > c.blueComponent + 0.25 { warm += 1 }
            if c.blueComponent > c.redComponent + 0.25 { blue += 1 }
        } }
        print("[ED5] link pixels: warm \(warm) · blue \(blue)")
        #expect(warm > 200, "the link's coral ink is not drawn (\(warm) warm pixels)")
        #expect(blue < 20, "the link is drawn in system blue (\(blue) blue pixels)")
    }

    private static func previewTextView(in view: NSView) -> PreviewTextView? {
        if let found = view as? PreviewTextView { return found }
        for sub in view.subviews { if let found = previewTextView(in: sub) { return found } }
        return nil
    }

    /// The workspace hands editable Preview the window's accent, as it hands read-only Preview.
    @Test func theWorkspaceHandsEditablePreviewItsAccent() throws {
        let code = try Self.code("EditorWorkspaceView.swift")
        #expect(code.contains("findRequest: inSplit ? splitPreviewFindRequest : findRequest, linkColor: accent)"))
    }

    // MARK: ED10 — the rail's dot says what the header's says

    @Test func theDotsNameTellsAStopFromAPendingWrite() throws {
        #expect(EditorSaveStatus.stopped("couldn’t write").dotName == "Not saving")
        #expect(EditorSaveStatus.unsaved.dotName == "Not saved yet")
        // A held file waits for ⌘S, as its header's "unsaved — ⌘S" says (EP3).
        #expect(EditorSaveStatus.heldUnsaved.word == "unsaved — ⌘S", "the premise: the header's word")
        #expect(EditorSaveStatus.heldUnsaved.dotName == "Unsaved — ⌘S saves it")
        let rail = try Self.code("EditorFileRailView.swift")
        #expect(rail.contains(".accessibilityHidden(dot == nil) .accessibilityLabel(documentStatus?.dotName ?? \"\")"),
                "the rail's dot does not use the header's name")
        #expect(!rail.contains("\"Unsaved\""))
        let header = try Self.code("EditorWorkspaceView.swift")
        #expect(header.contains(".accessibilityHidden(dotColour == nil) .accessibilityLabel(status.dotName)"))
    }

    // MARK: PD6 — the palette's current ink and mark are heard

    @Test func inkAndMarksSayWhatTheirFacesShow() throws {
        typealias Palette = EditorPDFFillPalette
        #expect(Palette.spokenValue(.ink, color: .blue, mark: .check) == "Blue")
        #expect(Palette.spokenValue(.ink, color: .black, mark: .check) == "Black")
        #expect(Palette.spokenValue(.marks, color: .blue, mark: .cross) == "Cross")
        #expect(Palette.spokenValue(.marks, color: .blue, mark: .check) == "Check Mark")
        #expect(Palette.spokenValue(.text, color: .black, mark: .dot) == "")
        let code = try Self.code("EditorPDFFillPalette.swift")
        #expect(code.contains(".accessibilityLabel(tool.title) .accessibilityValue(Self.spokenValue(tool, color: fill.color, mark: shownMark))"))
    }
}

/// **PD3 — a restricted file in a PDF batch is skipped before the run**, with its own reason,
/// rather than failed by the toolkit with a sentence that names the file a second time.
@MainActor
@Suite(.serialized) final class EditorPDFBatchRestrictedTests {

    let folder = NSTemporaryDirectory() + "pdf-batch-restricted-" + UUID().uuidString

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    /// **Rotate skips the restricted file, names it once, and counts it as skipped** — the plain
    /// file beside it is rotated. The restricted file comes first, so a batch that stopped at it
    /// would show.
    @Test func rotateSkipsARestrictedFileWithItsOwnReason() async throws {
        let restricted = path("Scan.pdf"), plain = path("Statement.pdf")
        PDFFixtures.writeRestricted(restricted)
        PDFFixtures.write(plain, pages: 2)
        let batch = EditorPDFBatch(kind: .rotate(quarterTurns: 1), paths: [restricted, plain], writer: "PDF Tools in Browse")
        batch.confirm = { _ in true }
        await batch.run(.rotate(quarterTurns: 1))
        #expect(batch.files[0].status == .skipped(.restrictedByOwner), "\(batch.files[0].status)")
        guard case .wrote = batch.files[1].status else {
            Issue.record("the plain file was not rotated: \(batch.files[1].status)"); return
        }
        #expect(batch.banner?.message == "Saved 1 rotated copy · 1 skipped", "\(String(describing: batch.banner?.message))")
        let detail = try #require(batch.banner?.detail)
        #expect(detail == "“Scan.pdf” — its owner doesn’t allow changing its pages\n"
                + EditorPDFToolEngine.liftRestrictionsStep, "\(detail)")
        #expect(detail.components(separatedBy: "Scan.pdf").count == 2, "the reason names the file twice: \(detail)")
    }

    /// **The way past the restrictions is said once, last** — however many files they stopped, and
    /// only when they stopped one: a locked file's line carries no such step.
    @Test func theRemovePasswordStepEndsTheReasonsOnce() throws {
        let step = EditorPDFToolEngine.liftRestrictionsStep
        let lines = try #require(EditorPDFBatch.reasons([("A.pdf", .skipped(.restrictedByOwner)),
                                                         ("B.pdf", .skipped(.lockedToOpen)),
                                                         ("C.pdf", .skipped(.restrictedByOwner))]))
            .components(separatedBy: "\n")
        #expect(lines == ["“A.pdf” — its owner doesn’t allow changing its pages",
                          "“B.pdf” — locked with a password",
                          "“C.pdf” — its owner doesn’t allow changing its pages", step], "\(lines)")
        #expect(EditorPDFBatch.reasons([("B.pdf", .skipped(.lockedToOpen))]) == "“B.pdf” — locked with a password")
        // Clean Metadata's encrypted skip is an owner's restriction too, with the same way past it,
        // still said once (F-E5).
        let metadata = try #require(EditorPDFBatch.reasons([("D.pdf", .skipped(.passwordProtected)),
                                                            ("A.pdf", .skipped(.restrictedByOwner))]))
            .components(separatedBy: "\n")
        #expect(metadata == ["“D.pdf” — its owner doesn’t allow changing it",
                             "“A.pdf” — its owner doesn’t allow changing its pages", step], "\(metadata)")
        #expect(EditorPDFBatch.reasons([("D.pdf", .skipped(.passwordProtected))])
                == "“D.pdf” — its owner doesn’t allow changing it\n" + step,
                "Clean Metadata's skip gave no way forward")
    }

    /// **Decided in the lane, before the toolkit runs** — and only for the tools that change the
    /// file in place: Compress and Clean Metadata rebuild the document and run on it (the latter's
    /// own password skip aside).
    @Test func onlyTheInPlaceToolsAreSkipped() {
        let rotate = EditorPDFTool.rotate(pages: [0], quarterTurns: 1)
        #expect(EditorPDFBatch.ownerForbids(rotate, isEncrypted: true, allowsAssembly: false))
        #expect(EditorPDFBatch.ownerForbids(.deletePages([0]), isEncrypted: true, allowsAssembly: false))
        #expect(!EditorPDFBatch.ownerForbids(rotate, isEncrypted: true, allowsAssembly: true))
        #expect(!EditorPDFBatch.ownerForbids(rotate, isEncrypted: false, allowsAssembly: false))
        #expect(!EditorPDFBatch.ownerForbids(.compress(.quality(0.35)), isEncrypted: true, allowsAssembly: false))
        let restricted = path("Restricted.pdf")
        PDFFixtures.writeRestricted(restricted)
        let turn = EditorPDFBatch.laneTurn(.rotate(quarterTurns: 1), input: URL(fileURLWithPath: restricted),
                                           progress: nil, isCancelled: nil)
        guard case .skipped(.restrictedByOwner) = turn else {
            Issue.record("the lane ran Rotate on a restricted file: \(turn)"); return
        }
    }
}
