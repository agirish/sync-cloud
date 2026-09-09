import AppKit
import SwiftUI
import Testing
@testable import FileExplorer

/// **Coming back to Edit put the reader at the top of the file.**
///
/// `PlainTextEditor` is an `NSViewRepresentable`, and a workspace switch destroys it: ⌘1 and back
/// runs `makeNSView` again, which assigns `view.string = text` into a brand-new text storage, and
/// the reader's place in the document is gone — on every trip through any other workspace.
///
/// **Where it goes is not where it looks, and that measurement is load-bearing enough to be pinned
/// below rather than described here.** Assigning `string` leaves the caret at the END of the new
/// text, while the scroll view is independently still at the top. So the symptom reads as "it went
/// back to the top of the file" when the caret is actually parked invisibly at the bottom of it —
/// and it is why the caret is placed unconditionally rather than only when something was
/// remembered. See `aRawTextViewParksTheCaretAtTheEndOfAnAssignedString`.
///
/// What made it read as arbitrary rather than as a reset is that almost everything else survived.
/// The buffer, the open file, the undo stack, Edit/Preview/Split, the rail filter and the rail tab
/// were all moved above the view a while ago, precisely because the view is rebuilt from nothing.
/// The place in the document was the one thing left behind.
@MainActor
@Suite struct EditorCaretAnchorTests {

    // MARK: The store

    @Test func anAnchorComesBackForTheFileItWasRecordedFor() {
        let anchors = EditorCaretAnchors()
        anchors.remember(120, for: "/a/one.md")
        anchors.remember(7, for: "/a/two.md")

        #expect(anchors.offset(for: "/a/one.md") == 120)
        #expect(anchors.offset(for: "/a/two.md") == 7)
    }

    /// **A file nobody has read answers nil, and a reader sitting at the top answers 0.**
    ///
    /// These were one value — `Int`, with 0 meaning both — for exactly one test run, and the
    /// difference is not academic. Because a fresh text view leaves the caret at the END of the
    /// document (see below), a restore that skips 0 as "nothing recorded" hands the top-of-file
    /// reader their document back with the caret at the bottom. The most common place to be was the
    /// one place that was not restored.
    @Test func nothingRecordedIsNotTheSameAsAnchoredAtTheTop() {
        let anchors = EditorCaretAnchors()
        #expect(anchors.offset(for: "/a/never-opened.md") == nil)

        anchors.remember(0, for: "/a/read-from-the-top.md")
        #expect(anchors.offset(for: "/a/read-from-the-top.md") == 0)
    }

    /// **Nothing open records nothing**, and asks for nothing. `document.path` is optional and is
    /// nil whenever the editor is showing its empty state or a refusal; a nil key would otherwise
    /// have to be spelled as some sentinel path, which is a second thing to keep in step.
    @Test func aNilPathIsNeitherRecordedNorAsked() {
        let anchors = EditorCaretAnchors()
        anchors.remember(50, for: nil)
        #expect(anchors.offset(for: nil) == nil)
    }

    @Test func forgettingAFileDropsItsAnchor() {
        let anchors = EditorCaretAnchors()
        anchors.remember(30, for: "/a/one.md")
        anchors.forget("/a/one.md")
        #expect(anchors.offset(for: "/a/one.md") == nil)
    }

    // MARK: The clamp

    /// **The case that would crash.** An anchor is a UTF-16 offset into the text as it stood when it
    /// was recorded, and the file can be shorter by the time it is asked for — edited in another
    /// app, reverted, truncated. `setSelectedRange` past the end of the storage raises
    /// `NSRangeException`, which takes the app down with every unsaved buffer in it.
    @Test func anAnchorPastTheEndIsBroughtBackToIt() {
        #expect(EditorCaretAnchors.clamped(500, in: "short") == 5)
        #expect(EditorCaretAnchors.clamped(0, in: "short") == 0)
        #expect(EditorCaretAnchors.clamped(3, in: "short") == 3)
        #expect(EditorCaretAnchors.clamped(-4, in: "short") == 0)
    }

    /// **Counted in UTF-16 code units, which is what `NSRange` counts in.** A character-count clamp
    /// looks right on ASCII and is wrong the moment somebody writes an emoji: "a👍b" is 3 characters
    /// and 4 UTF-16 units, so a caret legitimately at the end would be clamped one unit short and
    /// land inside the surrogate pair.
    @Test func theClampCountsTheSameUnitsAsNSRange() {
        let text = "a👍b"
        #expect(text.count == 3)
        #expect(EditorCaretAnchors.clamped(99, in: text) == 4,
                "the clamp counted Characters — a caret at the end of a file with an emoji in it lands mid-surrogate")
    }

    // MARK: What the text view actually does

    /// Walks a mounted hierarchy for the editor's marked scroll view — the same route
    /// `EditorFindBarTests` takes, because the claim here is likewise about what `makeNSView` really
    /// did rather than about what it was passed.
    private static func textView(of editor: PlainTextEditor) -> NSTextView? {
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        var found: NSTextView?
        func walk(_ v: NSView) {
            if let scroll = v as? NSScrollView,
               scroll.identifier == EditorDocumentSurface.identifier,
               let text = scroll.documentView as? NSTextView {
                found = text
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        return found
    }

    private static func editor(text: String, initialSelection: Int,
                               onSelectionChange: @escaping (NSRange) -> Void = { _ in }) -> PlainTextEditor {
        PlainTextEditor(text: .constant(text), isEditable: true, fontScale: 1,
                        documentID: "/a/b.md", undoManager: UndoManager(),
                        onSelectionChange: onSelectionChange,
                        initialSelection: initialSelection)
    }

    /// **Building the view must report no selection changes at all**, and this is the test for a
    /// defect that shipped.
    ///
    /// `NSTextView` calls `textViewDidChangeSelection` for programmatic moves as readily as for a
    /// click, and construction makes two: assigning `string` leaves the caret at the end of the new
    /// text, and `restoreCaret` then puts it back. With the delegate wired at the top of
    /// `makeNSView`, both were reported — measured at 11 then 4 on this fixture.
    ///
    /// The second is merely noise. **The first was a wrong answer that got written down**: the host
    /// records every reported selection as this file's anchor, so opening a file and switching
    /// workspace without ever clicking in the text recorded "end of document" — and coming back put
    /// the reader at the bottom of a file they had not touched. Both also wrote SwiftUI `@State`
    /// from inside an update pass.
    ///
    /// Nothing in construction needs a delegate, so the fix is to wire it last. Asserting the count
    /// is zero rather than one is deliberate: "the restore no longer reports" would still pass with
    /// the string assignment reporting, and that is the half that caused the bug.
    @Test func buildingTheViewReportsNoSelectionChange() {
        final class Box { var calls: [Int] = [] }
        let box = Box()
        _ = Self.textView(of: Self.editor(text: "hello there", initialSelection: 4,
                                          onSelectionChange: { box.calls.append($0.location) }))

        #expect(box.calls.isEmpty,
                "constructing the editor reported \(box.calls) — the host writes those down as the reader's caret, so a file nobody clicked in gets an anchor at the end of it")
    }

    /// **The mechanism.** A rebuilt text view opens with the caret where the anchor says, not at 0.
    @Test func aRebuiltTextViewOpensAtItsAnchor() throws {
        let body = String(repeating: "line of text\n", count: 200)
        let view = try #require(Self.textView(of: Self.editor(text: body, initialSelection: 900)))

        #expect(view.selectedRange().location == 900,
                "the editor was built at the top despite an anchor — the reader is back at line 1")
    }

    /// **What a fresh text view does unaided — and it is not what it looks like.**
    ///
    /// This is the measurement the whole design turns on, so it is pinned rather than described, and
    /// pinned against RAW AppKit rather than through `PlainTextEditor` — the editor now always
    /// places the caret, so it no longer exhibits this and could not hold the claim.
    ///
    /// Assigning `string` replaces the storage and leaves the insertion point after the LAST
    /// character. The scroll view is independently still at the top, which is why the symptom reads
    /// as "it went back to the top of the file" while the caret was actually parked invisibly at the
    /// bottom of it.
    ///
    /// Two decisions rest on this being 11 rather than 0: the caret is placed unconditionally (so a
    /// file with no anchor opens at the top instead of the end), and the status line is seeded from
    /// the same number the text view is given (so Ln/Col cannot disagree with the caret). Should a
    /// future AppKit change this, that is the conversation this test exists to start.
    @Test func aRawTextViewParksTheCaretAtTheEndOfAnAssignedString() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.string = "hello there"

        #expect(view.selectedRange().location == 11,
                "NSTextView no longer parks the caret at the end of an assigned string — the unconditional restore and the seeded status line were both built on it doing so")
    }

    /// **Zero is a place, and asking for it must put the caret there.**
    ///
    /// This one assertion covers the two cases an `offset > 0` early return broke, because the host
    /// spells both as 0: the reader who was at the top of the file, and the file nobody has read at
    /// all. Nothing about it looks like a restore — the request and the outcome are both 0 — which
    /// is exactly why it needs a test. Without it the skip is invisible, and the symptom is a caret
    /// at the end of a document somebody was reading the first line of.
    @Test func askingForTheTopPutsTheCaretThere() throws {
        let view = try #require(Self.textView(of: Self.editor(text: "hello there", initialSelection: 0)))
        #expect(view.selectedRange().location == 0,
                "a zero anchor was treated as no anchor, so the caret stayed where AppKit left it — at the end")
    }

    /// The clamp, through the real view: a file that shrank under its anchor must not raise.
    ///
    /// Reaching the assertion at all is most of the result — an unclamped `setSelectedRange` throws
    /// `NSRangeException` from inside `makeNSView` and takes the test process with it.
    @Test func anAnchorPastTheEndOfARewrittenFileDoesNotRaise() throws {
        let view = try #require(Self.textView(of: Self.editor(text: "tiny", initialSelection: 10_000)))
        #expect(view.selectedRange().location == 4,
                "the caret was placed outside the storage, or not clamped to its end")
    }

    // MARK: The wiring

    private static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/\(file)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(file) — every scan here would be vacuous")
        try #require(text.count > 500, "\(file) read as \(text.count) characters — truncated?")
        return text
    }

    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// **Both halves of the wiring, scanned rather than rendered.**
    ///
    /// Everything above proves the text view honours an anchor it is handed. None of it notices if
    /// the workspace stops handing one over, or stops recording where the caret went — and either
    /// omission restores the original defect exactly, with the whole suite green. Mounting
    /// `EditorWorkspaceView` to catch that means standing up a document, an autosave policy, a rail
    /// and twenty closures to observe one assignment.
    @Test func theWorkspaceRecordsTheCaretAndHandsTheAnchorBack() throws {
        let workspace = Self.codeOnly(try Self.source("EditorWorkspaceView.swift"))
        #expect(workspace.contains("document.caretAnchors.remember($0.location, for: document.path)"),
                "the workspace no longer records where the caret went — every anchor stays 0")
        #expect(workspace.contains("initialSelection: document.caretAnchors.offset(for: document.path) ?? 0"),
                "the workspace no longer hands the anchor to the text view — the caret resets on every switch")
        // **The status line reads the same anchor, or it contradicts the caret.** `caretOffset`
        // drives Ln/Col and is `@State`, so it comes back 0 on every switch — while the text view is
        // placed wherever the anchor says. Nothing reports that placement any more, by design (the
        // delegate is wired after it so construction cannot write SwiftUI state), so the readout has
        // to be seeded from the same number rather than told by the view.
        #expect(workspace.contains("caretOffset = EditorCaretAnchors.clamped("),
                "the status line is no longer seeded from the anchor — Ln/Col will claim line 1 while the caret sits elsewhere")
    }

    /// **The anchor store may not become observable.** The caret moves on every arrow key and every
    /// keystroke, so a `@Published` here would re-render the document's observers at typing speed —
    /// which is the exact cost `EditorBuffer` was split out of `EditorDocument` to remove, arriving
    /// back through a different door.
    @Test func theAnchorStoreAnnouncesNothing() throws {
        let store = Self.codeOnly(try Self.source("EditorCaretAnchors.swift"))
        #expect(!store.contains("@Published"),
                "the caret store publishes — typing now re-renders every observer of the document")
        #expect(!store.contains("ObservableObject"),
                "the caret store became observable — see EditorBuffer for what that costs on the keystroke path")
    }
}
