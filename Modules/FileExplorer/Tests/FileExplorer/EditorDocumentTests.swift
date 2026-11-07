import Testing
import AppKit
import Foundation
@testable import FileExplorer

/// The open document's state machine: what counts as dirty, and what a read-only file is allowed
/// to do.
@MainActor
@Suite struct EditorDocumentTests {

    private func stamp(_ size: Int) -> EditorFileStore.Stamp {
        EditorFileStore.Stamp(modifiedAt: Date(timeIntervalSince1970: 1), size: size)
    }

    @Test func anEmptyDocumentIsNotDirtyAndHasNothingToSave() {
        let document = EditorDocument()
        #expect(document.path == nil)
        #expect(!document.isDirty)
        #expect(!document.canSave)
        #expect(document.name == "")
    }

    @Test func typingMakesItDirtyAndSavingMakesItCleanAgain() {
        let document = EditorDocument()
        document.open(.editable(text: "one\n", stamp: stamp(4), encoding: .utf8), at: "/tmp/a.md")
        #expect(!document.isDirty)

        document.text = "one\ntwo\n"
        #expect(document.isDirty)
        #expect(document.canSave)

        document.markSaved(stamp: stamp(8))
        #expect(!document.isDirty)
        #expect(document.stamp?.size == 8)
    }

    /// Dirty is a comparison, not a flag: a flag set on the first keystroke would survive an undo
    /// back to the original text.
    @Test func undoingEveryEditMakesTheDocumentCleanWithoutSaving() {
        let document = EditorDocument()
        document.open(.editable(text: "original\n", stamp: stamp(9), encoding: .utf8), at: "/tmp/a.md")
        document.text = "original edited\n"
        #expect(document.isDirty)
        document.text = "original\n"
        #expect(!document.isDirty, "a document typed back to its saved text still reads as changed")
    }

    /// A lossy decode is shown and never saved, so it is never dirty however much is typed into it.
    /// That keeps ⌘S greyed out rather than offering to overwrite the file with the lossy text.
    @Test func aReadOnlyDocumentIsNeverDirty() {
        let document = EditorDocument()
        document.open(.readOnly(text: "caf\u{FFFD}\n", reason: EditorFileStore.lossyReason),
                      at: "/tmp/a.txt")
        #expect(document.isReadOnly)
        #expect(document.stamp == nil, "a read-only document has no stamp to save against")

        document.text = "anything at all"
        #expect(!document.isDirty)
        #expect(!document.canSave)
    }

    @Test func aRefusedFileShowsItsReasonAndOffersNothingToEdit() {
        let document = EditorDocument()
        document.open(.refused(reason: "Couldn't be read."), at: "/tmp/blob.bin")
        #expect(document.refusal == "Couldn't be read.")
        #expect(document.isReadOnly)
        #expect(document.text.isEmpty)
        #expect(!document.canSave)
    }

    @Test func openingASecondFileReplacesEverythingTheFirstOneLeft() {
        let document = EditorDocument()
        document.open(.readOnly(text: "bad", reason: "no"), at: "/tmp/a.txt")
        document.open(.editable(text: "good\n", stamp: stamp(5), encoding: .utf8), at: "/tmp/b.md")

        #expect(document.path == "/tmp/b.md")
        #expect(document.readOnlyReason == nil, "the previous file's read-only reason survived")
        #expect(document.refusal == nil)
        #expect(document.stamp?.size == 5)
        #expect(!document.isDirty)
    }

    @Test func closingLeavesNothingBehind() {
        let document = EditorDocument()
        document.open(.editable(text: "x\n", stamp: stamp(2), encoding: .utf8), at: "/tmp/a.md")
        document.text = "changed"
        document.close()

        #expect(document.path == nil)
        #expect(document.text.isEmpty)
        #expect(document.stamp == nil)
        #expect(!document.isDirty)
    }

    @Test func onlyMarkdownFilesClaimAPreview() {
        let document = EditorDocument()
        for (path, expected) in [("/tmp/a.md", true), ("/tmp/a.markdown", true),
                                 ("/tmp/a.MD", true), ("/tmp/a.txt", false),
                                 ("/tmp/a.json", false)] {
            document.open(.editable(text: "", stamp: stamp(0), encoding: .utf8), at: path)
            #expect(document.isMarkdown == expected, "\(path) answered \(document.isMarkdown)")
        }
    }

    /// The dirty answer is memoised per (buffer, saved state) pair, since it is read several times
    /// per keystroke and an `NSTextView`'s bridged string makes each read walk the buffer. A memo
    /// keyed on only one half would go stale when the other moved: a dot still lit after a save, or
    /// out while there is typing left to write.
    @Test func theDirtyAnswerFollowsBothTheBufferAndTheSavedText() {
        let document = EditorDocument()
        document.open(.editable(text: "a\n", stamp: stamp(2), encoding: .utf8), at: "/tmp/a.md")
        #expect(!document.isDirty)          // warms the memo before anything moves

        document.text = "b\n"
        #expect(document.isDirty, "the answer did not follow the buffer")

        document.markSaved(text: "b\n", stamp: stamp(2))
        #expect(!document.isDirty, "the answer did not follow a save")

        // A save of a snapshot that is not what the buffer now holds, as when a keystroke lands
        // during a background autosave.
        document.text = "c\n"
        document.markSaved(text: "b\n", stamp: stamp(2))
        #expect(document.isDirty, "a save of an older snapshot left the buffer reading clean")

        // Same length, different bytes: past the length shortcut and into the comparison.
        document.markSaved(text: "c\n", stamp: stamp(2))
        #expect(!document.isDirty)
        document.text = "d\n"
        #expect(document.isDirty, "an equal-length change was missed")
    }

    /// A change Unicode calls equivalent is still a change to the file. Swift's `==` is canonical
    /// equivalence, so a same-length buffer differing only in how an accent is written would read
    /// clean: no dot, ⌘S greyed, no autosave, no ask on close. Both pairs keep the UTF-8 length and
    /// change the bytes; each is typed as a Swift string and as bridged from a text storage.
    @Test(arguments: [("e\u{301}\u{E9}\n", "\u{E9}e\u{301}\n"), ("a\u{301}\u{316}\n", "a\u{316}\u{301}\n")],
          [false, true])
    func aChangeOnlyInHowUnicodeIsWrittenIsDirty(_ pair: (String, String), fromStorage: Bool) {
        let (saved, typed) = pair
        #expect(saved == typed && saved.utf8.count == typed.utf8.count,
                "the fixture no longer describes an equivalent, same-length pair")
        func asBuffer(_ text: String) -> String { fromStorage ? NSTextStorage(string: text).string : text }
        let document = EditorDocument()
        document.open(.editable(text: saved, stamp: stamp(saved.utf8.count), encoding: .utf8), at: "/tmp/a.md")
        #expect(!document.isDirty)
        document.text = asBuffer(typed)
        #expect(document.isDirty, "a buffer whose bytes differ from the file's reads as saved")
        document.text = asBuffer(saved)
        #expect(!document.isDirty, "the buffer back at the file's own bytes reads as changed")
    }

    @Test func theNameIsTheFilesOwnRatherThanItsPath() {
        let document = EditorDocument()
        document.open(.editable(text: "", stamp: stamp(0), encoding: .utf8), at: "/a/b/c/september-backlog.md")
        #expect(document.name == "september-backlog.md")
    }
}
