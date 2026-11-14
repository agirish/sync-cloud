import AppKit
import SwiftUI
import Testing
@testable import FileExplorer

/// Coming back to Edit keeps the reader's place in the file. A workspace switch destroys
/// `PlainTextEditor` and `makeNSView` assigns `view.string` into new storage, so the caret offset
/// lives above the view in `EditorCaretAnchors`. Assigning `string` parks the caret at the end
/// with the scroll at the top, so the caret is placed unconditionally.
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

    /// A file nobody has read answers nil, and a reader at the top answers 0. A fresh text view
    /// leaves the caret at the end, so a restore that skipped 0 as "nothing recorded" would hand a
    /// top-of-file reader the caret at the bottom.
    @Test func nothingRecordedIsNotTheSameAsAnchoredAtTheTop() {
        let anchors = EditorCaretAnchors()
        #expect(anchors.offset(for: "/a/never-opened.md") == nil)

        anchors.remember(0, for: "/a/read-from-the-top.md")
        #expect(anchors.offset(for: "/a/read-from-the-top.md") == 0)
    }

    /// Nothing open records and asks for nothing. `document.path` is nil in the empty state or a
    /// refusal; otherwise a nil key would need a sentinel path, a second thing to keep in step.
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

    /// An anchor is a UTF-16 offset into the text as recorded, and the file can be shorter when it
    /// is asked for (edited elsewhere, reverted, truncated). `setSelectedRange` past the end raises
    /// `NSRangeException`, taking the app down with every unsaved buffer, so it is clamped.
    @Test func anAnchorPastTheEndIsBroughtBackToIt() {
        #expect(EditorCaretAnchors.clamped(500, in: "short") == 5)
        #expect(EditorCaretAnchors.clamped(0, in: "short") == 0)
        #expect(EditorCaretAnchors.clamped(3, in: "short") == 3)
        #expect(EditorCaretAnchors.clamped(-4, in: "short") == 0)
    }

    /// Counted in UTF-16 code units, as `NSRange` counts. "a👍b" is 3 characters and 4 units, so a
    /// character-count clamp would put a caret at the end one unit short, inside the surrogate pair.
    @Test func theClampCountsTheSameUnitsAsNSRange() {
        let text = "a👍b"
        #expect(text.count == 3)
        #expect(EditorCaretAnchors.clamped(99, in: text) == 4,
                "the clamp counted Characters — a caret at the end of a file with an emoji in it lands mid-surrogate")
    }

    // MARK: What the text view actually does

    /// Walks a mounted hierarchy for the editor's marked scroll view, as `EditorFindBarTests` does,
    /// because the claim is about what `makeNSView` did, not what it was passed.
    private static func textView(of editor: PlainTextEditor) -> NSTextView? {
        let host = NSHostingView(rootView: editor.editorTestDefaults("EditorCaretAnchorTests"))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        return EditorTestRigs.markedScroll(in: host)?.documentView as? NSTextView
    }

    private static func editor(text: String, initialSelection: Int,
                               onSelectionChange: @escaping (NSRange) -> Void = { _ in }) -> PlainTextEditor {
        PlainTextEditor(source: EditorSourceStorage(text: text), isEditable: true, fontScale: 1,
                        documentID: "/a/b.md", undoManager: UndoManager(),
                        onSelectionChange: onSelectionChange,
                        initialSelection: initialSelection)
    }

    /// Building the view reports no selection change at all, so the delegate is wired last in
    /// `makeNSView`. `NSTextView` reports programmatic moves like clicks: assigning `string` would
    /// record "end of document" as the anchor of a file nobody clicked in, and write `@State` inside
    /// an update pass. Zero, not one: the string assignment's report is the harmful one.
    @Test func buildingTheViewReportsNoSelectionChange() {
        final class Box { var calls: [Int] = [] }
        let box = Box()
        _ = Self.textView(of: Self.editor(text: "hello there", initialSelection: 4,
                                          onSelectionChange: { box.calls.append($0.location) }))

        #expect(box.calls.isEmpty,
                "constructing the editor reported \(box.calls) — the host writes those down as the reader's caret, so a file nobody clicked in gets an anchor at the end of it")
    }

    /// A rebuilt text view opens with the caret where the anchor says, not at 0.
    @Test func aRebuiltTextViewOpensAtItsAnchor() throws {
        let body = String(repeating: "line of text\n", count: 200)
        let view = try #require(Self.textView(of: Self.editor(text: body, initialSelection: 900)))

        #expect(view.selectedRange().location == 900,
                "the editor was built at the top despite an anchor — the reader is back at line 1")
    }

    /// Raw AppKit: assigning `string` leaves the insertion point after the last character, with the
    /// scroll view at the top. The caret is placed unconditionally, and the status line seeded from
    /// the number the view is given, because of this; if AppKit changes it, revisit both.
    @Test func aRawTextViewParksTheCaretAtTheEndOfAnAssignedString() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.string = "hello there"

        #expect(view.selectedRange().location == 11,
                "NSTextView no longer parks the caret at the end of an assigned string — the unconditional restore and the seeded status line were both built on it doing so")
    }

    /// Zero is a place, and asking for it puts the caret there. The host passes 0 both for a reader
    /// at the top and for a file nobody has read, so an `offset > 0` early return would leave the
    /// caret at the end in both. Request and outcome are both 0, so the skip is otherwise invisible.
    @Test func askingForTheTopPutsTheCaretThere() throws {
        let view = try #require(Self.textView(of: Self.editor(text: "hello there", initialSelection: 0)))
        #expect(view.selectedRange().location == 0,
                "a zero anchor was treated as no anchor, so the caret stayed where AppKit left it — at the end")
    }

    /// The clamp, through the real view: a file that shrank under its anchor must not raise. An
    /// unclamped `setSelectedRange` throws `NSRangeException` in `makeNSView` and kills the process.
    @Test func anAnchorPastTheEndOfARewrittenFileDoesNotRaise() throws {
        let view = try #require(Self.textView(of: Self.editor(text: "tiny", initialSelection: 10_000)))
        #expect(view.selectedRange().location == 4,
                "the caret was placed outside the storage, or not clamped to its end")
    }

    // MARK: The wiring

    /// The workspace records the caret and hands the anchor back, scanned rather than rendered: the
    /// tests above show only that the text view honours an anchor it is handed.
    @Test func theWorkspaceRecordsTheCaretAndHandsTheAnchorBack() throws {
        let workspace = SourceText.codeOnly(try SourceText.fileExplorer("EditorWorkspaceView.swift"))
        #expect(workspace.contains("document.caretAnchors.remember($0.location, for: document.path)"),
                "the workspace no longer records where the caret went — every anchor stays 0")
        #expect(workspace.contains("initialSelection: document.caretAnchors.offset(for: document.path) ?? 0"),
                "the workspace no longer hands the anchor to the text view — the caret resets on every switch")
        // The status line reads the same anchor, or it contradicts the caret. `caretOffset` drives
        // Ln/Col and is `@State`, so it comes back 0 on every switch, and by design nothing reports
        // the text view's placement. So the readout is seeded from the same number.
        #expect(workspace.contains("caretOffset = EditorCaretAnchors.clamped("),
                "the status line is no longer seeded from the anchor — Ln/Col will claim line 1 while the caret sits elsewhere")
    }

    /// The anchor store must not become observable. The caret moves on every keystroke, so a
    /// `@Published` here would re-render the document's observers at typing speed, the cost
    /// `EditorBuffer` exists to keep off `EditorDocument`.
    @Test func theAnchorStoreAnnouncesNothing() throws {
        let store = SourceText.codeOnly(try SourceText.fileExplorer("EditorCaretAnchors.swift"))
        #expect(!store.contains("@Published"),
                "the caret store publishes — typing now re-renders every observer of the document")
        #expect(!store.contains("ObservableObject"),
                "the caret store became observable — see EditorBuffer for what that costs on the keystroke path")
    }
}
