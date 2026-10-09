import Testing
import Foundation
import AppKit
@testable import FileExplorer

/// **A session typed into for a while still shows what a fresh one would** (TE67 §3.7, 2026-10-07).
///
/// Each keystroke now re-reads part of the source and re-decorates part of the page, so an error
/// would not show at once: it would sit in the kept part and surface later. Chains of random
/// keystrokes, then — Preview's own, and Source's in Split, which reach the session as a change
/// under it — and after each one the session must hold the whole re-read of its source, and its
/// display what decorating that re-read afresh gives — with every list one list to TextKit.
@MainActor
@Suite struct PreviewEditSessionReuseTests {

    private static var iterations: Int {
        (ProcessInfo.processInfo.environment["TE67_PROPERTY_ITERATIONS"].flatMap(Int.init) ?? 2_000) / 4
    }

    @Test func aSessionTypedIntoShowsWhatAFreshOneWould() {
        var steps = 0
        var written = 0
        let seeds = ProcessInfo.processInfo.environment["TE67_PROPERTY_SEED"].flatMap(UInt64.init).map { [$0] }
            ?? Array(1...UInt64(Self.iterations))
        for seed in seeds {
            var random = SplitMix(seed: seed &+ 0x5E55)
            let text = (0..<random.int(1...3)).map { _ in PreviewEditPropertyTests.document(&random) }
                .joined(separator: "\n\n")
            let source = EditorSourceStorage(text: text)
            let session = PreviewEditSession(source: source, undoManager: UndoManager())
            for step in 0..<random.int(2...8) {
                let before = source.text
                let what: String
                if random.int(0...3) == 0 {
                    // Typed in Source, beside: any edit at all, not only one Preview would make.
                    let length = source.textStorage.length
                    let at = random.int(0...length)
                    let cut = random.int(0...2) == 0 ? min(length - at, random.int(1...6)) : 0
                    let inserts = MarkdownProjectionReuseTests.inserts
                    let text = random.int(0...3) == 0 ? "" : inserts[random.int(0...inserts.count - 1)]
                    source.replace(NSRange(location: at, length: cut), with: text, undoManager: nil)
                    what = "seed \(seed) step \(step) Source \(at)+\(cut) \(String(reflecting: text)): \(String(reflecting: before)) → \(String(reflecting: source.text))"
                } else {
                    let edit = PreviewEditPropertyTests.edit(&random, in: session.projection)
                    session.perform(edit)
                    if source.text != before { written += 1 }
                    what = "seed \(seed) step \(step) \(edit): \(String(reflecting: before)) → \(String(reflecting: source.text))"
                }
                steps += 1
                guard Self.expectFresh(session, what) else { break }
            }
        }
        print("[session] \(written) of \(steps) keystrokes wrote")
        // One replayed seed may refuse every keystroke; across them all, most must write.
        if seeds.count > 1 { #expect(written > steps / 4, "only \(written) of \(steps) keystrokes wrote") }
    }

    /// **A space held at a paragraph's start leaves the paragraph's look alone** — it was given the
    /// break's attributes, the storage spread them over the paragraph, and when the space went the
    /// paragraph had lost its spacing (seeds 806 and 2751, 2026-10-08).
    ///
    /// Mutation: take the held space's attributes from the character before it, always.
    @Test func aSpaceHeldAtAParagraphsStartLeavesItsLookAlone() {
        let source = EditorSourceStorage(text: "# Title\n\nWords here.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        let start = (session.projection.renderedString as NSString).range(of: "Words").location
        session.perform(RenderedEdit(range: NSRange(location: start, length: 0), text: " ", action: .typing))
        #expect(session.display.string.contains(" Words"), "the space is held, not written")
        // A keystroke the translator refuses drops the held space and writes nothing.
        session.perform(RenderedEdit(range: NSRange(location: start + 1, length: 0), text: "\"", action: .typing))
        Self.expectFresh(session, "after a held space at the paragraph's start")
    }

    /// **A keystroke in a long list replaces that item, not the list** — the list keeps its
    /// `NSTextList`, in the projection and on screen, so nothing else is laid out again; 340 ms a
    /// keystroke on a 256 KB note that is one list, when each re-read made the list anew.
    ///
    /// Mutation: replace the whole re-read part in `reprojected`, not `PreviewListIdentity.patch`'s,
    /// and the view's storage takes the whole list.
    @Test func typingInALongListReplacesOnlyThatItem() {
        let items = (1...200).map { "- Item \($0) with a **bold** word" }.joined(separator: "\n")
        let source = EditorSourceStorage(text: "# Title\n\n\(items)\n\nEnd.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        func list() -> NSTextList? {
            (session.display.attribute(.paragraphStyle, at: (session.display.string as NSString).range(of: "Item 1 ").location,
                                       effectiveRange: nil) as? NSParagraphStyle)?.textLists.first
        }
        let before = list()
        var edited = 0
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                              object: session.display, queue: nil) { note in
            edited = max(edited, (note.object as! NSTextStorage).editedRange.length)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let at = (session.display.string as NSString).range(of: "Item 100 ").location + 4
        session.perform(RenderedEdit(range: NSRange(location: at, length: 0), text: "x", action: .typing))
        #expect(source.text.contains("Itemx 100 "))
        #expect(list() === before, "the list is still the list it was")
        #expect(edited < 40, "\(edited) characters of the view's storage replaced")
        Self.expectFresh(session, "a keystroke in a long list")
    }

    /// **A list split in two, or two joined, still numbers right** — the one case where a list
    /// cannot keep its identity, because one new list continues two old ones, or two one. The
    /// first: `1)` starts a list of its own, numbered 1 and 2 again, and every item renders as it
    /// did — compared item by item, nothing changed, and Preview went on showing 3 and 4.
    ///
    /// Mutation: compare lists by shape alone, not by how they pair, and the first case shows 3, 4.
    @Test(arguments: [("1. a\n2. b\n1. c\n2. d", "1. c", "1) c"),
                      ("1. a\n2. b\n1) c\n2) d", "1) c\n2) d", "1. c\n2. d"),
                      ("1. a\n2. b\n3. c\n4. d", "3. c", "c"),
                      ("1. a\n2. b\n\nPara\n\n3. c\n4. d", "\n\nPara\n\n", "\n"),
                      ("- a\n- b\n- c\n- d", "- c", "* c"),
                      ("- a\n- b\n* c\n- d", "* c", "- c")])
    func aListSplitOrJoinedStillNumbersRight(text: String, target: String, replacement: String) {
        let source = EditorSourceStorage(text: "Intro.\n\n\(text)\n\nEnd.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        source.replace((source.text as NSString).range(of: target), with: replacement, undoManager: nil)
        Self.expectFresh(session, "\(target) → \(replacement)")
    }

    /// **A paragraph that was the tail of a longer one is redrawn too** — a fence typed into a
    /// quote's second line ends the quote's paragraph at its first, and the break that ended the
    /// whole paragraph is now a paragraph of its own; kept as it was, it still wore the quote's
    /// style, which the text system gives a paragraph's last character from its first (seed 2815).
    ///
    /// Mutation: stop `paragraphs(around:in:)` at the paragraph the change ends in.
    @Test func aParagraphCutShortRedrawsTheRestOfIt() {
        let source = EditorSourceStorage(text: "> **pasta**\n>   a b Café\n\n1. one\n2. two\n\nEnd.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        source.replace(NSRange(location: 13, length: 0), with: "~~~", undoManager: nil)
        #expect(source.text.hasPrefix("> **pasta**\n>~~~ "))
        Self.expectFresh(session, "a fence typed into a quote")
    }

    /// **A block that turns read-only says so on every line** — a code block in a list, given a tab
    /// in Source that the parser expands, can no longer be mapped and is read-only; only the line
    /// typed on changed, and the decoration redone for it alone left the others looking editable.
    /// And back again when the tab goes.
    ///
    /// Mutation: leave `.previewReadOnly` to the decoration, and line `a` keeps the editable look.
    @Test func aBlockThatTurnsReadOnlyIsMarkedSoOnEveryLine() throws {
        let source = EditorSourceStorage(text: "Intro.\n\n- item\n\n  ```\n  a\n  b\n  ```\n\nEnd.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        func readOnly(_ text: String) -> Bool {
            let at = (session.display.string as NSString).range(of: text).location
            return session.display.attribute(.previewReadOnly, at: at, effectiveRange: nil) != nil
                && session.display.attribute(.toolTip, at: at, effectiveRange: nil) as? String
                    == PreviewEditSession.readOnlyTip
        }
        #expect(!readOnly("a\n"))
        source.replace((source.text as NSString).range(of: "  b"), with: "\tb", undoManager: nil)
        let code = try #require(session.projection.blocks.first { if case .codeBlock = $0.kind { true } else { false } })
        #expect(code.readOnly == .unalignable, "the parser no longer expands this tab — find another way in")
        #expect(readOnly("a\n"), "the line not typed on")
        Self.expectFresh(session, "a code block turned read-only")
        source.replace((source.text as NSString).range(of: "\tb"), with: "  b", undoManager: nil)
        #expect(!readOnly("a\n"), "and editable again")
        Self.expectFresh(session, "a code block editable again")
    }

    /// **A picture that could not be shown is looked for again as you type anywhere** — the file
    /// may be written, or downloaded, after the note names it. Every keystroke decorated the whole
    /// page and asked again; once only the changed paragraphs were, a picture elsewhere never was.
    ///
    /// Mutation: drop `retryFailedImages()`, and the picture stays a placeholder.
    @Test func aPictureThatCouldNotBeShownIsLookedForAgainAsYouType() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("te67-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = EditorSourceStorage(text: "![pic](pic.png)\n\nWords.")
        let session = PreviewEditSession(source: source, undoManager: UndoManager(), documentFolder: folder.path)
        var loads = 0
        session.onImageLoaded = { _ in loads += 1 }
        func picture() -> NSImage? {
            let at = (session.display.string as NSString).range(of: "\u{FFFC}").location
            return (session.display.attribute(.attachment, at: at, effectiveRange: nil) as? NSTextAttachment)?.image
        }
        func settle(until done: () -> Bool) async throws {
            for _ in 0..<200 where !done() { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        try await settle { loads == 1 }
        #expect(loads == 1, "the first look, which finds nothing")
        #expect(picture()?.size != NSSize(width: 40, height: 30))

        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        try #require(image?.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("pic.png"))
        session.imageRetry = 0
        let words = (session.display.string as NSString).range(of: "Words").location
        session.perform(RenderedEdit(range: NSRange(location: words + 5, length: 0), text: "!", action: .typing))
        #expect(source.text.hasSuffix("Words!."), "the keystroke was written")
        try await settle { loads == 2 }
        #expect(loads == 2, "looked for again")
        #expect(picture()?.size == NSSize(width: 40, height: 30))
    }

    /// Where two renderings first differ, and in what — for a failure to say.
    static func firstDifference(_ a: NSAttributedString, _ b: NSAttributedString) -> String {
        var at = 0
        while at < min(a.length, b.length) {
            var left = NSRange(), right = NSRange()
            let x = a.attributes(at: at, effectiveRange: &left), y = b.attributes(at: at, effectiveRange: &right)
            if !PreviewAttributeShape.same(a.attributedSubstring(from: NSRange(location: at, length: 1)),
                                           b.attributedSubstring(from: NSRange(location: at, length: 1))) {
                let keys = Set(x.keys).union(y.keys).filter {
                    !(x[$0].map { String(describing: $0) } == y[$0].map { String(describing: $0) })
                }
                return " — first at \(at) \(String(reflecting: (a.string as NSString).substring(with: NSRange(location: at, length: 1)))), in \(keys.map(\.rawValue).sorted())" + (ProcessInfo.processInfo.environment["TE67_DETAIL"] != nil ? "\nDISPLAY \(x)\nFRESH \(y)" : "")
            }
            at = min(NSMaxRange(left), NSMaxRange(right))
        }
        return " — in length, \(a.length) against \(b.length)"
    }

    /// The session against a fresh read of its own source.
    @discardableResult
    static func expectFresh(_ session: PreviewEditSession, _ what: String,
                            sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        let full = MarkdownProjection.project(session.source.text, style: session.style)
        guard MarkdownProjectionReuseTests.expectSame(session.projection, full, what, sourceLocation: sourceLocation)
        else { return false }
        // Held spaces and an opened paragraph are in the display only: nothing to compare against.
        guard session.display.string == full.renderedString else { return true }
        let fresh = session.decorated(full.rendered)
        guard PreviewAttributeShape.same(session.display, fresh) else {
            Issue.record("the display differs from a fresh decoration\(firstDifference(session.display, fresh)): \(what)",
                         sourceLocation: sourceLocation)
            return false
        }
        guard MarkdownProjectionReuseTests.sameLists(session.display, fresh) else {
            Issue.record("a list is split across two NSTextLists: \(what)", sourceLocation: sourceLocation)
            return false
        }
        return true
    }
}
