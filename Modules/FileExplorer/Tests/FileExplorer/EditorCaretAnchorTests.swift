import AppKit
import SwiftUI
import Testing
@testable import FileExplorer

/// **Coming back to Edit put the reader at the top of the file.**
///
/// `PlainTextEditor` is an `NSViewRepresentable`, and a workspace switch destroys it: ⌘1 and back
/// runs `makeNSView` again, which assigns `view.string = text` into a brand-new text storage. A
/// fresh `NSTextView` selects `{0, 0}`, so the caret and the scroll both went to the top of the
/// document — on every trip through any other workspace.
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

    private static func editor(text: String, initialSelection: Int?) -> PlainTextEditor {
        PlainTextEditor(text: .constant(text), isEditable: true, fontScale: 1,
                        documentID: "/a/b.md", undoManager: UndoManager(),
                        initialSelection: initialSelection)
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
    /// This is the measurement the whole design turns on, so it is pinned rather than described.
    /// Assigning `view.string` replaces the storage and leaves the insertion point after the LAST
    /// character: mounted over "hello there" with no anchor, the caret reports 11, not 0. The scroll
    /// view is independently still at the top, which is why the symptom reads as "it went back to
    /// the top of the file" while the caret was actually parked invisibly at the bottom of it.
    ///
    /// Pinned because two decisions rest on it. `initialSelection` is optional rather than
    /// defaulting to 0, and a zero anchor is restored like any other — both of which are pointless
    /// if this is 0, and both of which are load-bearing because it is 11. Should a future AppKit
    /// change this, that is the conversation this test is here to start.
    @Test func aTextViewWithNoAnchorLeavesTheCaretWhereAppKitPutIt() throws {
        let view = try #require(Self.textView(of: Self.editor(text: "hello there", initialSelection: nil)))
        #expect(view.selectedRange().location == 11,
                "a fresh NSTextView no longer parks the caret at the end of an assigned string — the optional anchor and the zero-anchor restore were both built on it doing so")
    }

    /// **The reader who was at the top gets the top back.**
    ///
    /// The case an `offset > 0` early return silently broke, and the reason `offset(for:)` is
    /// optional. Nothing about this looks like a restore — the request and the outcome are both 0 —
    /// which is exactly why it needs a test: without one, the skip is invisible and the symptom is
    /// somebody's caret at the end of a file they were reading the first line of.
    @Test func anAnchorAtTheTopIsRestoredLikeAnyOther() throws {
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
        #expect(workspace.contains("initialSelection: document.caretAnchors.offset(for: document.path)"),
                "the workspace no longer hands the anchor to the text view — the caret resets on every switch")
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
