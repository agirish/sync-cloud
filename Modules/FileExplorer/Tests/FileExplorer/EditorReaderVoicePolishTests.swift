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

    /// **The workspace gates the counts on the file, and seeds Line/Col as the file arrives** — the
    /// call site of the rule above, the path the count was taken on, and the caret set beside the
    /// offset it is derived from rather than a debounce later.
    @Test func theWorkspaceGatesTheCountsOnTheFileAndSeedsTheCaret() throws {
        let code = try Self.code("EditorWorkspaceView.swift")
        #expect(code.contains("EditorStatusLine(facts: EditorStatusLine.shownFacts(facts, countedFor: factsPath, open: document.path),"),
                "the status line is handed counts without asking whose they are")
        #expect(code.contains("let path = document.path let version = document.textVersion"))
        #expect(code.contains("factsVersion = version factsPath = path"), "the count does not record the file it was taken on")
        #expect(code.contains("in: document.text) caret = EditorCaret.at(utf16Offset: caretOffset, in: document.text)"),
                "Line/Col is not seeded where the arriving file's caret offset is")
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
        #expect(EditorSaveStatus.heldUnsaved.dotName == "Not saved yet")
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
        #expect(detail == "“Scan.pdf” — its owner doesn’t allow changing its pages", "\(detail)")
        #expect(detail.components(separatedBy: "Scan.pdf").count == 2, "the reason names the file twice: \(detail)")
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
