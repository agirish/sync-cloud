import Testing
import Foundation
@testable import FileExplorer

/// One undo stack per document: that it survives a round trip, and — the half that matters — that
/// it is refused when it no longer fits the buffer.
@MainActor
@Suite final class EditorUndoStoreTests {

    /// **A class, for its `deinit`** — Swift Testing makes one instance per test, so the two tests
    /// that need real files put them in one folder the instance owns and removes when it goes. They
    /// each left a folder behind in the temporary directory before.
    let folder = NSTemporaryDirectory() + "undo-" + UUID().uuidString

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func store(limit: Int = 8) -> EditorUndoStore { EditorUndoStore(limit: limit) }

    /// Gives the open document something to undo — **a history worth keeping**: a document with
    /// nothing to undo or redo is not kept at all (2026-10-09), so every round trip below edits.
    private func edit(_ subject: EditorUndoStore) {
        subject.current.registerUndo(withTarget: subject) { _ in }
    }

    /// A file inside this test's own folder.
    private func file(_ name: String, _ body: String = "x") throws -> String {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent(name)
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func aDocumentGetsItsOwnStackAndKeepsIt() {
        let subject = store()
        subject.activate(path: "/n/a.md", text: "one")
        let first = subject.current

        edit(subject); subject.remember(text: "one")
        subject.activate(path: "/n/b.md", text: "two")
        #expect(subject.current !== first, "two documents shared one stack")

        edit(subject); subject.remember(text: "two")
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
        edit(subject); subject.remember(text: "the edited text")

        subject.activate(path: "/n/b.md", text: "elsewhere")
        edit(subject); subject.remember(text: "elsewhere")

        // Back to a.md, but the file on disk is what it was before the edits.
        subject.activate(path: "/n/a.md", text: "the ORIGINAL text")
        #expect(subject.current !== edited, "a stale stack was handed back")
    }

    /// **Equal strings, different bytes — and the stack is refused.**
    ///
    /// The fingerprint hashes the buffer's UTF-8 rather than the `String`, which is what took a
    /// 4 MiB file switch from 162 ms to 19 ms — see ``EditorUndoStore/Fingerprint``. This is the
    /// behaviour that bought: Swift compares and hashes strings for Unicode canonical equivalence,
    /// so these two are `==` and used to fingerprint alike, and the length field cannot separate
    /// them either because both are five UTF-8 bytes. Only the hash can, and now it does.
    ///
    /// **Refusing is the point, not a regression.** The bytes on disk differ, so a save of one over
    /// the other writes a different file — and this type's rule is that refusing costs a lost
    /// history while replaying a stale stack costs the app.
    @Test func aStackIsRefusedWhenTheBytesChangedUnderAnEqualString() {
        // q + dot-below + dot-above, against q + dot-above + dot-below.
        let first = "q\u{0323}\u{0307}"
        let second = "q\u{0307}\u{0323}"
        // The premise, asserted rather than assumed: Swift cannot tell these apart, and neither can
        // the length. If either of these ever stops holding, this test is measuring nothing.
        #expect(first == second, "fixture: these must be canonically equivalent")
        #expect(Array(first.utf8) != Array(second.utf8), "fixture: their bytes must differ")
        #expect(first.utf8.count == second.utf8.count, "fixture: the length must not separate them")

        let subject = store()
        subject.activate(path: "/n/a.md", text: first)
        let stack = subject.current
        edit(subject); subject.remember(text: first)

        subject.activate(path: "/n/b.md", text: "elsewhere")
        edit(subject); subject.remember(text: "elsewhere")

        subject.activate(path: "/n/a.md", text: second)
        #expect(subject.current !== stack,
                "a stack was handed back to a buffer holding different bytes")
    }

    /// The same text at the same path is the same buffer, whatever route it arrived by.
    @Test func anIdenticalBufferKeepsItsStack() {
        let subject = store()
        subject.activate(path: "/n/a.md", text: "same")
        let manager = subject.current
        edit(subject); subject.remember(text: "same")
        subject.activate(path: "/n/a.md", text: "same")
        #expect(subject.current === manager)
    }

    @Test func nothingOpenGetsAFreshStack() {
        let subject = store()
        subject.activate(path: "/n/a.md", text: "one")
        let manager = subject.current
        edit(subject); subject.remember(text: "one")
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
            edit(subject); subject.remember(text: name)
        }
        #expect(subject.keptCount == 3)
        #expect(subject.evictedCount == 0)

        subject.activate(path: "/n/d.md", text: "d")
        edit(subject); subject.remember(text: "d")
        #expect(subject.keptCount == 3, "the store grew past its limit")
        #expect(subject.evictedCount == 1, "nothing was evicted")

        // `a` was the oldest, so it is the one that lost its history.
        subject.activate(path: "/n/a.md", text: "a")
        let afterEviction = subject.current
        edit(subject); subject.remember(text: "a")
        subject.activate(path: "/n/c.md", text: "c")
        edit(subject); subject.remember(text: "c")
        subject.activate(path: "/n/a.md", text: "a")
        #expect(subject.current === afterEviction, "the rebuilt stack was dropped too")
    }

    /// Least-recently-USED, not least-recently-opened: revisiting a document moves it back to the
    /// front, so a file you keep returning to is not evicted by files you opened once.
    @Test func revisitingADocumentProtectsIt() {
        let subject = store(limit: 2)
        subject.activate(path: "/n/a.md", text: "a"); edit(subject); subject.remember(text: "a")
        subject.activate(path: "/n/b.md", text: "b"); edit(subject); subject.remember(text: "b")
        // Touch a again, making b the oldest.
        subject.activate(path: "/n/a.md", text: "a")
        let managerA = subject.current
        edit(subject); subject.remember(text: "a")
        subject.activate(path: "/n/c.md", text: "c"); edit(subject); subject.remember(text: "c")

        subject.activate(path: "/n/a.md", text: "a")
        #expect(subject.current === managerA, "the revisited document was evicted anyway")
    }

    /// **The file being opened is never the one evicted** (UND-7). Eviction runs on the way OUT of
    /// a document, before the incoming one is activated — so with the incoming file the least
    /// recently used, cycling through one more edited file than the limit dropped each file's
    /// history at the very moment it was reopened. Limit 2: a, b and c edited in turn, then a again.
    /// Mutation: evict `order.first` regardless of `opening` and a's stack is gone.
    @Test func theFileBeingOpenedIsNeverEvicted() {
        let subject = store(limit: 2)
        subject.activate(path: "/n/a.md", text: "a")
        let managerA = subject.current
        edit(subject); subject.remember(text: "a", opening: "/n/b.md")
        subject.activate(path: "/n/b.md", text: "b")
        let managerB = subject.current
        edit(subject); subject.remember(text: "b", opening: "/n/c.md")
        subject.activate(path: "/n/c.md", text: "c")
        edit(subject); subject.remember(text: "c", opening: "/n/a.md")
        #expect(subject.evictedCount == 1, "the limit was not enforced at all")
        subject.activate(path: "/n/a.md", text: "a")
        #expect(subject.current === managerA, "the file being opened was evicted to make room")
        edit(subject); subject.remember(text: "a", opening: "/n/b.md")
        subject.activate(path: "/n/b.md", text: "b")
        #expect(subject.current !== managerB, "b, the oldest that was not being opened, kept its history past the limit")
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
        edit(subject); subject.remember(text: "a")
        subject.forget("/n/a.md")
        #expect(subject.keptCount == 0)

        subject.activate(path: "/n/a.md", text: "a")
        #expect(subject.current !== manager, "a forgotten stack came back")
    }

    /// A stack for a file that is no longer there can never be handed back, so keeping it holds
    /// memory for an outcome that cannot happen.
    @Test func aStackForAVanishedFileIsDropped() throws {
        let path = try file("gone.md")

        let subject = store()
        subject.activate(path: path, text: "x")
        edit(subject); subject.remember(text: "x")
        #expect(subject.keptCount == 1)

        try FileManager.default.removeItem(atPath: path)
        subject.forgetMissingFiles()
        #expect(subject.keptCount == 0, "the history of a deleted file was kept")
    }

    /// The positive control for the sweep above: a file that is still there keeps its history.
    @Test func aStackForAFileThatStillExistsIsKept() throws {
        let path = try file("here.md")

        let subject = store()
        subject.activate(path: path, text: "x")
        edit(subject); subject.remember(text: "x")
        subject.forgetMissingFiles()
        #expect(subject.keptCount == 1, "the sweep took a file that is still there")
    }

    // MARK: The text storage kept beside each stack (TE67.0)

    /// **A stack comes back with the storage its actions edit.** An `NSTextView` registers undo
    /// against its storage, so a stack handed back beside a different one reverts text nobody can
    /// see — the mode-switch defect, reached by a file switch instead.
    @Test func aStackComesBackWithTheStorageItsActionsEdit() {
        let subject = store()
        subject.activate(path: "/n/a.md", text: "one")
        let storageA = subject.source
        edit(subject); subject.remember(text: "one")
        subject.activate(path: "/n/b.md", text: "two")
        #expect(subject.source !== storageA, "two documents shared one storage")
        #expect(subject.source.text == "two")
        edit(subject); subject.remember(text: "two")

        subject.activate(path: "/n/a.md", text: "one")
        #expect(subject.source === storageA, "the stack came back without the storage its actions edit")
    }

    /// **A refused stack takes its storage with it** — the fingerprint refusal, one level down. The
    /// storage holds the text the stack was made against; handing it back to a buffer that loaded
    /// something else would put that text on screen.
    @Test func aRefusedStackTakesItsStorageWithIt() {
        let subject = store()
        subject.activate(path: "/n/a.md", text: "the edited text")
        let edited = subject.source
        edit(subject); subject.remember(text: "the edited text")
        subject.activate(path: "/n/b.md", text: "elsewhere")
        edit(subject); subject.remember(text: "elsewhere")

        subject.activate(path: "/n/a.md", text: "the ORIGINAL text")
        #expect(subject.source !== edited, "a stale storage was handed back with a refused stack")
        #expect(subject.source.text == "the ORIGINAL text", "the fresh storage does not hold what was loaded")
        #expect(subject.source.textStorage.string == "the ORIGINAL text")
    }

    /// **The next load cannot write into the storage just put away.** `remember` runs before the
    /// buffer is replaced; a storage still attached would take the incoming file's text in, against
    /// a fingerprint of what it held — and be handed back holding the wrong file. Mutation: drop
    /// `source.buffer = nil` from `remember`.
    @Test func aKeptStorageIsNotWrittenByTheNextLoad() {
        let subject = store()
        let buffer = EditorBuffer()
        buffer.text = "one"
        subject.activate(path: "/n/a.md", text: "one")
        buffer.follow(subject.source)
        let storageA = subject.source

        edit(subject); subject.remember(text: buffer.text)
        buffer.text = "the next file"        // what `EditorDocument.open` does next
        #expect(storageA.textStorage.string == "one", "the load wrote the next file into a kept storage")

        subject.activate(path: "/n/b.md", text: buffer.text)
        buffer.follow(subject.source)
        #expect(buffer.source === subject.source)
        #expect(buffer.source.textStorage.string == "the next file")
    }

    /// Nothing open gets a fresh, empty storage beside its fresh stack.
    @Test func nothingOpenGetsAFreshStorage() {
        let subject = store()
        subject.activate(path: "/n/a.md", text: "one")
        let storageA = subject.source
        edit(subject); subject.remember(text: "one")
        subject.activate(path: nil, text: "")
        #expect(subject.source !== storageA)
        #expect(subject.source.text.isEmpty)
    }

    /// **Eviction releases the storage with the stack** — the memory the bound exists for. Asserted
    /// by the storage going away, not by the count alone.
    @Test func evictionReleasesTheStorageWithTheStack() {
        let subject = store(limit: 1)
        weak var storageA: EditorSourceStorage?
        autoreleasepool {
            subject.activate(path: "/n/a.md", text: "a")
            storageA = subject.source
            edit(subject); subject.remember(text: "a")
            subject.activate(path: "/n/b.md", text: "b"); edit(subject); subject.remember(text: "b")
            subject.activate(path: "/n/c.md", text: "c"); edit(subject); subject.remember(text: "c")
        }
        #expect(subject.evictedCount >= 1)
        #expect(storageA == nil, "an evicted document's storage was kept alive")
    }

    // MARK: Nothing to undo, nothing kept (2026-10-09)

    /// **A document opened only to be read keeps nothing.** Its stack is empty, and since TE67.0 the
    /// entry would also hold its whole text storage — up to 4 MiB of text as UTF-16, per file
    /// visited, for a history with nothing in it. Coming back builds a fresh one from what loads.
    @Test func aDocumentWithNothingToUndoKeepsNothing() {
        let subject = store()
        let text = String(repeating: "read only ", count: 1_000)
        weak var storage: EditorSourceStorage?
        autoreleasepool {
            subject.activate(path: "/n/read.md", text: text)
            storage = subject.source
            subject.remember(text: text)
            subject.activate(path: "/n/b.md", text: "b")
        }
        #expect(subject.keptCount == 0, "an empty history was kept")
        #expect(storage == nil, "an unedited document's storage was kept alive")
        subject.remember(text: "b")
        subject.activate(path: "/n/read.md", text: text)
        #expect(subject.source.text == text, "coming back did not show what loaded")
        #expect(!subject.current.canUndo)
    }

    /// **And files only read never push an edited file's history out.** With the limit at two,
    /// reading three files used to evict the one history that had anything in it.
    @Test func filesOnlyReadDoNotEvictAnEditedFilesHistory() {
        let subject = store(limit: 2)
        subject.activate(path: "/n/edited.md", text: "e")
        edit(subject)
        let manager = subject.current
        subject.remember(text: "e")
        for name in ["a", "b", "c"] {
            subject.activate(path: "/n/\(name).md", text: name)
            subject.remember(text: name)
        }
        #expect(subject.evictedCount == 0, "a read file took a slot")
        subject.activate(path: "/n/edited.md", text: "e")
        #expect(subject.current === manager, "the edited file's history was evicted by files only read")
    }

    // MARK: One storage from the start (2026-10-09)

    /// **The store starts on the buffer's own storage**, so the first load writes into neither.
    /// They used to start with one each: `remember` let go of the store's, the load then wrote the
    /// whole file into the buffer's — a storage about to be thrown away — and a view mounted on it
    /// logged "storage resync … with no undo" for a write nothing was wrong with.
    @Test func theFirstLoadWritesIntoNoStorage() {
        let buffer = EditorBuffer()
        let initial = buffer.source
        let subject = store()
        subject.adopt(buffer.source)
        #expect(subject.source === initial)
        subject.remember(text: buffer.text)          // `EditorDocumentLoad.run`'s order
        buffer.text = "the first file"
        subject.activate(path: "/n/a.md", text: buffer.text)
        buffer.follow(subject.source)
        #expect(initial.textStorage.length == 0, "the load wrote into a storage it then threw away")
        #expect(buffer.source.textStorage.string == "the first file")
    }

    /// **Never once a document is open**: its stack's actions edit the storage beside it, and a
    /// different one adopted under them would be the mode-switch defect again.
    @Test func adoptingIsRefusedOnceADocumentIsOpen() {
        let subject = store()
        subject.activate(path: "/n/a.md", text: "a")
        let mine = subject.source
        subject.adopt(EditorSourceStorage(text: "a"))
        #expect(subject.source === mine)
    }
}
