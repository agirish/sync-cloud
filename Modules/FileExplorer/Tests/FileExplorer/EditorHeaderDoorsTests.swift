import Testing
import SwiftUI
import AppKit
import Design
import DesignTestSupport
@testable import FileExplorer
import FileExplorerTestSupport

/// The document header's ＋ and ×: where they are drawn, what they say, and what they cost the
/// file name. Drawn, not read: a hosted SwiftUI tree exposes no labels and takes no synthetic
/// click under `swift test`, but it has one `_FocusRingView` per button, and pixels tell
/// identical-looking glyphs apart. What they do is scanned in the app target
/// (`EditorHeaderDoorsWiringTests`, `EditorDocumentCloseTests`).
@MainActor
@Suite(.serialized) struct EditorHeaderDoorsTests {

    /// Every setting the header reads, fresh per test (swift-testing builds a new suite instance
    /// for each). Never the standard domain, which under `swift test` every test process shares.
    private let defaults = ScratchDefaults("EditorHeaderDoorsTests")

    private func document(named name: String) throws -> EditorDocument {
        try TestTextFiles.document(named: name)
    }

    /// A bare header button's width: ``EditorHeaderChipLabel`` without its word, the 18pt of the ＋,
    /// Find, Expand and the ×. Read off the label, never the row, whose first button is
    /// "＋ New Text File" on the widest rung.
    static var bareChip: CGFloat {
        NSHostingView(rootView: EditorHeaderChipLabel(symbol: "plus")).fittingSize.width
    }

    /// Wide enough that every header here is on its worded rung, so two headers compared pixel for
    /// pixel are on the same rung.
    static let wide = CGSize(width: 1_400, height: 48)

    /// Runs `body` with Edit in Preview set to `editing` (on by default, which keeps Find in
    /// Preview). `headerContent` renders off a workspace in no view hierarchy, so the store reaches
    /// it through ``EditorWorkspaceView/readingSettings(from:)``, not `.defaultAppStorage`.
    private func withEditInPreview<T>(_ editing: Bool, _ body: () throws -> T) rethrows -> T {
        defaults.set(editing, forKey: EditorTextSettings.editsInPreviewKey)
        return try body()
    }

    private func workspace(_ document: EditorDocument, mode: EditorMode = .edit,
                           railIsHidden: Bool = false,
                           newTextFile: (() -> Void)? = {}) -> EditorWorkspaceView {
        EditorWorkspaceView.fixture(document: document, folder: "/n/Downloads", railIsHidden: railIsHidden,
                                    mode: mode, onNewTextFile: newTextFile)
            .readingSettings(from: defaults)
    }

    // MARK: What it says

    /// The tooltip names the folder, as the rail's ＋ does on the line beside it. Swapping the arms
    /// fails both lines.
    @Test func theTooltipNamesTheFolderItWillCreateIn() {
        #expect(EditorWorkspaceView.newTextFileTitle(folderName: "Downloads") == "New text file in Downloads")
        #expect(EditorWorkspaceView.newTextFileTitle(folderName: "") == "Pick a folder in the sidebar first")
    }

    /// Greyed where it shows. `.disabled` alone leaves a `.glyph` button pixel-identical at rest, so
    /// a ＋ with no ⌘N closure takes the tertiary style, on an open document and the empty page.
    @Test func thePlusLooksGreyedWithNoFolder() throws {
        let doc = try document(named: "note.md")
        for subject in [doc, EditorDocument()] {
            let live = try #require(Rendered(workspace(subject, newTextFile: {}).headerCard))
            let greyed = try #require(Rendered(workspace(subject, newTextFile: nil).headerCard))
            let a = try #require(live.nameRowRings.first, "no ＋ drawn")
            let b = try #require(greyed.nameRowRings.first, "no ＋ drawn with no folder — it should be greyed, not withheld")
            #expect(!live.samePixels(a, as: greyed, b),
                    "\(subject.path == nil ? "empty page" : "open file"): the ＋ with no folder draws the same pixels as a live one")
        }
    }

    // MARK: The empty page

    /// With no document open the header keeps the ＋ and, while lit, Expand, and nothing else: the
    /// ＋ draws an open file's pixels, and Expand wears as much accent as an open file's lit one.
    @Test func theEmptyPageKeepsThePlusAndOnlyALitExpand() throws {
        let doc = try document(named: "note.md")
        let empty = EditorDocument()
        let unlit = try #require(Rendered(workspace(empty, newTextFile: {}).headerCard, size: Self.wide))
        let lit = try #require(Rendered(workspace(empty, railIsHidden: true, newTextFile: {}).headerCard, size: Self.wide))
        let open = try #require(Rendered(workspace(doc, railIsHidden: true, newTextFile: {}).headerCard, size: Self.wide))
        #expect(unlit.nameRowRings.count == 1, "the empty page draws \(unlit.nameRowRings.count) buttons with the rail showing — the ＋ alone expected")
        try #require(lit.nameRowRings.count == 2, "the empty page draws \(lit.nameRowRings.count) buttons under Expand — the ＋ and the lit Files button expected")
        let openRow = open.nameRowRings
        try #require(openRow.count >= 7, "the open header draws \(openRow.count) buttons — the comparison would be about nothing")
        #expect(lit.samePixels(lit.nameRowRings[0], as: open, openRow[0]),
                "the empty page's first button is not the ＋ an open file's header draws")
        // The lit button is told by its accent count, not exact pixels, which differ by a shade of
        // anti-aliasing from the open header's. The ＋ has none.
        let accentHere = lit.accentPixels(in: lit.nameRowRings[1])
        let accentThere = open.accentPixels(in: openRow[openRow.count - 2])
        #expect(lit.accentPixels(in: lit.nameRowRings[0]) == 0, "the empty page's first button wears the accent — it is not the ＋")
        #expect(accentThere > 0 && abs(accentHere - accentThere) <= accentThere / 10,
                "the empty page's second button has \(accentHere) accent pixels against the lit Expand's \(accentThere) — it is not that button, lit")
    }

    // MARK: Where it is drawn

    /// The header's buttons run `＋ · Find`, the capsule, Expand, then ×. Identical rings are told
    /// apart by what only each does: Expand lights with the rail bit, and Find is withheld in
    /// Preview. The ＋'s `.disabled`, invisible at rest, is pinned by the scan below.
    @Test func thePlusLeadsTheHeadersButtonsAndExpandSitsBeforeTheClose() throws {
        let doc = try document(named: "note.md")
        #expect(doc.isMarkdown, "the fixture is not Markdown — Preview would resolve back to Source")
        let edit = try #require(Rendered(workspace(doc, newTextFile: {}).headerContent))
        let again = try #require(Rendered(workspace(doc, newTextFile: {}).headerContent))
        let lit = try #require(Rendered(workspace(doc, railIsHidden: true, newTextFile: {}).headerContent))
        let preview = try #require(withEditInPreview(false) { Rendered(workspace(doc, mode: .preview, newTextFile: {}).headerContent) })
        let editable = try #require(withEditInPreview(true) { Rendered(workspace(doc, mode: .preview, newTextFile: {}).headerContent) })

        #expect(edit.differingBox(from: again) == nil, "two renders of the same header differ — the detector is noise")
        let row = edit.nameRowRings
        // ＋, Find, the capsule's three segments, Expand and ×: seven.
        try #require(row.count == 7, "the name row draws \(row.count) buttons — ＋, Find, three segments, Expand and × expected")

        // Expand is the one before the ×: the only pixels the rail bit moves are in that ring.
        let lightBox = try #require(lit.differingBox(from: edit), "the rail bit changed nothing — cannot find Expand")
        #expect(row[row.count - 2].insetBy(dx: -2, dy: -2).contains(lightBox),
                "Expand lights at \(lightBox), not in the button before the × \(row[row.count - 2])")

        // Find is the second: Preview withholds exactly one button, the first draws the same glyph
        // there and Expand the same one slot along, so the one that went is after the ＋.
        let pRow = preview.nameRowRings
        try #require(pRow.count == row.count - 1,
                     "Preview draws \(pRow.count) buttons against Source's \(row.count) — Find alone should go")
        #expect(editable.nameRowRings.count == row.count,
                "Preview you can type in draws \(editable.nameRowRings.count) buttons against Source's \(row.count) — it keeps Find")
        #expect(edit.samePixels(row[0], as: preview, pRow[0]),
                "the first button in Source is not the first in Preview — Find is first, or the ＋ is withheld in Preview")
        #expect(edit.samePixels(row[row.count - 2], as: preview, pRow[pRow.count - 2]),
                "Expand in Source is not Expand in Preview — it was withheld, or it is not before the ×")
        #expect(!edit.samePixels(row[1], as: preview, pRow[1]),
                "the second button in Source survives in Preview — it is not Find")
    }

    /// Greyed with no folder and wired to the ⌘N closure: a source scan of the ＋'s own modifier
    /// chain, since neither shows on the hosted button. Comments are stripped, so prose can't
    /// satisfy it. An empty action, or `.disabled(false)`, each fails a line.
    @Test func thePlusCallsTheNewFileClosureAndGreysWithoutOne() throws {
        let chain = try Self.chain(from: "EditorHeaderChipLabel(symbol: \"plus\"", in: Self.headerSource())
        #expect(chain.contains("onNewTextFile?()"), "the header's ＋ does not call the ⌘N closure")
        #expect(chain.contains(".foregroundStyle(onNewTextFile == nil"), "the header's ＋ no longer LOOKS greyed without a folder")
        #expect(chain.contains(".disabled(onNewTextFile == nil)"), "the header's ＋ no longer greys without a folder")
        #expect(chain.contains("AppChord.newTextFile.display"), "the header's ＋ no longer shows ⌘N")
    }

    // MARK: The ×

    /// VoiceOver hears which file the × closes; the tooltip says what it does. Dropping the name
    /// fails the first line.
    @Test func theCloseButtonNamesTheFileItCloses() {
        #expect(EditorWorkspaceView.closeTitle(name: "note.md") == "Close note.md")
        #expect(EditorWorkspaceView.closeTitle(name: "") == "Close this document")
    }

    /// Voice Control answers to the word on the button too ("Click Find", "Click Tools", "Click
    /// Close") though the names only start with it: the word first, the full name kept. Read off
    /// the code, since an offscreen host has no accessibility tree. Dropping any modifier fails.
    @Test func voiceControlAnswersToTheButtonsWord() throws {
        #expect(EditorSpokenNames.names(word: "Close", label: "Close Plan.md") == ["Close", "Close Plan.md"])
        #expect(EditorSpokenNames.names(word: "Find", label: "Find") == ["Find"])
        let chip = EditorAcrossPolishTests.squashed(try EditorAcrossPolishTests.source("EditorHeaderChips.swift"))
        #expect(chip.contains(".accessibilityLabel(EditorWorkspaceView.closeTitle(name: name)) "
                              + ".accessibilityInputLabels(EditorSpokenNames.names(word: Self.word, label: EditorWorkspaceView.closeTitle(name: name)))"))
        let tools = EditorAcrossPolishTests.squashed(try EditorAcrossPolishTests.source("EditorPDFToolViews.swift"))
        #expect(tools.contains(".accessibilityLabel(\"PDF Tools\") .accessibilityInputLabels(EditorSpokenNames.names(word: \"Tools\", label: \"PDF Tools\"))"))
    }

    /// The × is the last button in the row, after the capsule, and stays in Preview. Told from the
    /// capsule by width (a segment is wider than a glyph, measured on the row) and from other
    /// glyphs by position; in Preview it draws the same pixels, so it wasn't withheld.
    @Test func theCloseButtonIsLastAfterTheCapsuleAndStaysInPreview() throws {
        let doc = try document(named: "note.md")
        let edit = try #require(Rendered(workspace(doc).headerContent))
        let preview = try #require(withEditInPreview(false) { Rendered(workspace(doc, mode: .preview).headerContent) })
        let row = edit.nameRowRings
        try #require(row.count >= 7, "the name row draws \(row.count) buttons — ＋, Find, three segments, Expand and × expected")
        // At 520pt "note.md" is on the bare-buttons rung, so the × is a glyph like the ＋.
        let glyph = row[0].width
        try #require(abs(glyph - Self.bareChip) <= 2, "the ＋ is \(glyph)pt — not on the bare rung, so the × is not a glyph either")
        let last = try #require(row.last)
        #expect(abs(last.width - glyph) <= 2,
                "the last button is \(last.width)pt wide, not a glyph like the ＋ (\(glyph)pt) — the × is not last")
        let segments = row.filter { abs($0.width - glyph) > 2 }
        try #require(!segments.isEmpty, "no capsule segment found — the width tell is not telling anything")
        #expect(segments.allSatisfy { $0.maxX <= last.minX + 0.5 },
                "a capsule segment sits right of the × — the × is not after the capsule")
        #expect(last.maxX <= edit.size.width + 0.5, "the × is drawn past the header's edge at \(last.maxX)")
        let pLast = try #require(preview.nameRowRings.last)
        #expect(edit.samePixels(last, as: preview, pLast), "the × in Preview is not the × in Source — it was withheld or replaced")
    }

    /// Closed, the document column is the empty page and its header stays with the ＋ alone: after
    /// `EditorDocument.close()`, where the host's close ends, one button draws the open header's ＋
    /// pixels, and there is no Find, capsule or ×.
    @Test func aClosedDocumentLeavesTheEmptyPageWithThePlusAlone() throws {
        let doc = try document(named: "note.md")
        // Wide, so the open header and the empty page are both on the worded rung.
        let size = CGSize(width: 1_600, height: 300)
        let open = try #require(Rendered(workspace(doc).editorTestDefaults(defaults), size: size))
        let openRow = open.nameRowRings
        try #require(openRow.count >= 7, "the open document drew \(openRow.count) header buttons — the control is about nothing")
        doc.close()
        let closed = try #require(Rendered(workspace(doc).editorTestDefaults(defaults), size: size))
        #expect(closed.rings.count == 1, "\(closed.rings.count) buttons are drawn over a closed document — the ＋ alone expected")
        if let plus = closed.rings.first {
            #expect(closed.samePixels(plus, as: open, openRow[0]), "the one button left after a close is not the ＋")
        }
        #expect(doc.path == nil && doc.text.isEmpty && doc.refusal == nil, "close() left a document behind")
    }

    /// The × acts through the host's closure and nothing else, outside Find's Preview guard. A scan
    /// of the ×'s own chain, comments stripped; `Button {}` or `if resolvedMode != .preview` fails.
    @Test func theCloseButtonCallsTheHostsClose() throws {
        let code = try Self.headerSource()
        let flat = code.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        #expect(flat.contains("EditorCloseChip(name: document.name, worded: reading.chipsWorded, accent: accent, action: onCloseDocument)"),
                "the header's Close does not call the host's close, name the file, or wear the row's rung")
        let chip = try ChromeGlassWiringTests.source("EditorHeaderChips.swift")
        #expect(chip.contains("Button(action: action)"), "Close's chip does not run the action it is given")
        #expect(chip.contains(".accessibilityLabel(EditorWorkspaceView.closeTitle(name: name))"), "Close no longer names the file")
        let header = try #require(code.range(of: "var headerContent: some View"))
        let capsule = try #require(code.range(of: "EditorModeBar(", range: header.upperBound..<code.endIndex))
        let close = try #require(code.range(of: "EditorCloseChip(", range: header.upperBound..<code.endIndex))
        #expect(capsule.lowerBound < close.lowerBound, "Close is declared before the capsule")
    }

    // MARK: What the two glyphs cost the file name

    /// The name row fits a 55-character name at every text size, at the narrowest column (260pt)
    /// and the 760pt window floor's (~390pt): nothing past the edge, no wrap, and a floor on the
    /// name at each width (the two constants). The capsule is icons-only at both.
    @Test(.machinePinned(.layoutMetrics)) func theNameRowFitsWithALongNameAtEveryTextSize() throws {
        let long = try document(named: "Quarterly household budget reconciliation notes for 2026.md")
        let short = try document(named: "a.md")
        let padding = 2 * EditorDocumentHeader<EmptyView>.horizontalPadding
        let cases: [(column: CGFloat, minimumInk: CGFloat)] = [
            (EditorLayoutMetrics.minDocumentWidth, Self.minimumNameInkAtTheNarrowestColumn),
            (Self.floorWindowDocumentColumn, Self.minimumNameInkAtTheFloorWindow),
        ]
        var report: [String] = []
        // Solid and glass: glass draws Expand's clearance beside the ×, 2pt the name pays for, and
        // Frosted is the default, so Solid alone isn't the fit users get.
        for glass in [false, true] {
        for (column, minimumInk) in cases {
            let width = column - padding
            for scale in FontSize.allCases.map(\.scale) {
                let size = CGSize(width: width, height: 60)
                let content = glass
                    ? AnyView(workspace(long).headerContent.environment(\.selectionLensAppearance, SelectionLensCallSiteTests.probe))
                    : AnyView(workspace(long).headerContent)
                let longRow = try #require(Rendered(content, size: size, fontScale: scale))
                let hLong = NSHostingView(rootView: AnyView(workspace(long).headerContent
                    .environment(\.appFontScale, scale).frame(width: width))).fittingSize.height
                let hShort = NSHostingView(rootView: AnyView(workspace(short).headerContent
                    .environment(\.appFontScale, scale).frame(width: width))).fittingSize.height
                #expect(abs(hLong - hShort) < 0.51,
                        "at \(column)pt, scale \(scale), a long name makes the header \(hLong)pt against \(hShort)pt — the row wrapped")
                let row = longRow.nameRowRings
                let last = try #require(row.last, "no buttons in the row at \(column)pt, scale \(scale)")
                #expect(last.maxX <= width + 0.5,
                        "at \(column)pt, scale \(scale), the × ends at \(last.maxX), past the header's \(width)")
                // The name's ink: from the dot column to the first button, on the row's own band.
                let first = try #require(row.first)
                let nameStart = EditorWorkspaceView.dotColumnWidth + 6
                let band = CGRect(x: nameStart, y: first.minY, width: first.minX - nameStart, height: first.height)
                let ink = (longRow.inkRight(in: band) ?? nameStart) - nameStart
                report.append("\(glass ? "glass " : "")\(Int(column))pt@\(scale): \(Int(ink.rounded()))pt")
                #expect(ink >= minimumInk,
                        "\(glass ? "glass, " : "")at \(column)pt, scale \(scale), the long name keeps \(ink)pt of ink — under \(minimumInk)pt")
            }
        }
        }
        print("[name-fit] \(report.joined(separator: " · "))")
    }

    /// The document column at the 760pt window floor, as `EditorLayoutMetrics.splitFraction`'s note
    /// measures it ("~391pt"), rounded down.
    static let floorWindowDocumentColumn: CGFloat = 390

    /// The floor at the narrowest column (260pt): at least 5pt of the name's ink, its ellipsis
    /// (measured down to 5.5pt under glass), so the name is never pushed out entirely. No higher:
    /// the capsule is already icons-only there.
    static let minimumNameInkAtTheNarrowestColumn: CGFloat = 5

    /// At the floor-window column the name keeps a real run of characters either side of the
    /// ellipsis. Measured 134–153pt; 60 is roughly ten characters.
    static let minimumNameInkAtTheFloorWindow: CGFloat = 60

    /// The capsule's words are drawn only when the whole file name fits beside them (`nameRow`):
    /// swept over `capsuleColumns` at every text size on a 55-character name, with a short name
    /// keeping its words at 560pt as the control.
    @Test func theCapsuleKeepsItsWordsOnlyWhenTheWholeNameFits() throws {
        let long = try document(named: "Quarterly household budget reconciliation notes for 2026.md")
        let short = try document(named: "a.md")
        let padding = 2 * EditorDocumentHeader<EmptyView>.horizontalPadding
        let nameStart = EditorWorkspaceView.dotColumnWidth + 6
        func measure(_ doc: EditorDocument, column: CGFloat, scale: CGFloat) throws -> (worded: Bool, ink: CGFloat) {
            let width = column - padding
            let r = try #require(Rendered(workspace(doc).headerContent,
                                          size: CGSize(width: width, height: 60), fontScale: scale))
            let row = r.nameRowRings
            let first = try #require(row.first, "no buttons at \(column)pt, \(scale)")
            // A worded segment is far wider than two glyph buttons; an icon segment is not. The
            // capsule's three segments sit after New Text File and Find.
            try #require(row.count == 7, "\(row.count) buttons at \(column)pt, \(scale)")
            let glyph = Self.bareChip
            let worded = row[2..<5].contains { $0.width > 2 * glyph }
            let band = CGRect(x: nameStart, y: first.minY, width: first.minX - nameStart, height: first.height)
            return (worded, (r.inkRight(in: band) ?? nameStart) - nameStart)
        }
        var shedForTheName = 0
        var report: [String] = []
        for scale in FontSize.allCases.map(\.scale) {
            let whole = try measure(long, column: 1_600, scale: scale)
            try #require(whole.worded, "at 1,600pt, \(scale), the long name still has no words beside it — the sweep would be about nothing")
            for column in Self.capsuleColumns {
                let m = try measure(long, column: column, scale: scale)
                if m.worded {
                    #expect(m.ink >= whole.ink - 1,
                            "at \(column)pt, \(scale), the words are drawn over a cut name: \(m.ink)pt of its \(whole.ink)pt")
                }
                // At 700pt the capsule alone would fit its words at every size, but the whole name
                // doesn't fit beside them at any, so the name decides and icons are drawn.
                if column == 700 {
                    #expect(!m.worded, "at 700pt, \(scale), the words are drawn beside a name that does not fit")
                    if !m.worded { shedForTheName += 1 }
                }
                report.append("\(Int(column))@\(scale):\(m.worded ? "W" : "g")\(Int(m.ink.rounded()))")
            }
            let control = try measure(short, column: 560, scale: scale)
            #expect(control.worded, "at 560pt, \(scale), a four-character name loses the words — they are shed for nothing")
        }
        #expect(shedForTheName == 4, "the words were shed for the name at 700pt at \(shedForTheName) of the four sizes")
        print("[words] \(report.joined(separator: " "))")
    }

    /// The buttons' words come all four together, only when the whole name fits beside them, and
    /// go before the capsule's (`EditorWorkspaceView.nameRowRungs`). The columns run past where the
    /// words return at Largest; the test prints each size's.
    @Test(.machinePinned(.pixelSampling))
    func theButtonsKeepTheirWordsOnlyWhenTheWholeNameFitsAndShedThemFirst() throws {
        let long = try document(named: "Quarterly household budget reconciliation notes for 2026.md")
        let short = try document(named: "a.md")
        let padding = 2 * EditorDocumentHeader<EmptyView>.horizontalPadding
        let nameStart = EditorWorkspaceView.dotColumnWidth + 6
        let glyph = Self.bareChip
        struct Reading { let capsuleWorded: Bool; let chipsWorded: Bool; let ink: CGFloat }
        func measure(_ doc: EditorDocument, column: CGFloat, scale: CGFloat) throws -> Reading {
            let width = column - padding
            let r = try #require(Rendered(workspace(doc).headerContent,
                                          size: CGSize(width: width, height: 60), fontScale: scale))
            let row = r.nameRowRings
            try #require(row.count == 7, "at \(column)pt, \(scale), the row draws \(row.count) buttons")
            // New Text File, Find, the capsule's three segments, Files, Close.
            let chips = [row[0], row[1], row[5], row[6]].map { $0.width > 1.5 * glyph }
            #expect(Set(chips).count == 1, "at \(column)pt, \(scale), the buttons are a mix of worded and bare: \(chips)")
            let band = CGRect(x: nameStart, y: row[0].minY, width: row[0].minX - nameStart, height: row[0].height)
            return Reading(capsuleWorded: row[2..<5].contains { $0.width > 2 * glyph },
                           chipsWorded: chips.allSatisfy { $0 },
                           ink: (r.inkRight(in: band) ?? nameStart) - nameStart)
        }
        var report: [String] = []
        var firstWorded: [String] = []
        for scale in FontSize.allCases.map(\.scale) {
            let whole = try measure(long, column: 2_000, scale: scale)
            try #require(whole.chipsWorded && whole.capsuleWorded,
                         "at 2,000pt, \(scale), the long name has no words beside it — the sweep would be about nothing")
            var first: CGFloat?
            var capsuleWordedAlone = false
            for column in Self.chipColumns {
                let m = try measure(long, column: column, scale: scale)
                if m.chipsWorded {
                    #expect(m.capsuleWorded, "at \(column)pt, \(scale), the buttons keep their words after the capsule lost its own")
                    #expect(m.ink >= whole.ink - 1,
                            "at \(column)pt, \(scale), the buttons' words are drawn over a cut name: \(m.ink)pt of its \(whole.ink)pt")
                    if first == nil { first = column }
                } else if m.capsuleWorded {
                    capsuleWordedAlone = true
                }
                report.append("\(Int(column))@\(scale):\(m.capsuleWorded ? "W" : "g")\(m.chipsWorded ? "B" : "b")\(Int(m.ink.rounded()))")
            }
            firstWorded.append("\(scale): \(first.map { "\(Int($0))" } ?? "none")")
            #expect(first != nil, "at \(scale) the buttons' words never come back over the long name by \(Self.chipColumns.last ?? 0)pt")
            #expect(capsuleWordedAlone,
                    "at \(scale) no column keeps the capsule's words without the buttons' — theirs are not shed first")
            let control = try measure(short, column: 760, scale: scale)
            #expect(control.chipsWorded && control.capsuleWorded,
                    "at 760pt, \(scale), a four-character name loses a word — they are shed for nothing")
        }
        print("[button-words] first worded column: \(firstWorded.joined(separator: " · "))")
        print("[button-words] \(report.joined(separator: " "))")
    }

    /// See ``theButtonsKeepTheirWordsOnlyWhenTheWholeNameFitsAndShedThemFirst``.
    static let chipColumns: [CGFloat] = [700, 800, 900, 1_000, 1_100, 1_150, 1_200, 1_250, 1_300, 1_400, 1_500]

    /// A plain-text file's two readings, the word then none, never a capsule (a `.txt` has nothing
    /// to preview), from the rule and the drawn row: a long name drops the word at a column a short
    /// one keeps it at. One reading only, or the bare one first, fails a line.
    @Test(.machinePinned(.pixelSampling))
    func plainTextHasTheWordedAndTheBareExpand() throws {
        let padding = 2 * EditorDocumentHeader<EmptyView>.horizontalPadding
        func expandWidth(_ name: String, column: CGFloat) throws -> CGFloat {
            let doc = try document(named: name)
            let r = try #require(Rendered(workspace(doc).headerContent, size: CGSize(width: column - padding, height: 60)))
            let row = r.nameRowRings
            try #require(row.count == 4, "\(name) at \(column)pt draws \(row.count) buttons — ＋, Find, Expand and × expected")
            let ratios = row.map { $0.width / Self.bareChip }
            #expect(ratios.allSatisfy { $0 > 1.5 } || ratios.allSatisfy { $0 < 1.5 },
                    "\(name) at \(column)pt: \(ratios) — some buttons worded and some bare")
            return ratios[2]
        }
        let long = "Quarterly household budget reconciliation notes for 2026.txt"
        #expect(try expandWidth("a.txt", column: 500) > 1.5, "a short .txt name loses Expand's word at 500pt")
        #expect(try expandWidth(long, column: 500) < 1.5, "a long .txt name keeps Expand's word over a cut name at 500pt")
        #expect(try expandWidth(long, column: 1_600) > 1.5, "a long .txt name never gets Expand's word")
    }

    /// The empty page keeps "No document open" whole at the narrowest column, at every text size:
    /// the lit Files drops its word before the title is cut. Measured as the title's ink against the
    /// same title with room.
    @Test(.machinePinned(.pixelSampling))
    func theEmptyPageKeepsItsTitleWholeAtTheNarrowestColumn() throws {
        let empty = EditorDocument()
        let padding = 2 * EditorDocumentHeader<EmptyView>.horizontalPadding
        let nameStart = EditorWorkspaceView.dotColumnWidth + 6
        func measure(width: CGFloat, scale: CGFloat, glass: Bool) throws -> (ink: CGFloat, worded: Bool) {
            let ws = workspace(empty, railIsHidden: true)
            let view = glass
                ? AnyView(ws.emptyHeaderContent.environment(\.selectionLensAppearance, SelectionLensCallSiteTests.probe))
                : AnyView(ws.emptyHeaderContent)
            let r = try #require(Rendered(view, size: CGSize(width: width, height: 60), fontScale: scale))
            let row = r.nameRowRings
            try #require(row.count == 2, "the lit empty page draws \(row.count) buttons — ＋ and Files expected")
            let band = CGRect(x: nameStart, y: row[0].minY - 4, width: row[0].minX - nameStart, height: row[0].height + 8)
            let glyph = Self.bareChip
            let worded = row[0].width > 1.5 * glyph, filesWorded = row[1].width > 1.5 * glyph
            #expect(worded == filesWorded, "\(width)pt, \(scale): New Text File and Files disagree about words — a mix")
            return ((r.inkRight(in: band) ?? nameStart) - nameStart, worded && filesWorded)
        }
        for glass in [false, true] {
            for scale in FontSize.allCases.map(\.scale) {
                let whole = try measure(width: 1_000, scale: scale, glass: glass)
                #expect(whole.worded, "\(glass ? "glass, " : "")\(scale): Files has no word even with room to spare")
                let narrow = try measure(width: EditorLayoutMetrics.minDocumentWidth - padding, scale: scale, glass: glass)
                #expect(narrow.ink >= whole.ink - 1,
                        "\(glass ? "glass, " : "")\(scale): at the narrowest column the title keeps \(narrow.ink)pt of its \(whole.ink)pt")
            }
        }
    }

    /// For ``theCapsuleKeepsItsWordsOnlyWhenTheWholeNameFits``: the first worded column at each
    /// text size (720 · 760 · 840 · 880) and the column below each, where a rule one step early
    /// shows, plus 560 (where the worded capsule first fits) and 700.
    static let capsuleColumns: [CGFloat] = [560, 700, 720, 740, 760, 820, 840, 860, 880]

    // MARK: Glass between the capsules

    /// In Frosted and Clear every glass capsule on the name row keeps 4pt from the next
    /// (`ChromeGlass.smallGlyphOutset`); Solid keeps the row's 6pt. Read under the probe appearance,
    /// which paints each capsule flat cyan, across every Expand state and both file kinds.
    @Test(.machinePinned(.pixelSampling))
    func everyGlassCapsuleOnTheNameRowKeepsFourPointsFromTheNext() throws {
        let md = try document(named: "note.md")
        let txt = try document(named: "note.txt")
        let long = try document(named: "Quarterly household budget reconciliation notes for 2026.md")
        var report: [String] = []
        var pairs = 0
        for (doc, width) in [(md, CGFloat(700)), (txt, 700), (long, 500), (EditorDocument(), 500)] {
            for railIsHidden in [false, true] {
                let ws = workspace(doc, railIsHidden: railIsHidden)
                // The empty page draws its own header; `headerContent` is a document's.
                let view = doc.path == nil ? AnyView(ws.emptyHeaderContent) : AnyView(ws.headerContent)
                let size = CGSize(width: width, height: 60)
                let rig = SelectionLensCallSiteTests.rig(view, size: size)
                let runs = Pixel.columnRuns(rig.capture(), width: width, Pixel.chromeProbe)
                // A capsule each: New Text File, Find, the mode capsule (Markdown only), Files and
                // Close, or the empty page's New Text File and, lit, Files.
                let expected = doc.path == nil ? (railIsHidden ? 2 : 1) : (doc.isMarkdown ? 5 : 4)
                try #require(runs.count == expected,
                             "\(doc.name.isEmpty ? "empty page" : doc.name), lit \(railIsHidden): \(runs.count) glass capsules, \(expected) expected — \(runs.map { Int($0.minX) })")
                let gaps = zip(runs, runs.dropFirst()).map { $1.minX - $0.maxX }
                report.append("\(doc.name.isEmpty ? "empty" : doc.name)/\(railIsHidden): \(gaps.map { String(format: "%.1f", $0) })")
                for gap in gaps {
                    #expect(gap >= ChromeGlass.minimumCapsuleGap - 0.5,
                            "\(doc.name.isEmpty ? "empty page" : doc.name), lit \(railIsHidden): two glass capsules \(gap)pt apart — \(gaps)")
                }
                // The room is taken only where glass is drawn: between the two buttons' own frames
                // the row's 6pt under Solid, and 6 + the outset under glass.
                let solid = try #require(Rendered(view, size: size)).nameRowRings
                let glassRings = FocusRings.frames(in: rig.host).sorted { $0.minX < $1.minX }
                    .filter { abs($0.midY - (solid.first?.midY ?? 0)) < 5 }
                if doc.path != nil || railIsHidden, solid.count >= 2, glassRings.count >= 2 {
                    let i = doc.path == nil ? 0 : solid.count - 2   // the pair that needs the room
                    let solidGap = solid[i + 1].minX - solid[i].maxX
                    let glassGap = glassRings[i + 1].minX - glassRings[i].maxX
                    pairs += 1
                    #expect(abs(solidGap - 6) < 0.5, "under Solid the pair sits \(solidGap)pt apart — Solid moved")
                    #expect(abs(glassGap - (6 + ChromeGlass.clearance(rowSpacing: 6))) < 0.5,
                            "under glass the pair sits \(glassGap)pt apart")
                }
            }
        }
        #expect(pairs == 7, "the Solid-versus-glass pair was measured \(pairs) times, not 7 — the check is not running")
        print("[glass-gaps] \(report.joined(separator: " · "))")
    }

    // MARK: The empty page's caption

    /// The empty page says how to open a file, in one sentence ending on ⌘O, and doesn't say ⌘N,
    /// which the header's ＋ carries. Both chords come from `AppChord`, as the caption's do. ⌘N in a
    /// variant, no ⌘O in one, two sentences, or "in any tab" each fails a line.
    @Test func theEmptyCaptionSaysHowToOpenAFileInOneSentence() throws {
        let open = AppChord.openInEditor.display
        let new = AppChord.newTextFile.display
        let variants = [(false, false), (false, true), (true, false), (true, true)].map {
            ($0, $1, EditorWorkspaceView.emptyCaption(hasFolder: $0, showsRail: $1))
        }
        for (hasFolder, showsRail, caption) in variants {
            #expect(caption.contains("press \(open) on a text file or PDF in Browse, Compare or Organize"),
                    "folder \(hasFolder), rail \(showsRail): “\(caption)” does not offer ⌘O")
            #expect(!caption.contains(new),
                    "folder \(hasFolder), rail \(showsRail): “\(caption)” repeats the header's ＋")
            // "Tab" names two things in this app (a pane's tabs and the workspace switcher), so the
            // caption names the workspaces instead.
            #expect(!caption.localizedCaseInsensitiveContains("tab"),
                    "folder \(hasFolder), rail \(showsRail): “\(caption)” says “tab”, which could mean a pane's tab")
            // One sentence: one full stop, at the end.
            #expect(caption.hasSuffix(".") && caption.dropLast().allSatisfy { $0 != "." },
                    "folder \(hasFolder), rail \(showsRail): “\(caption)” is not one sentence")
        }
        // "The list", never "the rail", which is only the code's word for it.
        #expect(EditorWorkspaceView.emptyCaption(hasFolder: true, showsRail: true).contains("from the list —"))
        #expect(!EditorWorkspaceView.emptyCaption(hasFolder: true, showsRail: false).contains("list"),
                "with no list on screen the caption sends the reader to one")
        for hasFolder in [true, false] { for showsRail in [true, false] {
            #expect(!EditorWorkspaceView.emptyCaption(hasFolder: hasFolder, showsRail: showsRail).contains("rail"))
        } }
        #expect(EditorWorkspaceView.emptyCaption(hasFolder: false, showsRail: true).hasPrefix("Pick a folder"))
        // The page draws this caption: a scan of the one call site, comments stripped.
        let code = try Self.headerSource()
        #expect(code.contains("caption(Self.emptyCaption(hasFolder: !folder.isEmpty, showsRail: showsRail),"),
                "the empty page does not draw `emptyCaption`")
    }

    // MARK: Source helpers

    static func headerSource() throws -> String {
        let text = try SourceText.fileExplorer("EditorWorkspaceView.swift")
        try #require(text.contains("var headerContent: some View"), "not reading EditorWorkspaceView.swift")
        return SourceComments.stripped(text)
    }

    /// One button: from the `Button` that draws `glyph` to the next `Button` or the header's end,
    /// so its action, label and modifier chain and nobody else's.
    static func chain(from glyph: String, in code: String) throws -> String {
        let header = try #require(code.range(of: "var headerContent: some View"))
        let rest = code[header.upperBound...]
        let end = rest.range(of: "private var metaRow")?.lowerBound ?? rest.endIndex
        let body = rest[..<end]
        let mark = try #require(body.range(of: glyph), "\(glyph) is not drawn in the header")
        let start = body.range(of: "Button", options: .backwards, range: body.startIndex..<mark.lowerBound)?.lowerBound
            ?? mark.lowerBound
        let tail = body[mark.upperBound...]
        // The next `Button`, not the next "Button" substring: `.chromeGlassGlyphButton(` sits in
        // the ×'s own chain, and would end it before its label.
        let stop = tail.range(of: #"(?<![A-Za-z_.])Button\b"#, options: .regularExpression)?.lowerBound
            ?? tail.range(of: "EditorModeBar")?.lowerBound ?? tail.endIndex
        return String(body[start..<stop])
    }
}

/// A header laid out and drawn in a real window: its rings and pixels, in points, top-left origin.
/// The pixels are read once from the bitmap's bytes; per-pixel `colorAt` is too slow under load.
/// Each distinct colour still goes once through `colorAt` + `usingColorSpace(.sRGB)`, which is not
/// a no-op: `colorAt` reports this sRGB bitmap as calibrated RGB, and converting moves a component
/// by up to 22/255, enough to shift the ink and accent thresholds below.
@MainActor
struct Rendered {
    /// Each distinct colour in the image, in sRGB as `colorAt` and its conversion give it.
    private struct Colour {
        let r, g, b: CGFloat
        let brightness: CGFloat
    }
    private let palette: [Colour]
    /// Per pixel, its colour's index in `palette`; row 0 at the top, as `colorAt` counts rows.
    private let indices: [Int32]
    let pixelsWide: Int
    let pixelsHigh: Int
    let rings: [CGRect]
    let size: CGSize
    private let scale: CGFloat

    static let defaultSize = CGSize(width: 520, height: 48)

    init?<V: View>(_ view: V, size: CGSize = Rendered.defaultSize, fontScale: CGFloat = 1) {
        let subject = view
            .environment(\.appFontScale, fontScale)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        // Measured in the host's own orientation; normalised to top-left if it is not flipped.
        self.rings = FocusRings.frames(in: host).map { ring in
            var frame = ring
            if !host.isFlipped { frame.origin.y = size.height - frame.maxY }
            return frame
        }
        // Bytes, 8 bits a sample, interleaved — what `cacheDisplay` gives. Anything else is refused
        // rather than misread.
        guard let data = rep.bitmapData, rep.bitsPerSample == 8, !rep.isPlanar,
              rep.samplesPerPixel >= 3, !rep.bitmapFormat.contains(.floatingPointSamples)
        else { return nil }
        let (w, h) = (rep.pixelsWide, rep.pixelsHigh)
        let stride = rep.bitsPerPixel / 8
        let first = rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        var palette: [Colour] = []
        var seen: [UInt32: Int32] = [:]
        var indices = [Int32](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let o = y * rep.bytesPerRow + x * stride
                var key = UInt32(data[o + first]) << 16 | UInt32(data[o + first + 1]) << 8 | UInt32(data[o + first + 2])
                if rep.samplesPerPixel > 3 { key |= UInt32(data[first == 1 ? o : o + 3]) << 24 }
                if let index = seen[key] { indices[y * w + x] = index; continue }
                // The first pixel of this colour goes through `colorAt`, as the thresholds expect.
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
                let index = Int32(palette.count)
                palette.append(Colour(r: c.redComponent, g: c.greenComponent, b: c.blueComponent,
                                      brightness: c.brightnessComponent))
                seen[key] = index
                indices[y * w + x] = index
            }
        }
        self.palette = palette
        self.indices = indices
        self.pixelsWide = w
        self.pixelsHigh = h
        self.size = size
        self.scale = CGFloat(w) / size.width
    }

    /// The name row's buttons, left to right: the rings sharing the topmost row's centre line. The
    /// meta row's autosave switch sits a row lower and is left out.
    var nameRowRings: [CGRect] {
        guard let top = rings.map(\.midY).min() else { return [] }
        return rings.filter { abs($0.midY - top) < 5 }.sorted { $0.minX < $1.minX }
    }

    /// The pixel at (`x`, `y`), top-left origin — `nil` outside the image, as `colorAt` answers.
    private func colour(_ x: Int, _ y: Int) -> Colour? {
        guard x >= 0, y >= 0, x < pixelsWide, y < pixelsHigh else { return nil }
        return palette[Int(indices[y * pixelsWide + x])]
    }

    /// The smallest rectangle, in points, holding every pixel that differs from `other` — `nil`
    /// when none do.
    func differingBox(from other: Rendered) -> CGRect? {
        guard pixelsWide == other.pixelsWide, pixelsHigh == other.pixelsHigh
        else { return CGRect(origin: .zero, size: size) }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for x in 0..<pixelsWide {
            for y in 0..<pixelsHigh where Self.differs(colour(x, y), other.colour(x, y)) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// Whether `ring` here and `theirs` in `other` hold the same pixels — the same glyph drawn in
    /// the same way, wherever it sits. Compared at the pixel grid, from each ring's own origin, so
    /// two rings that differ by a whole number of points compare exactly.
    func samePixels(_ ring: CGRect, as other: Rendered, _ theirs: CGRect) -> Bool {
        let w = Int((min(ring.width, theirs.width) * scale).rounded(.down))
        let h = Int((min(ring.height, theirs.height) * scale).rounded(.down))
        let ax = Int((ring.minX * scale).rounded()), ay = Int((ring.minY * scale).rounded())
        let bx = Int((theirs.minX * scale).rounded()), by = Int((theirs.minY * scale).rounded())
        guard w > 0, h > 0 else { return false }
        var inked = 0
        for dx in 0..<w {
            for dy in 0..<h {
                let p = colour(ax + dx, ay + dy)
                if Self.differs(p, other.colour(bx + dx, by + dy)) { return false }
                if let p, p.brightness < 0.6 { inked += 1 }
            }
        }
        // Two blank patches are "the same" about nothing.
        return inked > 0
    }

    /// The rightmost x, in points, of any ink darker than the background inside `band` — how far
    /// something drawn in that band actually reaches.
    func inkRight(in band: CGRect) -> CGFloat? {
        let x0 = max(0, Int(band.minX * scale)), x1 = min(pixelsWide, Int(band.maxX * scale))
        let y0 = max(0, Int(band.minY * scale)), y1 = min(pixelsHigh, Int(band.maxY * scale))
        guard x0 < x1, y0 < y1 else { return nil }
        for x in Swift.stride(from: x1 - 1, through: x0, by: -1) {
            for y in y0..<y1 {
                guard let c = colour(x, y) else { continue }
                if c.brightness < 0.6 { return CGFloat(x + 1) / scale }
            }
        }
        return nil
    }

    /// The pixels in `rect` whose sRGB components (0…1) `match` accepts.
    func pixels(in rect: CGRect, matching match: (CGFloat, CGFloat, CGFloat) -> Bool) -> Int {
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(pixelsWide, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale)), y1 = min(pixelsHigh, Int(rect.maxY * scale))
        var count = 0
        for x in x0..<max(x0, x1) {
            for y in y0..<max(y0, y1) {
                guard let c = colour(x, y) else { continue }
                if match(c.r, c.g, c.b) { count += 1 }
            }
        }
        return count
    }

    /// Pixels per square point — what turns a pixel count into an area the display cannot move.
    var pixelsPerPoint: CGFloat { scale * scale }

    /// How many pixels inside `ring` are the accent: blue well clear of red, which a neutral glyph
    /// or the white ground never is.
    func accentPixels(in ring: CGRect) -> Int {
        pixels(in: ring) { r, _, b in b - r > 0.1 }
    }

    private static func differs(_ a: Colour?, _ b: Colour?) -> Bool {
        guard let p = a, let q = b else { return false }
        return max(abs(p.r - q.r), max(abs(p.g - q.g), abs(p.b - q.b))) > 0.02
    }
}
