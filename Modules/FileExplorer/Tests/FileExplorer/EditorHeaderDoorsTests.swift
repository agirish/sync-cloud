import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// The document header's ＋ (TE45) and × (TE46): where they are drawn, what they call, what they
/// say, and what they cost the file name.
///
/// **Drawn, not read.** A hosted SwiftUI tree exposes neither labels nor tooltips under
/// `swift test`, and a synthetic click does not reach a SwiftUI `Button` in this harness (see
/// `PaneBackgroundDeselectMountedTests`). What it does expose is one `_FocusRingView` per button,
/// in the host's coordinates once converted — so the row's buttons can be counted and ordered —
/// and pixels, which tell identical-looking 18pt glyphs apart by what each one alone does.
///
/// What the ＋ DOES is the host's ⌘N closure, and what the × does is the host's close; both are
/// wired in the app target and scanned there (`EditorHeaderDoorsWiringTests`), and the close itself
/// is run there against a real document (`EditorDocumentCloseTests`).
@MainActor
@Suite(.serialized) struct EditorHeaderDoorsTests {

    private func document(named name: String) throws -> EditorDocument {
        let folder = NSTemporaryDirectory() + "doors-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent(name)
        try "hello".write(toFile: path, atomically: true, encoding: .utf8)
        let document = EditorDocument()
        _ = EditorFileStore.load(path: path, into: document)
        return document
    }

    private func workspace(_ document: EditorDocument, mode: EditorMode = .edit,
                           railIsHidden: Bool = false,
                           newTextFile: (() -> Void)? = {}) -> EditorWorkspaceView {
        EditorWorkspaceView(
            document: document,
            autosavePolicy: EditorAutosavePolicy(),
            folder: "/n/Downloads",
            entries: [],
            showsRail: false,
            railIsHidden: railIsHidden,
            accent: .blue,
            onAccent: .white,
            mode: .constant(mode),
            splitFraction: .constant(0.5),
            isNaming: .constant(false),
            typedName: .constant(""),
            railFilter: .constant(""),
            railFilterIsExpanded: .constant(false),
            railTab: .constant(.files),
            railOutlineAnchors: .constant([:]),
            undoManager: UndoManager(),
            prefilledName: { "Untitled.md" },
            refusal: { _ in nil },
            onOpen: { _ in },
            onCreate: { _ in true },
            onRevealInBrowse: { _ in },
            location: nil,
            onLocationDoor: { _ in },
            onToggleJustTheText: {},
            onNewTextFile: newTextFile,
            onCloseDocument: {})
    }

    // MARK: What it says

    /// The tooltip names the folder, the way the rail's ＋ names it on the line beside it. Mutation:
    /// swap the arms and both lines fail.
    @Test func theTooltipNamesTheFolderItWillCreateIn() {
        #expect(EditorWorkspaceView.newTextFileTitle(folderName: "Downloads") == "New text file in Downloads")
        #expect(EditorWorkspaceView.newTextFileTitle(folderName: "") == "Pick a folder in the sidebar first")
    }

    /// **Greyed where it shows.** `.disabled` alone leaves a `.glyph` hover-affordance button
    /// pixel-identical at rest (see above), so the ＋ with no folder takes the tertiary style: the
    /// first button's pixels differ between a header with the ⌘N closure and one without, on an open
    /// document and on the empty page. Mutation: drop the ＋'s `.foregroundStyle` and both fail.
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

    /// **With no document open the header keeps the ＋ — and, while it is lit, "Just the text" — and
    /// nothing else.** Read off the drawn card: one button unlit, two lit; the first draws the same
    /// pixels as an open file's ＋, and the second the same as an open file's LIT "Just the text"
    /// (the third button there: ＋ · Find · Just the text). So Find, the capsule and the × are gone
    /// and the two that stay are the real ones.
    ///
    /// Mutations: withhold the ＋ on the empty page (no buttons unlit), draw "Just the text" unlit
    /// too (two buttons unlit), or draw it after a stray Find (three lit) — each fails.
    @Test func theEmptyPageKeepsThePlusAndOnlyALitJustTheText() throws {
        let doc = try document(named: "note.md")
        let empty = EditorDocument()
        let unlit = try #require(Rendered(workspace(empty, newTextFile: {}).headerCard))
        let lit = try #require(Rendered(workspace(empty, railIsHidden: true, newTextFile: {}).headerCard))
        let open = try #require(Rendered(workspace(doc, railIsHidden: true, newTextFile: {}).headerCard))
        #expect(unlit.nameRowRings.count == 1, "the empty page draws \(unlit.nameRowRings.count) buttons with the rail showing — the ＋ alone expected")
        try #require(lit.nameRowRings.count == 2, "the empty page draws \(lit.nameRowRings.count) buttons under Just the text — the ＋ and the lit glyph expected")
        let openRow = open.nameRowRings
        try #require(openRow.count >= 3, "the open header draws \(openRow.count) buttons — the comparison would be about nothing")
        #expect(lit.samePixels(lit.nameRowRings[0], as: open, openRow[0]),
                "the empty page's first button is not the ＋ an open file's header draws")
        // The lit glyph is told by its accent: pixel-for-pixel it drew a shade apart from the open
        // header's (anti-aliasing of its fill, measured), so the accent pixels are counted instead —
        // the ＋ has none, the lit glyph's wash and ink have the open header's count.
        let accentHere = lit.accentPixels(in: lit.nameRowRings[1])
        let accentThere = open.accentPixels(in: openRow[2])
        #expect(lit.accentPixels(in: lit.nameRowRings[0]) == 0, "the empty page's first button wears the accent — it is not the ＋")
        #expect(accentThere > 0 && abs(accentHere - accentThere) <= accentThere / 10,
                "the empty page's second button has \(accentHere) accent pixels against the lit Just the text's \(accentThere) — it is not that glyph, lit")
    }

    // MARK: Where it is drawn

    /// **The ＋ leads the header's buttons: `＋ · Find · Just the text`, then the capsule.**
    ///
    /// The three are 18pt glyphs with identical rings, so each is told apart by something only it
    /// does. "Just the text" LIGHTS when the rail bit is set — the one ring whose pixels change is
    /// that glyph. Find is WITHHELD in Preview — the buttons left of it slide right by one slot, so
    /// a glyph that survives draws the same pixels one slot over. The ＋ is then the survivor that
    /// is not "Just the text".
    ///
    /// **`.disabled` does not grey a `.glyph` hover-affordance button at rest** — measured
    /// 2026-09-25, the header with and without the ⌘N closure renders pixel-identical — so the ＋'s
    /// greying is not a usable handle, and its `.disabled` is pinned by the scan below instead.
    @Test func thePlusLeadsTheHeadersButtonsBeforeFindAndJustTheText() throws {
        let doc = try document(named: "note.md")
        #expect(doc.isMarkdown, "the fixture is not Markdown — Preview would resolve back to Source")
        let edit = try #require(Rendered(workspace(doc, newTextFile: {}).headerContent))
        let again = try #require(Rendered(workspace(doc, newTextFile: {}).headerContent))
        let lit = try #require(Rendered(workspace(doc, railIsHidden: true, newTextFile: {}).headerContent))
        let preview = try #require(Rendered(workspace(doc, mode: .preview, newTextFile: {}).headerContent))

        #expect(edit.differingBox(from: again) == nil, "two renders of the same header differ — the detector is noise")
        let row = edit.nameRowRings
        // ＋, Find, Just the text, and the capsule's segments: six at the least.
        try #require(row.count >= 6, "the name row draws \(row.count) buttons — this check would be about nothing")

        // Just the text is the third: the only pixels the rail bit moves are in that ring.
        let lightBox = try #require(lit.differingBox(from: edit), "the rail bit changed nothing — cannot find Just the text")
        #expect(row[2].insetBy(dx: -2, dy: -2).contains(lightBox),
                "Just the text lights at \(lightBox), not in the third button \(row[2]) — the order is not ＋ · Find · Just the text")

        // Find is the second: Preview withholds exactly one button, and the first and third draw
        // the same glyphs there one slot along — so the one that went is the one between them.
        let pRow = preview.nameRowRings
        try #require(pRow.count == row.count - 1,
                     "Preview draws \(pRow.count) buttons against Source's \(row.count) — Find alone should go")
        #expect(edit.samePixels(row[0], as: preview, pRow[0]),
                "the first button in Source is not the first in Preview — Find is first, or the ＋ is withheld in Preview")
        #expect(edit.samePixels(row[2], as: preview, pRow[1]),
                "Just the text does not follow the withheld button in Preview — Find is not second")
        #expect(!edit.samePixels(row[1], as: preview, pRow[1]),
                "the second button in Source survives in Preview — it is not Find")
    }

    /// **Greyed with no folder, and wired to the ⌘N closure** — a source scan sliced to the ＋'s own
    /// modifier chain, because neither is observable on the hosted button (see above). Comments are
    /// stripped, so prose describing the wiring cannot satisfy it. Mutations: an empty action, or
    /// `.disabled(false)`, each fail one line.
    @Test func thePlusCallsTheNewFileClosureAndGreysWithoutOne() throws {
        let chain = try Self.chain(from: "Image(systemName: \"plus\")", in: Self.headerSource())
        #expect(chain.contains("onNewTextFile?()"), "the header's ＋ does not call the ⌘N closure")
        #expect(chain.contains(".foregroundStyle(onNewTextFile == nil"), "the header's ＋ no longer LOOKS greyed without a folder")
        #expect(chain.contains(".disabled(onNewTextFile == nil)"), "the header's ＋ no longer greys without a folder")
        #expect(chain.contains("AppChord.newTextFile.display"), "the header's ＋ no longer shows ⌘N")
    }

    // MARK: The ×

    /// VoiceOver hears which file the × closes; the tooltip says what it does. Mutation: drop the
    /// name and the first line fails.
    @Test func theCloseButtonNamesTheFileItCloses() {
        #expect(EditorWorkspaceView.closeTitle(name: "note.md") == "Close note.md")
        #expect(EditorWorkspaceView.closeTitle(name: "") == "Close this document")
    }

    /// **The × is the last button in the row — after the capsule — and stays in Preview.**
    ///
    /// Told apart from the capsule by width (a segment is wider than an 18pt glyph, measured on the
    /// row itself rather than hard-coded) and from the other glyphs by position: every ring that is
    /// not glyph-sized sits to its left. In Preview it draws the same pixels, so it was not withheld.
    @Test func theCloseButtonIsLastAfterTheCapsuleAndStaysInPreview() throws {
        let doc = try document(named: "note.md")
        let edit = try #require(Rendered(workspace(doc).headerContent))
        let preview = try #require(Rendered(workspace(doc, mode: .preview).headerContent))
        let row = edit.nameRowRings
        try #require(row.count >= 7, "the name row draws \(row.count) buttons — ＋, Find, Just the text, three segments and × expected")
        let glyph = row[0].width
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

    /// **Closed, the document column is the empty page — and its header stays, with the ＋ alone.**
    /// `EditorDocument.close()` is what the host's close ends in; this is what it leaves on screen:
    /// one button, drawing the pixels the open header's ＋ drew, and no Find, capsule or ×.
    @Test func aClosedDocumentLeavesTheEmptyPageWithThePlusAlone() throws {
        let doc = try document(named: "note.md")
        let size = CGSize(width: 600, height: 300)
        let open = try #require(Rendered(workspace(doc), size: size))
        let openRow = open.nameRowRings
        try #require(openRow.count >= 7, "the open document drew \(openRow.count) header buttons — the control is about nothing")
        doc.close()
        let closed = try #require(Rendered(workspace(doc), size: size))
        #expect(closed.rings.count == 1, "\(closed.rings.count) buttons are drawn over a closed document — the ＋ alone expected")
        if let plus = closed.rings.first {
            #expect(closed.samePixels(plus, as: open, openRow[0]), "the one button left after a close is not the ＋")
        }
        #expect(doc.path == nil && doc.text.isEmpty && doc.refusal == nil, "close() left a document behind")
    }

    /// The × acts through the host's closure and nothing else, and is not inside Find's Preview
    /// guard. A scan of the ×'s own chain, comments stripped. Mutations: `Button {}` or wrapping it
    /// in `if resolvedMode != .preview` each fail.
    @Test func theCloseButtonCallsTheHostsClose() throws {
        let code = try Self.headerSource()
        let chain = try Self.chain(from: "Image(systemName: \"xmark\")", in: code)
        #expect(chain.contains("Button(action: onCloseDocument)"), "the header's × does not call the host's close")
        #expect(chain.contains("Self.closeTitle(name: document.name)"), "the × no longer names the file")
        let header = try #require(code.range(of: "var headerContent: some View"))
        let capsule = try #require(code.range(of: "EditorModeBar(", range: header.upperBound..<code.endIndex))
        let xmark = try #require(code.range(of: "\"xmark\"", range: header.upperBound..<code.endIndex))
        #expect(capsule.lowerBound < xmark.lowerBound, "the × is declared before the capsule")
    }

    // MARK: What the two glyphs cost the file name

    /// **The name row still fits with a long name, at every text size** — the check the 09-16
    /// review found missing when an 8-character fixture hid a squeeze.
    ///
    /// The ＋ and × cost the name 48pt: two 18pt buttons and two 6pt gaps. Measured 2026-09-25 on a
    /// 55-character `.md` name, name ink at the NARROWEST document column (`minDocumentWidth`, less
    /// the header's padding — 232pt), at text sizes 0.9 · 1.0 · 1.25 · 1.35: **67 · 69 · 60 · 44pt
    /// before them, 10 · 11 · 12 · 10pt after** — the ellipsis and little else. At the ~391pt column
    /// the 760pt window floor gives (`splitFraction`'s measurement) it keeps 153 · 149 · 135 · 134.
    ///
    /// **The capsule is icons-only at BOTH widths, and was before the name-first rule too** —
    /// measured by the ring widths, at every size. So shedding its words, which is all the header
    /// may shed, buys nothing at 260 or 390: the 10–12pt there is what the row's fixed chrome — the
    /// dot's column, four 18pt glyphs, the 82–99pt icon capsule and the gaps — leaves of 232pt.
    /// Where the words DID cost the name is wider, and ``theCapsuleKeepsItsWordsOnlyWhenTheWholeNameFits``
    /// holds that.
    ///
    /// What is held here is what stays true at both widths — nothing is drawn past the edge (the ×
    /// included), and the row never wraps (a long name leaves the header the height a short one
    /// has) — plus a floor on the name at each. See the two constants for the floors and why.
    /// Mutation: force the worded capsule in the name row and 260pt fails at every size — the
    /// capsule alone is 198–251pt there, and the name is pushed out.
    @Test func theNameRowFitsWithALongNameAtEveryTextSize() throws {
        let long = try document(named: "Quarterly household budget reconciliation notes for 2026.md")
        let short = try document(named: "a.md")
        let padding = 2 * EditorDocumentHeader<EmptyView>.horizontalPadding
        let cases: [(column: CGFloat, minimumInk: CGFloat)] = [
            (EditorLayoutMetrics.minDocumentWidth, Self.minimumNameInkAtTheNarrowestColumn),
            (Self.floorWindowDocumentColumn, Self.minimumNameInkAtTheFloorWindow),
        ]
        var report: [String] = []
        for (column, minimumInk) in cases {
            let width = column - padding
            for scale in FontSize.allCases.map(\.scale) {
                let size = CGSize(width: width, height: 60)
                let longRow = try #require(Rendered(workspace(long).headerContent, size: size, fontScale: scale))
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
                report.append("\(Int(column))pt@\(scale): \(Int(ink.rounded()))pt")
                #expect(ink >= minimumInk,
                        "at \(column)pt, scale \(scale), the long name keeps \(ink)pt of ink — under \(minimumInk)pt")
            }
        }
        print("[name-fit] \(report.joined(separator: " · "))")
    }

    /// The document column at the 760pt window floor — the width
    /// `EditorLayoutMetrics.splitFraction`'s note measures ("~391pt"). Rounded down.
    static let floorWindowDocumentColumn: CGFloat = 390

    /// **The floor at the narrowest column (260pt), at all four text sizes: the name is DRAWN — at
    /// least 6pt of ink, which is its ellipsis.** Measured 10 · 11 · 12 · 10pt.
    ///
    /// Why no higher: at 260 the capsule is already icons-only, so the words are not there to give
    /// up, and the only other way to buy the name back is to drop or fold a glyph — which the
    /// round-2 decision ruled out ("everything else stays"). So the floor pins what that decision
    /// leaves: a name that is never pushed out entirely (a pushed-out name draws no ink at all, and
    /// that is what the worded capsule does here) and cannot get silently worse than its ellipsis.
    static let minimumNameInkAtTheNarrowestColumn: CGFloat = 6

    /// At the floor-window column the name keeps a real run of characters either side of the
    /// ellipsis. Measured 134–153pt; 60 is roughly ten characters.
    static let minimumNameInkAtTheFloorWindow: CGFloat = 60

    /// **The capsule's words are drawn only when the WHOLE file name fits beside them** — TE28's
    /// rule for the preview's Edit button, applied to the name row (see `nameRow`).
    ///
    /// Swept across the columns where the worded capsule itself would fit (from ~560pt), at every
    /// text size, on a 55-character `.md` name: wherever the words are drawn the name's ink is its
    /// whole width — measured on the same header given room to spare — and at 700pt, where the old
    /// rule drew the words over a truncated name at every size, the icons are drawn instead. The
    /// positive control: a short name keeps the words at the narrowest of those columns, so the
    /// rule is not "never".
    ///
    /// Mutations: let the capsule choose by its own width again (`forcedRung` nil in the worded
    /// row), and the sweep finds words over a cut name; force the icons everywhere, and the short
    /// name loses its words.
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
            // A worded segment is far wider than two glyph buttons; an icon segment is not.
            let worded = row.contains { $0.width > 2 * first.width }
            let band = CGRect(x: nameStart, y: first.minY, width: first.minX - nameStart, height: first.height)
            return (worded, (r.inkRight(in: band) ?? nameStart) - nameStart)
        }
        var shedForTheName = 0
        var report: [String] = []
        for scale in FontSize.allCases.map(\.scale) {
            let whole = try measure(long, column: 1_600, scale: scale)
            try #require(whole.worded, "at 1,600pt, \(scale), the long name still has no words beside it — the sweep would be about nothing")
            for column in stride(from: CGFloat(560), through: 900, by: 20) {
                let m = try measure(long, column: column, scale: scale)
                if m.worded {
                    #expect(m.ink >= whole.ink - 1,
                            "at \(column)pt, \(scale), the words are drawn over a cut name: \(m.ink)pt of its \(whole.ink)pt")
                }
                // 700pt is a column where the capsule's own rule drew the words at every size
                // (measured before this rule: 349 · 338 · 308 · 292pt of name beside them) and
                // the whole name does not fit beside them at any — so the name decides, and the
                // icons are drawn.
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

    // MARK: Source helpers

    static func headerSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/EditorWorkspaceView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        try #require(text.contains("var headerContent: some View"), "not reading EditorWorkspaceView.swift")
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[..<comment.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// One button: from the `Button` that draws `glyph` to the next `Button` or the end of the
    /// header — its action, its label and its modifier chain, and nobody else's.
    static func chain(from glyph: String, in code: String) throws -> String {
        let header = try #require(code.range(of: "var headerContent: some View"))
        let rest = code[header.upperBound...]
        let end = rest.range(of: "private var metaRow")?.lowerBound ?? rest.endIndex
        let body = rest[..<end]
        let mark = try #require(body.range(of: glyph), "\(glyph) is not drawn in the header")
        let start = body.range(of: "Button", options: .backwards, range: body.startIndex..<mark.lowerBound)?.lowerBound
            ?? mark.lowerBound
        let tail = body[mark.upperBound...]
        let stop = tail.range(of: "Button")?.lowerBound ?? tail.range(of: "EditorModeBar")?.lowerBound ?? tail.endIndex
        return String(body[start..<stop])
    }
}

/// A header laid out and drawn in a real window: its buttons' rings, and its pixels.
///
/// Shared with the × tests and the fit test, so every one of them reads the same geometry the
/// same way. Coordinates are points, top-left origin — the hosting view is flipped, and the bitmap
/// is converted by the backing scale, so a ring's frame and a differing pixel are in one space.
@MainActor
struct Rendered {
    let bitmap: NSBitmapImageRep
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
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        var found: [CGRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("FocusRing") {
                var frame = v.convert(v.bounds, to: host)
                // Measured in the host's own orientation; normalise to top-left if it is not flipped.
                if !host.isFlipped { frame.origin.y = size.height - frame.maxY }
                found.append(frame)
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        self.bitmap = rep
        self.rings = found
        self.size = size
        self.scale = CGFloat(rep.pixelsWide) / size.width
    }

    /// The name row's buttons, left to right: the rings sharing the topmost row's centre line. The
    /// meta row's autosave switch sits a row lower and is left out.
    var nameRowRings: [CGRect] {
        guard let top = rings.map(\.midY).min() else { return [] }
        return rings.filter { abs($0.midY - top) < 5 }.sorted { $0.minX < $1.minX }
    }

    /// The smallest rectangle, in points, holding every pixel that differs from `other` — `nil`
    /// when none do.
    func differingBox(from other: Rendered) -> CGRect? {
        guard bitmap.pixelsWide == other.bitmap.pixelsWide,
              bitmap.pixelsHigh == other.bitmap.pixelsHigh else { return CGRect(origin: .zero, size: size) }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh where Self.differs(bitmap.colorAt(x: x, y: y),
                                                             other.bitmap.colorAt(x: x, y: y)) {
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
                let p = bitmap.colorAt(x: ax + dx, y: ay + dy)
                if Self.differs(p, other.bitmap.colorAt(x: bx + dx, y: by + dy)) { return false }
                if let c = p?.usingColorSpace(.sRGB), c.brightnessComponent < 0.6 { inked += 1 }
            }
        }
        // Two blank patches are "the same" about nothing.
        return inked > 0
    }

    /// The rightmost x, in points, of any ink darker than the background inside `band` — how far
    /// something drawn in that band actually reaches.
    func inkRight(in band: CGRect) -> CGFloat? {
        let x0 = max(0, Int(band.minX * scale)), x1 = min(bitmap.pixelsWide, Int(band.maxX * scale))
        let y0 = max(0, Int(band.minY * scale)), y1 = min(bitmap.pixelsHigh, Int(band.maxY * scale))
        guard x0 < x1, y0 < y1 else { return nil }
        for x in stride(from: x1 - 1, through: x0, by: -1) {
            for y in y0..<y1 {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.brightnessComponent < 0.6 { return CGFloat(x + 1) / scale }
            }
        }
        return nil
    }

    /// How many pixels inside `ring` are the accent — blue well clear of red, which a neutral glyph
    /// or the white ground never is.
    func accentPixels(in ring: CGRect) -> Int {
        let x0 = max(0, Int(ring.minX * scale)), x1 = min(bitmap.pixelsWide, Int(ring.maxX * scale))
        let y0 = max(0, Int(ring.minY * scale)), y1 = min(bitmap.pixelsHigh, Int(ring.maxY * scale))
        var count = 0
        for x in x0..<max(x0, x1) {
            for y in y0..<max(y0, y1) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.blueComponent - c.redComponent > 0.1 { count += 1 }
            }
        }
        return count
    }

    private static func differs(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let p = a?.usingColorSpace(.sRGB), let q = b?.usingColorSpace(.sRGB) else { return false }
        return max(abs(p.redComponent - q.redComponent),
                   max(abs(p.greenComponent - q.greenComponent),
                       abs(p.blueComponent - q.blueComponent))) > 0.02
    }
}
