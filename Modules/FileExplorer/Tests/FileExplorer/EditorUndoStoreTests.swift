import Testing
import Foundation
@testable import FileExplorer

/// One undo stack per document: that it survives a round trip, and — the half that matters — that
/// it is refused when it no longer fits the buffer.
@MainActor
@Suite struct EditorUndoStoreTests {

    private func store(limit: Int = 8) -> EditorUndoStore { EditorUndoStore(limit: limit) }

    @Test func aDocumentGetsItsOwnStackAndKeepsIt() {
        let subject = store()
        subject.activate(path: "/n/a.md", text: "one")
        let first = subject.current

        subject.remember(text: "one")
        subject.activate(path: "/n/b.md", text: "two")
        #expect(subject.current !== first, "two documents shared one stack")

        subject.remember(text: "two")
        subject.activate(path: "/n/a.md", text: "one")
        #expect(subject.current === first, "the first document's history was not handed back")
    }

    /// **The case the whole fingerprint exists for.** Leave a file with autosave off, answer
    /// "Don't Save", and the disk holds text from before the edits while the stack holds
    /// registrations made against the text after them. Replaying that splices or throws
    /// `NSRangeException`; refusing it costs a lost history and nothing else.
    @Test func aStackIsRefusedWhenTheBufferCameBackDifferent() {
        let subject = store()
        subject.activate(path: "/n/a.md", text: "the edited text")
        let edited = subject.current
        subject.remember(text: "the edited text")

        subject.activate(path: "/n/b.md", text: "elsewhere")
        subject.remember(text: "elsewhere")

        // Back to a.md, but the file on disk is what it was before the edits.
        subject.activate(path: "/n/a.md", text: "the ORIGINAL text")
        #expect(subject.current !== edited, "a stale stack was handed back")
    }

    /// The same text at the same path is the same buffer, whatever route it arrived by.
    @Test func anIdenticalBufferKeepsItsStack() {
        let subject = store()
        subject.activate(path: "/n/a.md", text: "same")
        let manager = subject.current
        subject.remember(text: "same")
        subject.activate(path: "/n/a.md", text: "same")
        #expect(subject.current === manager)
    }

    @Test func nothingOpenGetsAFreshStack() {
        let subject = store()
        subject.activate(path: "/n/a.md", text: "one")
        let manager = subject.current
        subject.remember(text: "one")
        subject.activate(path: nil, text: "")
        #expect(subject.current !== manager)
    }

    // MARK: The bound

    /// **Eviction is asserted by counting it, not by inferring it from an absence.** A store that
    /// silently kept nothing at all would satisfy "the ninth document evicted the first".
    @Test func onlyTheLastFewDocumentsKeepTheirHistory() {
        let subject = store(limit: 3)
        for name in ["a", "b", "c"] {
            subject.activate(path: "/n/\(name).md", text: name)
            subject.remember(text: name)
        }
        #expect(subject.keptCount == 3)
        #expect(subject.evictedCount == 0)

        subject.activate(path: "/n/d.md", text: "d")
        subject.remember(text: "d")
        #expect(subject.keptCount == 3, "the store grew past its limit")
        #expect(subject.evictedCount == 1, "nothing was evicted")

        // `a` was the oldest, so it is the one that lost its history.
        subject.activate(path: "/n/a.md", text: "a")
        let afterEviction = subject.current
        subject.remember(text: "a")
        subject.activate(path: "/n/c.md", text: "c")
        subject.remember(text: "c")
        subject.activate(path: "/n/a.md", text: "a")
        #expect(subject.current === afterEviction, "the rebuilt stack was dropped too")
    }

    /// Least-recently-USED, not least-recently-opened: revisiting a document moves it back to the
    /// front, so a file you keep returning to is not evicted by files you opened once.
    @Test func revisitingADocumentProtectsIt() {
        let subject = store(limit: 2)
        subject.activate(path: "/n/a.md", text: "a"); subject.remember(text: "a")
        subject.activate(path: "/n/b.md", text: "b"); subject.remember(text: "b")
        // Touch a again, making b the oldest.
        subject.activate(path: "/n/a.md", text: "a")
        let managerA = subject.current
        subject.remember(text: "a")
        subject.activate(path: "/n/c.md", text: "c"); subject.remember(text: "c")

        subject.activate(path: "/n/a.md", text: "a")
        #expect(subject.current === managerA, "the revisited document was evicted anyway")
    }

    @Test func everyStackIsDepthBounded() {
        let subject = store()
        subject.activate(path: "/n/a.md", text: "a")
        #expect(subject.current.levelsOfUndo == EditorUndoStore.levelsOfUndo,
                "an unbounded stack can hold every block ever deleted from one file")
    }

    // MARK: Forgetting

    @Test func forgettingDropsAStackAndTheOpenOnesActions() {
        let subject = store()
        subject.activate(path: "/n/a.md", text: "a")
        let manager = subject.current
        subject.remember(text: "a")
        subject.forget("/n/a.md")
        #expect(subject.keptCount == 0)

        subject.activate(path: "/n/a.md", text: "a")
        #expect(subject.current !== manager, "a forgotten stack came back")
    }

    /// A stack for a file that is no longer there can never be handed back, so keeping it holds
    /// memory for an outcome that cannot happen.
    @Test func aStackForAVanishedFileIsDropped() throws {
        let folder = NSTemporaryDirectory() + "undo-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent("gone.md")
        try "x".write(toFile: path, atomically: true, encoding: .utf8)

        let subject = store()
        subject.activate(path: path, text: "x")
        subject.remember(text: "x")
        #expect(subject.keptCount == 1)

        try FileManager.default.removeItem(atPath: path)
        subject.forgetMissingFiles()
        #expect(subject.keptCount == 0, "the history of a deleted file was kept")
    }

    /// The positive control for the sweep above: a file that is still there keeps its history.
    @Test func aStackForAFileThatStillExistsIsKept() throws {
        let folder = NSTemporaryDirectory() + "undo-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent("here.md")
        try "x".write(toFile: path, atomically: true, encoding: .utf8)

        let subject = store()
        subject.activate(path: path, text: "x")
        subject.remember(text: "x")
        subject.forgetMissingFiles()
        #expect(subject.keptCount == 1, "the sweep took a file that is still there")
    }
}
