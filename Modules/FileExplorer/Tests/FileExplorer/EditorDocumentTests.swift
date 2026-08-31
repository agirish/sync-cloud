import Testing
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

    /// **Dirty is a comparison, not a flag.** A flag set on the first keystroke would survive an
    /// undo back to the original text and go on claiming the file had changed.
    @Test func undoingEveryEditMakesTheDocumentCleanWithoutSaving() {
        let document = EditorDocument()
        document.open(.editable(text: "original\n", stamp: stamp(9), encoding: .utf8), at: "/tmp/a.md")
        document.text = "original edited\n"
        #expect(document.isDirty)
        document.text = "original\n"
        #expect(!document.isDirty, "a document typed back to its saved text still reads as changed")
    }

    /// A lossy decode is shown and never saved, so it is never dirty however much is typed into it
    /// — which is what keeps ⌘S greyed out rather than offering to destroy the file.
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

    @Test func theNameIsTheFilesOwnRatherThanItsPath() {
        let document = EditorDocument()
        document.open(.editable(text: "", stamp: stamp(0), encoding: .utf8), at: "/a/b/c/september-backlog.md")
        #expect(document.name == "september-backlog.md")
    }
}
