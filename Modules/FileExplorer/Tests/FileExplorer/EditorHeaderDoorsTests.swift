import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// The document header's ＋ (TE45): where it is drawn, what it calls, and what it says.
///
/// **Drawn, not read.** A hosted SwiftUI tree exposes neither labels nor tooltips under
/// `swift test`, and a synthetic click does not reach a SwiftUI `Button` in this harness (see
/// `PaneBackgroundDeselectMountedTests`). What it does expose is one `_FocusRingView` per button,
/// in the host's coordinates once converted — so the row's buttons can be counted and ordered —
/// and pixels, which tell identical-looking 18pt glyphs apart by what each one alone does.
///
/// What the ＋ DOES is the host's ⌘N closure, handed over as-is; that wiring lives in the app target
/// and is scanned there (`EditorHeaderDoorsWiringTests`).
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
                           newTextFile: (() -> Void)?) -> EditorWorkspaceView {
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
            onNewTextFile: newTextFile)
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
